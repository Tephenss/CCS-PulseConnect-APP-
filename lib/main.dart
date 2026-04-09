import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'screens/welcome_screen.dart';
import 'screens/student/student_home.dart';
import 'screens/teacher/teacher_home.dart';
import 'services/auth_service.dart';
import 'package:firebase_core/firebase_core.dart';
import 'services/push_notification_service.dart';
import 'config/env.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Initialize Firebase FIRST
  await Firebase.initializeApp();
  
  // Initialize Push Notification Service
  await PushNotificationService().initialize();

  await Supabase.initialize(
    url: Env.supabaseUrl,
    anonKey: Env.supabaseAnonKey,
  );

  // Check if user is already logged in
  final authService = AuthService();
  final isLoggedIn = await authService.isLoggedIn();
  String role = 'student';
  
  if (isLoggedIn) {
    final userData = await authService.getCurrentUser();
    role = userData?['role']?.toString().toLowerCase() ?? 'student';
    
    // Save/Update FCM Token on app startup
    await PushNotificationService().updateToken();
  }

  runApp(PulseConnectApp(isLoggedIn: isLoggedIn, userRole: role));
}

class PulseConnectApp extends StatefulWidget {
  final bool isLoggedIn;
  final String userRole;

  static final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

  const PulseConnectApp({super.key, required this.isLoggedIn, required this.userRole});

  static _PulseConnectAppState of(BuildContext context) =>
      context.findAncestorStateOfType<_PulseConnectAppState>()!;

  @override
  State<PulseConnectApp> createState() => _PulseConnectAppState();
}

class _PulseConnectAppState extends State<PulseConnectApp> {
  late String _currentRole;

  @override
  void initState() {
    super.initState();
    _currentRole = widget.userRole;
  }

  void updateTheme(String role) {
    if (_currentRole != role) {
      setState(() => _currentRole = role);
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorKey: PulseConnectApp.navigatorKey,
      title: 'CCS PulseConnect',
      debugShowCheckedModeBanner: false,
      theme: _getTheme(_currentRole),
      home: widget.isLoggedIn 
          ? (_currentRole.toLowerCase() == 'teacher' ? const TeacherHome() : const StudentHome()) 
          : const WelcomeScreen(),
    );
  }

  ThemeData _getTheme(String role) {
    final bool isStudent = role.toLowerCase() == 'student';
    final Color primaryColor = isStudent ? const Color(0xFF9F1239) : const Color(0xFF064E3B);
    final Color secondaryColor = const Color(0xFFD4A843);
    
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
