class EventFormValidation {
  static const int descriptionMaxWords = 200;
  static const int eventFeeMax = 5000;
  static const int eventFeeMaxDigits = 4;

  static int countWords(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return 0;
    return trimmed.split(RegExp(r'\s+')).where((part) => part.isNotEmpty).length;
  }

  static String truncateToWordLimit(String text, int maxWords) {
    final raw = text;
    if (countWords(raw) <= maxWords) return raw;

    final buffer = StringBuffer();
    var words = 0;
    var inWord = false;

    for (var i = 0; i < raw.length; i++) {
      final char = raw[i];
      final isWhitespace = RegExp(r'\s').hasMatch(char);
      if (!isWhitespace) {
        if (!inWord) {
          words++;
          if (words > maxWords) break;
          inWord = true;
        }
        buffer.write(char);
      } else {
        inWord = false;
        buffer.write(char);
      }
    }

    return buffer.toString().trimRight();
  }

  static String? validateDescription(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) {
      return 'Event description is required.';
    }
    if (countWords(trimmed) > descriptionMaxWords) {
      return 'Description must be $descriptionMaxWords words or less.';
    }
    return null;
  }

  static String normalizeEventFeeInput(String raw) {
    final digitsOnly = raw.replaceAll(RegExp(r'\D'), '');
    final limited = digitsOnly.length > eventFeeMaxDigits
        ? digitsOnly.substring(0, eventFeeMaxDigits)
        : digitsOnly;
    if (limited.isEmpty) return '';
    final num = int.tryParse(limited);
    if (num == null) return '';
    if (num > eventFeeMax) return eventFeeMax.toString();
    return limited;
  }

  static String? validateEventFee(String raw, {required bool isPaid}) {
    if (!isPaid) return null;
    final normalized = normalizeEventFeeInput(raw);
    if (normalized.isEmpty) {
      return 'Enter the settlement amount for this paid event.';
    }
    final fee = int.tryParse(normalized);
    if (fee == null || fee <= 0) {
      return 'Enter the settlement amount for this paid event.';
    }
    if (fee > eventFeeMax) {
      return 'Settlement amount cannot exceed ₱${eventFeeMax.toString()}.';
    }
    return null;
  }
}
