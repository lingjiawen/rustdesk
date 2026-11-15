import 'package:flutter/services.dart';
import 'package:flutter_hbb/mobile/widgets/ime_text.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Pinyin still being composed is not committed text', () {
    const typing = TextEditingValue(
        text: '11ni hao', composing: TextRange(start: 2, end: 8));
    expect(committedImeText(typing), '11');
    expect(composingImeText(typing), 'ni hao');
  });

  test('a candidate counts as committed once the mark is cleared', () {
    // iOS first swaps in the candidate while it is still marked, then clears
    // the mark without changing the text.
    const stillMarked =
        TextEditingValue(text: '11你好', composing: TextRange(start: 2, end: 4));
    const cleared = TextEditingValue(text: '11你好');
    expect(committedImeText(stillMarked), '11');
    expect(committedImeText(cleared), '11你好');
  });

  test('a partly chosen phrase commits the chosen part', () {
    const partial =
        TextEditingValue(text: '11你hao', composing: TextRange(start: 3, end: 6));
    expect(committedImeText(partial), '11你');
    expect(composingImeText(partial), 'hao');
  });
}
