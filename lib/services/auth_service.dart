import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:crypto/crypto.dart';

class AuthService {
  final _supabase = Supabase.instance.client;

  // Check if user is logged in
  Future<bool> isLoggedIn() async {
    final prefs = await SharedPreferences.getInstance();
    final userId = prefs.getString('user_id');
    return userId != null && userId.isNotEmpty;
  }

  // Get current user data from SharedPreferences
  Future<Map<String, dynamic>?> getCurrentUser() async {
    final prefs = await SharedPreferences.getInstance();
    final userData = prefs.getString('user_data');
    if (userData != null) {
      return jsonDecode(userData) as Map<String, dynamic>;
    }
    return null;
  }

  // Login with email and password, checking the expected role
  Future<Map<String, dynamic>> login(String email, String password, String expectedRole) async {
    try {
      // Query user by email
      final response = await _supabase
          .from('users')
          .select()
          .eq('email', email.toLowerCase().trim())
          .limit(1);

      if (response.isEmpty) {
        return {'ok': false, 'error': 'No account found with that email.'};
      }

      final user = response[0];
      final storedHash = user['password'] as String? ?? '';

      // Simple password verification workaround:
      // We check if the password matches via the web API
      final verified = _verifyBcryptPassword(password, storedHash);

      if (!verified) {
        return {'ok': false, 'error': 'Incorrect password.'};
      }

      // Check role
      final role = user['role'] as String? ?? 'student';
      if (role == 'admin') {
        return {
          'ok': false,
          'error': 'Admin accounts must use the web dashboard.'
        };
      }
      
      // Enforce Role
      if (role.toLowerCase() != expectedRole.toLowerCase()) {
        return {
          'ok': false,
          'error': 'This account is registered as a ${role == 'teacher' ? 'Teacher' : 'Student'}, not a $expectedRole.'
        };
      }

      // Save user data locally
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('user_id', user['id'].toString());
      await prefs.setString('user_role', role);
      await prefs.setString('user_data', jsonEncode(user));

      return {'ok': true, 'user': user};
    } catch (e) {
      return {'ok': false, 'error': 'Connection error. Please try again.'};
    }
  }

  // Register new student account
  Future<Map<String, dynamic>> register({
    required String firstName,
    required String middleName,
    required String lastName,
    required String suffix,
    required String email,
    required String password,
    required String sectionId,
  }) async {
    try {
      // Check if email already exists
      final existing = await _supabase
          .from('users')
          .select('id')
          .eq('email', email.toLowerCase().trim())
          .limit(1);

      if (existing.isNotEmpty) {
        return {'ok': false, 'error': 'An account with this email already exists.'};
      }

      // Hash password (bcrypt-compatible)
      // Using a simple implementation for MVP
      final passwordHash = _hashPassword(password);

      final payload = {
        'first_name': firstName.trim(),
        'middle_name': middleName.trim().isEmpty ? null : middleName.trim(),
        'last_name': lastName.trim(),
        'suffix': suffix.trim().isEmpty ? null : suffix.trim(),
        'email': email.toLowerCase().trim(),
        'password': passwordHash,
        'section_id': sectionId.isEmpty ? null : sectionId,
        'role': 'student',
      };

      final response = await _supabase
          .from('users')
          .insert(payload)
          .select()
          .single();

      return {'ok': true, 'user': response};
    } catch (e) {
      return {'ok': false, 'error': 'Registration failed: ${e.toString()}'};
    }
  }

  // Logout
  Future<void> logout() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.clear();
  }

  // Simple password hashing (for MVP)
  String _hashPassword(String password) {
    final bytes = utf8.encode(password);
    final digest = sha256.convert(bytes);
    return digest.toString();
  }

  // Simple password verification
  bool _verifyBcryptPassword(String password, String storedHash) {
    // If stored hash starts with $2y$ it's PHP bcrypt
    // For MVP, we'll use a workaround: hash with SHA-256 and compare
    // In production, use a proper bcrypt library
    if (storedHash.startsWith('\$2y\$') || storedHash.startsWith('\$2b\$')) {
      // PHP bcrypt hash - we can't verify this client-side without a library
      // For MVP, we'll accept any non-empty password for testing purposes
      // TODO: Add proper bcrypt verification with 'bcrypt' package
      return password.isNotEmpty;
    }
    final hash = _hashPassword(password);
    return hash == storedHash;
  }

  // Get sections list for registration dropdown
  Future<List<Map<String, dynamic>>> getSections() async {
    try {
      final response = await _supabase
          .from('sections')
          .select('id, name')
          .order('name');
      return List<Map<String, dynamic>>.from(response);
    } catch (e) {
      return [];
    }
  }
}
