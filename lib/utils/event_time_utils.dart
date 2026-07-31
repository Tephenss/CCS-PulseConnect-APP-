import 'package:intl/intl.dart';

const Duration kManilaOffset = Duration(hours: 8);

DateTime? parseStoredEventDateTime(dynamic raw) {
  final text = raw?.toString().trim() ?? '';
  if (text.isEmpty) return null;

  final parsed = DateTime.tryParse(text);
  if (parsed == null) return null;

  final hasExplicitOffset = RegExp(
    r'(z|[+-]\d{2}:\d{2}|[+-]\d{4})$',
    caseSensitive: false,
  ).hasMatch(text);

  if (hasExplicitOffset) {
    return parsed.toUtc().add(kManilaOffset);
  }

  // Legacy values without timezone are treated as Manila wall time.
  return DateTime(
    parsed.year,
    parsed.month,
    parsed.day,
    parsed.hour,
    parsed.minute,
    parsed.second,
    parsed.millisecond,
    parsed.microsecond,
  );
}

bool usesEventSessions(Map<String, dynamic> event) {
  final embeddedSessions = event['sessions'];
  if (embeddedSessions is List && embeddedSessions.isNotEmpty) {
    return true;
  }

  final usesSessionsRaw = event['uses_sessions'];
  if (usesSessionsRaw == true ||
      (usesSessionsRaw?.toString().toLowerCase().trim() == 'true')) {
    return true;
  }

  final eventMode = (event['event_mode']?.toString() ?? '').toLowerCase().trim();
  if (eventMode == 'seminar_based') return true;

  final eventStructure =
      (event['event_structure']?.toString() ?? '').toLowerCase().trim();
  return eventStructure == 'one_seminar' || eventStructure == 'two_seminars';
}

String buildSessionDisplayName(Map<String, dynamic> session) {
  final title = (session['title']?.toString() ?? '').trim();
  if (title.isNotEmpty) return title;
  final topic = (session['topic']?.toString() ?? '').trim();
  if (topic.isNotEmpty) return topic;
  return 'Seminar';
}

String formatDateRange(DateTime? start, DateTime? end) {
  if (start == null) return 'TBA';
  if (end == null) return DateFormat('MMMM dd, yyyy').format(start);

  final isMultiDay = start.year != end.year ||
      start.month != end.month ||
      start.day != end.day;

  if (isMultiDay) {
    return '${DateFormat('MMMM dd, yyyy').format(start)} - ${DateFormat('MMMM dd, yyyy').format(end)}';
  }
  return DateFormat('MMMM dd, yyyy').format(start);
}

String formatTimeRange(DateTime? start, DateTime? end) {
  if (start == null) return 'TBA';
  if (end == null) return DateFormat('hh:mm a').format(start);
  return '${DateFormat('hh:mm a').format(start)} - ${DateFormat('hh:mm a').format(end)}';
}

/// Matches the teacher Events tab "Active" filter: published and not yet ended.
bool isTeacherActiveEvent(
  Map<String, dynamic> event, {
  DateTime? now,
}) {
  final status =
      (event['status']?.toString() ?? 'pending').toLowerCase().trim();
  if (status != 'published') return false;

  final reference = now ?? DateTime.now().toUtc().add(kManilaOffset);
  final endDate = parseStoredEventDateTime(event['end_at']);
  final isPast = endDate != null && endDate.isBefore(reference);
  return !isPast;
}

/// Home/calendar visibility: published or approved (ready to publish), not ended.
bool isCalendarVisibleEvent(
  Map<String, dynamic> event, {
  DateTime? now,
}) {
  final status =
      (event['status']?.toString() ?? 'pending').toLowerCase().trim();
  if (status != 'published' && status != 'approved') return false;

  final reference = now ?? DateTime.now().toUtc().add(kManilaOffset);
  final endDate = parseStoredEventDateTime(event['end_at']);
  final isPast = endDate != null && endDate.isBefore(reference);
  return !isPast;
}

int? normalizeRegistrationCloseWeeks(dynamic value) {
  if (value == null) return null;
  final raw = value.toString().trim();
  if (raw.isEmpty) return null;
  final parsed = int.tryParse(raw);
  if (parsed == null || parsed < 1 || parsed > 4) return null;
  return parsed;
}

int normalizeRegistrationCloseExtendDays(dynamic value) {
  if (value == null) return 0;
  final raw = value.toString().trim();
  if (raw.isEmpty) return 0;
  final parsed = int.tryParse(raw);
  // Stored offset from base close (DB allows up to 60); close date still
  // capped by organizers via edit UI / API at start-3 days.
  if (parsed == null || parsed < 0 || parsed > 60) return 0;
  return parsed;
}

bool isEventRegistrationWindowClosed(
  Map<String, dynamic> event, {
  DateTime? now,
}) {
  final lastDay = registrationLastDay(event);
  if (lastDay == null) return false;

  final reference = now ?? DateTime.now().toUtc().add(kManilaOffset);
  final today = DateTime(reference.year, reference.month, reference.day);
  return today.isAfter(lastDay);
}

DateTime? registrationLastDay(Map<String, dynamic> event) {
  final weeks = normalizeRegistrationCloseWeeks(event['registration_close_weeks']);
  if (weeks == null) return null;

  final start = parseStoredEventDateTime(event['start_at']);
  if (start == null) return null;

  final startDate = DateTime(start.year, start.month, start.day);
  final baseLastDay = startDate.subtract(Duration(days: weeks * 7));
  final extendDays = normalizeRegistrationCloseExtendDays(
    event['registration_close_extend_days'],
  );
  if (extendDays <= 0) return baseLastDay;
  return baseLastDay.add(Duration(days: extendDays));
}

String formatRegistrationDeadlineLabel(
  Map<String, dynamic> event, {
  DateTime? now,
}) {
  final lastDay = registrationLastDay(event);
  if (lastDay == null) return '';

  final dateText = DateFormat('MMM d, yyyy').format(lastDay);
  if (isEventRegistrationWindowClosed(event, now: now)) {
    return 'Closed on $dateText';
  }

  return 'Until $dateText';
}

String? registrationDeadlineSubtitle(Map<String, dynamic> event) {
  final weeks = normalizeRegistrationCloseWeeks(event['registration_close_weeks']);
  if (weeks == null) return null;

  final weeksLabel = '$weeks week${weeks == 1 ? '' : 's'} before event starts';
  final extendDays = normalizeRegistrationCloseExtendDays(
    event['registration_close_extend_days'],
  );
  final extendLabel = extendDays > 0
      ? ' · +$extendDays day${extendDays == 1 ? '' : 's'} extension'
      : '';
  final limitRaw = event['registration_limit']?.toString().trim() ?? '';
  final hasLimit = limitRaw.isNotEmpty && int.tryParse(limitRaw) != null;

  if (hasLimit) {
    return '$weeksLabel$extendLabel · May close earlier when slots are full';
  }

  return '$weeksLabel$extendLabel';
}

bool hasRegistrationDeadline(Map<String, dynamic> event) {
  return registrationLastDay(event) != null;
}
