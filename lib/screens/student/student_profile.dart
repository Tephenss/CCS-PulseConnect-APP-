import 'package:flutter/material.dart';
import '../../services/auth_service.dart';
import '../welcome_screen.dart';
import '../auth/change_password_screen.dart';
import 'student_certificates.dart';

class StudentProfile extends StatefulWidget {
  final Map<String, dynamic>? user;
  const StudentProfile({super.key, required this.user});

  @override
  State<StudentProfile> createState() => _StudentProfileState();
}


class _StudentProfileState extends State<StudentProfile> {
  final _authService = AuthService();
  String _sectionName = 'Loading...';

  @override
  void initState() {
    super.initState();
    _fetchSectionName();
  }

  Future<void> _fetchSectionName() async {
    final sectionId = widget.user?['section_id']?.toString();
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

  @override
  Widget build(BuildContext context) {
    final firstName = widget.user?['first_name'] as String? ?? 'Student';
    final lastName = widget.user?['last_name'] as String? ?? '';
    final email = widget.user?['email'] as String? ?? '';
    final studentId = widget.user?['student_id'] as String? ?? 'N/A';

    return Scaffold(
      backgroundColor: const Color(0xFFF9FAFB),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Header matching Teacher profile
              Row(
                children: [
                  const Expanded(child: Text('My Profile', style: TextStyle(fontSize: 24, fontWeight: FontWeight.w800, color: Color(0xFF1F2937)))),
                  IconButton(
                    icon: const Icon(Icons.logout_rounded, color: Colors.red),
                    onPressed: () async {
                      await _authService.logout();
                      if (!context.mounted) return;
                      Navigator.pushAndRemoveUntil(
                        context,
                        MaterialPageRoute(builder: (_) => const WelcomeScreen()),
                        (route) => false,
                      );
                    },
                  ),
                ],
              ),
              const SizedBox(height: 16),
              // Profile Card
            Container(
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(20),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.04),
                    blurRadius: 20,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: Column(
                children: [
                  Container(
                    width: 90,
                    height: 90,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: const Color(0xFFFFF1F2), // Light subset of maroon
                      border: Border.all(color: const Color(0xFF7F1D1D), width: 3),
                    ),
                    child: Center(
                      child: Text(
                        firstName.isNotEmpty ? firstName[0].toUpperCase() : 'S',
                        style: const TextStyle(
                          color: Color(0xFF7F1D1D),
                          fontSize: 36,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    '$firstName $lastName',
                    style: const TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.w800,
                      color: Color(0xFF1F2937),
                    ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    email,
                    style: TextStyle(
                      color: Colors.grey.shade500,
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const SizedBox(height: 24),
                  Container(
                    padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 20),
                    decoration: BoxDecoration(
                      color: Colors.grey.shade50,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: Colors.grey.shade200),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text('Student ID', style: TextStyle(color: Colors.grey.shade600, fontWeight: FontWeight.w600)),
                        Text(studentId, style: const TextStyle(color: Color(0xFF1F2937), fontWeight: FontWeight.w800)),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  Container(
                    padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 20),
                    decoration: BoxDecoration(
                      color: Colors.grey.shade50,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: Colors.grey.shade200),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text('Section', style: TextStyle(color: Colors.grey.shade600, fontWeight: FontWeight.w600)),
                        Text(_sectionName, style: const TextStyle(color: Color(0xFF1F2937), fontWeight: FontWeight.w800)),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 32),

            // Certificates Section
            const Text(
              'Achievements',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w800,
                color: Color(0xFF1F2937),
              ),
            ),
            const SizedBox(height: 16),
            Container(
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(20),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.04),
                    blurRadius: 20,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: ListTile(
                contentPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                leading: Container(
                  padding: const EdgeInsets.all(10),
                  decoration: const BoxDecoration(
                    color: Color(0xFFFFF1F2),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.workspace_premium_rounded, color: Color(0xFF7F1D1D)),
                ),
                title: const Text('My Certificates', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16, color: Color(0xFF1F2937))),
                subtitle: const Text('View earned certificates', style: TextStyle(fontSize: 12, color: Colors.grey)),
                trailing: const Icon(Icons.chevron_right_rounded, color: Colors.grey),
                onTap: () {
                  Navigator.push(context, MaterialPageRoute(builder: (_) => const StudentCertificates()));
                },
              ),
            ),
            const SizedBox(height: 32),

            // Security Section
            const Text(
              'Security',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w800,
                color: Color(0xFF1F2937),
              ),
            ),
            const SizedBox(height: 16),
            Container(
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(20),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.04),
                    blurRadius: 20,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: ListTile(
                contentPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                leading: Container(
                  padding: const EdgeInsets.all(10),
                  decoration: const BoxDecoration(
                    color: Color(0xFFFFF1F2),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.lock_outline_rounded, color: Color(0xFF7F1D1D)),
                ),
                title: const Text('Change Password', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16, color: Color(0xFF1F2937))),
                subtitle: const Text('Update your account password', style: TextStyle(fontSize: 12, color: Colors.grey)),
                trailing: const Icon(Icons.chevron_right_rounded, color: Colors.grey),
                onTap: () {
                  Navigator.push(context, MaterialPageRoute(builder: (_) => const ChangePasswordScreen()));
                },
              ),
            ),
            const SizedBox(height: 40),
          ],
        ),
      ),
    ),
    );
  }
}
