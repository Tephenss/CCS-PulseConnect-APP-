import 'package:flutter/material.dart';
import '../../services/event_service.dart';
import '../../widgets/custom_loader.dart';

class StudentResponseView extends StatefulWidget {
  final String eventId;
  final String studentId;

  const StudentResponseView({
    super.key,
    required this.eventId,
    required this.studentId,
  });

  @override
  State<StudentResponseView> createState() => _StudentResponseViewState();
}

class _StudentResponseViewState extends State<StudentResponseView> {
  final EventService _eventService = EventService();
  bool _isLoading = true;
  List<Map<String, dynamic>> _sections = [];

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  Future<void> _loadData() async {
    final bundle = await _eventService.getEvaluationBundle(
      eventId: widget.eventId,
      studentId: widget.studentId,
    );

    final rawSections = bundle['sections'];
    final sections = rawSections is List
        ? rawSections
            .whereType<Map>()
            .map((row) => Map<String, dynamic>.from(row))
            .where((section) => section['is_complete'] == true)
            .toList()
        : <Map<String, dynamic>>[];

    if (!mounted) return;
    setState(() {
      _sections = sections;
      _isLoading = false;
    });
  }

  Widget _buildRatingDisplay(int rating) {
    return Row(
      children: List.generate(5, (index) {
        return Icon(
          index < rating ? Icons.star_rounded : Icons.star_border_rounded,
          color: const Color(0xFFD4A843),
          size: 26,
        );
      }),
    );
  }

  Widget _buildSectionCard(Map<String, dynamic> section) {
    final rawQuestions = section['questions'];
    final questions = rawQuestions is List
        ? rawQuestions
            .whereType<Map>()
            .map((row) => Map<String, dynamic>.from(row))
            .toList()
        : <Map<String, dynamic>>[];
    final rawAnswers = section['answers'];
    final answers = rawAnswers is Map<String, dynamic>
        ? rawAnswers
        : (rawAnswers is Map ? Map<String, dynamic>.from(rawAnswers) : <String, dynamic>{});

    return Container(
      margin: const EdgeInsets.only(bottom: 20),
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: Colors.grey.shade200),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.03),
            blurRadius: 10,
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
          const SizedBox(height: 14),
          ...questions.asMap().entries.map((entry) {
            final index = entry.key;
            final question = entry.value;
            final questionId = question['id']?.toString() ?? '';
            final answerText = answers[questionId]?.toString() ?? '';
            final isRating = question['field_type']?.toString() == 'rating';
            final ratingVal = int.tryParse(answerText) ?? 0;

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
                    children: [
                      Container(
                        width: 30,
                        height: 30,
                        decoration: BoxDecoration(
                          color: const Color(0xFF064E3B).withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Center(
                          child: Text(
                            '${index + 1}',
                            style: const TextStyle(
                              color: Color(0xFF064E3B),
                              fontWeight: FontWeight.w800,
                              fontSize: 13,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          question['question_text']?.toString() ?? '',
                          style: const TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                            color: Color(0xFF374151),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  if (isRating)
                    _buildRatingDisplay(ratingVal)
                  else
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: const Color(0xFFE5E7EB)),
                      ),
                      child: Text(
                        answerText.isEmpty ? '(No answer provided)' : answerText,
                        style: TextStyle(
                          fontSize: 14,
                          color: answerText.isEmpty
                              ? Colors.grey
                              : const Color(0xFF1F2937),
                          fontStyle: answerText.isEmpty
                              ? FontStyle.italic
                              : FontStyle.normal,
                          height: 1.5,
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF9FAFB),
      appBar: AppBar(
        title: const Text(
          'My Evaluation',
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
          : _sections.isEmpty
              ? const Center(child: Text('No submitted evaluation data found.'))
              : ListView(
                  padding: const EdgeInsets.all(20),
                  children: _sections.map(_buildSectionCard).toList(),
                ),
    );
  }
}
