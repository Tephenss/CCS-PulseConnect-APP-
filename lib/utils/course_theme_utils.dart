import 'package:flutter/material.dart';

class CourseThemeUtils {
  static String normalizeCourse(dynamic rawCourse) {
    final value = rawCourse?.toString().trim().toUpperCase() ?? '';
    if (value == 'BSCS') return 'CS';
    if (value == 'BSIT') return 'IT';
    return value;
  }

  static bool isComputerScienceCourse(dynamic rawCourse) {
    return normalizeCourse(rawCourse) == 'CS';
  }

  static Color studentPrimaryForCourse(dynamic rawCourse) {
    return isComputerScienceCourse(rawCourse)
        ? const Color(0xFF047857)
        : const Color(0xFF7F1D1D);
  }

  static Color studentSecondaryForCourse(dynamic rawCourse) {
    return const Color(0xFFD4A843);
  }

  static Color studentDarkForCourse(dynamic rawCourse) {
    return isComputerScienceCourse(rawCourse)
        ? const Color(0xFF064E3B)
        : const Color(0xFF450A0A);
  }

  static Color studentLightForCourse(dynamic rawCourse) {
    return isComputerScienceCourse(rawCourse)
        ? const Color(0xFF047857)
        : const Color(0xFFBE123C);
  }

  static Color studentSoftForCourse(dynamic rawCourse) {
    return isComputerScienceCourse(rawCourse)
        ? const Color(0xFF6EE7B7)
        : const Color(0xFFFCA5A5);
  }

  static Color studentActionForCourse(dynamic rawCourse) {
    return isComputerScienceCourse(rawCourse)
        ? const Color(0xFF047857)
        : const Color(0xFF9F1239);
  }

  static bool isGreenStudentPrimary(Color primary) {
    return primary.toARGB32() == const Color(0xFF047857).toARGB32() ||
        primary.toARGB32() == const Color(0xFF16A34A).toARGB32();
  }

  static Color studentDarkFromPrimary(Color primary) {
    return isGreenStudentPrimary(primary)
        ? const Color(0xFF064E3B)
        : const Color(0xFF450A0A);
  }

  static Color studentLightFromPrimary(Color primary) {
    return isGreenStudentPrimary(primary)
        ? const Color(0xFF047857)
        : const Color(0xFFBE123C);
  }

  static Color studentSoftFromPrimary(Color primary) {
    return isGreenStudentPrimary(primary)
        ? const Color(0xFF6EE7B7)
        : const Color(0xFFFCA5A5);
  }

  static Color studentActionFromPrimary(Color primary) {
    return isGreenStudentPrimary(primary)
        ? const Color(0xFF047857)
        : const Color(0xFF9F1239);
  }

  /// Ticket cards: deep maroon / emerald — avoids bright pink-red stops.
  static List<Color> studentTicketGradientFromPrimary(Color primary) {
    if (isGreenStudentPrimary(primary)) {
      return const [
        Color(0xFF064E3B),
        Color(0xFF047857),
        Color(0xFF065F46),
        Color(0xFF064E3B),
      ];
    }
    return const [
      Color(0xFF3A0F14),
      Color(0xFF5C1F27),
      Color(0xFF4A181E),
      Color(0xFF3A0F14),
    ];
  }

  /// App bar / chrome: darker maroon than [studentActionFromPrimary] (less “red”).
  static Color studentChromeFromPrimary(Color primary) {
    return isGreenStudentPrimary(primary)
        ? const Color(0xFF064E3B)
        : const Color(0xFF7F1D1D);
  }

  static Color shade(Color color, double amount) {
    final hsl = HSLColor.fromColor(color);
    final lightness = (hsl.lightness + amount).clamp(0.0, 1.0);
    return hsl.withLightness(lightness).toColor();
  }
}
