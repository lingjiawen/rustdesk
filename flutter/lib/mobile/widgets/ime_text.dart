import 'package:flutter/services.dart';

/// The part of [value] an input method has committed: everything but the
/// marked text it is still composing (Pinyin letters, a Hangul syllable).
///
/// iOS commits a candidate in two updates, the new text while still marked and
/// then the mark cleared with the text unchanged, so the committed text is
/// what to compare against what was already sent.
String committedImeText(TextEditingValue value) {
  if (!value.isComposingRangeValid) return value.text;
  return value.composing.textBefore(value.text) +
      value.composing.textAfter(value.text);
}

/// The marked text being composed, or empty.
String composingImeText(TextEditingValue value) =>
    value.isComposingRangeValid ? value.composing.textInside(value.text) : '';
