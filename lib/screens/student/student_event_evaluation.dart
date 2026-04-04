import 'package:flutter/material.dart';
import '../../services/event_service.dart';

class StudentEventEvaluationScreen extends StatefulWidget {
  final String eventId;
  final String studentId;

  const StudentEventEvaluationScreen({
    super.key,
    required this.eventId,
    required this.studentId,
  });

  @override
  State<StudentEventEvaluationScreen> createState() => _StudentEventEvaluationScreenState();
}

class _StudentEventEvaluationScreenState extends State<StudentEventEvaluationScreen> {
  final EventService _eventService = EventService();
  bool _isLoading = true;
  List<Map<String, dynamic>> _questions = [];
  final Map<String, dynamic> _answers = {};

  @override
  void initState() {
    super.initState();
    _loadQuestions();
  }

  Future<void> _loadQuestions() async {
    final q = await _eventService.getEvaluationQuestions(widget.eventId);
    if (!mounted) return;
    setState(() {
      _questions = q;
      _isLoading = false;
    });
  }

  Future<void> _submit() async {
    for (final q in _questions) {
      if (q['required'] == true) {
        final ans = _answers[q['id']];
        if (ans == null || ans.toString().trim().isEmpty) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Please answer all required questions (e.g. ${q['question_text']})')),
          );
          return;
        }
      }
    }

    setState(() => _isLoading = true);
    
    final payload = _questions.map((q) {
      return {
        'question_id': q['id'],
        'answer_text': _answers[q['id']] ?? '',
      };
    }).toList();

    final res = await _eventService.submitEvaluation(
      eventId: widget.eventId,
      studentId: widget.studentId,
      answers: payload,
    );

    if (!mounted) return;
    setState(() => _isLoading = false);

    if (res['ok'] == true) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Evaluation Submitted! You can now download your certificate.')),
      );
      Navigator.pop(context, true); // Returns true = success
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(res['error'] ?? 'Submission failed.')),
      );
    }
  }

  Widget _buildRatingField(Map<String, dynamic> q) {
    final val = int.tryParse(_answers[q['id']]?.toString() ?? '0') ?? 0;
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: List.generate(5, (index) {
        final starIndex = index + 1;
        return IconButton(
          onPressed: () {
            setState(() {
              _answers[q['id']] = starIndex.toString();
            });
          },
          icon: Icon(
            starIndex <= val ? Icons.star_rounded : Icons.star_border_rounded,
            color: const Color(0xFFD4A843),
            size: 40,
          ),
        );
      }),
    );
  }

  Widget _buildTextField(Map<String, dynamic> q) {
    return TextFormField(
      initialValue: _answers[q['id']]?.toString() ?? '',
      maxLines: 4,
      onChanged: (v) => _answers[q['id']] = v,
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        title: const Text('Event Evaluation', style: TextStyle(color: Color(0xFF1F2937), fontWeight: FontWeight.bold)),
        backgroundColor: Colors.white,
        elevation: 0,
        iconTheme: const IconThemeData(color: Color(0xFF1F2937)),
      ),
      body: _isLoading 
        ? const Center(child: CircularProgressIndicator(color: Color(0xFF064E3B)))
        : _questions.isEmpty
          ? Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.fact_check_outlined, size: 64, color: Colors.grey),
                  const SizedBox(height: 16),
                  const Text('No evaluation questions available.'),
                  const SizedBox(height: 16),
                  ElevatedButton(
                     onPressed: () => Navigator.pop(context, true), // Force pass if no questions
                     style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF064E3B)),
                     child: const Text('SKIP & CLAIM CERTIFICATE', style: TextStyle(color: Colors.white)),
                  )
                ],
              )
            )
          : ListView.separated(
              padding: const EdgeInsets.all(24),
              itemCount: _questions.length + 1,
              separatorBuilder: (context, index) => const SizedBox(height: 24),
              itemBuilder: (context, index) {
                if (index == _questions.length) {
                  return ElevatedButton(
                    onPressed: _submit,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF064E3B),
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                    child: const Text('SUBMIT EVALUATION', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, letterSpacing: 1)),
                  );
                }

                final q = _questions[index];
                return Container(
                  padding: const EdgeInsets.all(20),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    border: Border.all(color: const Color(0xFFD4A843).withValues(alpha: 0.3)),
                    borderRadius: BorderRadius.circular(16),
                    boxShadow: [
                      BoxShadow(color: Colors.black.withValues(alpha: 0.02), blurRadius: 10, offset: const Offset(0, 4))
                    ]
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: Text(
                              q['question_text'] ?? '',
                              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: Color(0xFF1F2937)),
                            ),
                          ),
                          if (q['required'] == true)
                            const Text(' *', style: TextStyle(color: Colors.red, fontSize: 16)),
                        ],
                      ),
                      const SizedBox(height: 16),
                      q['field_type'] == 'rating' 
                        ? _buildRatingField(q)
                        : _buildTextField(q),
                    ],
                  ),
                );
              },
            ),
    );
  }
}
