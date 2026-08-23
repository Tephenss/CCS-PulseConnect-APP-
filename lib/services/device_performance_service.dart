import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Runtime quality level applied to animations / images / transitions.
enum PerformanceTier {
  low,
  medium,
  high,
}

/// User-facing preference in Settings (no Auto — pick a real mode).
enum PerformanceModePreference {
  batterySaver,
  balanced,
  highQuality,
}

extension PerformanceModePreferenceX on PerformanceModePreference {
  String get storageValue => name;

  String get title {
    switch (this) {
      case PerformanceModePreference.batterySaver:
        return 'Battery Saver';
      case PerformanceModePreference.balanced:
        return 'Balanced';
      case PerformanceModePreference.highQuality:
        return 'High Quality';
    }
  }

  String get shortDescription {
    switch (this) {
      case PerformanceModePreference.batterySaver:
        return 'Fewer animations, lighter images — smoothest on low-end';
      case PerformanceModePreference.balanced:
        return 'Some motion, moderate image quality';
      case PerformanceModePreference.highQuality:
        return 'Full shine, shimmer, and sharper images';
    }
  }

  PerformanceTier get tier {
    switch (this) {
      case PerformanceModePreference.batterySaver:
        return PerformanceTier.low;
      case PerformanceModePreference.balanced:
        return PerformanceTier.medium;
      case PerformanceModePreference.highQuality:
        return PerformanceTier.high;
    }
  }

  static PerformanceModePreference fromTier(PerformanceTier tier) {
    switch (tier) {
      case PerformanceTier.low:
        return PerformanceModePreference.batterySaver;
      case PerformanceTier.medium:
        return PerformanceModePreference.balanced;
      case PerformanceTier.high:
        return PerformanceModePreference.highQuality;
    }
  }

  static PerformanceModePreference fromStorage(
    String? raw, {
    required PerformanceTier suggested,
  }) {
    switch ((raw ?? '').trim()) {
      case 'batterySaver':
        return PerformanceModePreference.batterySaver;
      case 'balanced':
        return PerformanceModePreference.balanced;
      case 'highQuality':
        return PerformanceModePreference.highQuality;
      // Legacy "auto" / empty → device-suggested mode.
      case 'auto':
      case '':
      default:
        return fromTier(suggested);
    }
  }
}

extension PerformanceTierLabel on PerformanceTier {
  String get label {
    switch (this) {
      case PerformanceTier.low:
        return 'Battery Saver';
      case PerformanceTier.medium:
        return 'Balanced';
      case PerformanceTier.high:
        return 'High Quality';
    }
  }
}

/// Device-suggested tier + user Performance Mode preference.
class DevicePerformance extends ChangeNotifier {
  DevicePerformance._();
  static final DevicePerformance instance = DevicePerformance._();

  static const _prefsKey = 'performance_mode_pref';

  PerformanceTier _tier = PerformanceTier.medium;
  PerformanceTier _suggestedTier = PerformanceTier.medium;
  PerformanceModePreference _preference =
      PerformanceModePreference.balanced;

  PerformanceTier get tier => _tier;
  PerformanceTier get suggestedTier => _suggestedTier;
  PerformanceModePreference get preference => _preference;

  bool get isSuggestedSelected =>
      PerformanceModePreferenceX.fromTier(_suggestedTier) == _preference;

  bool _initialized = false;
  bool get isInitialized => _initialized;

  int? _ramMb;
  int get cores => Platform.numberOfProcessors;
  int? get ramMb => _ramMb;

  bool get enableShine => _tier == PerformanceTier.high;
  // Battery Saver keeps decorative loops static; functional progress
  // indicators and direct interaction feedback remain available.
  bool get enableDecorativeMotion => _tier != PerformanceTier.low;
  bool get enableHeavyShadows => _tier == PerformanceTier.high;
  bool get enableShadows => _tier != PerformanceTier.low;

  Duration get pageForwardDuration => switch (_tier) {
        PerformanceTier.low => const Duration(milliseconds: 140),
        PerformanceTier.medium => const Duration(milliseconds: 180),
        PerformanceTier.high => const Duration(milliseconds: 240),
      };

