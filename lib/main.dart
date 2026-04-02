import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'screens/welcome_screen.dart';
import 'screens/student/student_home.dart';
import 'screens/teacher/teacher_home.dart';
import 'services/auth_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await Supabase.initialize(
    url: 'https://vvwagzckacyglfjcdalj.supabase.co',
    anonKey:
        'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InZ2d2FnemNrYWN5Z2xmamNkYWxqIiwicm9sZSI6InNlcnZpY2Vfcm9sZSIsImlhdCI6MTc3NDg2MjcwMywiZXhwIjoyMDkwNDM4NzAzfQ.FjsbwZIQ7qLWpxeGmDYgE9CdjPVriCmwas6YCHWFpPE',
  );

  // Check if user is already logged in
  final authService = AuthService();
  final isLoggedIn = await authService.isLoggedIn();
  String role = 'student';
  
  if (isLoggedIn) {
    final userData = await authService.getCurrentUser();
    role = userData?['role']?.toString().toLowerCase() ?? 'student';
  }

  runApp(PulseConnectApp(isLoggedIn: isLoggedIn, userRole: role));
}

class PulseConnectApp extends StatelessWidget {
  final bool isLoggedIn;
  final String userRole;

  const PulseConnectApp({super.key, required this.isLoggedIn, required this.userRole});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'CCS PulseConnect',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF064E3B),
          primary: const Color(0xFF064E3B),
          secondary: const Color(0xFFD4A843),
          surface: Colors.white,
          brightness: Brightness.light,
        ),
        textTheme: GoogleFonts.interTextTheme(),
        scaffoldBackgroundColor: const Color(0xFFF8F9FA),
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFF064E3B),
          foregroundColor: Colors.white,
          elevation: 0,
          centerTitle: true,
        ),
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
            backgroundColor: const Color(0xFF064E3B),
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
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
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
            borderSide:
                const BorderSide(color: Color(0xFF064E3B), width: 2),
          ),
        ),
      ),
      home: isLoggedIn 
          ? (userRole == 'teacher' ? const TeacherHome() : const StudentHome()) 
          : const WelcomeScreen(),
    );
  }
}
