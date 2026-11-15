import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/consts.dart';
import 'package:flutter_hbb/mobile/widgets/session_panel.dart';

void main() {
  test('editing shortcuts use Cmd on a Mac and Ctrl on Windows', () {
    SessionShortcut copyFor(String platform) =>
        defaultSessionShortcuts(platform).firstWhere((s) => s.label == 'Copy');

    final mac = copyFor(kPeerPlatformMacOS);
    expect(mac.command, isTrue);
    expect(mac.ctrl, isFalse);
    expect(mac.describe(mac: true), '⌘C');

    final win = copyFor(kPeerPlatformWindows);
    expect(win.ctrl, isTrue);
    expect(win.command, isFalse);
    expect(win.describe(mac: false), 'Ctrl+C');
  });

  test('a custom shortcut survives saving', () {
    const s = SessionShortcut('Reopen tab', 'VK_T',
        ctrl: true, shift: true, custom: true);
    final back = SessionShortcut.fromJson(s.toJson())!;
    expect(back.describe(mac: false), 'Ctrl+Shift+T');
    expect(back.label, 'Reopen tab');
    expect(SessionShortcut.fromJson({'label': 'x'}), isNull);
  });
}
