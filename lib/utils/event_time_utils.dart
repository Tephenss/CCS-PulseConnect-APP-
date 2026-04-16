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
