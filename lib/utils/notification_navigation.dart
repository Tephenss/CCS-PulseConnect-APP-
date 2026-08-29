import 'package:flutter/material.dart';
import '../widgets/app_snackbar.dart';

import '../screens/student/student_certificates.dart';
import '../screens/student/student_event_details.dart';
import '../screens/student/student_event_evaluation.dart';
import '../screens/student/student_registration_requirements_page.dart';
import '../screens/teacher/teacher_event_manage.dart';
import '../screens/teacher/teacher_proposal_requirements_page.dart';
import '../services/auth_service.dart';
import '../services/event_service.dart';
import '../services/notification_service.dart';
import 'app_page_routes.dart';

class NotificationNavigation {
  static bool isTeacherRole(String? role) {
    return (role ?? '').trim().toLowerCase() == 'teacher';
  }

  static String resolveAction(AppNotification n) {
    final explicit = (n.actionType ?? '').trim().toLowerCase();
    if (explicit.isNotEmpty) return explicit;

    final route = (n.route ?? '').trim().toLowerCase();
    if (route.isNotEmpty) return route;

    final id = n.id;
    if (id.startsWith('cert_')) return 'certificate_ready';
    if (id.startsWith('eval_open_')) return 'eval_open';
    if (id.startsWith('proposal_req_') ||
        id.startsWith('proposal_under_review_')) {
      return 'proposal_requirements_requested';
    }
    if (id.startsWith('assign_')) return 'teacher_event_assigned';
    if (id.startsWith('reject_')) return 'proposal_rejected';
    if (id.startsWith('reg_access_approved_') ||
        id.startsWith('reg_open_') ||
        id.startsWith('reg_extended_') ||
        id.startsWith('reg_closed_')) {
      return 'reg_open';
    }
    if (id.startsWith('pub_') ||
        id.startsWith('approved_') ||
        id.startsWith('finished_') ||
        id.startsWith('near_') ||
        id.startsWith('start_') ||
        id.startsWith('end_') ||
        id.startsWith('ongoing_')) {
      return 'event_published';
    }

    final title = n.title.toLowerCase();
    if (title.contains('certificate')) return 'certificate_ready';
    if (title.contains('evaluation')) return 'eval_open';
    if (title.contains('proposal document') ||
        title.contains('proposal under review')) {
      return 'proposal_requirements_requested';
    }
    if (title.contains('assigned') || title.contains('qr scanner')) {
      return 'teacher_event_assigned';
    }
    return '';
  }

  static Future<void> open(
    BuildContext context,
    AppNotification n, {
    required AuthService auth,
    required EventService eventService,
    bool popFirst = false,
  }) async {
    final user = await auth.getCurrentUser();
    final role = (user?['role']?.toString() ?? '').trim().toLowerCase();
    final teacher = isTeacherRole(role);
    final action = resolveAction(n);
    final eventId = n.eventId?.trim() ?? '';

    if (!context.mounted) return;

    Future<void> push(Widget page) async {
      if (popFirst && context.mounted) {
        Navigator.of(context).pop();
        await Future<void>.delayed(const Duration(milliseconds: 120));
      }
      if (!context.mounted) return;
      await Navigator.of(context).push(AppPageRoute(builder: (_) => page));
    }

    if (action == 'certificate_ready' ||
        action == 'certificate' ||
        action == 'certificates' ||
        (n.route ?? '').toLowerCase() == 'certificates') {
      await push(const StudentCertificates());
      return;
    }

    if (!teacher &&
        (action == 'eval_open' ||
            action == 'evaluation' ||
            (n.route ?? '').toLowerCase() == 'evaluation') &&
        eventId.isNotEmpty) {
      final studentId = (user?['id']?.toString() ?? '').trim();
      if (studentId.isNotEmpty) {
        await push(
          StudentEventEvaluationScreen(
            eventId: eventId,
            studentId: studentId,
          ),
        );
        return;
      }
    }

    if (eventId.isEmpty) {
      if (context.mounted) {
        AppSnackBar.error(context, 'This notification has no page to open.');
      }
      return;
    }

    Map<String, dynamic>? event;
    try {
      event = await eventService.getEventById(eventId);
    } catch (_) {
      event = null;
    }
    if (!context.mounted) return;

    if (event == null) {
      AppSnackBar.error(context, 'This event is no longer available.');
      return;
    }

    if (teacher &&
        (action == 'proposal_requirements_requested' ||
            action == 'proposal-documents' ||
            action == 'proposal_under_review')) {
      await push(TeacherProposalRequirementsPage(event: event));
      return;
    }

    if (teacher) {
      await push(TeacherEventManage(event: event));
      return;
    }

    if (action == 'student_requirements_approved' ||
        action == 'student_requirements_declined') {
      await push(
        StudentRegistrationRequirementsPage(
          eventId: eventId,
          event: event,
        ),
      );
      return;
    }

    final userId = (user?['id']?.toString() ?? '').trim();
    String? yearLevel;
    String? courseCode;
    String? specialization;
    if (userId.isNotEmpty) {
      final scope = await eventService.getStudentTargetScope(userId);
      yearLevel = scope['yearLevel'];
      courseCode = scope['courseCode'];
      specialization = scope['specialization'];
    } else {
      yearLevel = await auth.getStudentYearLevel();
      courseCode = await auth.getStudentCourseCode();
    }
    if (!context.mounted) return;

    final allowed = eventService.isStudentAllowedForEvent(
      event,
      yearLevel: yearLevel,
      courseCode: courseCode,
      specialization: specialization,
    );
    if (!allowed) {
      AppSnackBar.warning(context, 'This event is not available for your course/year level.');
      return;
    }

    await push(
      StudentEventDetails(
        eventId: eventId,
        initialEvent: event,
      ),
    );
  }
}
