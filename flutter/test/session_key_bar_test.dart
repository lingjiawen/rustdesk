import 'package:flutter/material.dart';
import 'package:flutter_hbb/consts.dart';
import 'package:flutter_hbb/mobile/widgets/session_key_bar.dart';
import 'package:flutter_hbb/mobile/widgets/session_panel.dart';
import 'package:flutter_hbb/mobile/widgets/touch_gesture_engine.dart';
import 'package:flutter_test/flutter_test.dart';

class _Sink implements SessionKeySink {
  final on = <String>{};
  final locked = <String>{};
  final keys = <String>[];
  final shortcuts = <SessionShortcut>[];

  @override
  bool modifierOn(String name) => on.contains(name);
  @override
  bool modifierLocked(String name) => locked.contains(name);
  @override
  void setModifier(String name, {required bool on, bool locked = false}) {
    on ? this.on.add(name) : this.on.remove(name);
    on && locked ? this.locked.add(name) : this.locked.remove(name);
  }

  @override
  void key(String name) => keys.add(name);
  @override
  void shortcut(SessionShortcut shortcut) => shortcuts.add(shortcut);
}

String _tr(String s) => s;

void main() {
  late _Sink sink;
  setUp(() => sink = _Sink());

  Future<void> pumpArea(WidgetTester tester,
      {required String platform,
      bool keyboardVisible = true,
      bool padShown = false,
      Size size = const Size(390, 844),
      void Function(double, bool)? onLayout,
      VoidCallback? onHide}) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Align(
          alignment: Alignment.bottomCenter,
          child: StatefulBuilder(
            builder: (context, setState) => SessionKeyArea(
              sink: sink,
              platform: platform,
              keyboardVisible: keyboardVisible,
              padShown: padShown,
              onTogglePad: () {},
              onHide: onHide ?? () {},
              onSendText: () {},
              onPasteClipboard: () {},
              onLayout: onLayout ?? (_, __) {},
              tr: _tr,
            ),
          ),
        ),
      ),
    ));
    // Lets the delayed measurement run.
    await tester.pump(const Duration(milliseconds: 600));
  }

  testWidgets('a tapped modifier is for one key, a long-pressed one stays on',
      (tester) async {
    await pumpArea(tester,
        platform: kPeerPlatformWindows, size: const Size(844, 390));
    await tester.tap(find.text('Ctrl'));
    expect(sink.on, {'ctrl'});
    expect(sink.locked, isEmpty);

    await tester.longPress(find.text('Alt'));
    expect(sink.locked, {'alt'});

    await tester.tap(find.text('Esc'));
    expect(sink.keys, ['VK_ESCAPE']);
  });

  testWidgets('an arrow key held down keeps pressing until released',
      (tester) async {
    await pumpArea(tester,
        platform: kPeerPlatformWindows, size: const Size(844, 390));
    final gesture = await tester
        .startGesture(tester.getCenter(find.byIcon(Icons.keyboard_arrow_left)));
    await tester.pump(const Duration(milliseconds: 510));
    expect(sink.keys, ['VK_LEFT']);
    await tester.pump(KeyCap.repeatInterval * 3);
    expect(sink.keys.length, 4);
    await gesture.up();
    await tester.pump(KeyCap.repeatInterval * 3);
    expect(sink.keys.length, 4);
  });

  testWidgets('the pad sends function keys and the peer\'s own edit shortcuts',
      (tester) async {
    await pumpArea(tester, platform: kPeerPlatformMacOS, padShown: true);
    await tester.tap(find.text('F5'));
    expect(sink.keys, ['VK_F5']);
    await tester.tap(find.text('Copy'));
    expect(sink.shortcuts.single.key, 'VK_C');
    expect(sink.shortcuts.single.command, isTrue);
    expect(sink.shortcuts.single.ctrl, isFalse);

    sink = _Sink();
    await pumpArea(tester, platform: kPeerPlatformWindows, padShown: true);
    await tester.tap(find.text('Copy'));
    expect(sink.shortcuts.single.ctrl, isTrue);
    expect(find.text('Ins'), findsOneWidget);
  });

  testWidgets('every pad key fits a phone held either way', (tester) async {
    for (final size in const [Size(375, 667), Size(844, 390)]) {
      await pumpArea(tester,
          platform: kPeerPlatformWindows, padShown: true, size: size);
      expect(tester.takeException(), isNull);
      expect(find.text('F12'), findsOneWidget);
      expect(tester.getSize(find.byType(SessionKeyArea)).height,
          lessThan(size.height * 0.5));
    }
  });

  testWidgets('hidden unless something asks for it, and hide clears modifiers',
      (tester) async {
    final layouts = <(double, bool)>[];
    await pumpArea(tester,
        platform: kPeerPlatformWindows,
        keyboardVisible: false,
        onLayout: (h, v) => layouts.add((h, v)));
    expect(find.byType(SessionKeyBar), findsNothing);
    expect(layouts.last, (0.0, false));

    var hidden = false;
    sink.setModifier('shift', on: true, locked: true);
    await pumpArea(tester,
        platform: kPeerPlatformWindows,
        keyboardVisible: false,
        onLayout: (h, v) => layouts.add((h, v)),
        onHide: () => hidden = true);
    expect(find.byType(SessionKeyBar), findsOneWidget);
    expect(layouts.last, (SessionKeyBar.height, true));

    await tester.tap(find.byIcon(Icons.keyboard_hide));
    expect(hidden, isTrue);
    expect(sink.on, isEmpty);
  });

  test('text is sent line by line with Return in between', () {
    expect(splitTextForSession('ls -la'), ['ls -la']);
    expect(splitTextForSession('ls', enter: true), ['ls', '\n']);
    expect(splitTextForSession('a\r\nb\n\nc'), ['a', '\n', 'b', '\n', '\n', 'c']);
    expect(splitTextForSession('', enter: true), isEmpty);
  });

  test('saved pointer speed and ball position survive bad values', () {
    expect(parsePointerSpeed(''), 1.0);
    expect(parsePointerSpeed('1.5'), 1.5);
    expect(parsePointerSpeed('9'), kPointerSpeedMax);
    expect(parseBallPosition(''), const Offset(1, 0.4));
    expect(parseBallPosition(formatBallPosition(const Offset(0, 0.25))),
        const Offset(0, 0.25));
    expect(parseBallPosition('0.2,7'), const Offset(0, 1));
  });
}
