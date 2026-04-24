import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'screens/welcome_screen.dart';
import 'screens/student/student_home.dart';
import 'screens/teacher/teacher_home.dart';
import 'screens/auth/email_verification_screen.dart';
import 'services/auth_service.dart';
import 'package:firebase_core/firebase_core.dart';
import 'services/push_notification_service.dart';
import 'config/env.dart';
import 'utils/course_theme_utils.dart';
import 'utils/teacher_theme_utils.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Initialize Firebase first, but keep app boot resilient if config is missing.
  var firebaseReady = false;
  try {
    await Firebase.initializeApp();
    firebaseReady = true;
  } catch (e) {
    debugPrint('Firebase init skipped: $e');
  }

  // Initialize Supabase before any service that touches Supabase.instance
  await Supabase.initialize(
    url: Env.supabaseUrl,
    anonKey: Env.supabaseAnonKey,
  );

  // Initialize Push Notification Service only when Firebase is available.
  if (firebaseReady) {
    await PushNotificationService().initialize();
  }

  // Check if user is already logged in
  final authService = AuthService();
  final isLoggedIn = await authService.isLoggedIn();
  String role = 'student';
  String studentCourse = 'IT';
  Map<String, dynamic>? initialUserData;
  bool needsEmailVerification = false;
  
  if (isLoggedIn) {
    // Always refresh from server first so verification/approval gates
    // use the latest account state, not stale local cache.
    final serverUser = await authService.refreshCurrentUserFromServer();
    final userData = serverUser ?? await authService.getCurrentUser();
    initialUserData = userData;
    role = userData?['role']?.toString().toLowerCase() ?? 'student';
    studentCourse = CourseThemeUtils.normalizeCourse(userData?['course']) == 'CS'
        ? 'CS'
        : 'IT';
    needsEmailVerification = AuthService.requiresDailyEmailVerification(userData);
    
    // Save/Update FCM Token on app startup when Firebase is ready.
    if (firebaseReady) {
      await PushNotificationService().updateToken();
    }
  }

  runApp(
    PulseConnectApp(
      isLoggedIn: isLoggedIn,
      userRole: role,
      studentCourse: studentCourse,
      emailVerified: !needsEmailVerification,
      initialUser: initialUserData,
    ),
  );
}

class PulseConnectApp extends StatefulWidget {
  final bool isLoggedIn;
  final String userRole;
  final String studentCourse;
  final bool emailVerified;
  final Map<String, dynamic>? initialUser;

  static final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

  const PulseConnectApp({
    super.key,
    required this.isLoggedIn,
    required this.userRole,
    required this.studentCourse,
    this.emailVerified = false,
    this.initialUser,
  });

  static PulseConnectAppState of(BuildContext context) =>
      context.findAncestorStateOfType<PulseConnectAppState>()!;

  @override
  State<PulseConnectApp> createState() => PulseConnectAppState();
}

class PulseConnectAppState extends State<PulseConnectApp> {
  late String _currentRole;
  late String _currentStudentCourse;

  @override
  void initState() {
    super.initState();
    _currentRole = widget.userRole;
    _currentStudentCourse = widget.studentCourse;
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
      title: 'CCS PulseConnect',
      debugShowCheckedModeBanner: false,
      theme: _getTheme(_currentRole, _currentStudentCourse),
      home: widget.isLoggedIn
          ? (!widget.emailVerified && widget.initialUser != null
                ? EmailVerificationScreen(user: widget.initialUser!)
                : (_currentRole.toLowerCase() == 'teacher'
                      ? const TeacherHome()
                      : const StudentHome()))
          : const WelcomeScreen(),
    );
  }

  ThemeData _getTheme(String role, String studentCourse) {
    final bool isStudent = role.toLowerCase() == 'student';
    final Color primaryColor = isStudent
        ? CourseThemeUtils.studentPrimaryForCourse(studentCourse)
        : TeacherThemeUtils.primary;
    final Color secondaryColor = isStudent
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
      ),
      textTheme: GoogleFonts.interTextTheme(),
      scaffoldBackgroundColor: const Color(0xFFF8F9FA),
      appBarTheme: AppBarTheme(
        backgroundColor: primaryColor,
        foregroundColor: Colors.white,
        elevation: 0,
        centerTitle: true,
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




