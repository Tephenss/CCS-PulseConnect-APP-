import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'config/env.dart';
import 'screens/auth/email_verification_screen.dart';
import 'screens/auth/login_screen.dart';
import 'screens/student/student_home.dart';
import 'screens/teacher/teacher_home.dart';
import 'screens/welcome_screen.dart';
import 'widgets/pulseconnect_splash_screen.dart';
import 'services/auth_service.dart';
import 'services/device_performance_service.dart';
import 'services/live_ui_sync.dart';
import 'services/offline_backup_service.dart';
import 'services/offline_sync_service.dart';
import 'services/push_notification_service.dart';
import 'services/notification_service.dart';
import 'utils/course_theme_utils.dart';
import 'utils/teacher_theme_utils.dart';
import 'utils/app_restarter.dart';
import 'utils/app_page_routes.dart';
import 'widgets/app_snackbar.dart';

void _disableFlutterDebugOutlines() {
  // Flutter debug paint / inspector draws a neon green-cyan border around the
  // whole screen. Force it off every time — DevTools can turn it back on.
  debugPaintSizeEnabled = false;
  debugPaintBaselinesEnabled = false;
  debugPaintLayerBordersEnabled = false;
  debugPaintPointersEnabled = false;
  debugRepaintRainbowEnabled = false;
  debugProfilePaintsEnabled = false;
  debugProfileLayoutsEnabled = false;
  debugDisableClipLayers = false;
  debugDisablePhysicalShapeLayers = false;
  debugDisableOpacityLayers = false;
  WidgetsApp.debugShowWidgetInspectorOverride = false;
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  _disableFlutterDebugOutlines();

  // Detect low/mid/high device + load Performance Mode preference.
  await DevicePerformance.instance.init();

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
    var courseNorm = CourseThemeUtils.normalizeCourse(userData?['course']);
    if (courseNorm != 'CS' && courseNorm != 'IT') {
      final fromSection = await authService.getStudentCourseCode();
      courseNorm = CourseThemeUtils.normalizeCourse(fromSection);
    }
    studentCourse = courseNorm == 'CS' ? 'CS' : 'IT';

    // Daily OTP reset (12:00 AM Asia/Manila): clear in-app session so the
    // user must re-login + verify. Keep FCM token (same phone / same person).
    // Install trust miss is handled at the login gate (not here) so a brief
    // API blip / first-boot does not wipe a still-valid session.
    if (AuthService.requiresDailyEmailVerification(userData)) {
      await authService.logout(unregisterPush: false);
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
    // Manual/orphan logout: drop device token. Daily OTP gate keeps it.
    if (!await AuthService.shouldKeepFcmToken()) {
      await PushNotificationService().unregisterCurrentToken();
    }
  }

  runApp(
    AppRestarter.wrap(
      PulseConnectApp(
        isLoggedIn: isLoggedIn,
        userRole: role,
        studentCourse: studentCourse,
      ),
    ),
  );
}

class PulseConnectApp extends StatefulWidget {
  final bool isLoggedIn;
  final String userRole;
  final String studentCourse;

  static GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();
  static GlobalKey<ScaffoldMessengerState> scaffoldMessengerKey =
      GlobalKey<ScaffoldMessengerState>();

  /// Fresh navigator keys after a Performance Mode remount.
  static void rotateRootKeys() {
    navigatorKey = GlobalKey<NavigatorState>();
    scaffoldMessengerKey = GlobalKey<ScaffoldMessengerState>();
  }

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
  /// Shown as MaterialApp.home so IME/system-back cannot pop to Welcome.
  Map<String, dynamic>? _emailOtpUser;
  String? _emailOtpGateReason;
  bool _emailOtpPostRegistration = false;
  String? _loginRoleOverride;
  late bool _enteredApp;
  /// Soft remount (Performance Mode) must re-read prefs — widget.isLoggedIn is
  /// only the cold-start value from main() and goes stale after login.
  bool _sessionHydrating = false;

  /// Survives [AppRestarter] remounts so teacher/CS splash does not flash maroon
  /// for one frame while prefs hydrate (widget.userRole is still main()'s value).
  static String? _cachedRole;
  static String? _cachedStudentCourse;
  static bool? _cachedEnteredApp;

