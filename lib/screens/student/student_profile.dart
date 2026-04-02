import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../services/auth_service.dart';
import '../welcome_screen.dart';
import '../auth/change_password_screen.dart';

class StudentProfile extends StatefulWidget {
  final Map<String, dynamic>? user;
  const StudentProfile({super.key, this.user});

  @override
  State<StudentProfile> createState() => _StudentProfileState();
}

class _StudentProfileState extends State<StudentProfile> {
  final _authService = AuthService();
  bool _isLoading = false;
  String? _profilePicBase64;

  @override
  void initState() {
    super.initState();
    _loadProfilePic();
  }

  Future<void> _loadProfilePic() async {
    final prefs = await SharedPreferences.getInstance();
    final userId = widget.user?['id']?.toString() ?? '';
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
      final userId = widget.user?['id']?.toString() ?? '';
      await prefs.setString('profile_pic_$userId', base64String);
      
      setState(() {
        _profilePicBase64 = base64String;
      });
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
    final firstName = widget.user?['first_name'] as String? ?? 'Student';
    final lastName = widget.user?['last_name'] as String? ?? '';
    final idNumber = widget.user?['id_number'] as String? ?? 'Not specified';
    final email = widget.user?['email'] as String? ?? 'No email';
    // Mocks for year level and section if not populated right away
    final yearLevel = widget.user?['year_level']?.toString() ?? 'Grade 12';
    final section = widget.user?['section']?.toString() ?? 'A';

    return Scaffold(
      backgroundColor: const Color(0xFFF8F9FA),
      appBar: AppBar(
        title: const Text('My Profile', style: TextStyle(fontWeight: FontWeight.w700)),
        elevation: 0,
        actions: [
          IconButton(
            icon: const Icon(Icons.logout_rounded, color: Colors.red),
            onPressed: _isLoading ? null : _logout,
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
        child: Column(
          children: [
            // Profile Info Header
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 32),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(24),
                boxShadow: [
                  BoxShadow(color: Colors.black.withValues(alpha: 0.05), blurRadius: 20, offset: const Offset(0, 10))
                ],
              ),
              child: Column(
                children: [
                  Stack(
                    alignment: Alignment.bottomRight,
                    children: [
                      Container(
                        width: 100,
                        height: 100,
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
                            ? Center(
                                child: Text(
                                  firstName.isNotEmpty ? firstName[0].toUpperCase() : 'S',
                                  style: const TextStyle(fontSize: 40, fontWeight: FontWeight.bold, color: Color(0xFF064E3B)),
                                ),
                              )
                            : null,
                      ),
                      GestureDetector(
                        onTap: _pickProfilePic,
                        child: Container(
                          padding: const EdgeInsets.all(6),
                          decoration: const BoxDecoration(
                            color: Color(0xFF064E3B),
                            shape: BoxShape.circle,
                          ),
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
                  const Align(
                    alignment: Alignment.centerLeft,
                    child: Text('Profile Information', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: Color(0xFFD4A843))),
                  ),
                  const SizedBox(height: 16),
                  _buildProfileDetailRow('First Name', firstName),
                  _buildProfileDetailRow('Last Name', lastName),
                  _buildProfileDetailRow('ID Number', idNumber),
                  _buildProfileDetailRow('Email', email),
                  _buildProfileDetailRow('Year Level', yearLevel),
                  _buildProfileDetailRow('Section', section),
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
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(16),
                  boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.03), blurRadius: 10, offset: const Offset(0, 4))],
                ),
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

            const SizedBox(height: 40),
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
          SizedBox(
            width: 90,
            child: Text(label, style: TextStyle(color: Colors.grey.shade500, fontSize: 13, fontWeight: FontWeight.w600)),
          ),
          const SizedBox(width: 16),
          Expanded(child: Text(value, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14))),
        ],
      ),
    );
  }
}
