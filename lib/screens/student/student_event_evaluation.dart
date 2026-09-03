import 'package:flutter/material.dart';
import '../../widgets/app_snackbar.dart';
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
  bool _isSubmitting = false;
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
          final sectionTitle = section['title']?.toString() ?? 'this section';
          AppSnackBar.warning(context, 'Please answer all required questions in $sectionTitle.');
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
      AppSnackBar.warning(context, 'Please provide at least one answer before submitting.');
      return;
    }

    // Prevent double-tap from claiming two FIFO codes for one student.
    if (_isSubmitting) return;
    setState(() {
      _isSubmitting = true;
      _isLoading = true;
    });
    final result = await _eventService.submitEvaluation(
      eventId: widget.eventId,
      studentId: widget.studentId,
      answers: payload,
    );

    if (!mounted) return;
    setState(() {
      _isLoading = false;
      _isSubmitting = false;
    });

    if (result['ok'] == true) {
      final cert = result['certificate'];
      final issued = cert is Map && (cert['issued'] is num)
          ? (cert['issued'] as num).toInt()
          : int.tryParse(cert is Map ? '${cert['issued']}' : '') ?? 0;
      final skipped = cert is Map ? cert['skipped']?.toString() ?? '' : '';
      // ignore: avoid_print
      debugPrint('[eval] submit ok issued=$issued skipped=$skipped');
      // Eval answers already saved — never surface cert pool as a hard failure.
      // Only mention certificates when this event actually has cert setup.
      final String message;
      if (skipped == 'not_configured' || skipped == 'certs_not_linked') {
        message = 'Evaluation submitted successfully.';
      } else if (issued > 0 || skipped == 'already_issued') {
        message =
            'Evaluation submitted. Your certificate is ready — open My Certificates.';
      } else if (skipped == 'checkout_required') {
        message =
            'Evaluation submitted. Time-out is still required before a certificate can be issued.';
      } else if (skipped == 'eval_incomplete') {
        message =
            'Evaluation submitted. Finish all required questions to receive your certificate.';
      } else if (skipped == 'no_pool_codes') {
        message =
            'Evaluation submitted. Certificate codes are not ready yet — ask your teacher to link/import codes and Send.';
      } else if (skipped == 'insert_failed') {
        message =
            'Evaluation submitted. Certificate save failed — ask your teacher to resend from Event Details.';
      } else {
        message = 'Evaluation submitted successfully.';
      }
      AppSnackBar.success(context, message);
      Navigator.pop(context, true);
      return;
    }

    AppSnackBar.error(context, result['error']?.toString() ?? 'Submission failed.');
  }

  static const List<MapEntry<int, String>> _ratingScaleLabels = [
    MapEntry(5, 'Outstanding'),
    MapEntry(4, 'Very Satisfactory'),
    MapEntry(3, 'Satisfactory'),
    MapEntry(2, 'Unsatisfactory'),
    MapEntry(1, 'Poor'),
  ];

  Widget _buildRatingScaleIndicator() {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFFFFFBFB),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFFE7D0D4)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'INDICATORS',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w900,
              letterSpacing: 1.2,
              color: Color(0xFF9F1239),
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            'Please rate the activity as it was conducted using the 5-point scale below (5 being the highest and 1 the lowest). Choose the number which corresponds to your evaluation. Your honest assessment will help improve future activities.',
            style: TextStyle(
              fontSize: 12,
              height: 1.45,
              fontWeight: FontWeight.w500,
              color: Color(0xFF52525B),
            ),
          ),
          const SizedBox(height: 14),
          ..._ratingScaleLabels.map((entry) {
            return Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 22,
                    child: Text(
                      '${entry.key}',
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w800,
                        color: Color(0xFF18181B),
                      ),
                    ),
                  ),
                  const Text(
                    '—  ',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: Color(0xFF71717A),
                    ),
                  ),
                  Expanded(
                    child: Text(
                      entry.value,
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFF3F3F46),
                      ),
                    ),
                  ),
                ],
              ),
            );
          }),
        ],
      ),
    );
  }

  Widget _buildRatingField(String scopeId, Map<String, dynamic> question) {
    final questionId = question['id']?.toString() ?? '';
    final value = int.tryParse(
          _answers[_answerKey(scopeId, questionId)]?.toString() ?? '0',
        ) ??
        0;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: List.generate(5, (index) {
            final score = index + 1;
            final selected = value == score;
            return Expanded(
              child: Padding(
                padding: EdgeInsets.only(right: index == 4 ? 0 : 6),
                child: InkWell(
                  borderRadius: BorderRadius.circular(12),
                  onTap: () {
                    setState(() {
                      _answers[_answerKey(scopeId, questionId)] =
                          score.toString();
                    });
                  },
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 160),
                    height: 46,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: selected
                          ? const Color(0xFF9F1239)
                          : Colors.white,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: selected
                            ? const Color(0xFF9F1239)
                            : const Color(0xFFD4D4D8),
                        width: selected ? 1.5 : 1,
                      ),
                    ),
                    child: Text(
                      '$score',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w800,
                        color: selected
                            ? Colors.white
                            : const Color(0xFF3F3F46),
                      ),
                    ),
                  ),
                ),
              ),
            );
          }),
        ),
        const SizedBox(height: 8),
        const Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              '1 Poor',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: Color(0xFF71717A),
              ),
            ),
            Text(
              '5 Outstanding',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: Color(0xFF71717A),
              ),
            ),
          ],
        ),
      ],
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
    final hasRatingQuestions = questions.any(
      (q) => (q['field_type']?.toString() ?? '') == 'rating',
    );

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
          if (hasRatingQuestions) _buildRatingScaleIndicator(),
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
