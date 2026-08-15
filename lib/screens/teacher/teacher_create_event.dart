import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';
import 'package:speech_to_text/speech_to_text.dart';

import '../../services/ai_service.dart';
import '../../services/auth_service.dart';
import '../../services/event_service.dart';
import '../../services/mobile_backend_service.dart';
import '../../services/native_document_picker.dart';
import '../../utils/teacher_theme_utils.dart';
import '../../widgets/app_snackbar.dart';
import '../../widgets/custom_loader.dart';

class _ProposalReqDraft {
  _ProposalReqDraft({
    required this.code,
    required this.label,
    this.isDefault = false,
    this.file,
    this.fileName,
    TextEditingController? labelCtrl,
  }) : labelCtrl = labelCtrl ??
            (isDefault ? null : TextEditingController(text: label));

  final String code;
  String label;
  final bool isDefault;
  File? file;
  String? fileName;
  final TextEditingController? labelCtrl;
}

class TeacherCreateEvent extends StatefulWidget {
  const TeacherCreateEvent({super.key});

  @override
  State<TeacherCreateEvent> createState() => _TeacherCreateEventState();
}

class _TeacherCreateEventState extends State<TeacherCreateEvent> {
  int _currentStep = 1;
  static final DateFormat _dateTimeFormat = DateFormat('MM/dd/yyyy hh:mm a');
  static const Duration _manilaOffset = Duration(hours: 8);

  // Form Field Controllers
  final _titleCtrl = TextEditingController();
  final _locationCtrl = TextEditingController();
  final _descCtrl = TextEditingController();
  final _startDateCtrl = TextEditingController();
  final _endDateCtrl = TextEditingController();
  final _seminar1TitleCtrl = TextEditingController();
  final _seminar1StartCtrl = TextEditingController();
  final _seminar1EndCtrl = TextEditingController();
  final _seminar2TitleCtrl = TextEditingController();
  final _seminar2StartCtrl = TextEditingController();
  final _seminar2EndCtrl = TextEditingController();

  String _eventType = 'Event';
  final _eventTypeOtherCtrl = TextEditingController();
  String _targetCourse = 'ALL';
  List<String> _targetYears = ['ALL'];
  String _eventMode = 'simple';
  int _seminarCount = 1;
  final _graceTimeCtrl = TextEditingController(text: '30');
  final _eventFeeCtrl = TextEditingController();
  final _registrationLimitCtrl = TextEditingController();
  bool _isFreeEvent = true;
  int? _registrationCloseWeeks = 1;
  File? _coverFile;
  Uint8List? _coverBytes;
  String _submitStatus = '';

  final List<_ProposalReqDraft> _proposalItems = [
    _ProposalReqDraft(
      code: 'LU-AA-FO-113',
      label: 'LU-AA-FO-113(ACTIVITY PROPOSAL FORM)',
      isDefault: true,
    ),
    _ProposalReqDraft(
      code: 'LU-AA-FO-108',
      label: 'LU-AA-FO-108(ANNUAL PROPOSAL PLAN)',
      isDefault: true,
    ),
  ];
  final Set<String> _studentPresetCodes = <String>{};
  final List<TextEditingController> _studentOtherCtrls = [];

  static const Map<String, String> _studentRequirementPresets = {
    'PARENT_CONSENT': 'Parent Consent',
    'MEDICAL_CERTIFICATE': 'Medical Certificate',
    'STUDENT_ID': 'Student ID',
    'PARENTS_ID': "Parent's ID",
  };

  final _authService = AuthService();
  final _eventService = EventService();
  final _aiService = AiService();

  bool _isSubmitting = false;

  // Speech to Text Variables
  final SpeechToText _speechToText = SpeechToText();
  bool _speechEnabled = false;
  bool _isListening = false;
  String _lastWords = '';

  // AI Variables
  bool _isAiProcessing = false;
  String _previousDescription = '';
  bool _canUndo = false;

  String? _validationError;

  DateTime? _parseDateTime(String text) {
    if (text.trim().isEmpty) return null;
    try {
      final parsed = _dateTimeFormat.parseStrict(text.trim());
      // Keep wall-clock components stable so event times stay Manila-based
      // even if the device/emulator timezone is changed.
      return DateTime(
        parsed.year,
        parsed.month,
        parsed.day,
        parsed.hour,
        parsed.minute,
      );
    } catch (_) {
      return null;
    }
  }

  void _applySimpleEventEndDefaultFromStart() {
    if (_eventMode == 'seminar_based') return;
    final start = _parseDateTime(_startDateCtrl.text);
    if (start == null) {
      _endDateCtrl.text = '';
      return;
    }
    final fixedEnd = DateTime(start.year, start.month, start.day, 17, 0);
    _endDateCtrl.text = _dateTimeFormat.format(fixedEnd);
  }

  String _toUtcIsoFromManila(DateTime manilaWallTime) {
    final utc = DateTime.utc(
      manilaWallTime.year,
      manilaWallTime.month,
      manilaWallTime.day,
      manilaWallTime.hour,
      manilaWallTime.minute,
    ).subtract(_manilaOffset);
    return utc.toIso8601String();
  }

  bool _validateStep(int step) {
    setState(() => _validationError = null);
    if (step == 1) {
      if (_titleCtrl.text.trim().isEmpty) {
        setState(() => _validationError = 'Please enter an event title.');
        return false;
      }
      if (_locationCtrl.text.trim().isEmpty) {
        setState(() => _validationError = 'Please specify a location.');
        return false;
      }
      if (_eventType == 'Other') {
        final custom = _eventTypeOtherCtrl.text.trim();
        if (custom.isEmpty) {
          setState(
            () => _validationError = 'Specify what this Other event type is.',
          );
          return false;
        }
        if (custom.length > 80) {
          setState(
            () => _validationError =
                'Custom event type must be 80 characters or less.',
          );
          return false;
        }
      }
      if (!_isFreeEvent) {
        final fee = double.tryParse(_eventFeeCtrl.text.trim());
        if (fee == null || fee <= 0) {
          setState(
            () => _validationError =
                'Enter the settlement amount students must pay for this paid event.',
          );
          return false;
        }
      }
      final limitRaw = _registrationLimitCtrl.text.trim();
      if (limitRaw.isNotEmpty) {
        final limit = int.tryParse(limitRaw);
        if (limit == null || limit < 1 || limit > 9999) {
          setState(
            () => _validationError =
                'Student limit must be a whole number between 1 and 9999.',
          );
          return false;
        }
      }
    } else if (step == 2) {
      if (_descCtrl.text.trim().isEmpty) {
        setState(() => _validationError = 'Please add a description.');
        return false;
      }
    } else if (step == 3) {
      if (_eventMode == 'seminar_based') {
        DateTime? s1 = _parseDateTime(_seminar1StartCtrl.text);
        DateTime? e1 = _parseDateTime(_seminar1EndCtrl.text);
        if (_seminar1TitleCtrl.text.trim().isEmpty ||
            s1 == null ||
            e1 == null) {
          setState(
            () => _validationError =
                'Seminar 1 title, start, and end are required.',
          );
          return false;
        }
        if (e1.isBefore(s1) || e1.isAtSameMomentAs(s1)) {
          setState(
            () => _validationError =
                'Seminar 1 end time must be after start time.',
          );
          return false;
        }

        if (_seminarCount >= 2) {
          DateTime? s2 = _parseDateTime(_seminar2StartCtrl.text);
          DateTime? e2 = _parseDateTime(_seminar2EndCtrl.text);
          if (_seminar2TitleCtrl.text.trim().isEmpty ||
              s2 == null ||
              e2 == null) {
            setState(
              () => _validationError =
                  'Seminar 2 title, start, and end are required.',
            );
            return false;
          }
          if (e2.isBefore(s2) || e2.isAtSameMomentAs(s2)) {
            setState(
              () => _validationError =
                  'Seminar 2 end time must be after start time.',
            );
            return false;
          }
          if (s2.isBefore(e1) && e2.isAfter(s1)) {
            setState(
              () => _validationError = 'Seminar schedules must not overlap.',
            );
            return false;
          }
          if (!_isAllowedScheduleTime(s2) || !_isAllowedScheduleTime(e2)) {
            setState(
              () => _validationError =
                  'Seminar time must be 7:00 AM or later, and minutes must be 00 or 30 only.',
            );
            return false;
          }
        }
        if (!_isAllowedScheduleTime(s1) || !_isAllowedScheduleTime(e1)) {
          setState(
            () => _validationError =
                'Seminar time must be 7:00 AM or later, and minutes must be 00 or 30 only.',
          );
          return false;
        }
        if (s1.isBefore(_earliestAllowedCreateDateTime())) {
          setState(
            () => _validationError =
                'Seminar start date/time must be tomorrow or later (starting 7:00 AM).',
          );
          return false;
        }
      } else {
        DateTime? s1 = _parseDateTime(_startDateCtrl.text);
        DateTime? e1 = _parseDateTime(_endDateCtrl.text);
        if (s1 == null || e1 == null) {
          setState(
            () => _validationError = 'Start and end dates are required.',
          );
          return false;
        }
        final sameDay =
            s1.year == e1.year && s1.month == e1.month && s1.day == e1.day;
        if (!sameDay) {
          setState(
            () => _validationError =
                'For simple events, end date must be the same day as start date.',
          );
          return false;
        }
        if (e1.hour != 17 || e1.minute != 0) {
          setState(
            () => _validationError =
                'For simple events, end time is fixed at 5:00 PM.',
          );
          return false;
        }
        if (e1.isBefore(s1) || e1.isAtSameMomentAs(s1)) {
          setState(
            () => _validationError = 'End time must be after start time.',
          );
          return false;
        }
        if (!_isAllowedScheduleTime(s1)) {
          setState(
            () => _validationError =
                'Event time must be 7:00 AM or later, and minutes must be 00 or 30 only.',
          );
          return false;
        }
        if (s1.isBefore(_earliestAllowedCreateDateTime())) {
          setState(
            () => _validationError =
                'Start date/time must be tomorrow or later (starting 7:00 AM).',
          );
          return false;
        }
      }
      final maxClose = _maxRegistrationCloseWeeks();
      if (maxClose >= 1) {
        final closeWeeks = _registrationCloseWeeks ?? 0;
        if (closeWeeks < 1 || closeWeeks > maxClose) {
          setState(
            () => _validationError =
                'Registration close limit must be between 1 and $maxClose week${maxClose == 1 ? '' : 's'} for this start date.',
          );
          return false;
        }
      }
    } else if (step == 4) {
      for (var i = 0; i < _proposalItems.length; i++) {
        final item = _proposalItems[i];
        final label = item.isDefault
            ? item.label
            : (item.labelCtrl?.text.trim() ?? item.label.trim());
        if (label.isEmpty) {
          setState(
            () => _validationError =
                'Enter a title for every additional requirement.',
          );
          return false;
        }
        if (item.file == null) {
          setState(
            () => _validationError = 'Upload the file for "$label".',
          );
          return false;
        }
      }
    }
    return true;
  }

