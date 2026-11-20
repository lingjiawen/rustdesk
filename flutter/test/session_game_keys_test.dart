import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_hbb/consts.dart';
import 'package:flutter_hbb/mobile/widgets/game_keys.dart';
import 'package:flutter_hbb/mobile/widgets/panel_quick_actions.dart';
import 'package:flutter_hbb/mobile/widgets/phone_resolution.dart';
import 'package:flutter_hbb/models/model.dart' show Resolution;
import 'package:flutter_hbb/mobile/widgets/session_panel.dart';
import 'package:flutter_test/flutter_test.dart';

class _Sink implements GameKeySink {
  final log = <(String, bool)>[];
  final combos = <String>[];
  final scrolls = <int>[];
  var looked = Offset.zero;

  @override
  void press(String key, bool down,
      {bool ctrl = false, bool shift = false, bool alt = false}) {
    log.add((key, down));
    if (down && (ctrl || shift || alt)) {
      combos.add([if (ctrl) 'ctrl', if (shift) 'shift', if (alt) 'alt', key]
          .join('+'));
    }
  }

  @override
  void look(double dx, double dy) => looked += Offset(dx, dy);

  @override
  void scroll(int notches) => scrolls.add(notches);
}

void main() {
  late _Sink sink;
  setUp(() => sink = _Sink());

  Future<void> pumpOverlay(WidgetTester tester,
      {ValueChanged<GameKeyLayouts>? onChanged,
      GameKeyLayouts? layouts,
      bool lookSupported = false,
      bool shown = true}) async {
    tester.view.physicalSize = const Size(844, 390);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Stack(children: [
          if (shown)
            Positioned.fill(
              child: GameKeysOverlay(
                sink: sink,
                layouts: layouts ??
                    GameKeyLayouts([GameKeyLayout('', defaultGameKeys())]),
                onChanged: onChanged ?? (_) {},
                onClose: () {},
                lookSupported: lookSupported,
                tr: (s) => s,
              ),
            ),
        ]),
      ),
    ));
  }

  testWidgets('keys stay down while held, several at once', (tester) async {
    await pumpOverlay(tester);
    final w = await tester.startGesture(tester.getCenter(find.text('W')));
    final space =
        await tester.startGesture(tester.getCenter(find.text('Space')));
    expect(sink.log, [('VK_W', true), ('VK_SPACE', true)]);
    await w.up();
    expect(sink.log.last, ('VK_W', false));

    // Closing the overlay lets go of what is still held.
    await pumpOverlay(tester, shown: false);
    expect(sink.log.last, ('VK_SPACE', false));
    await space.up();
  });

  testWidgets('in edit mode a key is dragged to a new place, not pressed',
      (tester) async {
    GameKeyLayouts? saved;
    await pumpOverlay(tester, onChanged: (layouts) => saved = layouts);
    final before = tester.getCenter(find.text('W'));
    await tester.tap(find.byIcon(Icons.tune));
    await tester.pump();
    await tester.drag(find.text('W'), const Offset(120, -80));
    await tester.pump();
    expect(sink.log, isEmpty);
    final after = tester.getCenter(find.text('W'));
    expect(after.dx, greaterThan(before.dx + 60));
    expect(after.dy, lessThan(before.dy - 40));
    final w = saved!.layout.keys.firstWhere((k) => k.key == 'VK_W');
    expect(w.center(const Size(844, 390)), after);
  });

  test('the default keys fit a phone held either way without overlapping', () {
    for (final area in const [Size(844, 369), Size(390, 750)]) {
      final rects = [
        for (final k in defaultGameKeys())
          Rect.fromCircle(center: k.center(area), radius: k.extent / 2)
      ];
      for (var i = 0; i < rects.length; i++) {
        expect((Offset.zero & area).contains(rects[i].topLeft), isTrue);
        expect((Offset.zero & area).contains(rects[i].bottomRight), isTrue);
        for (var j = i + 1; j < rects.length; j++) {
          expect(rects[i].overlaps(rects[j]), isFalse, reason: '$i/$j $area');
        }
      }
    }
  });

  test('a moved key keeps its distance from the nearest corner', () {
    const landscape = Size(844, 390);
    final key =
        const GameKey('VK_F', 0, 0).movedTo(const Offset(800, 350), landscape);
    expect(key.center(landscape), const Offset(800, 350));
    expect(key.center(const Size(390, 844)), const Offset(346, 804));

    // A bare list of keys is what was saved while there was one layout.
    final saved = jsonEncode([key.toJson()]);
    final loaded = parseGameKeyLayouts(saved).layout.keys.single;
    expect(loaded.center(landscape), const Offset(800, 350));
    for (final bad in ['not json', '[{"key":"VK_NOPE","dx":1,"dy":1}]']) {
      expect(parseGameKeyLayouts(bad).layout.keys.length,
          defaultGameKeys().length);
    }
  });

  testWidgets('another layout is picked by name and remembered',
      (tester) async {
    GameKeyLayouts? saved;
    await pumpOverlay(tester,
        onChanged: (layouts) => saved = layouts,
        layouts: GameKeyLayouts([
          GameKeyLayout('', defaultGameKeys()),
          const GameKeyLayout('Racing', [GameKey('VK_F', 60, 60)]),
        ]));
    expect(find.text('W'), findsOneWidget);
    await tester.tap(find.text('Default'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Racing'));
    await tester.pumpAndSettle();
    expect(find.text('W'), findsNothing);
    expect(find.text('F'), findsOneWidget);

    final loaded = parseGameKeyLayouts(jsonEncode(saved!.toJson()));
    expect(loaded.layout.name, 'Racing');
    expect(loaded.layouts.length, 2);
  });

  GameKeyLayouts oneLayout(List<GameKey> keys, {bool look = false}) =>
      GameKeyLayouts([GameKeyLayout('', keys, look: look)]);

  testWidgets('a joystick holds the keys of the way it is pushed',
      (tester) async {
    await pumpOverlay(tester,
        layouts: oneLayout(const [GameKey(kGameKeyStickWasd, 100, 100)]));
    final thumb =
        await tester.startGesture(tester.getCenter(find.text('WASD')));
    expect(sink.log, isEmpty);
    await thumb.moveBy(const Offset(-40, -40));
    expect(sink.log.toSet(), {('VK_W', true), ('VK_A', true)});
    sink.log.clear();
    await thumb.moveBy(const Offset(80, 40));
    expect(
        sink.log.toSet(), {('VK_W', false), ('VK_A', false), ('VK_D', true)});
    await thumb.up();
    expect(sink.log.last, ('VK_D', false));
  });

  testWidgets(
      'a tap holds a locking key, a key can carry modifiers and '
      'a wheel key keeps turning', (tester) async {
    await pumpOverlay(tester,
        layouts: oneLayout(const [
          GameKey('VK_W', 60, 60, lock: true),
          GameKey('VK_1', 160, 60, ctrl: true),
          GameKey(kGameKeyWheelUp, 60, 60, right: true),
        ]));
    await tester.tap(find.text('W'));
    expect(sink.log, [('VK_W', true)]);
    await tester.tap(find.text('W'));
    expect(sink.log, [('VK_W', true), ('VK_W', false)]);

    await tester.tap(find.text('Ctrl+1'));
    expect(sink.combos, ['ctrl+VK_1']);

    final wheel = await tester.startGesture(
        tester.getCenter(find.byIcon(Icons.keyboard_double_arrow_up)));
    await tester.pump(const Duration(milliseconds: 250));
    await wheel.up();
    expect(sink.scrolls, [1, 1, 1]);
    await tester.pump(const Duration(milliseconds: 250));
    expect(sink.scrolls.length, 3);
  });

  testWidgets('with mouse look on, a drag between the keys turns the view',
      (tester) async {
    final keys = const [GameKey(kGameKeyMouseLeft, 60, 60, right: true)];
    await pumpOverlay(tester, layouts: oneLayout(keys), lookSupported: true);
    await tester.dragFrom(const Offset(400, 200), const Offset(30, -10));
    expect(sink.looked, Offset.zero);

    await tester.tap(find.byIcon(Icons.mouse_outlined));
    await tester.pump();
    await tester.dragFrom(const Offset(400, 200), const Offset(30, -10));
    expect(sink.looked, const Offset(30, -10));
    // Aiming goes on with the fire button held.
    await tester.drag(find.text('LMB'), const Offset(0, 20));
    expect(sink.looked, const Offset(30, 10));
    expect(sink.log, [(kGameKeyMouseLeft, true), (kGameKeyMouseLeft, false)]);
  });

  test('the new kinds of key and mouse look survive saving', () {
    final saved = jsonEncode(oneLayout(const [
      GameKey(kGameKeyStickArrows, 80, 80, size: kGameKeySizeLarge),
      GameKey('VK_F', 10, 10, shift: true, alt: true, lock: true),
    ], look: true)
        .toJson());
    final layout = parseGameKeyLayouts(saved).layout;
    expect(layout.look, isTrue);
    expect(layout.keys.first.extent, kGameKeySizeLarge * kGameStickScale);
    expect(layout.keys.last.text, 'Shift+Alt+F');
    expect(layout.keys.last.lock, isTrue);
    expect(gameStickKeys(kGameKeyStickArrows, const Offset(0, 30), 50),
        {'VK_DOWN'});
    expect(gameStickKeys(kGameKeyStickArrows, const Offset(2, 3), 50), isEmpty);
  });

  test('layouts are copied, renamed and removed', () {
    var layouts = GameKeyLayouts([GameKeyLayout('', defaultGameKeys())]);
    expect(layouts.removed(0).layouts.length, 1);
    layouts = layouts.added('Shooter').withKeys(const [GameKey('VK_F', 1, 1)]);
    expect(layouts.layout.name, 'Shooter');
    expect(layouts.layouts.first.keys.length, defaultGameKeys().length);
    layouts = layouts.renamed(0, 'Base').removed(1);
    expect(layouts.layouts.single.name, 'Base');
    expect(layouts.current, 0);
  });

  test('saved quick actions keep their order and pick up new ones', () {
    final all = kPanelQuickActions.map((e) => e.$1).toList();
    expect(parsePanelActions('').map((e) => e.id), all);
    expect(parsePanelActions('').every((e) => e.shown), isTrue);

    final entries = parsePanelActions('chat,-keyboard,gone');
    expect(entries.first, (id: 'chat', shown: true));
    expect(entries.firstWhere((e) => e.id == 'keyboard').shown, isFalse);
    expect(entries.map((e) => e.id).toSet(), all.toSet());
    // An action the saved order does not know follows its default neighbour.
    final ids = entries.map((e) => e.id).toList();
    expect(ids.indexOf('fn-keys'), ids.indexOf('keyboard') + 1);
    expect(parsePanelActions(formatPanelActions(entries)), entries);
  });

  test('frame rate and preset mapping', () {
    for (final preset in [
      kRemoteImageQualityLow,
      kRemoteImageQualityBalanced,
      kRemoteImageQualityBest
    ]) {
      expect(presetForCustomQuality(customQualityForPreset(preset)), preset);
    }
    expect(parseSessionFps(null), 30);
    expect(parseSessionFps('60'), 60);
    expect(parseSessionFps('100'), 120);
    // Frames a 60 Hz screen cannot show are not worth asking for.
    expect(sessionFpsChoices(60), [30, 60]);
    expect(sessionFpsChoices(120), [30, 60, 120]);
    expect(sessionFpsChoices(0), [30, 60, 120]);
    // Speed mode is the low bitrate at 60 frames, HD mode the best preset.
    expect(sessionModeFps(120), 60);
    expect(sessionModeOf(kRemoteImageQualityCustom, 25), SessionMode.speed);
    expect(sessionModeOf(kRemoteImageQualityLow, 0), SessionMode.speed);
    expect(sessionModeOf(kRemoteImageQualityBest, 0), SessionMode.hd);
    expect(sessionModeOf(kRemoteImageQualityCustom, 75), SessionMode.hd);
    expect(sessionModeOf(kRemoteImageQualityCustom, 34), isNull);
    expect(sessionModeOf(kRemoteImageQualityBalanced, 0), isNull);
    // A custom quality of 50 is the remote's bitrate ratio 1; its presets
    // are 0.5, 0.67 and 1.5.
    expect(customQualityForPreset(kRemoteImageQualityLow), 25);
    expect(customQualityForPreset(kRemoteImageQualityBest), 75);
    // A phone looks at about half the pixels of the laptop's own resolution.
    final offered = [
      for (final (w, h) in [
        (1024, 665),
        (1147, 745),
        (1352, 878),
        (1512, 982),
        (1800, 1169),
        (1280, 720),
      ])
        Resolution(w, h)
    ];
    final pick = pickPhoneResolution(offered, 1512, 982)!;
    expect((pick.width, pick.height), (1147, 745));
    expect(pickPhoneResolution([Resolution(1512, 982)], 1512, 982), isNull);
  });
}
