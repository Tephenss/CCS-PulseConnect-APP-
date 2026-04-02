import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../services/auth_service.dart';
import '../welcome_screen.dart';
import '../auth/change_password_screen.dart';

class TeacherProfile extends StatefulWidget {
  const TeacherProfile({super.key});

  @override
  State<TeacherProfile> createState() => _TeacherProfileState();
}

class _TeacherProfileState extends State<TeacherProfile> {
  final _authService = AuthService();
  Map<String, dynamic>? _user;
  bool _isLoading = false;
  String? _profilePicBase64;

  @override
  void initState() {
    super.initState();
    _loadUser();
  }

  Future<void> _loadProfilePic() async {
    if (_user == null) return;
    final prefs = await SharedPreferences.getInstance();
    final userId = _user!['id']?.toString() ?? '';
    setState(() {
      _profilePicBase64 = prefs.getString('profile_pic_$userId');
    });
  }

  Future<void> _pickProfilePic() async {
    final picker = ImagePicker();
    final xfile = await picker.pickImage(source: ImageSource.gallery, imageQuality: 50);
    if (xfile != null) {
      final bytes = await File(xfile.path).readAsBytes();
      final base64String = base64Encode(bytes);
      
      final prefs = await SharedPreferences.getInstance();
      final userId = _user?['id']?.toString() ?? '';
      if (userId.isNotEmpty) {
        await prefs.setString('profile_pic_$userId', base64String);
      }
      
      setState(() {
        _profilePicBase64 = base64String;
      });
    }
  }

  Future<void> _loadUser() async {
    final user = await _authService.getCurrentUser();
    if (mounted) {
      setState(() {
        _user = user;
      });
      _loadProfilePic();
    }
  }

  Future<void> _logout() async {
    setState(() => _isLoading = true);
    await _authService.logout();
    if (mounted) {
      Navigator.pushAndRemoveUntil(
        context,
        MaterialPageRoute(builder: (_) => const WelcomeScreen()),
        (route) => false,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_user == null) {
      return const Center(child: CircularProgressIndicator(color: Color(0xFF064E3B)));
    }

    final firstName = _user?['first_name'] as String? ?? 'Teacher';
    final lastName = _user?['last_name'] as String? ?? '';
    final email = _user?['email'] as String? ?? 'No email';
    final contactNumber = _user?['contact_number'] as String? ?? 'Not specified';
    final birthday = _user?['birthday'] as String? ?? 'Not specified';
    final gradeAdvisor = _user?['grade_advisor'] as String? ?? 'General Faculty';

    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
        child: Column(
          children: [
            // Header
            Row(
              children: [
                const Expanded(child: Text('My Profile', style: TextStyle(fontSize: 24, fontWeight: FontWeight.w800, color: Color(0xFF1F2937)))),
                IconButton(
                  icon: const Icon(Icons.logout_rounded, color: Colors.red),
                  onPressed: _isLoading ? null : _logout,
                ),
              ],
            ),
            const SizedBox(height: 16),

            // Profile Card
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 32),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(24),
                boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.05), blurRadius: 20, offset: const Offset(0, 10))],
              ),
              child: Column(
                children: [
                  Stack(
                    alignment: Alignment.bottomRight,
                    children: [
                      Container(
                        width: 100, height: 100,
                        decoration: BoxDecoration(
                          color: const Color(0xFFF0FDF4),
                          shape: BoxShape.circle,
                          border: Border.all(color: const Color(0xFFD4A843), width: 3),
                          image: _profilePicBase64 != null
                              ? DecorationImage(
                                  image: MemoryImage(base64Decode(_profilePicBase64!)),
                                  fit: BoxFit.cover,
                                )
                              : null,
                        ),
                        child: _profilePicBase64 == null
                            ? Center(child: Text(firstName.isNotEmpty ? firstName[0].toUpperCase() : 'T', style: const TextStyle(fontSize: 40, fontWeight: FontWeight.bold, color: Color(0xFF064E3B))))
                            : null,
                      ),
                      GestureDetector(
                        onTap: _pickProfilePic,
                        child: Container(
                          padding: const EdgeInsets.all(6),
                          decoration: const BoxDecoration(color: Color(0xFF064E3B), shape: BoxShape.circle),
                          child: const Icon(Icons.camera_alt_rounded, color: Colors.white, size: 16),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Text('$firstName $lastName', style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800, color: Color(0xFF1F2937))),
                  const SizedBox(height: 4),
                  Text(email, style: TextStyle(fontSize: 14, color: Colors.grey.shade600, fontWeight: FontWeight.w500)),
                  
                  const SizedBox(height: 32),
                  const Align(alignment: Alignment.centerLeft, child: Text('My Information', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: Color(0xFFD4A843)))),
                  const SizedBox(height: 16),
                  _buildProfileDetailRow('First Name', firstName),
                  _buildProfileDetailRow('Last Name', lastName),
                  _buildProfileDetailRow('Email', email),
                  _buildProfileDetailRow('Contact', contactNumber),
                  _buildProfileDetailRow('Birthday', birthday),
                  _buildProfileDetailRow('Grade Advisor', gradeAdvisor),
                ],
              ),
            ),
            
            const SizedBox(height: 24),
            
            // Change Password Action
            GestureDetector(
              onTap: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (context) => const ChangePasswordScreen()),
                );
              },
              child: Container(
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16), boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.03), blurRadius: 10, offset: const Offset(0, 4))]),
                child: Row(
                  children: [
                    const Icon(Icons.lock_outline, color: Color(0xFF064E3B)),
                    const SizedBox(width: 16),
                    const Expanded(child: Text('Change Password', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16))),
                    Icon(Icons.chevron_right, color: Colors.grey.shade400),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 40), // Padding for bottom nav
          ],
        ),
      ),
    );
  }

  Widget _buildProfileDetailRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(width: 90, child: Text(label, style: TextStyle(color: Colors.grey.shade500, fontSize: 13, fontWeight: FontWeight.w600))),
          const SizedBox(width: 16),
          Expanded(child: Text(value, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14))),
        ],
      ),
    );
  }
}