  bool _isAllowedScheduleTime(DateTime value) {
    if (value.hour < 7) return false;
    return value.minute == 0 || value.minute == 30;
  }

  DateTime _earliestAllowedCreateDateTime() {
    final now = DateTime.now();
    return DateTime(now.year, now.month, now.day).add(
      const Duration(days: 1, hours: 7),
    );
  }

  int _maxRegistrationCloseWeeks() {
    final start = _eventMode == 'seminar_based'
        ? _parseDateTime(_seminar1StartCtrl.text)
        : _parseDateTime(_startDateCtrl.text);
    if (start == null) return 0;
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final startDay = DateTime(start.year, start.month, start.day);
    final diffDays = startDay.difference(today).inDays;
    if (diffDays < 7) return 0;
    return diffDays ~/ 7 > 4 ? 4 : diffDays ~/ 7;
  }

  void _syncCloseWeeksForStart() {
    final maxClose = _maxRegistrationCloseWeeks();
    if (maxClose < 1) {
      _registrationCloseWeeks = null;
      return;
    }
    final current = _registrationCloseWeeks ?? 1;
    _registrationCloseWeeks = current.clamp(1, maxClose);
  }

  @override
  void initState() {
    super.initState();
    _initSpeech();
  }

  void _initSpeech() async {
    _speechEnabled = await _speechToText.initialize(
      onError: (val) {},
      onStatus: (val) {
        if (val == 'done' || val == 'notListening') {
          if (mounted) setState(() => _isListening = false);
        }
      },
    );
    setState(() {});
  }

  @override
  void dispose() {
    _titleCtrl.dispose();
    _locationCtrl.dispose();
    _descCtrl.dispose();
    _eventTypeOtherCtrl.dispose();
    _startDateCtrl.dispose();
    _endDateCtrl.dispose();
    _seminar1TitleCtrl.dispose();
    _seminar1StartCtrl.dispose();
    _seminar1EndCtrl.dispose();
    _seminar2TitleCtrl.dispose();
    _seminar2StartCtrl.dispose();
    _seminar2EndCtrl.dispose();
    _graceTimeCtrl.dispose();
    _eventFeeCtrl.dispose();
    _registrationLimitCtrl.dispose();
    for (final item in _proposalItems) {
      item.labelCtrl?.dispose();
    }
    for (final ctrl in _studentOtherCtrls) {
      ctrl.dispose();
    }
    _speechToText.stop();
    super.dispose();
  }

  String get _resolvedEventType {
    if (_eventType != 'Other') return _eventType;
    return _eventTypeOtherCtrl.text.trim();
  }

  void _submit() async {
    if (!_validateStep(3) || !_validateStep(4)) return;

    setState(() => _isSubmitting = true);
    final user = await _authService.getCurrentUser();
    final teacherId = user?['id'];

    final eventFor = _encodeTargetParticipant(_targetCourse, _targetYears);
    final graceTime = int.tryParse(_graceTimeCtrl.text) ?? 30;

    Map<String, dynamic> payload;
    if (_eventMode == 'seminar_based') {
      final sessions = <Map<String, dynamic>>[
        {
          'title': _seminar1TitleCtrl.text.trim(),
          'start_at': _toUtcIsoFromManila(
            _parseDateTime(_seminar1StartCtrl.text)!,
          ),
          'end_at': _toUtcIsoFromManila(_parseDateTime(_seminar1EndCtrl.text)!),
          'location': _locationCtrl.text.trim(),
          'scan_window_minutes': graceTime,
        },
      ];
      if (_seminarCount >= 2) {
        sessions.add({
          'title': _seminar2TitleCtrl.text.trim(),
          'start_at': _toUtcIsoFromManila(
            _parseDateTime(_seminar2StartCtrl.text)!,
          ),
          'end_at': _toUtcIsoFromManila(_parseDateTime(_seminar2EndCtrl.text)!),
          'location': _locationCtrl.text.trim(),
          'scan_window_minutes': graceTime,
        });
      }

      final starts =
          sessions
              .map((s) => DateTime.parse(s['start_at'] as String).toUtc())
              .toList()
            ..sort();
      final ends =
          sessions
              .map((s) => DateTime.parse(s['end_at'] as String).toUtc())
              .toList()
            ..sort();
      final firstStart = starts.first;
      final lastEnd = ends.last;

      payload = {
        'title': _titleCtrl.text.trim(),
        'description': _descCtrl.text.trim(),
        'location': _locationCtrl.text.trim(),
        'start_at': firstStart.toIso8601String(),
        'end_at': lastEnd.toIso8601String(),
        'event_type': _resolvedEventType,
        'event_for': eventFor,
        'grace_time': graceTime,
        'created_by': teacherId,
        'event_mode': 'seminar_based',
        'event_span':
            (firstStart.year == lastEnd.year &&
                firstStart.month == lastEnd.month &&
                firstStart.day == lastEnd.day)
            ? 'single_day'
            : 'multi_day',
        'sessions': sessions,
      };
      _applyRegistrationFields(payload);
    } else {
      final s1 = _parseDateTime(_startDateCtrl.text)!;
      final e1 = DateTime(s1.year, s1.month, s1.day, 17, 0);
      payload = {
        'title': _titleCtrl.text.trim(),
        'description': _descCtrl.text.trim(),
        'location': _locationCtrl.text.trim(),
        'start_at': _toUtcIsoFromManila(s1),
        'end_at': _toUtcIsoFromManila(e1),
        'event_type': _resolvedEventType,
        'event_for': eventFor,
        'grace_time': graceTime,
        'created_by': teacherId,
        'event_mode': 'simple',
        'event_span':
            (s1.year == e1.year && s1.month == e1.month && s1.day == e1.day)
            ? 'single_day'
            : 'multi_day',
        'sessions': const [],
      };
      _applyRegistrationFields(payload);
    }

    payload['proposal_requirements'] = _proposalItems
        .map(
          (item) => {
            'code': item.code,
            'label': item.isDefault
                ? item.label
                : (item.labelCtrl?.text.trim().isNotEmpty == true
                      ? item.labelCtrl!.text.trim()
                      : item.label),
          },
        )
        .toList();
    payload['student_requirements'] = _collectStudentRequirements();

    setState(() => _submitStatus = 'Saving event...');
    final result = await _eventService.createEvent(payload);
    if (!mounted) return;
    if (result['ok'] != true) {
      setState(() {
        _isSubmitting = false;
        _submitStatus = '';
      });
      _handleError(result['error']);
      return;
    }

    final created = result['event'];
    final eventId = created is Map
        ? (created['id']?.toString() ?? '').trim()
        : '';
    if (eventId.isEmpty) {
      setState(() {
        _isSubmitting = false;
        _submitStatus = '';
      });
      _handleError('Event was created but no event id was returned.');
      return;
    }

    try {
      if (_coverFile != null && _coverBytes != null) {
        setState(() => _submitStatus = 'Uploading cover image...');
        final coverName = _coverFile!.path.split(Platform.pathSeparator).last;
        final coverRes = await MobileBackendService().uploadEventCoverFile(
          eventId: eventId,
          bytes: _coverBytes!,
          fileName: coverName.isEmpty ? 'cover.jpg' : coverName,
        );
        if (coverRes['ok'] != true && mounted) {
          AppSnackBar.warning(
            context,
            coverRes['error']?.toString() ??
                'Event saved, but cover upload failed.',
          );
        }
      }

      final savedReqs = created is Map && created['proposal_requirements'] is List
          ? List<Map<String, dynamic>>.from(
              (created['proposal_requirements'] as List).whereType<Map>().map(
                (row) => Map<String, dynamic>.from(row),
              ),
            )
          : <Map<String, dynamic>>[];
      if (savedReqs.length != _proposalItems.length) {
        throw Exception(
          'Proposal requirements could not be prepared. Nothing was submitted.',
        );
      }

      for (var i = 0; i < _proposalItems.length; i++) {
        final item = _proposalItems[i];
        final file = item.file;
        if (file == null) continue;
        final requirementId = (savedReqs[i]['id']?.toString() ?? '').trim();
        if (requirementId.isEmpty) {
          throw Exception('Missing uploaded proposal file data.');
        }
        setState(
          () => _submitStatus =
              'Uploading proposal file ${i + 1} of ${_proposalItems.length}...',
        );
        final bytes = await file.readAsBytes();
        final uploadRes = await MobileBackendService().uploadProposalDocumentFile(
          eventId: eventId,
          requirementId: requirementId,
          bytes: bytes,
          fileName: (item.fileName ?? file.path.split(Platform.pathSeparator).last)
              .trim()
              .isEmpty
              ? 'proposal-document'
              : (item.fileName ?? file.path.split(Platform.pathSeparator).last),
        );
        if (uploadRes['ok'] != true) {
          throw Exception(
            uploadRes['error']?.toString() ?? 'Failed to upload ${item.label}.',
          );
        }
      }

      setState(() => _submitStatus = 'Submitting proposal for admin review...');
      final reviewRes = await MobileBackendService().submitProposalReviewSecure(
        eventId: eventId,
      );
      if (reviewRes['ok'] != true) {
        throw Exception(
          reviewRes['error']?.toString() ??
              'Failed to submit the proposal for review.',
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isSubmitting = false;
          _submitStatus = '';
        });
        _handleError(e.toString().replaceFirst('Exception: ', ''));
      }
      return;
    }

