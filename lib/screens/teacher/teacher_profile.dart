import 'dart:io';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:image_cropper/image_cropper.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as path;
import '../../services/auth_service.dart';
import '../../widgets/custom_loader.dart';
import '../welcome_screen.dart';
import '../auth/change_password_screen.dart';
import '../../utils/teacher_theme_utils.dart';

class TeacherProfile extends StatefulWidget {
  final Map<String, dynamic>? user;
  final VoidCallback? onUpdate;
  const TeacherProfile({super.key, this.user, this.onUpdate});

  @override
  State<TeacherProfile> createState() => _TeacherProfileState();
}

class _TeacherProfileState extends State<TeacherProfile> {
  final _authService = AuthService();
  Map<String, dynamic>? _user;
  bool _isUploading = false;
  bool _isLoggingOut = false;
  final ImagePicker _picker = ImagePicker();

  @override
  void initState() {
    super.initState();
    _user = widget.user;
    if (_user == null) {
      _loadUser();
    }
  }

  Future<void> _pickProfilePic() async {
    try {
      final xfile = await _picker.pickImage(source: ImageSource.gallery);
      if (xfile == null) return;

      // Crop the selected image
      final croppedFile = await _cropImage(xfile.path);
      if (croppedFile == null) return;

      setState(() => _isUploading = true);
      
      // Save to local storage for immediate preview
      final directory = await getApplicationDocumentsDirectory();
      final fileName = 'profile_${DateTime.now().millisecondsSinceEpoch}${path.extension(croppedFile.path)}';
      final savedImage = await File(croppedFile.path).copy('${directory.path}/$fileName');

      // Update AuthService (Uploads to Supabase Storage)
      final res = await _authService.uploadAvatar(savedImage);
      
      if (mounted) {
        setState(() {
          _isUploading = false;
          if (res['ok']) {
            _user = res['user'];
          }
        });
        
        if (res['ok']) {
          final warning = res['warning']?.toString();
          if (widget.onUpdate != null) widget.onUpdate!();
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                (warning != null && warning.isNotEmpty)
                    ? warning
                    : 'Profile picture cloud-synced!',
              ),
              backgroundColor:
                  (warning != null && warning.isNotEmpty) ? Colors.orange : TeacherThemeUtils.primary,
            ),
          );
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(res['error'] ?? 'Upload failed'), backgroundColor: Colors.red),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isUploading = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: ${e.toString()}'), backgroundColor: Colors.red),
        );
      }
    }
  }

  Future<CroppedFile?> _cropImage(String filePath) async {
    return await ImageCropper().cropImage(
      sourcePath: filePath,
      maxWidth: 512,
      maxHeight: 512,
      aspectRatio: const CropAspectRatio(ratioX: 1, ratioY: 1), // Square for circular avatar
      compressQuality: 90,
      uiSettings: [
        AndroidUiSettings(
          toolbarTitle: 'Edit Profle Picture',
          toolbarColor: TeacherThemeUtils.primary,
          toolbarWidgetColor: Colors.white,
          initAspectRatio: CropAspectRatioPreset.square,
          lockAspectRatio: true,
          hideBottomControls: false,
        ),
        IOSUiSettings(
          title: 'Edit Profile Picture',
          rotateButtonsHidden: false,
          rotateClockwiseButtonHidden: false,
          aspectRatioLockEnabled: true,
        ),
      ],
    );
  }

  Future<void> _loadUser() async {
    final user = await _authService.getCurrentUser();
    if (mounted) {
      setState(() {
        _user = user;
      });
    }
  }

  Future<void> _refreshProfile() async {
    await _loadUser();
    if (widget.onUpdate != null) {
      widget.onUpdate!();
    }
  }

  Future<void> _confirmLogout() async {
    if (_isLoggingOut) return;

    final shouldLogout = await showDialog<bool>(
      context: context,
      barrierDismissible: true,
      builder: (context) => AlertDialog(
        backgroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        title: const Text(
          'Sign Out?',
          style: TextStyle(fontWeight: FontWeight.w800, color: Color(0xFF111827)),
        ),
        content: const Text(
          'Are you sure you want to sign out of your account?',
          style: TextStyle(color: Color(0xFF4B5563), height: 1.4),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text(
              'Cancel',
              style: TextStyle(color: Color(0xFF6B7280), fontWeight: FontWeight.w700),
            ),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: TeacherThemeUtils.primary,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            ),
            child: const Text('Sign Out'),
          ),
        ],
      ),
    );

    if (shouldLogout == true) {
      await _logout();
    }
  }

  Future<void> _logout() async {
    if (_isLoggingOut) return;
    setState(() => _isLoggingOut = true);
    try {
      await _authService.logout();
      if (mounted) {
        Navigator.pushAndRemoveUntil(
          context,
          MaterialPageRoute(builder: (_) => const WelcomeScreen()),
          (route) => false,
        );
      }
    } catch (_) {
      if (!mounted) return;
      setState(() => _isLoggingOut = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Failed to sign out. Please try again.'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_user == null) {
      return const Center(child: PulseConnectLoader());
    }

    final firstName = _user?['first_name'] as String? ?? 'Teacher';
    final lastName = _user?['last_name'] as String? ?? '';
    final email = _user?['email'] as String? ?? 'No email';
    final contactNumber = _user?['contact_number'] as String? ?? 'Not specified';
    final birthday = _user?['birthday'] as String? ?? 'Not specified';
    final gradeAdvisorRaw = _user?['grade_advisor'] as String?;
    final gradeAdvisor = (gradeAdvisorRaw == null || gradeAdvisorRaw.trim().isEmpty)
        ? 'Not Assigned'
        : gradeAdvisorRaw;

    return Scaffold(
      backgroundColor: const Color(0xFFF9FAFB),
      body: Stack(
        children: [
          RefreshIndicator(
            onRefresh: _refreshProfile,
            color: TeacherThemeUtils.primary,
            child: SingleChildScrollView(
              physics: const AlwaysScrollableScrollPhysics(),
              child: Column(
              children: [
            // Curved Header with Profile Info
            Stack(
              clipBehavior: Clip.none,
              children: [
                // Teacher Green Curved Background
                Container(
                  height: 220,
                  width: double.infinity,
                  decoration: const BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: TeacherThemeUtils.chromeGradient,
                    ),
                    borderRadius: BorderRadius.vertical(bottom: Radius.circular(40)),
                  ),
                ),
                
                // Content over background
                SafeArea(
                  bottom: false,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
                    child: Column(
                      children: [
                        // Header Row
                        Row(
                          children: [
                            const Expanded(child: Text('My Profile', style: TextStyle(fontSize: 24, fontWeight: FontWeight.w900, color: Colors.white, letterSpacing: -0.5))),
                            IconButton(
                              icon: Container(
                                padding: const EdgeInsets.all(8),
                                decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.2), shape: BoxShape.circle),
                                child: const Icon(Icons.logout_rounded, color: Colors.white, size: 20),
                              ),
                              onPressed: (_isUploading || _isLoggingOut) ? null : _confirmLogout,
                            ),
                          ],
                        ),
                        const SizedBox(height: 30),
                        
                        // Centered Avatar
                        GestureDetector(
                          onTap: (_isUploading || _isLoggingOut) ? null : _pickProfilePic,
                          child: Stack(
                            children: [
                              Container(
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  border: Border.all(color: Colors.white, width: 4),
                                  boxShadow: [
                                    BoxShadow(
                                      color: Colors.black.withValues(alpha: 0.1),
                                      blurRadius: 20,
                                      spreadRadius: 5,
                                    ),
                                  ],
                                ),
                                child: Container(
                                  width: 120,
                                  height: 120,
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    color: const Color(0xFFECFDF5),
                                    border: Border.all(color: const Color(0xFFD4A843), width: 2), // Gold inner ring
                                    image: _user?['photo_url'] != null && (_user?['photo_url'] as String).isNotEmpty
                                        ? DecorationImage(
                                            image: (_user?['photo_url'] as String).startsWith('http')
                                                ? NetworkImage(_user?['photo_url'])
                                                : FileImage(File(_user?['photo_url'])),
                                            fit: BoxFit.cover,
                                          )
                                        : null,
                                  ),
                                  child: _user?['photo_url'] == null || (_user?['photo_url'] as String).isEmpty
                                      ? Center(
                                          child: Text(
                                            firstName.isNotEmpty ? firstName[0].toUpperCase() : 'T',
                                            style: const TextStyle(color: TeacherThemeUtils.dark, fontSize: 44, fontWeight: FontWeight.w900),
                                          ),
                                        )
                                      : null,
                                ),
                              ),
                              if (_isUploading)
                                Positioned.fill(
                                  child: Container(
                                    decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.3), shape: BoxShape.circle),
                                    child: const Center(child: PulseConnectLoader(size: 14, color: Colors.white)),
                                  ),
                                ),
                              Positioned(
                                bottom: 4,
                                right: 4,
                                child: Container(
                                  padding: const EdgeInsets.all(8),
                                  decoration: BoxDecoration(
                                    color: const Color(0xFFD4A843), // Gold camera button
                                    shape: BoxShape.circle,
                                    border: Border.all(color: Colors.white, width: 2),
                                  ),
                                  child: const Icon(Icons.camera_alt_rounded, color: Colors.white, size: 16),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
            
            // Bottom Content
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 24, 24, 40),
              child: Column(
                children: [
                  Text('$firstName $lastName', style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w900, color: Color(0xFF111827), letterSpacing: -0.5)),
                  const SizedBox(height: 4),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                    decoration: BoxDecoration(color: TeacherThemeUtils.primary.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(100)),
                    child: Text(email, style: const TextStyle(color: TeacherThemeUtils.dark, fontSize: 13, fontWeight: FontWeight.w700)),
                  ),
                  
                  const SizedBox(height: 32),
                  
                  // My Information Card
                  const Align(
                    alignment: Alignment.centerLeft,
                    child: Text('MY INFORMATION', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w900, color: Color(0xFF6B7280), letterSpacing: 1.2)),
                  ),
                  const SizedBox(height: 16),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(24),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(24),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.03),
                          blurRadius: 20,
                          offset: const Offset(0, 10),
                        ),
                      ],
                    ),
                    child: Column(
                      children: [
                        _buildProfileDetailRow('Contact', contactNumber),
                        const Divider(height: 24, thickness: 1, color: Color(0xFFF3F4F6)),
                        _buildProfileDetailRow('Birthday', birthday),
                        const Divider(height: 24, thickness: 1, color: Color(0xFFF3F4F6)),
                        _buildProfileDetailRow('Advisor', gradeAdvisor),
                      ],
                    ),
                  ),
                  
                  const SizedBox(height: 32),
                  
                  // Security Selection
                  const Align(
                    alignment: Alignment.centerLeft,
                    child: Text('SECURITY', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w900, color: Color(0xFF6B7280), letterSpacing: 1.2)),
                  ),
                  const SizedBox(height: 16),
                  
                  _buildActionCard(
                    icon: Icons.lock_person_rounded,
                    title: 'Change Password',
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => const ChangePasswordScreen(role: 'Teacher'),
                      ),
                    ),
                  ),
                  const SizedBox(height: 120), // Extra space for bottom nav
                ],
              ),
            ),
          ],
              ),
            ),
          ),
          if (_isLoggingOut)
            Positioned.fill(
              child: Container(
                color: Colors.black.withValues(alpha: 0.35),
                child: const Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      PulseConnectLoader(size: 16, color: Colors.white),
                      SizedBox(height: 14),
                      Text(
                        'Signing out...',
                        style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w700,
                          fontSize: 14,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildActionCard({required IconData icon, required String title, required VoidCallback onTap}) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 20),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(24),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.03),
              blurRadius: 20,
              offset: const Offset(0, 10),
            ),
          ],
        ),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(color: TeacherThemeUtils.primary.withValues(alpha: 0.1), shape: BoxShape.circle),
              child: Icon(icon, color: TeacherThemeUtils.mid, size: 20),
            ),
            const SizedBox(width: 16),
            Expanded(child: Text(title, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16, color: Color(0xFF111827)))),
            const Icon(Icons.chevron_right_rounded, color: Color(0xFFD1D5DB)),
          ],
        ),
      ),
    );
  }

  Widget _buildProfileDetailRow(String label, String value) {
    return Row(
      children: [
        Text(label, style: TextStyle(color: Colors.grey.shade500, fontSize: 13, fontWeight: FontWeight.w700)),
        const Spacer(),
        Text(value, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 14, color: Color(0xFF111827))),
      ],
    );
  }
}
