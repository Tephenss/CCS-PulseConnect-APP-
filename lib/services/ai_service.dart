import 'dart:convert';
import 'package:http/http.dart' as http;

class AiService {
  // Using the API key from your config.php for immediate integration
  static const String _geminiApiKey = 'AIzaSyCyeXBGSH_BOhN_VF3H8WCTSmDsOlw-vOA';
  
  Future<Map<String, dynamic>> improveText(String rawText) async {
    if (rawText.trim().isEmpty) {
      return {'ok': false, 'error': 'No text provided.'};
    }

    final String url = 'https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent?key=$_geminiApiKey';
    final systemPrompt = "You are an expert event copywriter and AI editor for the 'College of Computer Studies (CCS) PulseConnect', a university Event Management System. Your job is to take raw, messy, dictated Speech-to-Text notes (which may contain typos, bad grammar, or mixed Taglish) and polish them into a highly professional, engaging event description for students and faculty.\n"
        "REQUIREMENTS:\n"
        "1. Fix all typos and misheard words from speech-to-text.\n"
        "2. Improve grammar and flow so it sounds academic but still exciting and friendly.\n"
        "3. Expand appropriately for an IT/CS university event.\n"
        "4. DO NOT use markdown formatting or bullet symbols (*, -, •). Output MUST be plain text only.\n"
        "5. FORMAT the text in clear blocks, NOT one long paragraph:\n"
        "   - First, a short overview paragraph (1–2 sentences).\n"
        "   - Then a 'Key Details:' line followed by 2–4 short sentences, each on its own line.\n"
        "   - Optionally, a 'Reminders:' line with 1–3 short sentences, each on its own line.\n"
        "6. Do not add headings for date, time, or venue if they are not present in the raw text.\n"
        "7. Output ONLY the final polished text, ready to be pasted directly into the event description box.";

    final payload = {
      "contents": [
        {
          "role": "user",
          "parts": [
            {"text": "$systemPrompt\n\nRAW TEXT TO FORMAT:\n$rawText"}
          ]
        }
      ]
    };

    try {
      final response = await http.post(
        Uri.parse(url),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode(payload),
      );

      if (response.statusCode == 200) {
        final jsonRes = jsonDecode(response.body);
        final formattedText = jsonRes['candidates'][0]['content']['parts'][0]['text'] ?? '';
        return {'ok': true, 'improved_text': formattedText.trim()};
      } else {
        return {'ok': false, 'error': 'API Error: ${response.statusCode}'};
      }
    } catch (e) {
      return {'ok': false, 'error': 'Connection Error: $e'};
    }
  }
}
