import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'event_form_validation.dart';

class DescriptionWordLimitFormatter extends TextInputFormatter {
  DescriptionWordLimitFormatter({this.snapshot});

  final ValueNotifier<String>? snapshot;

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    var text = newValue.text;
    var words = EventFormValidation.countWords(text);
    final lastValid = snapshot?.value ?? oldValue.text;

    if (words > EventFormValidation.descriptionMaxWords) {
      text = EventFormValidation.truncateToWordLimit(
        text,
        EventFormValidation.descriptionMaxWords,
      );
      words = EventFormValidation.countWords(text);
    }

    final lastWords = EventFormValidation.countWords(lastValid);
    if (words >= EventFormValidation.descriptionMaxWords &&
        lastWords >= EventFormValidation.descriptionMaxWords &&
        text.length > lastValid.length) {
      return oldValue;
    }

    snapshot?.value = text;
    if (text == newValue.text) return newValue;

    return TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
      composing: TextRange.empty,
    );
  }
}