  String get currentRole => _currentRole;
  String get currentStudentCourse => _currentStudentCourse;

  void _rememberSessionTheme({
    required String role,
    required String studentCourse,
    required bool enteredApp,
  }) {
    _cachedRole = role;
    _cachedStudentCourse = studentCourse;
    _cachedEnteredApp = enteredApp;
  }

  void _clearSessionThemeCache() {
    _cachedRole = null;
    _cachedStudentCourse = null;
    _cachedEnteredApp = null;
  }

  @override
  void initState() {
    super.initState();
    _disableFlutterDebugOutlines();
    WidgetsBinding.instance.addObserver(this);
    // Prefer last-known session over stale constructor args from main().
    _currentRole = _cachedRole ?? widget.userRole;
    _currentStudentCourse = _cachedStudentCourse ?? widget.studentCourse;
    _enteredApp = _cachedEnteredApp ?? widget.isLoggedIn;
    _sessionHydrating = true;
    _rememberSessionTheme(
      role: _currentRole,
      studentCourse: _currentStudentCourse,
      enteredApp: _enteredApp,
    );
    _startConnectivityMonitoring();
    _startOfflineWarmupTicker();
    _scheduleDailyVerificationCheck();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_bootstrapAfterMount());
    });
  }

  Future<void> _bootstrapAfterMount() async {
    try {
      await _hydrateSessionFromStorage();
    } finally {
      if (mounted && _sessionHydrating) {
        setState(() => _sessionHydrating = false);
      } else {
        _sessionHydrating = false;
      }
    }
    // Mid-session soft remount: only Manila-day rollover may log out.
    unawaited(_enforceDailyVerificationLogout());
    if (!mounted) return;
    if (_enteredApp && await _authService.isLoggedIn()) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        unawaited(PushNotificationService().consumePendingTap());
      });
    }
  }

  /// Keep the user logged in across AppRestarter remounts (Performance Mode).
  Future<void> _hydrateSessionFromStorage() async {
    try {
      final loggedIn = await _authService.isLoggedIn();
      if (!mounted) return;

      if (!loggedIn) {
        if (_enteredApp) {
          setState(() {
            _enteredApp = false;
            _emailOtpUser = null;
            _loginRoleOverride = null;
          });
        }
        _clearSessionThemeCache();
        return;
      }

      final user = await _authService.getCurrentUser();
      if (user == null || !mounted) return;

      final role = (user['role']?.toString() ?? 'student').toLowerCase();
      var courseNorm = CourseThemeUtils.normalizeCourse(user['course']);
      if (courseNorm != 'CS' && courseNorm != 'IT') {
        final fromSection = await _authService.getStudentCourseCode();
        final sectionNorm = CourseThemeUtils.normalizeCourse(fromSection);
        if (sectionNorm == 'CS' || sectionNorm == 'IT') {
          courseNorm = sectionNorm;
        }
      }
      final course = courseNorm == 'CS' ? 'CS' : 'IT';

      if (_enteredApp &&
          _currentRole.toLowerCase() == role &&
          (role != 'student' || _currentStudentCourse == course)) {
        _rememberSessionTheme(
          role: _currentRole,
          studentCourse: _currentStudentCourse,
          enteredApp: true,
        );
        return;
      }

      setState(() {
        _enteredApp = true;
        _currentRole = role;
        if (role == 'student') {
          _currentStudentCourse = course;
        }
        _loginRoleOverride = null;
        _emailOtpUser = null;
        _emailOtpGateReason = null;
        _emailOtpPostRegistration = false;
      });
      _rememberSessionTheme(
        role: _currentRole,
        studentCourse: _currentStudentCourse,
        enteredApp: true,
      );
    } catch (e) {
      debugPrint('Session hydrate after remount skipped: $e');
    }
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
    // Never kick during login OTP / register OTP — that flow IS the daily gate.
    if (_emailOtpUser != null || AuthService.isOtpGateActive) return;
    if (!_enteredApp) return;
    if (AuthService.isAuthFlowBusy) return;
    _isEnforcingDailyVerification = true;
    try {
      final loggedIn = await _authService.isLoggedIn();
      if (!loggedIn) return;
      if (_emailOtpUser != null || AuthService.isOtpGateActive) return;
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
      if (AuthService.isAuthFlowBusy || AuthService.isOtpGateActive) return;

      await _authService.logout(unregisterPush: false);
      if (!mounted) return;
      setState(() {
        _enteredApp = false;
        _emailOtpUser = null;
        _loginRoleOverride = null;
      });
      _clearSessionThemeCache();
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

  /// MaterialApp.home is only applied on the first frame. After Welcome→Login
  /// pushes, changing `home` alone does nothing — force a stack replace.
  void _replaceRoot(Widget page) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final nav = PulseConnectApp.navigatorKey.currentState;
      if (nav == null) return;
      nav.pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => page),
        (_) => false,
      );
    });
  }

  Widget _otpPage() {
    final user = _emailOtpUser!;
    final id = user['id']?.toString() ?? 'otp';
    return EmailVerificationScreen(
      key: ValueKey('email-otp-$id'),
      user: user,
      gateReason: _emailOtpGateReason,
      postRegistrationReviewFlow: _emailOtpPostRegistration,
    );
  }

  /// Replace MaterialApp route with OTP (navigator hard-reset).
  void showEmailVerificationGate(
    Map<String, dynamic> user, {
    String? gateReason,
    bool postRegistrationReviewFlow = false,
  }) {
    AuthService.setOtpGateActive(true);
    setState(() {
      _emailOtpUser = Map<String, dynamic>.from(user);
      _emailOtpGateReason = gateReason;
      _emailOtpPostRegistration = postRegistrationReviewFlow;
      _loginRoleOverride = null;
      _enteredApp = false;
    });
    _replaceRoot(_otpPage());
  }

  void showLogin(String role) {
    AuthService.setOtpGateActive(false);
    setState(() {
      _emailOtpUser = null;
      _emailOtpGateReason = null;
      _emailOtpPostRegistration = false;
      _loginRoleOverride = role;
      _enteredApp = false;
      _currentRole = role;
    });
    _rememberSessionTheme(
      role: role,
      studentCourse: _currentStudentCourse,
      enteredApp: false,
    );
    _replaceRoot(
      LoginScreen(key: ValueKey('login-$role'), role: role),
    );
  }

  void exitEmailVerificationToLogin(String role) {
    AuthService.setOtpGateActive(false);
    setState(() {
      _emailOtpUser = null;
      _emailOtpGateReason = null;
      _emailOtpPostRegistration = false;
      _loginRoleOverride = role;
      _enteredApp = false;
    });
    _replaceRoot(
      LoginScreen(key: ValueKey('login-$role'), role: role),
    );
  }

  void exitEmailVerificationToWelcome() {
    AuthService.setOtpGateActive(false);
    setState(() {
      _emailOtpUser = null;
      _emailOtpGateReason = null;
      _emailOtpPostRegistration = false;
      _loginRoleOverride = null;
      _enteredApp = false;
    });
    _clearSessionThemeCache();
    _replaceRoot(const WelcomeScreen());
  }

  /// Call after local logout so Performance Mode remount does not restore
  /// a teacher/student home splash from the previous session cache.
  void clearSessionAfterLogout() {
    _clearSessionThemeCache();
    if (!mounted) return;
    setState(() {
      _enteredApp = false;
      _emailOtpUser = null;
      _emailOtpGateReason = null;
      _emailOtpPostRegistration = false;
      _loginRoleOverride = null;
    });
  }

  void enterAppAfterAuth({required String role, String? course}) {
    AuthService.setOtpGateActive(false);
    final normalizedRole = role.toLowerCase();
    final nextCourse = normalizedRole == 'student'
        ? (CourseThemeUtils.isComputerScienceCourse(course) ? 'CS' : 'IT')
        : _currentStudentCourse;
    setState(() {
      _emailOtpUser = null;
      _emailOtpGateReason = null;
      _emailOtpPostRegistration = false;
      _loginRoleOverride = null;
      _enteredApp = true;
      _currentRole = role;
      _currentStudentCourse = nextCourse;
    });
    _rememberSessionTheme(
      role: _currentRole,
      studentCourse: _currentStudentCourse,
      enteredApp: true,
    );
    _replaceRoot(
      normalizedRole == 'teacher'
          ? const TeacherHome()
          : const StudentHome(),
    );
    unawaited(AuthService.clearFcmKeepFlag());
    unawaited(PushNotificationService().updateToken());
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(PushNotificationService().consumePendingTap());
    });
  }

  Widget _buildRootHome() {
    // Auth screens (Login/OTP) are shown only via _replaceRoot — never as
    // MaterialApp.home — so we don't mount EmailVerificationScreen twice
    // (home rebuild + push) and send two different codes.
    if (_sessionHydrating) {
      // Soft remount (Performance Mode): use cached role so teacher stays blue
      // (not a one-frame maroon flash from stale main() constructor args).
      final isTeacher = _currentRole.toLowerCase() == 'teacher';
      return PulseConnectSplashScreen.aligned(
        role: _currentRole,
        course: _currentStudentCourse,
        statusMessage: !_enteredApp
            ? 'Connecting to PulseCONNECT...'
            : (isTeacher
                ? 'Loading faculty dashboard & events...'
                : 'Loading student portal & events...'),
      );
    }
    if (_enteredApp) {
      return _currentRole.toLowerCase() == 'teacher'
          ? const TeacherHome()
          : const StudentHome();
    }
    return const WelcomeScreen();
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
      final ctx = PulseConnectApp.navigatorKey.currentContext;
      if (ctx == null) return;
      if (offline) {
        AppSnackBar.warning(ctx, 'Offline mode detected. Using the latest synced data on this device.', title: 'No Connection');
      } else {
        AppSnackBar.success(ctx, 'You are back online. Syncing the latest data now.', title: 'Connected');
      }
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
    _disableFlutterDebugOutlines();
    if (state == AppLifecycleState.resumed) {
      NotificationService().resumePolling();
      unawaited(_reconcileConnectivityState());
      unawaited(_enforceDailyVerificationLogout());
      _scheduleDailyVerificationCheck();
      // Catch up lists/bell if a push arrived while backgrounded (FCM
      // notification payloads do not run Dart onMessage in background).
      unawaited(() async {
        if (await _authService.isLoggedIn()) {
          await LiveUiSync.syncNow('resume');
          // Re-register FCM token so publishes can find devices again.
          unawaited(PushNotificationService().updateToken());
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
      if (state == AppLifecycleState.paused ||
          state == AppLifecycleState.detached) {
        NotificationService().pausePolling();
      }
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
      // Schedule after the current frame so an in-flight Navigator push
      // (e.g. login → OTP) is not wiped by a MaterialApp rebuild.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        if (_currentRole == role && _currentStudentCourse == nextCourse) return;
        setState(() {
          _currentRole = role;
          _currentStudentCourse = nextCourse;
        });
        _rememberSessionTheme(
          role: role,
          studentCourse: nextCourse,
          enteredApp: _enteredApp,
        );
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
      debugShowMaterialGrid: false,
      showPerformanceOverlay: false,
      checkerboardRasterCacheImages: false,
      checkerboardOffscreenLayers: false,
      showSemanticsDebugger: false,
      theme: _getTheme(_currentRole, _currentStudentCourse),
      builder: (context, child) {
        _disableFlutterDebugOutlines();
        return ClipRect(
          child: ColoredBox(
            color: const Color(0xFF09090B),
            child: child ?? const SizedBox.shrink(),
          ),
        );
      },
      home: _buildRootHome(),
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
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: {
          TargetPlatform.android: AppPageTransitionsBuilder(),
          TargetPlatform.iOS: AppPageTransitionsBuilder(),
        },
      ),
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
        tertiary: primaryColor,
        outline: const Color(0xFFE5E7EB),
        outlineVariant: const Color(0xFFE5E7EB),
      ),
      focusColor: Colors.transparent,
      hoverColor: primaryColor.withValues(alpha: 0.04),
      highlightColor: primaryColor.withValues(alpha: 0.08),
      splashColor: primaryColor.withValues(alpha: 0.12),
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