  Duration get pageReverseDuration => switch (_tier) {
        PerformanceTier.low => const Duration(milliseconds: 100),
        PerformanceTier.medium => const Duration(milliseconds: 140),
        PerformanceTier.high => const Duration(milliseconds: 180),
      };

  int get imageCacheWidth => switch (_tier) {
        PerformanceTier.low => 480,
        PerformanceTier.medium => 720,
        PerformanceTier.high => 1080,
      };

  /// Subtitle for profile menu card.
  String get settingsSubtitle {
    if (isSuggestedSelected) {
      return '${_preference.title} · For this device';
    }
    return _preference.title;
  }

  double shadowBlur(double full) {
    if (_tier == PerformanceTier.low) return 0;
    if (_tier == PerformanceTier.medium) return full * 0.35;
    return full;
  }

  double shadowOpacity(double full) {
    if (_tier == PerformanceTier.low) return 0;
    if (_tier == PerformanceTier.medium) return full * 0.5;
    return full;
  }

  Future<void> init() async {
    if (_initialized) return;

    _ramMb = await _androidTotalMemMb();
    _suggestedTier = _detectSuggestedTier(cores: cores, ramMb: _ramMb);

    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_prefsKey);
    _preference = PerformanceModePreferenceX.fromStorage(
      raw,
      suggested: _suggestedTier,
    );

    // Persist migration away from legacy "auto".
    if (raw == null || raw.trim().isEmpty || raw.trim() == 'auto') {
      await prefs.setString(_prefsKey, _preference.storageValue);
    }

    _applyPreference(notify: false);
    _initialized = true;
    debugPrint(
      '[perf] pref=${_preference.name} tier=${_tier.name} '
      'suggested=${_suggestedTier.name} cores=$cores ramMb=${_ramMb ?? 'n/a'}',
    );
    _applyImageCacheLimits();
  }

  Future<void> setPreference(PerformanceModePreference preference) async {
    _preference = preference;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsKey, preference.storageValue);
    _applyPreference();
    _applyImageCacheLimits();
    debugPrint('[perf] preference=${_preference.name} → tier=${_tier.name}');
  }

  void _applyPreference({bool notify = true}) {
    _tier = _preference.tier;
    if (notify) notifyListeners();
  }

  PerformanceTier _detectSuggestedTier({
    required int cores,
    required int? ramMb,
  }) {
    if (kIsWeb) return PerformanceTier.medium;

    if (ramMb == null) {
      if (cores <= 6) return PerformanceTier.low;
      if (cores >= 8) return PerformanceTier.medium;
      return PerformanceTier.low;
    }

    if (ramMb < 4800 || cores <= 4) return PerformanceTier.low;
    if (ramMb >= 8000 && cores >= 8) return PerformanceTier.high;
    return PerformanceTier.medium;
  }

  Future<int?> _androidTotalMemMb() async {
    if (kIsWeb || !Platform.isAndroid) return null;
    try {
      final lines = await File('/proc/meminfo').readAsLines();
      for (final line in lines) {
        if (!line.startsWith('MemTotal:')) continue;
        final kb = int.tryParse(line.replaceAll(RegExp(r'[^0-9]'), ''));
        if (kb == null) return null;
        return kb ~/ 1024;
      }
    } catch (_) {}
    return null;
  }

  void _applyImageCacheLimits() {
    switch (_tier) {
      case PerformanceTier.low:
        PaintingBinding.instance.imageCache.maximumSize = 40;
        PaintingBinding.instance.imageCache.maximumSizeBytes = 32 << 20;
      case PerformanceTier.medium:
        PaintingBinding.instance.imageCache.maximumSize = 80;
        PaintingBinding.instance.imageCache.maximumSizeBytes = 64 << 20;
      case PerformanceTier.high:
        PaintingBinding.instance.imageCache.maximumSize = 120;
        PaintingBinding.instance.imageCache.maximumSizeBytes = 100 << 20;
    }
  }

  @Deprecated('Use setPreference instead')
  void forceTier(PerformanceTier tier) {
    unawaited(setPreference(PerformanceModePreferenceX.fromTier(tier)));
  }
}
