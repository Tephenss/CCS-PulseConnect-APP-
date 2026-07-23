import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'config/env.dart';
import 'screens/student/student_home.dart';
import 'screens/teacher/teacher_home.dart';
import 'screens/welcome_screen.dart';
import 'services/auth_service.dart';
import 'services/live_ui_sync.dart';
import 'services/offline_backup_service.dart';
import 'services/offline_sync_service.dart';
import 'services/push_notification_service.dart';
import 'utils/course_theme_utils.dart';
import 'utils/teacher_theme_utils.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Never leave Flutter debug outlines on (green widget/size borders).
  debugPaintSizeEnabled = false;
  debugPaintBaselinesEnabled = false;
  debugPaintLayerBordersEnabled = false;
  debugPaintPointersEnabled = false;
  debugRepaintRainbowEnabled = false;

  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.light,
      systemNavigationBarColor: Colors.white,
      systemNavigationBarDividerColor: Colors.transparent,
      systemNavigationBarIconBrightness: Brightness.dark,
    ),
  );

  try {
    await OfflineBackupService().autoRestoreIfNeeded();
  } catch (e) {
    debugPrint('Automatic restore skipped: $e');
  }

  var firebaseReady = false;
  try {
    await Firebase.initializeApp();
    firebaseReady = true;
  } catch (e) {
    debugPrint('Firebase init skipped: $e');
  }

  await Supabase.initialize(
    url: Env.supabaseUrl,
    anonKey: Env.supabaseAnonKey,
  );

  if (firebaseReady) {
    await PushNotificationService().initialize();
  }

  final authService = AuthService();
  var isLoggedIn = await authService.isLoggedIn();
  String role = 'student';
  String studentCourse = 'IT';

  if (isLoggedIn) {
    final serverUser = await authService.refreshCurrentUserFromServer();
    final userData = serverUser ?? await authService.getCurrentUser();
    role = userData?['role']?.toString().toLowerCase() ?? 'student';
    studentCourse = CourseThemeUtils.normalizeCourse(userData?['course']) == 'CS'
        ? 'CS'
        : 'IT';

    // Daily OTP reset (12:00 AM Asia/Manila) OR known-untrusted IP:
    // force logout so the user must re-login + verify before entering home.
    // If public IP cannot be resolved yet, keep the session (avoid false logout).
    // Note: mid-session enforce (resume/idle) is daily-only — see
    // [_enforceDailyVerificationLogout] — so IP churn won't kick open screens.
    if (await authService.requiresEmailVerification(
      userData,
      unknownTrustRequiresVerification: false,
    )) {
      await authService.logout();
      isLoggedIn = false;
      role = 'student';
      studentCourse = 'IT';
    } else if (firebaseReady) {
      await PushNotificationService().updateToken();
      // Keep trust fresh while this install stays active.
      final uid = userData?['id']?.toString().trim() ?? '';
      if (uid.isNotEmpty) {
        unawaited(authService.trustCurrentDevice(uid));
      }
    }
  } else if (firebaseReady) {
    // Clear orphan device tokens left after OTP/logout so Welcome/Login
    // screens never receive account pushes.
    await PushNotificationService().unregisterCurrentToken();
  }

  runApp(
    PulseConnectApp(
      isLoggedIn: isLoggedIn,
      userRole: role,
      studentCourse: studentCourse,
    ),
  );
}

class PulseConnectApp extends StatefulWidget {
  final bool isLoggedIn;
  final String userRole;
  final String studentCourse;

  static final GlobalKey<NavigatorState> navigatorKey =
      GlobalKey<NavigatorState>();
  static final GlobalKey<ScaffoldMessengerState> scaffoldMessengerKey =
      GlobalKey<ScaffoldMessengerState>();

  const PulseConnectApp({
    super.key,
    required this.isLoggedIn,
    required this.userRole,
    required this.studentCourse,
  });

  static PulseConnectAppState of(BuildContext context) =>
      context.findAncestorStateOfType<PulseConnectAppState>()!;

  @override
  State<PulseConnectApp> createState() => PulseConnectAppState();
}

