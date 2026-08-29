import 'package:flutter/services.dart';

import 'event_form_validation.dart';

class EventFeeInputFormatter extends TextInputFormatter {
  const EventFeeInputFormatter();
  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final normalized = EventFormValidation.normalizeEventFeeInput(newValue.text);
    return TextEditingValue(
      text: normalized,
      selection: TextSelection.collapsed(offset: normalized.length),
    );
  }
}
