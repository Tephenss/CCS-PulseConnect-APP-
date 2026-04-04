import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:speech_to_text/speech_to_text.dart';
import '../../services/auth_service.dart';
import '../../services/event_service.dart';
import '../../services/ai_service.dart';

class TeacherCreateEvent extends StatefulWidget {
  const TeacherCreateEvent({super.key});

  @override
  State<TeacherCreateEvent> createState() => _TeacherCreateEventState();
}

class _TeacherCreateEventState extends State<TeacherCreateEvent> {
  int _currentStep = 1;

  // Form Field Controllers
  final _titleCtrl = TextEditingController();
  final _locationCtrl = TextEditingController();
  bool _splitBatches = false;
  final _descCtrl = TextEditingController();
  final _startDateCtrl = TextEditingController();
  final _endDateCtrl = TextEditingController();
  final _startDateCtrl2 = TextEditingController();
  final _endDateCtrl2 = TextEditingController();
  
  String _eventType = 'Event';
  String _eventFor = 'All';
  final _graceTimeCtrl = TextEditingController(text: '15');

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
    if (text.isEmpty) return null;
    try {
      return DateFormat('MM/dd/yyyy hh:mm a').parse(text);
    } catch (e) {
      return null;
    }
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
    } else if (step == 2) {
      if (_descCtrl.text.trim().isEmpty) {
        setState(() => _validationError = 'Please add a description.');
        return false;
      }
    } else if (step == 3) {

      DateTime? s1 = _parseDateTime(_startDateCtrl.text);
      DateTime? e1 = _parseDateTime(_endDateCtrl.text);

      if (s1 == null || e1 == null) {
        setState(() => _validationError = 'Start and end dates are required.');
        return false;
      }
      if (e1.isBefore(s1) || e1.isAtSameMomentAs(s1)) {
        setState(() => _validationError = 'End time must be after start time.');
        return false;
      }

      if (_splitBatches) {
        DateTime? s2 = _parseDateTime(_startDateCtrl2.text);
        DateTime? e2 = _parseDateTime(_endDateCtrl2.text);
        if (s2 == null || e2 == null) {
          setState(() => _validationError = 'Both batches require start and end dates.');
          return false;
        }
        if (e2.isBefore(s2) || e2.isAtSameMomentAs(s2)) {
          setState(() => _validationError = 'Batch 2 end time must be after start time.');
          return false;
        }
      }
    }
    return true;
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
    _startDateCtrl.dispose();
    _endDateCtrl.dispose();
    _startDateCtrl2.dispose();
    _endDateCtrl2.dispose();
    _speechToText.stop();
    super.dispose();
  }

  void _submit() async {
    if (!_validateStep(3)) return;

    setState(() => _isSubmitting = true);
    final user = await _authService.getCurrentUser();
    final teacherId = user?['id'];

    if (_splitBatches) {
      DateTime s1 = _parseDateTime(_startDateCtrl.text)!;
      DateTime e1 = _parseDateTime(_endDateCtrl.text)!;
      DateTime s2 = _parseDateTime(_startDateCtrl2.text)!;
      DateTime e2 = _parseDateTime(_endDateCtrl2.text)!;

      // Create Batch 1
      final payload1 = {
        'title': '${_titleCtrl.text.trim()} (Batch 1)',
        'description': _descCtrl.text.trim(),
        'location': _locationCtrl.text.trim(),
        'start_at': s1.toUtc().toIso8601String(),
        'end_at': e1.toUtc().toIso8601String(),
        'event_type': _eventType,
        'event_for': _eventFor,
        'grace_time': int.tryParse(_graceTimeCtrl.text) ?? 15,
        'created_by': teacherId,
        'event_span': (s1.year == e1.year && s1.month == e1.month && s1.day == e1.day) ? 'single_day' : 'multi_day',
      };

      // Create Batch 2
      final payload2 = {
        'title': '${_titleCtrl.text.trim()} (Batch 2)',
        'description': _descCtrl.text.trim(),
        'location': _locationCtrl.text.trim(),
        'start_at': s2.toUtc().toIso8601String(),
        'end_at': e2.toUtc().toIso8601String(),
        'event_type': _eventType,
        'event_for': _eventFor,
        'grace_time': int.tryParse(_graceTimeCtrl.text) ?? 15,
        'created_by': teacherId,
        'event_span': (s2.year == e2.year && s2.month == e2.month && s2.day == e2.day) ? 'single_day' : 'multi_day',
      };

      final res1 = await _eventService.createEvent(payload1);
      final res2 = await _eventService.createEvent(payload2);

      if (mounted) {
        setState(() => _isSubmitting = false);
        if (res1['ok'] && res2['ok']) {
          _handleSuccess();
        } else {
          _handleError(res1['error'] ?? res2['error']);
        }
      }
    } else {
      // Standard Single Event
      DateTime s1 = _parseDateTime(_startDateCtrl.text)!;
      DateTime e1 = _parseDateTime(_endDateCtrl.text)!;

      final payload = {
        'title': _titleCtrl.text.trim(),
        'description': _descCtrl.text.trim(),
        'location': _locationCtrl.text.trim(),
        'start_at': s1.toUtc().toIso8601String(),
        'end_at': e1.toUtc().toIso8601String(),
        'event_type': _eventType,
        'event_for': _eventFor,
        'grace_time': int.tryParse(_graceTimeCtrl.text) ?? 15,
        'created_by': teacherId,
        'event_span': (s1.year == e1.year && s1.month == e1.month && s1.day == e1.day) ? 'single_day' : 'multi_day',
      };


      final result = await _eventService.createEvent(payload);
      
      if (mounted) {
        setState(() => _isSubmitting = false);
        if (result['ok']) {
          _handleSuccess();
        } else {
          _handleError(result['error']);
        }
      }
    }
  }


  void _handleSuccess() {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Event(s) saved successfully!'), backgroundColor: Color(0xFF10B981)),
    );
    Navigator.pop(context, true);
  }

  void _handleError(dynamic error) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Failed to save: $error'), backgroundColor: Colors.red),
    );
  }

  void _next() {
    if (!_validateStep(_currentStep)) return;
    if (_currentStep < 3) setState(() => _currentStep++);
  }


  void _back() {
    if (_currentStep > 1) setState(() => _currentStep--);
  }

  // --- Voice Control Logic ---
  void _listenToggle() async {
    if (!_speechEnabled) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Speech recognition not available on this device.')));
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
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Please add some description text first.')));
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
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Description improved by AI!'), backgroundColor: Color(0xFFD4A843)),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(aiResult['error'].toString()), backgroundColor: Colors.red),
        );
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
                        icon: const Icon(Icons.close_rounded, size: 20, color: Color(0xFF9CA3AF)),
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
                        style: const TextStyle(fontSize: 15, color: Color(0xFF111827), height: 1.5),
                        decoration: const InputDecoration(
                          hintText: 'Tell attendees what this event is about...\n\nBe descriptive and exciting!',
                          hintStyle: TextStyle(color: Color(0xFF9CA3AF), fontSize: 15, height: 1.5),
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
            Container(color: const Color(0xFFF3F4F6), height: 1), // Soft subtle divider
            _buildStepperRow(),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
                child: _buildStepContent(),
              ),
            ),
            Container(
              decoration: BoxDecoration(
                color: Colors.white,
                boxShadow: [
                  BoxShadow(color: Colors.black.withValues(alpha: 0.03), blurRadius: 10, offset: const Offset(0, -2))
                ]
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

    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 20, 20, 16),
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: const Color(0xFF064E3B).withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(12),
            ),
            child: const Icon(Icons.event_available_rounded, color: Color(0xFF064E3B), size: 22),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Create Event', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 20, color: Color(0xFF111827), letterSpacing: -0.3)),
                Text(subtitle, style: const TextStyle(color: Color(0xFF6B7280), fontSize: 13, fontWeight: FontWeight.w500)),
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
          _buildStepIndicator(3, 'Schedule'),
        ],
      ),
    );
  }

  Widget _buildStepIndicator(int stepNum, String title) {
    bool isActiveOrPassed = _currentStep >= stepNum;
    bool isActive = _currentStep == stepNum;

    Color color = isActiveOrPassed ? const Color(0xFF064E3B) : const Color(0xFFD1D5DB);
    Color textColor = isActiveOrPassed ? const Color(0xFF064E3B) : const Color(0xFF9CA3AF);

    return Row(
      children: [
        AnimatedContainer(
          duration: const Duration(milliseconds: 300),
          width: 30,
          height: 30,
          decoration: BoxDecoration(
            color: isActive ? color.withValues(alpha: 0.15) : (isActiveOrPassed ? color : Colors.transparent),
            shape: BoxShape.circle,
            border: Border.all(color: color, width: 2),
          ),
          child: Center(
            child: Text(
              '$stepNum',
              style: TextStyle(
                color: isActive ? color : (isActiveOrPassed ? Colors.white : color),
                fontWeight: FontWeight.w800, 
                fontSize: 13
              ),
            ),
          ),
        ),
        const SizedBox(width: 8),
        Text(
          title,
          style: TextStyle(color: textColor, fontWeight: isActive ? FontWeight.w800 : FontWeight.w600, fontSize: 13),
        ),
      ],
    );
  }

  Widget _buildLine(int stepNum) {
    bool isPassed = _currentStep > stepNum;
    Color color = isPassed ? const Color(0xFFD4A843) : const Color(0xFFF3F4F6); // Gold when pass, soft bare grey when pending
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
          Icon(Icons.error_outline_rounded, color: Colors.red.shade700, size: 20),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              _validationError!,
              style: TextStyle(color: Colors.red.shade700, fontWeight: FontWeight.w600, fontSize: 13),
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
        _buildLabel('Event Title'),
        _buildTextField(controller: _titleCtrl, hint: 'e.g. CCS Summit 2026', prefixIcon: Icons.edit_outlined),
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
                    items: ['Event', 'Seminar', 'Off-Campus Activity', 'Sports Event', 'Other'],
                    onChanged: (v) => setState(() => _eventType = v!),
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
                  _buildLabel('Target Participant'),
                  _buildDropdown(
                    value: _eventFor,
                    items: ['All', '1', '2', '3', '4', 'None'],
                    itemLabels: {
                      'All': 'All Levels',
                      '1': '1st Year',
                      '2': '2nd Year',
                      '3': '3rd Year',
                      '4': '4th Year',
                      'None': 'None',
                    },
                    onChanged: (v) => setState(() => _eventFor = v!),
                    prefixIcon: Icons.groups_outlined,
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 24),

        _buildLabel('Location'),
        _buildTextField(controller: _locationCtrl, hint: 'e.g. CCS Auditorium', prefixIcon: Icons.location_on_outlined),
        const SizedBox(height: 32),

        Container(
          decoration: BoxDecoration(
            color: const Color(0xFFF9FAFB),
            border: Border.all(color: const Color(0xFFF3F4F6)), 
            borderRadius: BorderRadius.circular(16)
          ),
          child: CheckboxListTile(
            value: _splitBatches,
            onChanged: (v) => setState(() => _splitBatches = v ?? false),
            title: const Text('Split Event into 2 Batches', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 14, color: Color(0xFF111827))),
            subtitle: const Text('Setup two completely separate schedules.', style: TextStyle(fontSize: 12, color: Color(0xFF6B7280))),
            controlAffinity: ListTileControlAffinity.leading,
            activeColor: const Color(0xFF064E3B),
            contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
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
              icon: const Icon(Icons.open_in_full_rounded, size: 18, color: Color(0xFF6B7280)),
            ),
          ],
        ),
        AnimatedContainer(
          duration: const Duration(milliseconds: 300),
          decoration: BoxDecoration(
            border: Border.all(color: _isListening ? Colors.red.shade200 : Colors.transparent, width: 1.5),
            borderRadius: BorderRadius.circular(20),
            color: _isListening ? Colors.red.shade50 : const Color(0xFFF3F4F6),
          ),
          child: Stack(
            children: [
              TextFormField(
                controller: _descCtrl,
                maxLines: 9,
                keyboardType: TextInputType.multiline,
                style: const TextStyle(fontSize: 15, color: Color(0xFF111827), height: 1.5),
                decoration: const InputDecoration(
                  hintText: 'Tell attendees what this event is about...\n\nBe descriptive and exciting!',
                  hintStyle: TextStyle(color: Color(0xFF9CA3AF), fontSize: 15, height: 1.5),
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
                  color: const Color(0xFFD4A843).withValues(alpha: _isAiProcessing ? 0 : 0.4),
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
                    ? const SizedBox(
                        width: 20, 
                        height: 20, 
                        child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.white),
                      )
                    : Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const Icon(Icons.auto_awesome_rounded, color: Colors.white, size: 20),
                          const SizedBox(width: 10),
                          Text(
                            'AI Enhance Description', 
                            style: TextStyle(
                              color: Colors.white, 
                              fontWeight: FontWeight.w800, 
                              fontSize: 14,
                              shadows: [Shadow(color: Colors.black.withValues(alpha: 0.1), blurRadius: 4, offset: const Offset(0, 1))]
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
                _isListening ? 'Listening… tap to stop' : 'Tap the mic to dictate',
                style: TextStyle(
                  fontSize: 13,
                  color: _isListening ? Colors.red.shade600 : const Color(0xFF6B7280),
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
              icon: const Icon(Icons.undo_rounded, size: 16, color: Color(0xFF6B7280)),
              label: const Text('Undo AI changes', style: TextStyle(color: Color(0xFF6B7280), fontWeight: FontWeight.w700, fontSize: 13)),
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
        _buildNumberField(controller: _graceTimeCtrl, hint: '15', prefixIcon: Icons.timer_outlined),
        const SizedBox(height: 24),
      ],
    );

    if (!_splitBatches) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          commonFields,
          _buildLabel('Start Date & Time'),
          _buildDateTimeInput(_startDateCtrl, Icons.calendar_today_rounded),
          const SizedBox(height: 24),
          _buildLabel('End Date & Time'),
          _buildDateTimeInput(_endDateCtrl, Icons.access_time_rounded, isEnabled: _startDateCtrl.text.isNotEmpty),
        ],
      );
    } else {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          commonFields,
          _buildBatchBadge('BATCH 1 SCHEDULE'),
          const SizedBox(height: 20),
          _buildLabel('Start Date & Time'),
          _buildDateTimeInput(_startDateCtrl, Icons.calendar_today_rounded),
          const SizedBox(height: 24),
          _buildLabel('End Date & Time'),
          _buildDateTimeInput(_endDateCtrl, Icons.access_time_rounded, isEnabled: _startDateCtrl.text.isNotEmpty),
          
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
                        (index) => SizedBox(width: 4, height: 1, child: DecoratedBox(decoration: BoxDecoration(color: Colors.grey.shade300))),
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
          const SizedBox(height: 32),

          _buildBatchBadge('BATCH 2 SCHEDULE'),
          const SizedBox(height: 20),
          _buildLabel('Batch 2 - Start Date & Time'),
          _buildDateTimeInput(_startDateCtrl2, Icons.calendar_today_rounded),
          const SizedBox(height: 24),
          _buildLabel('Batch 2 - End Date & Time'),
          _buildDateTimeInput(_endDateCtrl2, Icons.access_time_rounded, isEnabled: _startDateCtrl2.text.isNotEmpty),
        ],
      );
    }
  }

  Widget _buildDropdown({
    required String value,
    required List<String> items,
    Map<String, String>? itemLabels,
    required void Function(String?) onChanged,
    required IconData prefixIcon,
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
                items: items.map((String val) {
                  return DropdownMenuItem<String>(
                    value: val,
                    child: Text(
                      itemLabels?[val] ?? val,
                      style: const TextStyle(fontSize: 14, color: Color(0xFF111827), fontWeight: FontWeight.w500),
                    ),
                  );
                }).toList(),
                onChanged: onChanged,
                icon: const Icon(Icons.keyboard_arrow_down_rounded, color: Color(0xFF6B7280)),
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

  Widget _buildNumberField({required TextEditingController controller, required String hint, required IconData prefixIcon}) {
    return TextFormField(
      controller: controller,
      keyboardType: TextInputType.number,
      style: const TextStyle(fontSize: 15, color: Color(0xFF111827), fontWeight: FontWeight.w500),
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: const TextStyle(color: Color(0xFF9CA3AF), fontSize: 15, fontWeight: FontWeight.normal),
        prefixIcon: Icon(prefixIcon, color: const Color(0xFF9CA3AF), size: 20),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: const BorderSide(color: Colors.transparent)),
        enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: const BorderSide(color: Colors.transparent)),
        focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: const BorderSide(color: Color(0xFF064E3B), width: 1.5)),
        filled: true,
        fillColor: const Color(0xFFF3F4F6),
        contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
      ),
    );
  }

  Widget _buildBatchBadge(String text) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: const Color(0xFF064E3B).withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(text, style: const TextStyle(color: Color(0xFF064E3B), fontWeight: FontWeight.w800, fontSize: 11, letterSpacing: 0.8)),
    );
  }

  Widget _buildLabel(String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8, left: 4),
      child: Text(text, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13, color: Color(0xFF4B5563))),
    );
  }

  Widget _buildTextField({required TextEditingController controller, required String hint, required IconData prefixIcon}) {
    return TextFormField(
      controller: controller,
      style: const TextStyle(fontSize: 15, color: Color(0xFF111827), fontWeight: FontWeight.w500),
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: const TextStyle(color: Color(0xFF9CA3AF), fontSize: 15, fontWeight: FontWeight.normal),
        prefixIcon: Icon(prefixIcon, color: const Color(0xFF9CA3AF), size: 20),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: const BorderSide(color: Colors.transparent)),
        enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: const BorderSide(color: Colors.transparent)),
        focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: const BorderSide(color: Color(0xFF064E3B), width: 1.5)),
        filled: true,
        fillColor: const Color(0xFFF3F4F6),
        contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
      ),
    );
  }

  Widget _buildDateTimeInput(TextEditingController controller, IconData prefixIcon, {bool isEnabled = true}) {
    return Opacity(
      opacity: isEnabled ? 1.0 : 0.5,
      child: AbsorbPointer(
        absorbing: !isEnabled,
        child: TextFormField(
          controller: controller,
          readOnly: true,
          onTap: () => _selectDateTime(controller),
          style: const TextStyle(fontSize: 15, color: Color(0xFF111827), fontWeight: FontWeight.w500),
          decoration: InputDecoration(
            hintText: 'mm/dd/yyyy  --:-- --',
            hintStyle: const TextStyle(color: Color(0xFF9CA3AF), fontSize: 15, letterSpacing: 1.2, fontWeight: FontWeight.normal),
            prefixIcon: Icon(prefixIcon, color: const Color(0xFF9CA3AF), size: 20),
            suffixIcon: const Icon(Icons.calendar_month_rounded, color: Color(0xFF6B7280), size: 20),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: const BorderSide(color: Colors.transparent)),
            enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: const BorderSide(color: Colors.transparent)),
            focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: const BorderSide(color: Color(0xFF064E3B), width: 1.5)),
            filled: true,
            fillColor: isEnabled ? const Color(0xFFF3F4F6) : const Color(0xFFE5E7EB),
            contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
          ),
        ),
      ),
    );
  }

  Future<void> _selectDateTime(TextEditingController controller) async {
    DateTime? initialDate = _parseDateTime(controller.text);
    TimeOfDay initialTime = const TimeOfDay(hour: 0, minute: 0); // Default to 12:00 AM (0:00)

    // Tomorrow Only Restriction - Normalized to Start of Day (00:00:00)
    final DateTime now = DateTime.now();
    final DateTime tomorrow = DateTime(now.year, now.month, now.day).add(const Duration(days: 1));
    
    final DateTime? pickedDate = await showDatePicker(
      context: context,
      initialDate: (initialDate != null && !initialDate.isBefore(tomorrow)) ? initialDate : tomorrow,
      firstDate: tomorrow,
      lastDate: DateTime(2101),


      builder: (context, child) {
        return Theme(
          data: Theme.of(context).copyWith(
            colorScheme: const ColorScheme.light(
              primary: Color(0xFF064E3B), 
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
                primary: Color(0xFF064E3B), 
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

        final DateTime fullDateTime = DateTime(
          pickedDate.year,
          pickedDate.month,
          pickedDate.day,
          hour,
          minute,
        );

        if (mounted) {
          setState(() {
            controller.text = DateFormat('MM/dd/yyyy hh:mm a').format(fullDateTime);
          });
          // Removed manual auto-sync to match new Web Dashboard rules
        }
      }
    }
  }


  Widget _buildBottomNav() {
    bool isLast = _currentStep == 3;
    bool isFirst = _currentStep == 1;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          OutlinedButton.icon(
            onPressed: isFirst ? null : _back,
            icon: const Icon(Icons.chevron_left_rounded, size: 20),
            label: const Text('Back', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 14)),
            style: OutlinedButton.styleFrom(
              foregroundColor: const Color(0xFF4B5563),
              side: BorderSide(color: isFirst ? Colors.transparent : const Color(0xFFE5E7EB), width: 1.5),
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
          ),
          
          ElevatedButton(
            onPressed: _isSubmitting ? null : (isLast ? _submit : _next),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF064E3B),
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 14),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              elevation: 4,
              shadowColor: const Color(0xFF064E3B).withValues(alpha: 0.4),
            ),
            child: _isSubmitting
                ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                : Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (isLast) const Icon(Icons.check_rounded, size: 18),
                      if (isLast) const SizedBox(width: 8),
                      Text(isLast ? 'Save Event' : 'Next', style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 14)),
                      if (!isLast) const SizedBox(width: 8),
                      if (!isLast) const Icon(Icons.chevron_right_rounded, size: 18),
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}
