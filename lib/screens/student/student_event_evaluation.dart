import 'package:flutter/material.dart';
import '../../services/event_service.dart';
import '../../widgets/custom_loader.dart';

class StudentEventEvaluationScreen extends StatefulWidget {
  final String eventId;
  final String studentId;

  const StudentEventEvaluationScreen({
    super.key,
    required this.eventId,
    required this.studentId,
  });

  @override
  State<StudentEventEvaluationScreen> createState() =>
      _StudentEventEvaluationScreenState();
}

class _StudentEventEvaluationScreenState
    extends State<StudentEventEvaluationScreen> {
  final EventService _eventService = EventService();
  bool _isLoading = true;
  Map<String, dynamic> _bundle = {};
  List<Map<String, dynamic>> _sections = [];
  final Map<String, dynamic> _answers = {};

  @override
  void initState() {
    super.initState();
    _loadBundle();
  }

  String _answerKey(String scopeId, String questionId) => '$scopeId::$questionId';

  Future<void> _loadBundle() async {
    final bundle = await _eventService.getEvaluationBundle(
      eventId: widget.eventId,
      studentId: widget.studentId,
    );

    final rawSections = bundle['sections'];
    final sections = rawSections is List
        ? rawSections
            .whereType<Map>()
            .map((row) => Map<String, dynamic>.from(row))
            .toList()
        : <Map<String, dynamic>>[];

    _answers.clear();
    for (final section in sections) {
      final scopeId = section['scope_id']?.toString() ?? '';
      final rawAnswers = section['answers'];
      final answers = rawAnswers is Map<String, dynamic>
          ? rawAnswers
          : (rawAnswers is Map ? Map<String, dynamic>.from(rawAnswers) : <String, dynamic>{});
      answers.forEach((questionId, value) {
        _answers[_answerKey(scopeId, questionId)] = value;
      });
    }

    if (!mounted) return;
    setState(() {
      _bundle = bundle;
      _sections = sections;
      _isLoading = false;
    });
  }

  String _sectionSubtitle(Map<String, dynamic> section) {
    final scope = section['scope']?.toString() ?? '';
    if (scope == 'event') {
      return 'Applies to the whole event.';
    }
    return 'Applies only to the seminar you attended.';
  }

  Future<void> _submit() async {
    for (final section in _sections) {
      final scopeId = section['scope_id']?.toString() ?? '';
      final questions = (section['questions'] as List?)
              ?.whereType<Map>()
              .map((row) => Map<String, dynamic>.from(row))
              .toList() ??
          <Map<String, dynamic>>[];

      for (final question in questions) {
        if (question['required'] != true) continue;
        final questionId = question['id']?.toString() ?? '';
        final value = _answers[_answerKey(scopeId, questionId)];
        if (value == null || value.toString().trim().isEmpty) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                'Please answer all required questions in ${section['title'] ?? 'this section'}.',
              ),
            ),
          );
          return;
        }
      }
    }

    final payload = <Map<String, dynamic>>[];
    for (final section in _sections) {
      final scope = section['scope']?.toString() ?? '';
      final scopeId = section['scope_id']?.toString() ?? '';
      final questions = (section['questions'] as List?)
              ?.whereType<Map>()
              .map((row) => Map<String, dynamic>.from(row))
              .toList() ??
          <Map<String, dynamic>>[];

      for (final question in questions) {
        final questionId = question['id']?.toString() ?? '';
        final answerText = _answers[_answerKey(scopeId, questionId)]?.toString() ?? '';
        if (questionId.isEmpty || answerText.trim().isEmpty) continue;

        payload.add({
          'question_id': questionId,
          'answer_text': answerText,
          if (scope == 'session') 'session_id': scopeId,
        });
      }
    }

    if (payload.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please provide at least one answer before submitting.')),
      );
      return;
    }

    setState(() => _isLoading = true);
    final result = await _eventService.submitEvaluation(
      eventId: widget.eventId,
      studentId: widget.studentId,
      answers: payload,
    );

    if (!mounted) return;
    setState(() => _isLoading = false);

    if (result['ok'] == true) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Evaluation submitted successfully.')),
      );
      Navigator.pop(context, true);
      return;
    }

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(result['error']?.toString() ?? 'Submission failed.')),
    );
  }

  Widget _buildRatingField(String scopeId, Map<String, dynamic> question) {
    final questionId = question['id']?.toString() ?? '';
    final value = int.tryParse(
          _answers[_answerKey(scopeId, questionId)]?.toString() ?? '0',
        ) ??
        0;

    return Wrap(
      spacing: 2,
      runSpacing: 2,
      children: List.generate(5, (index) {
        final starIndex = index + 1;
        return IconButton(
          onPressed: () {
            setState(() {
              _answers[_answerKey(scopeId, questionId)] = starIndex.toString();
            });
          },
          icon: Icon(
            starIndex <= value ? Icons.star_rounded : Icons.star_border_rounded,
            color: const Color(0xFFD4A843),
            size: 34,
          ),
        );
      }),
    );
  }

  Widget _buildTextField(String scopeId, Map<String, dynamic> question) {
    final questionId = question['id']?.toString() ?? '';
    return TextFormField(
      initialValue: _answers[_answerKey(scopeId, questionId)]?.toString() ?? '',
      maxLines: 4,
      onChanged: (value) {
        _answers[_answerKey(scopeId, questionId)] = value;
      },
      decoration: InputDecoration(
        hintText: 'Type your feedback here...',
        filled: true,
        fillColor: Colors.grey.shade100,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
      ),
    );
  }

  Widget _buildSectionCard(Map<String, dynamic> section) {
    final scopeId = section['scope_id']?.toString() ?? '';
    final questions = (section['questions'] as List?)
            ?.whereType<Map>()
            .map((row) => Map<String, dynamic>.from(row))
            .toList() ??
        <Map<String, dynamic>>[];

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: const Color(0xFFD4A843).withValues(alpha: 0.28)),
        borderRadius: BorderRadius.circular(18),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.03),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            section['title']?.toString() ?? 'Evaluation Section',
            style: const TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w800,
              color: Color(0xFF1F2937),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            _sectionSubtitle(section),
            style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: Color(0xFF6B7280),
            ),
          ),
          const SizedBox(height: 18),
          ...questions.map((question) {
            final fieldType = question['field_type']?.toString() ?? 'text';
            return Container(
              margin: const EdgeInsets.only(bottom: 16),
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: const Color(0xFFF9FAFB),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: const Color(0xFFE5E7EB)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Text(
                          question['question_text']?.toString() ?? '',
                          style: const TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                            color: Color(0xFF111827),
                          ),
                        ),
                      ),
                      if (question['required'] == true)
                        const Text(
                          ' *',
                          style: TextStyle(color: Colors.red, fontSize: 16),
                        ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  if (fieldType == 'rating')
                    _buildRatingField(scopeId, question)
                  else
                    _buildTextField(scopeId, question),
                ],
              ),
            );
          }),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final eligible = _bundle['is_eligible'] == true;
    final hasQuestions = _bundle['has_questions'] == true;

    return Scaffold(
      backgroundColor: const Color(0xFFF9FAFB),
      appBar: AppBar(
        title: const Text(
          'Event Evaluation',
          style: TextStyle(
            color: Color(0xFF1F2937),
            fontWeight: FontWeight.bold,
          ),
        ),
        backgroundColor: Colors.white,
        elevation: 0,
        iconTheme: const IconThemeData(color: Color(0xFF1F2937)),
      ),
      body: _isLoading
          ? const Center(child: PulseConnectLoader())
          : !eligible
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      _bundle['message']?.toString() ??
                          'Evaluation is only available for attendees.',
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFF6B7280),
                      ),
                    ),
                  ),
                )
              : !hasQuestions
                  ? const Center(
                      child: Padding(
                        padding: EdgeInsets.all(24),
                        child: Text(
                          'No evaluation questions are available yet for the sections you attended.',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            color: Color(0xFF6B7280),
                          ),
                        ),
                      ),
                    )
                  : ListView(
                      padding: const EdgeInsets.all(20),
                      children: [
                        ..._sections.map(_buildSectionCard),
                        const SizedBox(height: 8),
                        ElevatedButton(
                          onPressed: _submit,
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFF064E3B),
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(vertical: 16),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(14),
                            ),
                          ),
                          child: const Text(
                            'SUBMIT EVALUATION',
                            style: TextStyle(
                              fontWeight: FontWeight.w800,
                              letterSpacing: 0.5,
                            ),
                          ),
                        ),
                      ],
                    ),
    );
  }
}
