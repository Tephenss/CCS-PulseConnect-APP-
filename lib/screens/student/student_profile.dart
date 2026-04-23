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
import 'student_certificates.dart';
import '../../utils/course_theme_utils.dart';

class StudentProfile extends StatefulWidget {
  final Map<String, dynamic>? user;
  final VoidCallback? onUpdate;
  const StudentProfile({super.key, required this.user, this.onUpdate});

  @override
  State<StudentProfile> createState() => _StudentProfileState();
}


class _StudentProfileState extends State<StudentProfile> {
  final _authService = AuthService();
  String _sectionName = 'Loading...';
  final ImagePicker _picker = ImagePicker();
  bool _isUploading = false;
  bool _isLoggingOut = false;
  Map<String, dynamic>? _localUser;

  Color _studentPrimary(BuildContext context) => CourseThemeUtils
      .studentPrimaryForCourse(_localUser?['course']);
  Color _studentLight(BuildContext context) =>
      CourseThemeUtils.studentLightForCourse(_localUser?['course']);

  @override
  void initState() {
    super.initState();
    _localUser = widget.user;
    _fetchSectionName();
  }

  Future<void> _pickImage(ImageSource source) async {
    try {
      final XFile? pickedFile = await _picker.pickImage(
        source: source,
      );

      if (pickedFile == null) return;

      // Crop the selected image
      final croppedFile = await _cropImage(pickedFile.path);
      if (croppedFile == null) return;

      setState(() => _isUploading = true);

      // Save to local storage for instant feedback
      final directory = await getApplicationDocumentsDirectory();
      final fileName = 'profile_${DateTime.now().millisecondsSinceEpoch}${path.extension(croppedFile.path)}';
      final savedImage = await File(croppedFile.path).copy('${directory.path}/$fileName');

      // Update AuthService (Uploads to Supabase Storage and updates database)
      final res = await _authService.uploadAvatar(savedImage);
      
      if (mounted) {
        setState(() {
          _isUploading = false;
          if (res['ok']) {
            _localUser = res['user'];
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
                  (warning != null && warning.isNotEmpty) ? Colors.orange : Colors.green,
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
          toolbarColor: _studentPrimary(context),
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

  void _showPickOptions() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('Change Profile Picture', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: Color(0xFF1F2937))),
              const SizedBox(height: 20),
              ListTile(
                leading: Icon(
                  Icons.photo_library_rounded,
                  color: _studentPrimary(context),
                ),
                title: const Text('Choose from Gallery', style: TextStyle(fontWeight: FontWeight.w600)),
                onTap: () {
                  Navigator.pop(context);
                  _pickImage(ImageSource.gallery);
                },
              ),
              ListTile(
                leading: Icon(
                  Icons.camera_alt_rounded,
                  color: _studentPrimary(context),
                ),
                title: const Text('Take a Photo', style: TextStyle(fontWeight: FontWeight.w600)),
                onTap: () {
                  Navigator.pop(context);
                  _pickImage(ImageSource.camera);
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _fetchSectionName() async {
    final sectionId = _localUser?['section_id']?.toString();
    if (sectionId == null || sectionId.isEmpty) {
      if (mounted) setState(() => _sectionName = 'Not Set');
      return;
    }
    final sections = await _authService.getSections();
    final match = sections.firstWhere((s) => s['id'].toString() == sectionId, orElse: () => {});
    if (mounted) {
      setState(() {
        _sectionName = match.isNotEmpty ? (match['name'] as String? ?? 'Not Set') : 'Not Set';
      });
    }
  }

  Future<void> _refreshProfile() async {
    final latestUser = await _authService.getCurrentUser();
    if (!mounted) return;
    setState(() {
      _localUser = latestUser ?? _localUser;
    });
    await _fetchSectionName();
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
              backgroundColor: _studentPrimary(context),
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
      if (!mounted) return;
      Navigator.pushAndRemoveUntil(
        context,
        MaterialPageRoute(builder: (_) => const WelcomeScreen()),
        (route) => false,
      );
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
    final firstName = _localUser?['first_name'] as String? ?? 'Student';
    final lastName = _localUser?['last_name'] as String? ?? '';
    final email = _localUser?['email'] as String? ?? '';
    final studentId = _localUser?['student_id'] as String? ?? 'N/A';
    final photoUrl = _localUser?['photo_url'] as String?;

    return Scaffold(
      backgroundColor: const Color(0xFFF9FAFB),
      body: Stack(
        children: [
          RefreshIndicator(
            onRefresh: _refreshProfile,
            color: _studentPrimary(context),
            child: SingleChildScrollView(
              physics: const AlwaysScrollableScrollPhysics(),
              child: Column(
              children: [
            // Curved Header with Profile Info
            Stack(
              clipBehavior: Clip.none,
              children: [
                // Maroon Curved Background
                Container(
                  height: 220,
                  width: double.infinity,
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [_studentLight(context), _studentPrimary(context)],
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
                          onTap: (_isUploading || _isLoggingOut) ? null : _showPickOptions,
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
                                    color: const Color(0xFFFFF1F2),
                                    border: Border.all(color: const Color(0xFFD4A843), width: 2), // Gold inner ring
                                    image: photoUrl != null && photoUrl.isNotEmpty
                                        ? DecorationImage(
                                            image: photoUrl.startsWith('http')
                                                ? NetworkImage(photoUrl)
                                                : FileImage(File(photoUrl)),
                                            fit: BoxFit.cover,
                                          )
                                        : null,
                                  ),
                                  child: photoUrl == null || photoUrl.isEmpty
                                      ? Center(
                                          child: Text(
                                            firstName.isNotEmpty ? firstName[0].toUpperCase() : 'S',
                                            style: TextStyle(
                                              color: _studentPrimary(context),
                                              fontSize: 44,
                                              fontWeight: FontWeight.w900,
                                            ),
                                          ),
                                        )
                                      : null,
                                ),
                              ),
                              if (_isUploading)
                                Positioned.fill(
                                  child: Container(
                                    decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.3), shape: BoxShape.circle),
                                    child: const Center(child: PulseConnectLoader(size: 14)),
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
                    decoration: BoxDecoration(
                      color: _studentPrimary(context).withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(100),
                    ),
                    child: Text(
                      email,
                      style: TextStyle(
                        color: _studentPrimary(context),
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  
                  const SizedBox(height: 32),
                  
                  // Unified Info Card
                  Container(
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
                        IntrinsicHeight(
                          child: Row(
                            children: [
                              Expanded(
                                child: _buildSimpleInfo('STUDENT ID', studentId),
                              ),
                              Container(width: 1, height: 40, color: Colors.grey.withValues(alpha: 0.1)),
                              Expanded(
                                child: _buildSimpleInfo('COURSE/SECTION', _sectionName),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  
                  const SizedBox(height: 40),
                  
                  // Menu Items Header
                  const Align(
                    alignment: Alignment.centerLeft,
                    child: Text('ACCOUNT SETTINGS', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w900, color: Color(0xFF6B7280), letterSpacing: 1.2)),
                  ),
                  const SizedBox(height: 16),
                  
                  _buildMenuCard(
                    icon: Icons.workspace_premium_rounded,
                    title: 'My Certificates',
                    subtitle: 'View your earned achievements',
                    onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const StudentCertificates())),
                  ),
                  
                  const SizedBox(height: 16),
                  
                  _buildMenuCard(
                    icon: Icons.lock_person_rounded,
                    title: 'Security',
                    subtitle: 'Manage your password and auth',
                    onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const ChangePasswordScreen())),
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

  Widget _buildSimpleInfo(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 24, horizontal: 16),
      child: Column(
        children: [
          Text(label, style: TextStyle(fontSize: 10, fontWeight: FontWeight.w900, color: Colors.grey.shade500, letterSpacing: 1)),
          const SizedBox(height: 8),
          Text(value, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w900, color: Color(0xFF111827))),
        ],
      ),
    );
  }

  Widget _buildMenuCard({required IconData icon, required String title, required String subtitle, required VoidCallback onTap}) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
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
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: _studentPrimary(context).withValues(alpha: 0.1),
                shape: BoxShape.circle,
              ),
              child: Icon(icon, color: _studentPrimary(context), size: 22),
            ),
            const SizedBox(width: 20),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: Color(0xFF111827))),
                  const SizedBox(height: 2),
                  Text(subtitle, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Colors.grey.shade500)),
                ],
              ),
            ),
            const Icon(Icons.chevron_right_rounded, color: Color(0xFFD1D5DB), size: 24),
          ],
        ),
      ),
    );
  }
}