    if (!mounted) return;
    setState(() {
      _isSubmitting = false;
      _submitStatus = '';
    });
    _handleSuccess();
  }

  void _applyRegistrationFields(Map<String, dynamic> payload) {
    payload['is_free_event'] = _isFreeEvent;
    if (_isFreeEvent) {
      payload['event_fee'] = null;
    } else {
      payload['event_fee'] =
          double.tryParse(_eventFeeCtrl.text.trim()) ?? 0;
    }
    final limitRaw = _registrationLimitCtrl.text.trim();
    payload['registration_limit'] = limitRaw.isEmpty
        ? null
        : int.tryParse(limitRaw);
    final maxClose = _maxRegistrationCloseWeeks();
    payload['registration_close_weeks'] =
        (maxClose >= 1) ? (_registrationCloseWeeks ?? 1).clamp(1, maxClose) : null;
  }

  List<Map<String, String>> _collectStudentRequirements() {
    final items = <Map<String, String>>[];
    for (final entry in _studentRequirementPresets.entries) {
      if (_studentPresetCodes.contains(entry.key)) {
        items.add({'code': entry.key, 'label': entry.value});
      }
    }
    for (final ctrl in _studentOtherCtrls) {
      final label = ctrl.text.trim();
      if (label.isNotEmpty) {
        items.add({'code': 'OTHER', 'label': label});
      }
    }
    return items;
  }

  List<String> _normalizeTargetYears(List<String> values) {
    final cleaned = values
        .map((v) => v.trim().toUpperCase())
        .where((v) => ['ALL', '1', '2', '3', '4'].contains(v))
        .toList();
    if (cleaned.contains('ALL') || cleaned.isEmpty) {
      return ['ALL'];
    }
    return cleaned.toSet().toList();
  }

  void _toggleTargetYear(String value, bool selected) {
    final normalizedValue = value.trim().toUpperCase();
    final current = List<String>.from(_targetYears);

    if (normalizedValue == 'ALL') {
      setState(() {
        _targetYears = selected ? ['ALL'] : ['ALL'];
      });
      return;
    }

    if (selected) {
      current.remove('ALL');
      current.add(normalizedValue);
    } else {
      current.remove(normalizedValue);
    }

    setState(() {
      _targetYears = _normalizeTargetYears(current);
    });
  }

  String _encodeTargetParticipant(String courseValue, List<String> yearValues) {
    final course = courseValue.trim().toUpperCase();
    final years = _normalizeTargetYears(yearValues);
    const allowedCourses = ['ALL', 'BSIT', 'BSIT-SD', 'BSIT-BA', 'BSCS'];
    final normalizedCourse = allowedCourses.contains(course) ? course : 'ALL';

    if (normalizedCourse == 'ALL' &&
        years.length == 1 &&
        years.first == 'ALL') {
      return 'All';
    }
    if (normalizedCourse == 'ALL' && years.length == 1) {
      return years.first;
    }
    if (years.length == 1 && years.first == 'ALL') {
      return normalizedCourse;
    }
    return 'COURSE=$normalizedCourse;YEARS=${years.join(',')}';
  }

  void _handleSuccess() {
    AppSnackBar.success(
      context,
      'Event saved and submitted for admin review.',
    );
    Navigator.pop(context, true);
  }

  void _handleError(dynamic error) {
    AppSnackBar.error(context, 'Failed to save: $error');
  }

  void _next() {
    if (!_validateStep(_currentStep)) return;
    if (_currentStep < 4) setState(() => _currentStep++);
  }

  void _back() {
    if (_currentStep > 1) setState(() => _currentStep--);
  }

  // --- Voice Control Logic ---
  void _listenToggle() async {
    if (!_speechEnabled) {
      AppSnackBar.error(context, 'Speech recognition not available on this device.');
      return;
    }

    if (_speechToText.isNotListening) {
      FocusScope.of(context).unfocus(); // Request focus drop so keyboard hides
      _lastWords = _descCtrl.text;
      await _speechToText.listen(
        onResult: (result) {
          setState(() {
            _descCtrl.text = _lastWords.isEmpty
                ? result.recognizedWords
                : '$_lastWords ${result.recognizedWords}';
          });
        },
      );
      setState(() => _isListening = true);
    } else {
      await _speechToText.stop();
      setState(() => _isListening = false);
    }
  }

  // --- AI Improve Logic ---
  void _improveWithAi() async {
    if (_descCtrl.text.trim().isEmpty) {
      AppSnackBar.warning(context, 'Please add some description text first.');
      return;
    }

    setState(() => _isAiProcessing = true);

    final aiResult = await _aiService.improveText(_descCtrl.text);

    if (mounted) {
      setState(() => _isAiProcessing = false);
      if (aiResult['ok'] == true) {
        _previousDescription = _descCtrl.text;
        setState(() {
          _descCtrl.text = aiResult['improved_text'];
          _canUndo = true;
        });
        AppSnackBar.success(context, 'Description improved by AI!');
      } else {
        AppSnackBar.error(context, aiResult['error'].toString());
      }
    }
  }

  void _undoAiImprove() {
    setState(() {
      _descCtrl.text = _previousDescription;
      _canUndo = false;
    });
  }

  // --- Description helpers ---
  void _openDescriptionFullScreen() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (context) {
        return DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.9,
          maxChildSize: 0.98,
          minChildSize: 0.6,
          builder: (context, scrollController) {
            return Padding(
              padding: EdgeInsets.only(
                left: 24,
                right: 24,
                top: 20,
                bottom: MediaQuery.of(context).viewInsets.bottom + 20,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Text(
                        'Description (Expanded)',
                        style: TextStyle(
                          fontWeight: FontWeight.w800,
                          fontSize: 16,
                          color: Color(0xFF111827),
                        ),
                      ),
                      const Spacer(),
                      IconButton(
                        icon: const Icon(
                          Icons.close_rounded,
                          size: 20,
                          color: Color(0xFF9CA3AF),
                        ),
                        onPressed: () => Navigator.pop(context),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Expanded(
                    child: SingleChildScrollView(
                      controller: scrollController,
                      child: TextFormField(
                        controller: _descCtrl,
                        maxLines: null,
                        keyboardType: TextInputType.multiline,
                        style: const TextStyle(
                          fontSize: 15,
                          color: Color(0xFF111827),
                          height: 1.5,
                        ),
                        decoration: const InputDecoration(
                          hintText:
                              'Tell attendees what this event is about...\n\nBe descriptive and exciting!',
                          hintStyle: TextStyle(
                            color: Color(0xFF9CA3AF),
                            fontSize: 15,
                            height: 1.5,
                          ),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.all(Radius.circular(20)),
                          ),
                          contentPadding: EdgeInsets.fromLTRB(20, 20, 20, 20),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      body: SafeArea(
        child: Column(
          children: [
            _buildHeader(),
            Container(
              color: const Color(0xFFF3F4F6),
              height: 1,
            ), // Soft subtle divider
            _buildStepperRow(),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(
                  horizontal: 24,
                  vertical: 20,
                ),
                child: _buildStepContent(),
              ),
            ),
            Container(
              decoration: BoxDecoration(
                color: Colors.white,
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.03),
                    blurRadius: 10,
                    offset: const Offset(0, -2),
                  ),
                ],
              ),
              child: _buildBottomNav(),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader() {
    String subtitle = 'Fill in the event info';
    if (_currentStep == 2) subtitle = 'Add a detailed description';
    if (_currentStep == 3) subtitle = 'Set the exact schedule';
    if (_currentStep == 4) subtitle = 'Event & student requirements';

    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 20, 20, 16),
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: TeacherThemeUtils.primary.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(12),
            ),
            child: const Icon(
              Icons.event_available_rounded,
              color: TeacherThemeUtils.primary,
              size: 22,
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Create Event',
                  style: TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: 20,
                    color: Color(0xFF111827),
                    letterSpacing: -0.3,
                  ),
                ),
                Text(
                  subtitle,
                  style: const TextStyle(
                    color: Color(0xFF6B7280),
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.close_rounded, color: Color(0xFF9CA3AF)),
            onPressed: () => Navigator.pop(context),
          ),
        ],
      ),
    );
  }

  Widget _buildStepperRow() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 20),
      child: Row(
        children: [
          _buildStepIndicator(1, 'Info'),
          _buildLine(1),
          _buildStepIndicator(2, 'Details'),
          _buildLine(2),
          _buildStepIndicator(3, 'Sched'),
          _buildLine(3),
          _buildStepIndicator(4, 'Reqs'),
        ],
      ),
    );
  }

  Widget _buildStepIndicator(int stepNum, String title) {
    bool isActiveOrPassed = _currentStep >= stepNum;
    bool isActive = _currentStep == stepNum;

    Color color = isActiveOrPassed
        ? TeacherThemeUtils.primary
        : const Color(0xFFD1D5DB);
    Color textColor = isActiveOrPassed
        ? TeacherThemeUtils.primary
        : const Color(0xFF9CA3AF);

    return Row(
      children: [
        AnimatedContainer(
          duration: const Duration(milliseconds: 300),
          width: 30,
          height: 30,
          decoration: BoxDecoration(
            color: isActive
                ? color.withValues(alpha: 0.15)
                : (isActiveOrPassed ? color : Colors.transparent),
            shape: BoxShape.circle,
            border: Border.all(color: color, width: 2),
          ),
          child: Center(
            child: Text(
              '$stepNum',
              style: TextStyle(
                color: isActive
                    ? color
                    : (isActiveOrPassed ? Colors.white : color),
                fontWeight: FontWeight.w800,
                fontSize: 13,
              ),
            ),
          ),
        ),
        if (isActive) ...[
          const SizedBox(width: 6),
          Text(
            title,
            style: TextStyle(
              color: textColor,
              fontWeight: FontWeight.w800,
              fontSize: 12,
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildLine(int stepNum) {
    bool isPassed = _currentStep > stepNum;
    Color color = isPassed
        ? const Color(0xFFD4A843)
        : const Color(
            0xFFF3F4F6,
          ); // Gold when pass, soft bare grey when pending
    return Expanded(
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 300),
        height: 2,
        margin: const EdgeInsets.symmetric(horizontal: 10),
        color: color,
        curve: Curves.easeInOut,
      ),
    );
  }

  Widget _buildStepContent() {
    return Column(
      children: [
        if (_validationError != null) _buildErrorBanner(),
        if (_currentStep == 1) _buildStep1(),
        if (_currentStep == 2) _buildStep2(),
        if (_currentStep == 3) _buildStep3(),
        if (_currentStep == 4) _buildStep4(),
      ],
    );
  }

  Widget _buildErrorBanner() {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 20),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: Colors.red.shade50,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.red.shade200),
      ),
      child: Row(
        children: [
          Icon(
            Icons.error_outline_rounded,
            color: Colors.red.shade700,
            size: 20,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              _validationError!,
              style: TextStyle(
                color: Colors.red.shade700,
                fontWeight: FontWeight.w600,
                fontSize: 13,
              ),
            ),
          ),
        ],
      ),
    );
  }

  // --- STEP 1: INFO ---
  Widget _buildStep1() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildLabel('Event Cover Image'),
        Text(
          'Mobile Event Details header background. Must be 16:9 landscape (e.g. 1600×900) · JPG, PNG, or WEBP · max 5MB.',
          style: TextStyle(
            fontSize: 11,
            height: 1.4,
            color: Colors.grey.shade600,
            fontWeight: FontWeight.w500,
          ),
        ),
        const SizedBox(height: 10),
        _buildCoverPicker(),
        const SizedBox(height: 24),
        _buildLabel('Event Title'),
        _buildTextField(
          controller: _titleCtrl,
          hint: 'e.g. CCS Summit 2026',
          prefixIcon: Icons.edit_outlined,
        ),
        const SizedBox(height: 24),

        _buildLabel('Location'),
        _buildTextField(
          controller: _locationCtrl,
          hint: 'e.g. Laguna University',
          prefixIcon: Icons.location_on_outlined,
        ),
        const SizedBox(height: 24),

        Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildLabel('Event Type'),
                  _buildDropdown(
                    value: _eventType,
                    items: [
                      'Event',
                      'Seminar',
                      'Off-Campus Activity',
                      'Sports Event',
                      'Other',
                    ],
                    onChanged: (v) => setState(() {
                      _eventType = v!;
                      if (_eventType != 'Other') {
                        _eventTypeOtherCtrl.clear();
                      }
                    }),
                    prefixIcon: Icons.category_outlined,
                  ),
                ],
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildLabel('Target Course'),
                  _buildDropdown(
                    value: _targetCourse,
                    items: ['ALL', 'BSIT', 'BSIT-SD', 'BSIT-BA', 'BSCS'],
                    itemLabels: {
                      'ALL': 'All Courses',
                      'BSIT': 'BSIT (All)',
                      'BSIT-SD': 'BSIT-SD',
                      'BSIT-BA': 'BSIT-BA',
                      'BSCS': 'BSCS',
                    },
                    onChanged: (v) => setState(() => _targetCourse = v!),
                    prefixIcon: Icons.groups_outlined,
                  ),
                ],
              ),
            ),
          ],
        ),
        if (_eventType == 'Other') ...[
          const SizedBox(height: 16),
          _buildLabel('Specify event type'),
          TextField(
            controller: _eventTypeOtherCtrl,
            maxLength: 80,
            textCapitalization: TextCapitalization.words,
            decoration: InputDecoration(
              hintText: 'e.g. Capstone Defense, Hackathon',
              counterText: '',
              prefixIcon: const Icon(Icons.edit_outlined),
              filled: true,
              fillColor: Colors.white,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: BorderSide(color: Colors.grey.shade300),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: BorderSide(color: Colors.grey.shade300),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: BorderSide(
                  color: TeacherThemeUtils.primary,
                  width: 2,
                ),
              ),
            ),
          ),
        ],
        const SizedBox(height: 16),
        _buildLabel('Target Year'),
        _buildTargetYearChips(),
        const SizedBox(height: 24),
        _buildLabel('Registration Type'),
        _buildRegistrationTypeCard(
          selected: _isFreeEvent,
          title: 'Free Event',
          subtitle: 'When published, students can register immediately.',
          onTap: () => setState(() => _isFreeEvent = true),
        ),
        const SizedBox(height: 10),
        _buildRegistrationTypeCard(
          selected: !_isFreeEvent,
          title: 'Paid Event',
          subtitle: 'Students need payment approval before they can register.',
          onTap: () => setState(() => _isFreeEvent = false),
        ),
        if (!_isFreeEvent) ...[
          const SizedBox(height: 16),
          _buildLabel('Settlement Amount (₱)'),
          _buildNumberField(
            controller: _eventFeeCtrl,
            hint: 'e.g. 250.00',
            prefixIcon: Icons.payments_outlined,
            decimal: true,
          ),
        ],
        const SizedBox(height: 16),
        _buildLabel('Student Limit'),
        _buildNumberField(
          controller: _registrationLimitCtrl,
          hint: 'e.g. 50 (max 9999)',
          prefixIcon: Icons.people_outline_rounded,
        ),
        const SizedBox(height: 6),
        Text(
          'Registration closes automatically once this number of students have registered. Leave blank for no cap.',
          style: TextStyle(
            fontSize: 11,
            color: Colors.grey.shade600,
            height: 1.4,
          ),
        ),
        const SizedBox(height: 32),

        Container(
          decoration: BoxDecoration(
            color: const Color(0xFFF9FAFB),
            border: Border.all(color: const Color(0xFFF3F4F6)),
            borderRadius: BorderRadius.circular(16),
          ),
          child: Column(
            children: [
              RadioListTile<String>(
                value: 'simple',
                groupValue: _eventMode,
                onChanged: (v) => setState(() {
                  _eventMode = v ?? 'simple';
                  _seminarCount = 1;
                  _applySimpleEventEndDefaultFromStart();
                }),
                title: const Text(
                  'Simple Event',
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 14,
                    color: Color(0xFF111827),
                  ),
                ),
                subtitle: const Text(
                  'Single schedule window.',
                  style: TextStyle(fontSize: 12, color: Color(0xFF6B7280)),
                ),
                activeColor: TeacherThemeUtils.primary,
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 2,
                ),
              ),
              RadioListTile<String>(
                value: 'seminar_based',
                groupValue: _eventMode,
                onChanged: (v) =>
                    setState(() => _eventMode = v ?? 'seminar_based'),
                title: const Text(
                  'Seminar Based',
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 14,
                    color: Color(0xFF111827),
                  ),
                ),
                subtitle: const Text(
                  'One or two seminar sessions under one event.',
                  style: TextStyle(fontSize: 12, color: Color(0xFF6B7280)),
                ),
                activeColor: TeacherThemeUtils.primary,
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 2,
                ),
              ),
              if (_eventMode == 'seminar_based')
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                  child: Row(
                    children: [
                      const Text(
                        'Seminar Count',
                        style: TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 12,
                          color: Color(0xFF4B5563),
                        ),
                      ),
                      const Spacer(),
                      ChoiceChip(
                        label: const Text('1'),
                        selected: _seminarCount == 1,
                        onSelected: (_) => setState(() => _seminarCount = 1),
                      ),
                      const SizedBox(width: 8),
                      ChoiceChip(
                        label: const Text('2'),
                        selected: _seminarCount == 2,
                        onSelected: (_) => setState(() => _seminarCount = 2),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }

  // --- STEP 2: DETAILS ---
  Widget _buildStep2() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            _buildLabel('Description'),
            const Spacer(),
            IconButton(
              tooltip: 'Expand view',
              onPressed: _openDescriptionFullScreen,
              icon: const Icon(
                Icons.open_in_full_rounded,
                size: 18,
                color: Color(0xFF6B7280),
              ),
            ),
          ],
        ),
        AnimatedContainer(
          duration: const Duration(milliseconds: 300),
          decoration: BoxDecoration(
            border: Border.all(
              color: _isListening ? Colors.red.shade200 : Colors.transparent,
              width: 1.5,
            ),
            borderRadius: BorderRadius.circular(20),
            color: _isListening ? Colors.red.shade50 : const Color(0xFFF3F4F6),
          ),
          child: Stack(
            children: [
              TextFormField(
                controller: _descCtrl,
                maxLines: 9,
                keyboardType: TextInputType.multiline,
                style: const TextStyle(
                  fontSize: 15,
                  color: Color(0xFF111827),
                  height: 1.5,
                ),
                decoration: const InputDecoration(
                  hintText:
                      'Tell attendees what this event is about...\n\nBe descriptive and exciting!',
                  hintStyle: TextStyle(
                    color: Color(0xFF9CA3AF),
                    fontSize: 15,
                    height: 1.5,
                  ),
                  border: InputBorder.none,
                  contentPadding: EdgeInsets.fromLTRB(20, 20, 50, 20),
                ),
              ),
            ],
          ),
        ),
        // --- Step 2 Controls ---
        const SizedBox(height: 32),

        // --- AI ENHANCE SECTION (Now on top) ---
        Center(
          child: Container(
            width: double.infinity,
            constraints: const BoxConstraints(maxWidth: 260),
            height: 52,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              gradient: LinearGradient(
                colors: _isAiProcessing
                    ? [Colors.grey.shade300, Colors.grey.shade400]
                    : [const Color(0xFFD4A843), const Color(0xFFB8942F)],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              boxShadow: [
                BoxShadow(
                  color: const Color(
                    0xFFD4A843,
                  ).withValues(alpha: _isAiProcessing ? 0 : 0.4),
                  blurRadius: 12,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: Material(
              color: Colors.transparent,
              child: InkWell(
                onTap: _isAiProcessing ? null : _improveWithAi,
                borderRadius: BorderRadius.circular(16),
                child: Center(
                  child: _isAiProcessing
                      ? const PulseConnectLoader(size: 20, color: Colors.white)
                      : Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            const Icon(
                              Icons.auto_awesome_rounded,
                              color: Colors.white,
                              size: 20,
                            ),
                            const SizedBox(width: 10),
                            Text(
                              'AI Enhance Description',
                              style: TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.w800,
                                fontSize: 14,
                                shadows: [
                                  Shadow(
                                    color: Colors.black.withValues(alpha: 0.1),
                                    blurRadius: 4,
                                    offset: const Offset(0, 1),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                ),
              ),
            ),
          ),
        ),

        const SizedBox(height: 32),

        // --- MIC DICTATION SECTION (Centered below) ---
        Center(
          child: Column(
            children: [
              GestureDetector(
                onTap: _listenToggle,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  padding: const EdgeInsets.all(18),
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: LinearGradient(
                      colors: _isListening
                          ? [Colors.red.shade500, Colors.red.shade700]
                          : [const Color(0xFF111827), const Color(0xFF374151)],
                    ),
                    boxShadow: [
                      if (_isListening)
                        BoxShadow(
                          color: Colors.red.withValues(alpha: 0.4),
                          blurRadius: 24,
                          spreadRadius: 2,
                        )
                      else
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.2),
                          blurRadius: 20,
                          offset: const Offset(0, 8),
                        ),
                    ],
                  ),
                  child: Icon(
                    _isListening ? Icons.mic_rounded : Icons.mic_none_rounded,
                    color: Colors.white,
                    size: 28,
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Text(
                _isListening
                    ? 'Listening… tap to stop'
                    : 'Tap the mic to dictate',
                style: TextStyle(
                  fontSize: 13,
                  color: _isListening
                      ? Colors.red.shade600
                      : const Color(0xFF6B7280),
                  fontWeight: _isListening ? FontWeight.w800 : FontWeight.w600,
                  letterSpacing: 0.2,
                ),
              ),
            ],
          ),
        ),

        if (_canUndo) ...[
          const SizedBox(height: 16),
          Center(
            child: TextButton.icon(
              onPressed: _undoAiImprove,
              icon: const Icon(
                Icons.undo_rounded,
                size: 16,
                color: Color(0xFF6B7280),
              ),
              label: const Text(
                'Undo AI changes',
                style: TextStyle(
                  color: Color(0xFF6B7280),
                  fontWeight: FontWeight.w700,
                  fontSize: 13,
                ),
              ),
            ),
          ),
        ],
      ],
    );
  }

  // --- STEP 3: SCHEDULE ---
  Widget _buildStep3() {
    Widget commonFields = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildLabel('Grace Time (Minutes)'),
        _buildNumberField(
          controller: _graceTimeCtrl,
          hint: '30',
          prefixIcon: Icons.timer_outlined,
        ),
        const SizedBox(height: 24),
      ],
    );

    if (_eventMode != 'seminar_based') {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          commonFields,
          _buildLabel('Start Date & Time'),
          _buildDateTimeInput(_startDateCtrl, Icons.calendar_today_rounded),
          const SizedBox(height: 24),
          _buildLabel('End Date & Time'),
          _buildDateTimeInput(
            _endDateCtrl,
            Icons.access_time_rounded,
            isEnabled: _startDateCtrl.text.isNotEmpty,
          ),
          const SizedBox(height: 24),
          _buildRegistrationCloseWeeksField(),
        ],
      );
    } else {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          commonFields,
          _buildBatchBadge('SEMINAR 1 SCHEDULE'),
          const SizedBox(height: 20),
          _buildLabel('Seminar 1 Title'),
          _buildTextField(
            controller: _seminar1TitleCtrl,
            hint: 'e.g. Seminar Proper',
            prefixIcon: Icons.menu_book_rounded,
          ),
          const SizedBox(height: 24),
          _buildLabel('Start Date & Time'),
          _buildDateTimeInput(_seminar1StartCtrl, Icons.calendar_today_rounded),
          const SizedBox(height: 24),
          _buildLabel('End Date & Time'),
          _buildDateTimeInput(
            _seminar1EndCtrl,
            Icons.access_time_rounded,
            isEnabled: _seminar1StartCtrl.text.isNotEmpty,
          ),

          if (_seminarCount >= 2) ...[
            const SizedBox(height: 32),
            Row(
              children: [
                Container(width: 48, height: 2, color: const Color(0xFFD4A843)),
                Expanded(
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      return Flex(
                        direction: Axis.horizontal,
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        mainAxisSize: MainAxisSize.max,
                        children: List.generate(
                          (constraints.constrainWidth() / 8).floor(),
                          (index) => SizedBox(
                            width: 4,
                            height: 1,
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                color: Colors.grey.shade300,
                              ),
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
            const SizedBox(height: 32),
            _buildBatchBadge('SEMINAR 2 SCHEDULE'),
            const SizedBox(height: 20),
            _buildLabel('Seminar 2 Title'),
            _buildTextField(
              controller: _seminar2TitleCtrl,
              hint: 'e.g. Workshop Session',
              prefixIcon: Icons.menu_book_outlined,
            ),
            const SizedBox(height: 24),
            _buildLabel('Start Date & Time'),
            _buildDateTimeInput(
              _seminar2StartCtrl,
              Icons.calendar_today_rounded,
            ),
            const SizedBox(height: 24),
            _buildLabel('End Date & Time'),
            _buildDateTimeInput(
              _seminar2EndCtrl,
              Icons.access_time_rounded,
              isEnabled: _seminar2StartCtrl.text.isNotEmpty,
            ),
          ],
          const SizedBox(height: 24),
          _buildRegistrationCloseWeeksField(),
        ],
      );
    }
  }

  Widget _buildStep4() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: const Color(0xFFE5E7EB)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: TeacherThemeUtils.primary.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(999),
                      border: Border.all(
                        color: TeacherThemeUtils.primary.withValues(alpha: 0.25),
                      ),
                    ),
                    child: const Text(
                      'EVENT REQ',
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 0.6,
                        color: TeacherThemeUtils.primary,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    'Required for admin review',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: Colors.grey.shade600,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Text(
                'Upload the required proposal forms for admin review before your event can be published.',
                style: TextStyle(
                  fontSize: 12,
                  height: 1.45,
                  color: Colors.grey.shade700,
                ),
              ),
              const SizedBox(height: 16),
              ..._proposalItems.asMap().entries.map((entry) {
                return Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: _buildProposalRequirementCard(entry.key, entry.value),
                );
              }),
              OutlinedButton.icon(
                onPressed: _addAdditionalProposalRequirement,
                icon: const Icon(Icons.add_rounded, size: 18),
                label: const Text(
                  'Add Additional Requirement',
                  style: TextStyle(fontWeight: FontWeight.w800, fontSize: 13),
                ),
                style: OutlinedButton.styleFrom(
                  foregroundColor: TeacherThemeUtils.primary,
                  side: BorderSide(
                    color: TeacherThemeUtils.primary.withValues(alpha: 0.35),
                  ),
                  backgroundColor: TeacherThemeUtils.primary.withValues(
                    alpha: 0.06,
                  ),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 12,
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 18),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: const Color(0xFFE5E7EB)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0xFFE0F2FE),
                      borderRadius: BorderRadius.circular(999),
                      border: Border.all(color: const Color(0xFFBAE6FD)),
                    ),
                    child: const Text(
                      'STUDENT REQ',
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 0.6,
                        color: Color(0xFF0369A1),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    'Optional',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      color: Colors.grey.shade500,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Text(
                'Select documents students must upload on the app before registering. Leave this empty if students can register directly.',
                style: TextStyle(
                  fontSize: 12,
                  height: 1.45,
                  color: Colors.grey.shade700,
                ),
              ),
              const SizedBox(height: 14),
              ..._studentRequirementPresets.entries.map((entry) {
                final selected = _studentPresetCodes.contains(entry.key);
                return Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: InkWell(
                    onTap: () {
                      setState(() {
                        if (selected) {
                          _studentPresetCodes.remove(entry.key);
                        } else {
                          _studentPresetCodes.add(entry.key);
                        }
                      });
                    },
                    borderRadius: BorderRadius.circular(14),
                    child: Container(
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: selected
                            ? const Color(0xFFF0F9FF)
                            : const Color(0xFFF9FAFB),
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(
                          color: selected
                              ? const Color(0xFF7DD3FC)
                              : const Color(0xFFE5E7EB),
                        ),
                      ),
                      child: Row(
                        children: [
                          Icon(
                            selected
                                ? Icons.check_box_rounded
                                : Icons.check_box_outline_blank_rounded,
                            color: selected
                                ? const Color(0xFF0284C7)
                                : const Color(0xFF9CA3AF),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  entry.value,
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w800,
                                    fontSize: 14,
                                    color: Color(0xFF111827),
                                  ),
                                ),
                                Text(
                                  'Students upload this on the app',
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: Colors.grey.shade600,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              }),
              const SizedBox(height: 8),
              Row(
                children: [
                  const Text(
                    'Other Requirements',
                    style: TextStyle(
                      fontWeight: FontWeight.w800,
                      fontSize: 14,
                      color: Color(0xFF111827),
                    ),
                  ),
                  const Spacer(),
                  TextButton.icon(
                    onPressed: () {
                      setState(() {
                        _studentOtherCtrls.add(TextEditingController());
                      });
                    },
                    icon: const Icon(Icons.add_rounded, size: 16),
                    label: const Text(
                      'Add Other',
                      style: TextStyle(fontWeight: FontWeight.w800),
                    ),
                  ),
                ],
              ),
              ..._studentOtherCtrls.asMap().entries.map((entry) {
                return Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Row(
                    children: [
                      Expanded(
                        child: _buildTextField(
                          controller: entry.value,
                          hint: 'Additional document name',
                          prefixIcon: Icons.description_outlined,
                        ),
                      ),
                      IconButton(
                        onPressed: () {
                          setState(() {
                            entry.value.dispose();
                            _studentOtherCtrls.removeAt(entry.key);
                          });
                        },
                        icon: const Icon(Icons.close_rounded),
                      ),
                    ],
                  ),
                );
              }),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildProposalRequirementCard(int index, _ProposalReqDraft item) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFFF9FAFB),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFE5E7EB)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: item.isDefault
                    ? Text(
                        item.label,
                        style: const TextStyle(
                          fontWeight: FontWeight.w800,
                          fontSize: 13,
                          color: Color(0xFF111827),
                        ),
                      )
                    : _buildTextField(
                        controller: item.labelCtrl!,
                        hint: 'Additional requirement title',
                        prefixIcon: Icons.edit_outlined,
                      ),
              ),
              if (!item.isDefault)
                IconButton(
                  onPressed: () {
                    setState(() {
                      item.labelCtrl?.dispose();
                      _proposalItems.removeAt(index);
                    });
                  },
                  icon: const Icon(Icons.delete_outline_rounded),
                ),
            ],
          ),
          if (item.isDefault)
            Padding(
              padding: const EdgeInsets.only(top: 4, bottom: 8),
              child: Text(
                'Required default document',
                style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
              ),
            )
          else
            const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: () => _pickProposalFile(index),
            icon: Icon(
              item.file == null
                  ? Icons.upload_file_rounded
                  : Icons.check_circle_rounded,
              size: 18,
            ),
            label: Text(
              item.file == null
                  ? 'Upload file (PDF, DOC, image)'
                  : (item.fileName ?? 'File selected'),
              style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCoverPicker() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (_coverBytes != null) ...[
          Stack(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(16),
                child: AspectRatio(
                  aspectRatio: 16 / 9,
                  child: Image.memory(_coverBytes!, fit: BoxFit.cover),
                ),
              ),
              Positioned(
                top: 8,
                right: 8,
                child: Material(
                  color: Colors.black.withValues(alpha: 0.62),
                  shape: const CircleBorder(),
                  child: InkWell(
                    customBorder: const CircleBorder(),
                    onTap: () {
                      setState(() {
                        _coverFile = null;
                        _coverBytes = null;
                      });
                    },
                    child: const Padding(
                      padding: EdgeInsets.all(6),
                      child: Icon(
                        Icons.close_rounded,
                        color: Colors.white,
                        size: 18,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
        ],
        OutlinedButton.icon(
          onPressed: _pickCoverImage,
          icon: const Icon(Icons.image_outlined, size: 18),
          label: Text(
            _coverFile == null ? 'Upload cover image (16:9)' : 'Change cover',
            style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 13),
          ),
          style: OutlinedButton.styleFrom(
            foregroundColor: const Color(0xFF374151),
            side: const BorderSide(color: Color(0xFFD1D5DB)),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildRegistrationTypeCard({
    required bool selected,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: selected
              ? TeacherThemeUtils.primary.withValues(alpha: 0.06)
              : Colors.white,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: selected
                ? TeacherThemeUtils.primary.withValues(alpha: 0.35)
                : const Color(0xFFE5E7EB),
          ),
        ),
        child: Row(
          children: [
            Icon(
              selected
                  ? Icons.check_box_rounded
                  : Icons.check_box_outline_blank_rounded,
              color: selected
                  ? TeacherThemeUtils.primary
                  : const Color(0xFF9CA3AF),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      fontWeight: FontWeight.w800,
                      fontSize: 14,
                      color: Color(0xFF111827),
                    ),
                  ),
                  Text(
                    subtitle,
                    style: TextStyle(
                      fontSize: 11,
                      height: 1.35,
                      color: Colors.grey.shade600,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildRegistrationCloseWeeksField() {
    final maxClose = _maxRegistrationCloseWeeks();
    final items = maxClose < 1
        ? <String>['']
        : List<String>.generate(maxClose, (i) => '${i + 1}');
    final value = maxClose < 1
        ? ''
        : '${(_registrationCloseWeeks ?? 1).clamp(1, maxClose)}';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildLabel('Registration Close Limit'),
        _buildDropdown(
          value: value,
          items: items,
          itemLabels: {
            '': 'Select event start date first',
            for (var i = 1; i <= 4; i++)
              '$i': i == 1 ? '1 week before start' : '$i weeks before start',
          },
          enabled: maxClose >= 1,
          onChanged: (v) {
            if (maxClose < 1) return;
            setState(() {
              _registrationCloseWeeks = int.tryParse(v ?? '');
            });
          },
          prefixIcon: Icons.event_busy_outlined,
        ),
        const SizedBox(height: 8),
        Text(
          maxClose < 1
              ? 'Close-weeks options appear when the event starts at least 1 week from today.'
              : 'Options update from the event start date vs today (maximum 4 weeks before start).',
          style: TextStyle(
            fontSize: 11,
            height: 1.4,
            color: Colors.grey.shade600,
          ),
        ),
      ],
    );
  }

  void _addAdditionalProposalRequirement() {
    setState(() {
      final next = _proposalItems.length + 1;
      _proposalItems.add(
        _ProposalReqDraft(
          code: 'DOC$next',
          label: '',
          isDefault: false,
        ),
      );
    });
  }

  Future<void> _pickCoverImage() async {
    final picker = ImagePicker();
    final picked = await picker.pickImage(
      source: ImageSource.gallery,
      maxWidth: 1920,
      maxHeight: 1080,
      imageQuality: 72,
    );
    if (picked == null) return;
    final file = File(picked.path);
    final bytes = await file.readAsBytes();
    if (bytes.length > 5 * 1024 * 1024) {
      if (!mounted) return;
      setState(
        () => _validationError = 'Cover image must be 5MB or smaller.',
      );
      return;
    }
    try {
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      final image = frame.image;
      final width = image.width;
      final height = image.height;
      final ratio = width / height;
      image.dispose();
      if ((ratio - (16 / 9)).abs() > 0.08) {
        if (!mounted) return;
        setState(
          () => _validationError =
              'Cover must be 16:9 landscape (≈1.78:1). Uploaded image is ${width}x$height.',
        );
        return;
      }
    } catch (_) {
      if (!mounted) return;
      setState(() => _validationError = 'Unable to read cover image dimensions.');
      return;
    }
    if (!mounted) return;
    setState(() {
      _coverFile = file;
      _coverBytes = bytes;
      _validationError = null;
    });
  }

  Future<void> _pickProposalFile(int index) async {
    try {
      String? fileName;
      String? filePath;
      if (!kIsWeb && Platform.isAndroid) {
        final native = await NativeDocumentPicker.pickAndroid(
          maxBytes: 10 * 1024 * 1024,
        );
        if (native == null) return;
        fileName = native.name;
        filePath = native.path;
      } else {
        final result = await FilePicker.platform.pickFiles(
          type: FileType.custom,
          allowedExtensions: const ['pdf', 'doc', 'docx', 'jpg', 'jpeg', 'png', 'webp'],
          allowMultiple: false,
        );
        if (result == null || result.files.isEmpty) return;
        final picked = result.files.first;
        fileName = picked.name;
        filePath = picked.path;
      }
      if (filePath == null || filePath.trim().isEmpty) return;
      final file = File(filePath);
      final size = await file.length();
      if (size <= 0 || size > 10 * 1024 * 1024) {
        if (!mounted) return;
        AppSnackBar.error(context, 'Each proposal file must be 10MB or smaller.');
        return;
      }
      if (!mounted) return;
      setState(() {
        _proposalItems[index].file = file;
        _proposalItems[index].fileName = fileName;
        _validationError = null;
      });
    } on PlatformException catch (error) {
      if (!mounted) return;
      AppSnackBar.error(
        context,
        (error.message ?? error.code).trim().isEmpty
            ? 'Unable to open file picker.'
            : (error.message ?? error.code),
      );
    } catch (error) {
      if (!mounted) return;
      AppSnackBar.error(context, 'Unable to open file picker: $error');
    }
  }

  Widget _buildDropdown({
    required String value,
    required List<String> items,
    Map<String, String>? itemLabels,
    required void Function(String?) onChanged,
    required IconData prefixIcon,
    bool enabled = true,
    String? hintText,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      decoration: BoxDecoration(
        color: const Color(0xFFF3F4F6),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: [
          Icon(prefixIcon, color: const Color(0xFF9CA3AF), size: 20),
          const SizedBox(width: 12),
          Expanded(
            child: DropdownButtonHideUnderline(
              child: DropdownButton<String>(
                value: value,
                hint: hintText == null ? null : Text(hintText),
                items: items.map((String val) {
                  return DropdownMenuItem<String>(
                    value: val,
                    child: Text(
                      itemLabels?[val] ?? val,
                      style: const TextStyle(
                        fontSize: 14,
                        color: Color(0xFF111827),
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  );
                }).toList(),
                onChanged: enabled ? onChanged : null,
                icon: const Icon(
                  Icons.keyboard_arrow_down_rounded,
                  color: Color(0xFF6B7280),
                ),
                dropdownColor: Colors.white,
                borderRadius: BorderRadius.circular(16),
                isExpanded: true,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTargetYearChips() {
    final options = const {
      'ALL': 'All Levels',
      '1': '1st Year',
      '2': '2nd Year',
      '3': '3rd Year',
      '4': '4th Year',
    };

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: const Color(0xFFF3F4F6),
        borderRadius: BorderRadius.circular(16),
      ),
      child: GridView.count(
        crossAxisCount: 3,
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        crossAxisSpacing: 6,
        mainAxisSpacing: 6,
        childAspectRatio: 2.4,
        children: options.entries.map((entry) {
          final key = entry.key;
          final selected = _targetYears.contains(key);
          return FilterChip(
            label: Center(
              child: Text(
                entry.value,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: selected ? Colors.white : const Color(0xFF374151),
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            labelPadding: EdgeInsets.zero,
            padding: EdgeInsets.zero,
            selected: selected,
            onSelected: (v) => _toggleTargetYear(key, v),
            showCheckmark: false,
            backgroundColor: Colors.white,
            selectedColor: TeacherThemeUtils.primary,
            side: BorderSide(
              color: selected
                  ? TeacherThemeUtils.primary
                  : const Color(0xFFD1D5DB),
            ),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(999),
            ),
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            visualDensity: const VisualDensity(horizontal: -1, vertical: -1),
          );
        }).toList(),
      ),
    );
  }

  Widget _buildNumberField({
    required TextEditingController controller,
    required String hint,
    required IconData prefixIcon,
    bool decimal = false,
  }) {
    return TextFormField(
      controller: controller,
      keyboardType: TextInputType.numberWithOptions(decimal: decimal),
      style: const TextStyle(
        fontSize: 15,
        color: Color(0xFF111827),
        fontWeight: FontWeight.w500,
      ),
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: const TextStyle(
          color: Color(0xFF9CA3AF),
          fontSize: 15,
          fontWeight: FontWeight.normal,
        ),
        prefixIcon: Icon(prefixIcon, color: const Color(0xFF9CA3AF), size: 20),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: const BorderSide(color: Colors.transparent),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: const BorderSide(color: Colors.transparent),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: const BorderSide(
            color: TeacherThemeUtils.primary,
            width: 1.5,
          ),
        ),
        filled: true,
        fillColor: const Color(0xFFF3F4F6),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 20,
          vertical: 18,
        ),
      ),
    );
  }

  Widget _buildBatchBadge(String text) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: TeacherThemeUtils.primary.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        text,
        style: const TextStyle(
          color: TeacherThemeUtils.primary,
          fontWeight: FontWeight.w800,
          fontSize: 11,
          letterSpacing: 0.8,
        ),
      ),
    );
  }

  Widget _buildLabel(String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8, left: 4),
      child: Text(
        text,
        style: const TextStyle(
          fontWeight: FontWeight.w700,
          fontSize: 13,
          color: Color(0xFF4B5563),
        ),
      ),
    );
  }

  Widget _buildTextField({
    required TextEditingController controller,
    required String hint,
    required IconData prefixIcon,
  }) {
    return TextFormField(
      controller: controller,
      style: const TextStyle(
        fontSize: 15,
        color: Color(0xFF111827),
        fontWeight: FontWeight.w500,
      ),
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: const TextStyle(
          color: Color(0xFF9CA3AF),
          fontSize: 15,
          fontWeight: FontWeight.normal,
        ),
        prefixIcon: Icon(prefixIcon, color: const Color(0xFF9CA3AF), size: 20),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: const BorderSide(color: Colors.transparent),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: const BorderSide(color: Colors.transparent),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: const BorderSide(
            color: TeacherThemeUtils.primary,
            width: 1.5,
          ),
        ),
        filled: true,
        fillColor: const Color(0xFFF3F4F6),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 20,
          vertical: 18,
        ),
      ),
    );
  }

  Widget _buildDateTimeInput(
    TextEditingController controller,
    IconData prefixIcon, {
    bool isEnabled = true,
  }) {
    return Opacity(
      opacity: isEnabled ? 1.0 : 0.5,
      child: AbsorbPointer(
        absorbing: !isEnabled,
        child: TextFormField(
          controller: controller,
          readOnly: true,
          onTap: () => _selectDateTime(controller),
          style: const TextStyle(
            fontSize: 15,
            color: Color(0xFF111827),
            fontWeight: FontWeight.w500,
          ),
          decoration: InputDecoration(
            hintText: 'mm/dd/yyyy  --:-- --',
            hintStyle: const TextStyle(
              color: Color(0xFF9CA3AF),
              fontSize: 15,
              letterSpacing: 1.2,
              fontWeight: FontWeight.normal,
            ),
            prefixIcon: Icon(
              prefixIcon,
              color: const Color(0xFF9CA3AF),
              size: 20,
            ),
            suffixIcon: const Icon(
              Icons.calendar_month_rounded,
              color: Color(0xFF6B7280),
              size: 20,
            ),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(16),
              borderSide: const BorderSide(color: Colors.transparent),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(16),
              borderSide: const BorderSide(color: Colors.transparent),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(16),
              borderSide: const BorderSide(
                color: TeacherThemeUtils.primary,
                width: 1.5,
              ),
            ),
            filled: true,
            fillColor: isEnabled
                ? const Color(0xFFF3F4F6)
                : const Color(0xFFE5E7EB),
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 20,
              vertical: 18,
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _selectDateTime(TextEditingController controller) async {
    final isSimpleEndPicker =
        _eventMode != 'seminar_based' && identical(controller, _endDateCtrl);
    final simpleStart = isSimpleEndPicker
        ? _parseDateTime(_startDateCtrl.text)
        : null;

    DateTime? initialDate = _parseDateTime(controller.text);
    if (isSimpleEndPicker && simpleStart != null) {
      initialDate = simpleStart;
    }
    TimeOfDay initialTime = initialDate != null
        ? TimeOfDay(hour: initialDate.hour, minute: initialDate.minute)
        : const TimeOfDay(hour: 0, minute: 0);

    // Tomorrow Only Restriction - Normalized to Start of Day (00:00:00)
    final DateTime now = DateTime.now();
    final DateTime tomorrow = DateTime(
      now.year,
      now.month,
      now.day,
    ).add(const Duration(days: 1));

    final DateTime firstDate = isSimpleEndPicker && simpleStart != null
        ? DateTime(simpleStart.year, simpleStart.month, simpleStart.day)
        : tomorrow;
    final DateTime lastDate = isSimpleEndPicker && simpleStart != null
        ? DateTime(simpleStart.year, simpleStart.month, simpleStart.day)
        : DateTime(2101);

    final DateTime? pickedDate = await showDatePicker(
      context: context,
      initialDate: (initialDate != null && !initialDate.isBefore(firstDate))
          ? initialDate
          : firstDate,
      firstDate: firstDate,
      lastDate: lastDate,

      builder: (context, child) {
        return Theme(
          data: Theme.of(context).copyWith(
            colorScheme: const ColorScheme.light(
              primary: TeacherThemeUtils.primary,
              onPrimary: Colors.white,
              onSurface: Color(0xFF111827),
            ),
          ),
          child: child!,
        );
      },
    );

    if (pickedDate != null) {
      if (!mounted) return;
      final TimeOfDay? pickedTime = await showTimePicker(
        context: context,
        initialTime: initialTime,
        builder: (context, child) {
          return Theme(
            data: Theme.of(context).copyWith(
              colorScheme: const ColorScheme.light(
                primary: TeacherThemeUtils.primary,
                onPrimary: Colors.white,
                onSurface: Color(0xFF111827),
              ),
            ),
            child: child!,
          );
        },
      );

      if (pickedTime != null) {
        int hour = pickedTime.hour;
        int minute = pickedTime.minute;

        // Strict 30-Minute Increment Snapping
        if (minute < 15) {
          minute = 0;
        } else if (minute < 45) {
          minute = 30;
        } else {
          minute = 0;
          hour = (hour + 1) % 24;
        }
        if (hour < 7) hour = 7;

        final DateTime fullDateTime = DateTime(
          pickedDate.year,
          pickedDate.month,
          pickedDate.day,
          hour,
          minute,
        );

        if (mounted) {
          setState(() {
            if (_eventMode != 'seminar_based' &&
                identical(controller, _endDateCtrl)) {
              final start = _parseDateTime(_startDateCtrl.text);
              if (start != null) {
                final fixedEnd = DateTime(
                  start.year,
                  start.month,
                  start.day,
                  17,
                  0,
                );
                controller.text = _dateTimeFormat.format(fixedEnd);
              } else {
                controller.text = _dateTimeFormat.format(fullDateTime);
              }
            } else {
              controller.text = _dateTimeFormat.format(fullDateTime);
            }
            if (_eventMode != 'seminar_based' &&
                identical(controller, _startDateCtrl)) {
              _applySimpleEventEndDefaultFromStart();
            }
            if (identical(controller, _startDateCtrl) ||
                identical(controller, _seminar1StartCtrl)) {
              _syncCloseWeeksForStart();
            }
          });
          // Removed manual auto-sync to match new Web Dashboard rules
        }
      }
    }
  }

  Widget _buildBottomNav() {
    bool isLast = _currentStep == 4;
    bool isFirst = _currentStep == 1;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_submitStatus.isNotEmpty) ...[
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Text(
                _submitStatus,
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: Color(0xFF4B5563),
                ),
              ),
            ),
          ],
          Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          OutlinedButton.icon(
            onPressed: isFirst ? null : _back,
            icon: const Icon(Icons.chevron_left_rounded, size: 20),
            label: const Text(
              'Back',
              style: TextStyle(fontWeight: FontWeight.w700, fontSize: 14),
            ),
            style: OutlinedButton.styleFrom(
              foregroundColor: const Color(0xFF4B5563),
              side: BorderSide(
                color: isFirst ? Colors.transparent : const Color(0xFFE5E7EB),
                width: 1.5,
              ),
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
          ),

          ElevatedButton(
            onPressed: _isSubmitting ? null : (isLast ? _submit : _next),
            style: ElevatedButton.styleFrom(
              backgroundColor: TeacherThemeUtils.primary,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 14),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              elevation: 4,
              shadowColor: TeacherThemeUtils.dark.withValues(alpha: 0.4),
            ),
            child: _isSubmitting
                ? const PulseConnectLoader(size: 20, color: Colors.white)
                : Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (isLast) const Icon(Icons.check_rounded, size: 18),
                      if (isLast) const SizedBox(width: 8),
                      Text(
                        isLast ? 'Save Event' : 'Next',
                        style: const TextStyle(
                          fontWeight: FontWeight.w800,
                          fontSize: 14,
                        ),
                      ),
                      if (!isLast) const SizedBox(width: 8),
                      if (!isLast)
                        const Icon(Icons.chevron_right_rounded, size: 18),
                    ],
                  ),
          ),
          ],
        ),
        ],
      ),
    );
  }
}
