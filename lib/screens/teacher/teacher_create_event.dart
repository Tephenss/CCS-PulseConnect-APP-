import 'package:flutter/material.dart';
import '../../services/auth_service.dart';
import '../../services/event_service.dart';

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

  final _authService = AuthService();
  final _eventService = EventService();
  bool _isSubmitting = false;

  @override
  void dispose() {
    _titleCtrl.dispose();
    _locationCtrl.dispose();
    _descCtrl.dispose();
    _startDateCtrl.dispose();
    _endDateCtrl.dispose();
    _startDateCtrl2.dispose();
    _endDateCtrl2.dispose();
    super.dispose();
  }

  void _submit() async {
    setState(() => _isSubmitting = true);
    final user = await _authService.getCurrentUser();
    
    final payload = {
      'title': _titleCtrl.text,
      'description': _descCtrl.text,
      'location': _locationCtrl.text,
      'start_at': _startDateCtrl.text.isNotEmpty ? _startDateCtrl.text : DateTime.now().toIso8601String(), // Mock for now
      'end_at': _endDateCtrl.text.isNotEmpty ? _endDateCtrl.text : DateTime.now().add(const Duration(hours: 2)).toIso8601String(),
      'type': 'Academic', // default
      'created_by': user?['id'],
      'is_split_batch': _splitBatches,
      if (_splitBatches) 'batch2_start': _startDateCtrl2.text,
      if (_splitBatches) 'batch2_end': _endDateCtrl2.text,
    };

    final result = await _eventService.createEvent(payload);

    if (mounted) {
      setState(() => _isSubmitting = false);
      if (result['ok'] == true) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Event saved successfully!'), backgroundColor: Color(0xFF10B981)),
        );
        Navigator.pop(context, true);
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(result['error'].toString()), backgroundColor: Colors.red),
        );
      }
    }
  }

  void _next() {
    if (_currentStep < 3) setState(() => _currentStep++);
  }

  void _back() {
    if (_currentStep > 1) setState(() => _currentStep--);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      body: SafeArea(
        child: Column(
          children: [
            _buildHeader(),
            const Divider(height: 1, color: Color(0xFFE5E7EB)),
            _buildStepperRow(),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(24),
                child: _buildStepContent(),
              ),
            ),
            const Divider(height: 1, color: Color(0xFFE5E7EB)),
            _buildBottomNav(),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader() {
    String subtitle = 'Fill in the event info';
    if (_currentStep == 2) subtitle = 'Add a description';
    if (_currentStep == 3) subtitle = 'Set the schedule';

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
      child: Row(
        children: [
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              color: const Color(0xFF064E3B).withValues(alpha: 0.1), // Light Green bg
              borderRadius: BorderRadius.circular(12),
            ),
            child: const Icon(Icons.add, color: Color(0xFF064E3B), size: 24), // Dark Green icon
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Create Event', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 20, color: Color(0xFF111827))),
                Text(subtitle, style: const TextStyle(color: Color(0xFF6B7280), fontSize: 13, fontWeight: FontWeight.w500)),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.close_rounded, color: Color(0xFF6B7280)),
            onPressed: () => Navigator.pop(context),
          ),
        ],
      ),
    );
  }

  Widget _buildStepperRow() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
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

    Color color = isActiveOrPassed ? const Color(0xFF064E3B) : const Color(0xFFD1D5DB); // Dark Green
    Color textColor = isActiveOrPassed ? const Color(0xFF064E3B) : const Color(0xFF9CA3AF);

    return Row(
      children: [
        Container(
          width: 32,
          height: 32,
          decoration: BoxDecoration(
            color: isActive ? color.withValues(alpha: 0.1) : Colors.transparent,
            shape: BoxShape.circle,
            border: Border.all(color: color, width: 2),
          ),
          child: Center(
            child: Text(
              '$stepNum',
              style: TextStyle(color: color, fontWeight: FontWeight.bold, fontSize: 14),
            ),
          ),
        ),
        const SizedBox(width: 8),
        Text(
          title,
          style: TextStyle(
            color: textColor,
            fontWeight: isActive ? FontWeight.w700 : FontWeight.w600,
            fontSize: 13,
          ),
        ),
      ],
    );
  }

  Widget _buildLine(int stepNum) {
    bool isPassed = _currentStep > stepNum;
    Color color = isPassed ? const Color(0xFFD4A843) : const Color(0xFFE5E7EB); // Gold Line
    return Expanded(
      child: Container(
        height: 2,
        margin: const EdgeInsets.symmetric(horizontal: 12),
        color: color,
      ),
    );
  }

  Widget _buildStepContent() {
    if (_currentStep == 1) return _buildStep1();
    if (_currentStep == 2) return _buildStep2();
    return _buildStep3();
  }

  // --- STEP 1: INFO ---
  Widget _buildStep1() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildLabel('Event Title'),
        _buildTextField(
          controller: _titleCtrl,
          hint: 'e.g. CCS Summit 2026',
          prefixIcon: Icons.edit_outlined,
        ),
        const SizedBox(height: 20),
        
        _buildLabel('Location'),
        _buildTextField(
          controller: _locationCtrl,
          hint: 'e.g. CCS Auditorium',
          prefixIcon: Icons.location_on_outlined,
        ),
        const SizedBox(height: 32),

        Container(
          decoration: BoxDecoration(
            border: Border.all(color: const Color(0xFFE5E7EB)),
            borderRadius: BorderRadius.circular(16),
          ),
          child: CheckboxListTile(
            value: _splitBatches,
            onChanged: (v) => setState(() => _splitBatches = v ?? false),
            title: const Text('Split Event into 2 Batches', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 15, color: Color(0xFF111827))),
            subtitle: const Text('Allows you to set up two completely separate schedules (Batch 1 & Batch 2) on the final step.', style: TextStyle(fontSize: 12, color: Color(0xFF6B7280))),
            controlAffinity: ListTileControlAffinity.leading,
            activeColor: const Color(0xFF064E3B), // Dark Green
            contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
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
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            _buildLabel('Description'),
            const Text('Click the mic to dictate', style: TextStyle(fontSize: 12, color: Color(0xFF9CA3AF), fontWeight: FontWeight.w500)),
          ],
        ),
        Container(
          decoration: BoxDecoration(
            border: Border.all(color: const Color(0xFFE5E7EB)),
            borderRadius: BorderRadius.circular(16),
          ),
          child: Stack(
            children: [
              TextFormField(
                controller: _descCtrl,
                maxLines: 8,
                decoration: const InputDecoration(
                  hintText: 'Tell attendees what this event is about...',
                  hintStyle: TextStyle(color: Color(0xFF9CA3AF), fontSize: 16),
                  border: InputBorder.none,
                  contentPadding: EdgeInsets.all(20),
                ),
              ),
              Positioned(
                top: 16,
                right: 16,
                child: Container(
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(color: const Color(0xFFE5E7EB)),
                  ),
                  child: IconButton(
                    icon: const Icon(Icons.mic_none_rounded, color: Color(0xFF6B7280)),
                    onPressed: () {},
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            TextButton.icon(
              onPressed: () {},
              icon: const Icon(Icons.open_in_full_rounded, size: 16, color: Color(0xFF6B7280)),
              label: const Text('Expand', style: TextStyle(color: Color(0xFF4B5563), fontWeight: FontWeight.w700)),
            ),
            const SizedBox(width: 8),
            OutlinedButton.icon(
              onPressed: () {},
              icon: const Icon(Icons.auto_awesome, size: 16, color: Color(0xFFD4A843)), // Gold
              label: const Text('AI Improve', style: TextStyle(color: Color(0xFFD4A843), fontWeight: FontWeight.w800)),
              style: OutlinedButton.styleFrom(
                side: const BorderSide(color: Color(0xFFD4A843)),
                backgroundColor: const Color(0xFFD4A843).withValues(alpha: 0.1),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
            ),
          ],
        ),
      ],
    );
  }

  // --- STEP 3: SCHEDULE ---
  Widget _buildStep3() {
    if (!_splitBatches) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildLabel('Start Date & Time'),
          _buildDateTimeInput(_startDateCtrl, Icons.calendar_today_outlined),
          const SizedBox(height: 20),
          _buildLabel('End Date & Time'),
          _buildDateTimeInput(_endDateCtrl, Icons.access_time_rounded),
        ],
      );
    } else {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildBatchBadge('BATCH 1 SCHEDULE'),
          const SizedBox(height: 16),
          _buildLabel('Start Date & Time'),
          _buildDateTimeInput(_startDateCtrl, Icons.calendar_today_outlined),
          const SizedBox(height: 20),
          _buildLabel('End Date & Time'),
          _buildDateTimeInput(_endDateCtrl, Icons.access_time_rounded),
          
          const SizedBox(height: 24),
          // Custom dotted line divider mock
          Row(
            children: [
              Container(width: 40, height: 2, color: const Color(0xFFD4A843)), // Gold
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
          const SizedBox(height: 24),

          _buildBatchBadge('BATCH 2 SCHEDULE'),
          const SizedBox(height: 16),
          _buildLabel('Batch 2 - Start Date & Time'),
          _buildDateTimeInput(_startDateCtrl2, Icons.calendar_today_outlined),
          const SizedBox(height: 20),
          _buildLabel('Batch 2 - End Date & Time'),
          _buildDateTimeInput(_endDateCtrl2, Icons.access_time_rounded),
        ],
      );
    }
  }

  Widget _buildBatchBadge(String text) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: const Color(0xFF064E3B).withValues(alpha: 0.1), // Light green bg
        border: Border.all(color: const Color(0xFF064E3B).withValues(alpha: 0.3)),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        text,
        style: const TextStyle(
          color: Color(0xFF064E3B), // Dark green text
          fontWeight: FontWeight.w800,
          fontSize: 11,
          letterSpacing: 0.5,
        ),
      ),
    );
  }

  Widget _buildLabel(String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(text, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14, color: Color(0xFF4B5563))),
    );
  }

  Widget _buildTextField({required TextEditingController controller, required String hint, required IconData prefixIcon}) {
    return TextFormField(
      controller: controller,
      style: const TextStyle(fontSize: 16, color: Color(0xFF111827)),
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: const TextStyle(color: Color(0xFF9CA3AF), fontSize: 16),
        prefixIcon: Icon(prefixIcon, color: const Color(0xFF9CA3AF)),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: const BorderSide(color: Color(0xFFE5E7EB))),
        enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: const BorderSide(color: Color(0xFFE5E7EB))),
        focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: const BorderSide(color: Color(0xFF064E3B))), // Dark Green focus
        filled: true,
        fillColor: Colors.white,
      ),
    );
  }

  Widget _buildDateTimeInput(TextEditingController controller, IconData prefixIcon) {
    return TextFormField(
      controller: controller,
      style: const TextStyle(fontSize: 16, color: Color(0xFF111827)),
      decoration: InputDecoration(
        hintText: 'mm/dd/yyyy  --:-- --',
        hintStyle: const TextStyle(color: Color(0xFF4B5563), fontSize: 16, letterSpacing: 1.5),
        prefixIcon: Icon(prefixIcon, color: const Color(0xFF9CA3AF)),
        suffixIcon: const Icon(Icons.calendar_month_outlined, color: Color(0xFF111827)),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: const BorderSide(color: Color(0xFFE5E7EB))),
        enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: const BorderSide(color: Color(0xFFE5E7EB))),
      ),
    );
  }

  // --- BOTTOM NAV ---
  Widget _buildBottomNav() {
    bool isLast = _currentStep == 3;
    bool isFirst = _currentStep == 1;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          // Back Button
          OutlinedButton.icon(
            onPressed: isFirst ? null : _back,
            icon: const Icon(Icons.chevron_left_rounded, size: 20),
            label: const Text('Back', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
            style: OutlinedButton.styleFrom(
              foregroundColor: const Color(0xFF6B7280),
              side: BorderSide(color: isFirst ? Colors.transparent : const Color(0xFFE5E7EB)),
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
          ),
          
          // Next / Save Button
          ElevatedButton(
            onPressed: _isSubmitting ? null : (isLast ? _submit : _next),
            style: ElevatedButton.styleFrom(
              backgroundColor: isLast ? const Color(0xFF064E3B) : const Color(0xFF064E3B), // Uniform Dark Green
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              elevation: 0,
            ),
            child: _isSubmitting
                ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                : Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (isLast) const Icon(Icons.check_rounded, size: 20),
                      if (isLast) const SizedBox(width: 8),
                      Text(isLast ? 'Save Event' : 'Next', style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
                      if (!isLast) const SizedBox(width: 8),
                      if (!isLast) const Icon(Icons.chevron_right_rounded, size: 20),
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}
