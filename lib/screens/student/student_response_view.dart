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
  List<Map<String, dynamic>> _questions = [];
  List<Map<String, dynamic>> _answers = [];

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  Future<void> _loadData() async {
    final questions = await _eventService.getEvaluationQuestions(widget.eventId);
    final answers = await _eventService.getStudentAnswers(widget.eventId, widget.studentId);
    if (!mounted) return;
    setState(() {
      _questions = questions;
      _answers = answers;
      _isLoading = false;
    });
  }

  String _getAnswer(String questionId) {
    for (var a in _answers) {
      if (a['question_id']?.toString() == questionId.toString()) {
        return a['answer_text']?.toString() ?? '';
      }
    }
    return '';
  }

  Widget _buildRatingDisplay(int rating) {
    return Row(
      children: List.generate(5, (index) {
        return Icon(
          index < rating ? Icons.star_rounded : Icons.star_border_rounded,
          color: const Color(0xFFD4A843),
          size: 28,
        );
      }),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF9FAFB),
      appBar: AppBar(
        title: const Text('My Evaluation', style: TextStyle(color: Color(0xFF1F2937), fontWeight: FontWeight.bold)),
        backgroundColor: Colors.white,
        elevation: 0,
        iconTheme: const IconThemeData(color: Color(0xFF1F2937)),
      ),
      body: _isLoading
          ? const Center(child: PulseConnectLoader())
          : _questions.isEmpty
              ? const Center(child: Text('No evaluation data found.'))
              : ListView.separated(
                  padding: const EdgeInsets.all(20),
                  itemCount: _questions.length,
                  separatorBuilder: (context, index) => const SizedBox(height: 16),
                  itemBuilder: (context, index) {
                    final q = _questions[index];
                    final answerText = _getAnswer(q['id'].toString());
                    final isRating = q['field_type'] == 'rating';
                    final ratingVal = int.tryParse(answerText) ?? 0;

                    return Container(
                      padding: const EdgeInsets.all(20),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: Colors.grey.shade200),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.02),
                            blurRadius: 8,
                            offset: const Offset(0, 2),
                          ),
                        ],
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Container(
                                width: 32,
                                height: 32,
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
                                      fontSize: 14,
                                    ),
                                  ),
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Text(
                                  q['question_text'] ?? '',
                                  style: const TextStyle(
                                    fontSize: 15,
                                    fontWeight: FontWeight.w600,
                                    color: Color(0xFF374151),
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 14),
                          const Divider(height: 1),
                          const SizedBox(height: 14),
                          if (isRating)
                            _buildRatingDisplay(ratingVal)
                          else
                            Container(
                              width: double.infinity,
                              padding: const EdgeInsets.all(14),
                              decoration: BoxDecoration(
                                color: const Color(0xFFF3F4F6),
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: Text(
                                answerText.isEmpty ? '(No answer provided)' : answerText,
                                style: TextStyle(
                                  fontSize: 14,
                                  color: answerText.isEmpty ? Colors.grey : const Color(0xFF1F2937),
                                  fontStyle: answerText.isEmpty ? FontStyle.italic : FontStyle.normal,
                                  height: 1.5,
                                ),
                              ),
                            ),
                        ],
                      ),
                    );
                  },
                ),
    );
  }
}