class PulseConnectAppState extends State<PulseConnectApp>
    with WidgetsBindingObserver {
  late String _currentRole;
  late String _currentStudentCourse;
  final AuthService _authService = AuthService();
  final OfflineSyncService _offlineSyncService = OfflineSyncService();
  final OfflineBackupService _offlineBackupService = OfflineBackupService();
  final Connectivity _connectivity = Connectivity();
  StreamSubscription<List<ConnectivityResult>>? _connectivitySubscription;
  Timer? _offlineWarmupTimer;
  Timer? _dailyVerificationTimer;
  bool _isEnforcingDailyVerification = false;
  bool? _isOffline;
  bool? _lastShownConnectivityState;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _currentRole = widget.userRole;
    _currentStudentCourse = widget.studentCourse;
    _startConnectivityMonitoring();
    _startOfflineWarmupTicker();
    _scheduleDailyVerificationCheck();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_enforceDailyVerificationLogout());
    });
  }

  /// Manila calendar-day boundary (UTC+8).
  Duration _durationUntilNextManilaMidnight() {
    const tzOffset = Duration(hours: 8);
    final nowLocal = DateTime.now().toUtc().add(tzOffset);
    final nextMidnight = DateTime(
      nowLocal.year,
      nowLocal.month,
      nowLocal.day,
    ).add(const Duration(days: 1));
    final wait = nextMidnight.difference(nowLocal);
    if (wait <= Duration.zero) {
      return const Duration(seconds: 1);
    }
    return wait;
  }

  void _scheduleDailyVerificationCheck() {
    _dailyVerificationTimer?.cancel();
    _dailyVerificationTimer = Timer(_durationUntilNextManilaMidnight(), () {
      unawaited(_enforceDailyVerificationLogout());
      _scheduleDailyVerificationCheck();
    });
  }

  Future<void> _enforceDailyVerificationLogout() async {
    if (_isEnforcingDailyVerification) return;
    if (AuthService.isAuthFlowBusy) return;
    _isEnforcingDailyVerification = true;
    try {
      final loggedIn = await _authService.isLoggedIn();
      if (!loggedIn) return;
      if (AuthService.isAuthFlowBusy) return;

      final user = await _authService.getCurrentUser();
      // Transient prefs/session read failure — never kick a live session.
      if (user == null) return;

      // Mid-session: ONLY Manila 12:00 AM day rollover forces re-login.
      // Do NOT logout for IP/network changes while the user is idle on a page
      // (carrier IP churn / brief offline was sending people to Welcome).
      final verifiedAtRaw = (user['email_verified_at']?.toString() ?? '').trim();
      if (verifiedAtRaw.isEmpty) {
        // Incomplete cached profile — keep session; login gate still enforces OTP.
        return;
      }
      if (!AuthService.requiresDailyEmailVerification(user)) {
        // Still online on a trusted day — refresh trust quietly (no logout).
        final uid = user['id']?.toString().trim() ?? '';
        if (uid.isNotEmpty) {
          unawaited(_authService.trustCurrentDevice(uid));
        }
        return;
      }
      if (AuthService.isAuthFlowBusy) return;

      await _authService.logout();
      final nav = PulseConnectApp.navigatorKey.currentState;
      if (nav == null) return;
      nav.pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => const WelcomeScreen()),
        (_) => false,
      );
    } finally {
      _isEnforcingDailyVerification = false;
    }
  }

  bool _resultsAreOffline(List<ConnectivityResult> results) {
    return results.isEmpty ||
        results.every((result) => result == ConnectivityResult.none);
  }

  Future<void> _primeOfflineReadiness({bool syncQueue = false}) async {
    try {
      final user = await _authService.getCurrentUser();
      if (user == null) {
        await _offlineBackupService.autoBackupIfConfigured();
        return;
      }

      final actorId = (user['id']?.toString() ?? '').trim();
      final role = (user['role']?.toString() ?? '').trim().toLowerCase();
      if (actorId.isEmpty) {
        await _offlineBackupService.autoBackupIfConfigured();
        return;
      }

      final isTeacher = role == 'teacher';
      if (syncQueue) {
        await _offlineSyncService.syncPendingQueue(
          actorId: actorId,
          isTeacher: isTeacher,
        );
      }
      await _offlineSyncService.refreshSnapshotForCurrentScanner(
        actorId: actorId,
        isTeacher: isTeacher,
      );
      await _offlineBackupService.autoBackupIfConfigured();
    } catch (_) {
      // Keep app bootstrap resilient.
    }
  }

  void _showConnectivityNotice({required bool offline}) {
    _lastShownConnectivityState = offline;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final messenger = PulseConnectApp.scaffoldMessengerKey.currentState;
      if (messenger == null) return;
      messenger.clearSnackBars();
      messenger.showSnackBar(
        SnackBar(
          behavior: SnackBarBehavior.floating,
          backgroundColor: offline
              ? const Color(0xFFD97706)
              : const Color(0xFF047857),
          content: Text(
            offline
                ? 'Offline mode detected. Using the latest synced data on this device.'
                : 'You are back online. Syncing the latest data now.',
          ),
        ),
      );
    });
  }

  Future<void> _startConnectivityMonitoring() async {
    final initial = await _connectivity.checkConnectivity();
    if (!mounted) return;
    _isOffline = _resultsAreOffline(initial);
    if (_isOffline == false) {
      unawaited(_primeOfflineReadiness(syncQueue: true));
    } else {
      unawaited(_offlineBackupService.autoBackupIfConfigured());
    }
    _lastShownConnectivityState = _isOffline;

    _connectivitySubscription = _connectivity.onConnectivityChanged.listen((
      results,
    ) {
      final offline = _resultsAreOffline(results);
      final previous = _isOffline;
      _isOffline = offline;
      if (previous != null && previous != offline) {
        _showConnectivityNotice(offline: offline);
      }
      if (offline) {
        unawaited(_offlineBackupService.autoBackupIfConfigured());
      } else {
        unawaited(_primeOfflineReadiness(syncQueue: true));
      }
    });
  }

  void _startOfflineWarmupTicker() {
    _offlineWarmupTimer?.cancel();
    _offlineWarmupTimer = Timer.periodic(const Duration(seconds: 60), (_) {
      if (_isOffline == false) {
        unawaited(_primeOfflineReadiness());
      }
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_reconcileConnectivityState());
      unawaited(_enforceDailyVerificationLogout());
      _scheduleDailyVerificationCheck();
      // Catch up lists/bell if a push arrived while backgrounded (FCM
      // notification payloads do not run Dart onMessage in background).
      unawaited(() async {
        if (await _authService.isLoggedIn()) {
          await LiveUiSync.syncNow('resume');
        }
      }());
      if (_isOffline == false || _isOffline == null) {
        unawaited(_primeOfflineReadiness(syncQueue: true));
      }
      return;
    }

    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      unawaited(_offlineBackupService.autoBackupIfConfigured());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _connectivitySubscription?.cancel();
    _offlineWarmupTimer?.cancel();
    _dailyVerificationTimer?.cancel();
    super.dispose();
  }

  Future<void> _reconcileConnectivityState() async {
    final current = _resultsAreOffline(await _connectivity.checkConnectivity());
    final previous = _isOffline;
    _isOffline = current;

    if (previous != null && previous != current) {
      _showConnectivityNotice(offline: current);
      return;
    }

    if (_lastShownConnectivityState != current) {
      _showConnectivityNotice(offline: current);
    }
  }

  void updateTheme(String role, {String? course}) {
    final normalizedRole = role.toLowerCase();
    final nextCourse = normalizedRole == 'student'
        ? (CourseThemeUtils.isComputerScienceCourse(course) ? 'CS' : 'IT')
        : _currentStudentCourse;
    if (_currentRole != role || _currentStudentCourse != nextCourse) {
      setState(() {
        _currentRole = role;
        _currentStudentCourse = nextCourse;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorKey: PulseConnectApp.navigatorKey,
      scaffoldMessengerKey: PulseConnectApp.scaffoldMessengerKey,
      title: 'CCS PulseConnect',
      debugShowCheckedModeBanner: false,
      theme: _getTheme(_currentRole, _currentStudentCourse),
      builder: (context, child) {
        // Seal the root so no theme/seed color can peek through as edge lines.
        return ColoredBox(
          color: Colors.white,
          child: child ?? const SizedBox.shrink(),
        );
      },
      home: widget.isLoggedIn
          ? (_currentRole.toLowerCase() == 'teacher'
                ? const TeacherHome()
                : const StudentHome())
          : const WelcomeScreen(),
    );
  }

  ThemeData _getTheme(String role, String studentCourse) {
    final isStudent = role.toLowerCase() == 'student';
    final primaryColor = isStudent
        ? CourseThemeUtils.studentPrimaryForCourse(studentCourse)
        : TeacherThemeUtils.primary;
    final secondaryColor = isStudent
        ? CourseThemeUtils.studentSecondaryForCourse(studentCourse)
        : const Color(0xFFD4A843);

    return ThemeData(
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(
        seedColor: primaryColor,
        primary: primaryColor,
        secondary: secondaryColor,
        surface: Colors.white,
        brightness: Brightness.light,
      ).copyWith(
        surface: Colors.white,
        surfaceContainerLowest: Colors.white,
        surfaceContainerLow: const Color(0xFFF8F9FA),
        surfaceContainer: const Color(0xFFF3F4F6),
        surfaceContainerHigh: const Color(0xFFE5E7EB),
        surfaceContainerHighest: const Color(0xFFE5E7EB),
        surfaceTint: Colors.transparent,
      ),
      textTheme: GoogleFonts.interTextTheme(),
      scaffoldBackgroundColor: Colors.white,
      appBarTheme: AppBarTheme(
        backgroundColor: primaryColor,
        foregroundColor: Colors.white,
        elevation: 0,
        centerTitle: true,
        surfaceTintColor: Colors.transparent,
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: primaryColor,
          foregroundColor: Colors.white,
          padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 16),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
          textStyle: const TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: Colors.white,
        contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: Colors.grey.shade300),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: Colors.grey.shade300),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: primaryColor, width: 2),
        ),
      ),
    );
  }
}
