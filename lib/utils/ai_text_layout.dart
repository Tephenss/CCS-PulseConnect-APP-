class AiTextLayout {
  static String formatImprovedDescription(String text) {
    var cleaned = text.replaceAll('\r\n', '\n').replaceAll('\r', '\n').trim();
    if (cleaned.isEmpty) return '';

    cleaned = cleaned.replaceAll(RegExp(r'[ \t]*•[ \t]*'), '\n• ');
    cleaned = cleaned.replaceAll(RegExp(r'\n+•\s*'), '\n• ');

    cleaned = cleaned.replaceAllMapped(
      RegExp(r'[ \t]+-\s+(?=[A-Z(])'),
      (_) => '\n- ',
    );

    cleaned = cleaned.replaceAllMapped(
      RegExp(r'([.:!?])\n•\s*'),
      (match) => '${match.group(1)}\n\n• ',
    );
    cleaned = cleaned.replaceAllMapped(
      RegExp(r'([.:!?])\n-\s*'),
      (match) => '${match.group(1)}\n\n- ',
    );

    if (!cleaned.contains('\n\n') && cleaned.length > 220) {
      cleaned = cleaned.replaceAllMapped(
        RegExp(r'([.!?])\s+(?=[A-Z(])'),
        (match) => '${match.group(1)}\n\n',
      );
    }

    cleaned = cleaned.replaceAll(RegExp(r'\n{3,}'), '\n\n');
    cleaned = cleaned.replaceAll(RegExp(r'[^\S\n]{2,}'), ' ');

    return cleaned.trim();
  }
}
