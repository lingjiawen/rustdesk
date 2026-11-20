import 'package:flutter_hbb/utils/ios_clipboard_watcher.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late int count;
  late String clipboard;
  late bool allowed;
  late bool foreground;
  late DateTime now;
  late int reads;
  late List<String> sent;
  late IosClipboardWatcher watcher;

  setUp(() {
    count = 1;
    clipboard = 'first';
    allowed = true;
    foreground = true;
    now = DateTime(2026);
    reads = 0;
    sent = [];
    watcher = IosClipboardWatcher(
      changeCount: () async => count,
      hasText: () async => clipboard.isNotEmpty,
      readText: () async {
        reads++;
        return allowed ? clipboard : '';
      },
      send: sent.add,
      isForeground: () => foreground,
      now: () => now,
    );
  });

  void copy(String text) {
    clipboard = text;
    count++;
    now = now.add(const Duration(seconds: 10));
  }

  test('the clipboard is read once for each change, also when refused',
      () async {
    allowed = false;
    for (var i = 0; i < 5; i++) {
      await watcher.poll();
    }
    expect(reads, 1);
    expect(sent, isEmpty);

    allowed = true;
    copy('second');
    await watcher.poll();
    await watcher.poll();
    expect(reads, 2);
    expect(sent, ['second']);
  });

  test('what comes back from the remote side is not read', () async {
    await watcher.poll();
    expect(sent, ['first']);

    // Handoff brings the remote clipboard back right after a text was sent.
    clipboard = 'first';
    count++;
    now = now.add(const Duration(seconds: 2));
    await watcher.poll();

    // And right after the remote side's text was put on the phone.
    now = now.add(const Duration(seconds: 10));
    clipboard = 'from remote';
    count++;
    await watcher.wroteLocal('from remote');
    count++;
    now = now.add(const Duration(seconds: 2));
    await watcher.poll();
    expect(reads, 1);
    expect(sent, ['first']);

    copy('third');
    await watcher.poll();
    expect(sent, ['first', 'third']);
  });

  test('nothing is read in the background or when there is no text',
      () async {
    foreground = false;
    await watcher.poll();
    expect(reads, 0);

    foreground = true;
    clipboard = '';
    await watcher.poll();
    expect(reads, 0);
  });
}
