/// Shared display helpers for stored / parsed class-schedule rows.

String classScheduleFormatTimeLabel(String label) {
  final parts = label
      .split(RegExp(r'\s*;\s*'))
      .map((p) => p.trim())
      .where((p) => p.isNotEmpty)
      .map(classScheduleFormatTimeRange)
      .where((p) => p.isNotEmpty);
  return parts.join('; ');
}

String classScheduleFormatTimeRange(String raw) {
  final original = raw.trim();
  if (original.isEmpty) return '';
  if (RegExp(r'[ap]\.?m\.?', caseSensitive: false).hasMatch(original) &&
      original.contains('–')) {
    return original;
  }
  var t = original.toLowerCase().replaceAll(' ', '').replaceAll('.', '');
  t = t.replaceAll('–', '-').replaceAll('—', '-');
  final range = RegExp(r'^(\d{1,2}):(\d{2})(am|pm)?-(\d{1,2}):(\d{2})(am|pm)?$')
      .firstMatch(t);
  if (range != null) {
    final h1 = int.parse(range.group(1)!);
    final min1 = int.parse(range.group(2)!);
    final h2 = int.parse(range.group(4)!);
    final min2 = int.parse(range.group(5)!);
    final pair = _pairMeridians(h1, h2, range.group(3) ?? '', range.group(6) ?? '');
    return '${_clock(h1, min1, pair.$1)} – ${_clock(h2, min2, pair.$2)}';
  }
  final single = RegExp(r'^(\d{1,2}):(\d{2})(am|pm)?$').firstMatch(t);
  if (single != null) {
    final h = int.parse(single.group(1)!);
    final min = int.parse(single.group(2)!);
    var p = (single.group(3) ?? '').toUpperCase();
    if (p.isEmpty) p = _defaultMeridian(h);
    return _clock(h, min, p);
  }
  return original;
}

String classScheduleDayLabel(String raw) {
  switch (raw.trim().toLowerCase()) {
    case 'm':
    case 'mon':
    case 'monday':
      return 'Mon';
    case 't':
    case 'tue':
    case 'tues':
    case 'tuesday':
      return 'Tue';
    case 'w':
    case 'wed':
    case 'wednesday':
      return 'Wed';
    case 'th':
    case 'thu':
    case 'thur':
    case 'thurs':
    case 'thursday':
      return 'Thu';
    case 'f':
    case 'fri':
    case 'friday':
      return 'Fri';
    case 's':
    case 'sat':
    case 'saturday':
      return 'Sat';
    case 'su':
    case 'sun':
    case 'sunday':
      return 'Sun';
    default:
      return raw.trim();
  }
}

String _defaultMeridian(int hour) {
  if (hour >= 1 && hour <= 6) return 'PM';
  if (hour == 12) return 'PM';
  return 'AM';
}

(String, String) _pairMeridians(
  int startHour,
  int endHour,
  String startRaw,
  String endRaw,
) {
  var start = startRaw.toUpperCase();
  var end = endRaw.toUpperCase();
  if (start.isEmpty) start = _defaultMeridian(startHour);
  if (end.isEmpty) {
    end = _defaultMeridian(endHour);
    if (startHour > endHour) {
      end = 'PM';
    } else if (start == 'PM' && endHour >= 7 && endHour <= 11) {
      end = 'PM';
    }
  }
  return (start, end);
}

String _clock(int hour, int minute, String meridian) {
  final mm = minute.toString().padLeft(2, '0');
  return '$hour:$mm ${meridian.toUpperCase()}';
}
