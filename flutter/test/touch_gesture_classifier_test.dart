import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/consts.dart';
import 'package:flutter_hbb/mobile/widgets/touch_gesture_engine.dart';

class _RecordingSink implements TouchGestureSink {
  final events = <String>[];
  final moves = <Offset>[];
  bool touchable = true;

  @override
  void prepareCursorMove() => events.add('prepare');
  @override
  void moveCursorBy(Offset delta, Offset position) {
    events.add('moveBy');
    moves.add(delta);
  }
  @override
  bool canTouchAt(Offset position) => touchable;
  @override
  void moveCursorTo(Offset position) =>
      events.add('moveTo ${position.dx.round()},${position.dy.round()}');
  @override
  void dragCursorTo(Offset delta, Offset position) => events.add('dragTo');
  @override
  void click(TouchButton button) => events.add('click ${button.name}');
  @override
  void buttonDown(TouchButton button) => events.add('down ${button.name}');
  @override
  void buttonUp(TouchButton button) => events.add('up ${button.name}');
  @override
  void scroll(Offset fingerDelta) => events.add('scroll');
  @override
  void scrollEnd() => events.add('scrollEnd');
  @override
  void zoomCanvas(double ratio, Offset focal) => events.add('zoom');
  @override
  void panCanvas(Offset delta) => events.add('pan');
  @override
  void showHint(TouchHint? hint) => events.add('hint ${hint?.name}');
  @override
  void haptic(TouchHaptic kind) {}
  @override
  void systemSwipe(TouchSwipe direction) => events.add('swipe ${direction.name}');

  List<String> get actions => events
      .where((e) => !e.startsWith('hint') && e != 'prepare')
      .toSet()
      .toList();
}

class _FakeTimer implements Timer {
  _FakeTimer(this.due, this.callback);
  final Duration due;
  final void Function() callback;
  bool _active = true;
  @override
  void cancel() => _active = false;
  @override
  bool get isActive => _active;
  @override
  int get tick => 0;
}

class _Clock {
  final timers = <_FakeTimer>[];
  Duration now = Duration.zero;

  Timer create(Duration d, void Function() cb) {
    final t = _FakeTimer(now + d, cb);
    timers.add(t);
    return t;
  }

  Duration advance(int ms) {
    now += Duration(milliseconds: ms);
    for (final t in timers.toList()) {
      if (t.isActive && t.due <= now) {
        t.cancel();
        t.callback();
      }
    }
    return now;
  }
}

void main() {
  late _RecordingSink sink;
  late _Clock clock;
  late TouchGestureClassifier c;

  void setUpMode({required bool touchMode}) {
    sink = _RecordingSink();
    clock = _Clock();
    c = TouchGestureClassifier(sink,
        touchMode: touchMode, timerFactory: clock.create);
  }

  group('pointer mode', () {
    setUp(() => setUpMode(touchMode: false));

    test('tap clicks as soon as the finger lifts', () {
      c.pointerDown(1, const Offset(100, 100), clock.now);
      c.pointerUp(1, const Offset(101, 100), clock.advance(60));
      expect(sink.actions, ['click left']);
    });

    test('two-finger tap right-clicks without a left click', () {
      c.pointerDown(1, const Offset(100, 100), clock.now);
      c.pointerDown(2, const Offset(160, 100), clock.advance(20));
      c.pointerUp(1, const Offset(100, 100), clock.advance(60));
      c.pointerUp(2, const Offset(160, 100), clock.advance(10));
      expect(sink.actions, ['click right']);
    });

    test('one-finger move only moves the cursor', () {
      c.pointerDown(1, const Offset(100, 100), clock.now);
      c.pointerMove(1, const Offset(140, 100), clock.advance(30));
      c.pointerUp(1, const Offset(140, 100), clock.advance(30));
      expect(sink.actions, ['moveBy']);
    });

    test('a resting finger keeps moving the cursor when it slides at once',
        () {
      c.pointerDown(1, const Offset(100, 100), clock.now);
      c.pointerMove(1, const Offset(100, 160), clock.advance(200));
      c.pointerUp(1, const Offset(100, 160), clock.advance(50));
      expect(sink.actions, ['moveBy']);
    });

    test('hold then move drags with the left button', () {
      c.pointerDown(1, const Offset(100, 100), clock.now);
      clock.advance(520);
      expect(sink.events, contains('hint drag'));
      c.pointerMove(1, const Offset(150, 100), clock.advance(20));
      c.pointerUp(1, const Offset(150, 100), clock.advance(20));
      expect(sink.actions, ['down left', 'moveBy', 'up left']);
    });

    test('double tap and move clicks, then drags', () {
      c.pointerDown(1, const Offset(100, 100), clock.now);
      c.pointerUp(1, const Offset(100, 100), clock.advance(60));
      c.pointerDown(2, const Offset(104, 100), clock.advance(120));
      c.pointerMove(2, const Offset(160, 100), clock.advance(40));
      c.pointerUp(2, const Offset(160, 100), clock.advance(40));
      expect(sink.actions, ['click left', 'down left', 'moveBy', 'up left']);
    });

    test('a fast finger sends the cursor farther than a slow one', () {
      c.pointerDown(1, const Offset(100, 100), clock.now);
      c.pointerMove(1, const Offset(100, 115), clock.advance(150));
      c.pointerMove(1, const Offset(100, 130), clock.advance(150));
      c.pointerUp(1, const Offset(100, 130), clock.advance(20));
      final slow = sink.moves.last.distance;
      setUpMode(touchMode: false);
      c.pointerDown(1, const Offset(100, 100), clock.now);
      c.pointerMove(1, const Offset(100, 115), clock.advance(5));
      c.pointerMove(1, const Offset(100, 130), clock.advance(5));
      c.pointerUp(1, const Offset(100, 130), clock.advance(20));
      final fast = sink.moves.last.distance;
      expect(slow, lessThan(15));
      expect(fast, greaterThan(15 * 2));
    });

    test('three-finger swipe up opens the overview without clicking', () {
      c.pointerDown(1, const Offset(100, 300), clock.now);
      c.pointerDown(2, const Offset(150, 300), clock.advance(10));
      c.pointerDown(3, const Offset(200, 300), clock.advance(10));
      for (var y = 290; y >= 220; y -= 10) {
        c.pointerMove(1, Offset(100, y.toDouble()), clock.advance(8));
        c.pointerMove(2, Offset(150, y.toDouble()), clock.now);
        c.pointerMove(3, Offset(200, y.toDouble()), clock.now);
      }
      c.pointerUp(1, const Offset(100, 220), clock.advance(10));
      c.pointerUp(2, const Offset(150, 220), clock.now);
      c.pointerUp(3, const Offset(200, 220), clock.now);
      expect(sink.actions, ['swipe up']);
    });

    test('two fingers moving together scroll; pinching zooms', () {
      c.pointerDown(1, const Offset(100, 100), clock.now);
      c.pointerDown(2, const Offset(200, 100), clock.advance(10));
      c.pointerMove(1, const Offset(100, 130), clock.advance(16));
      c.pointerMove(2, const Offset(200, 130), clock.advance(1));
      c.pointerUp(1, const Offset(100, 130), clock.advance(16));
      c.pointerUp(2, const Offset(200, 130), clock.advance(1));
      expect(sink.actions, ['scroll', 'scrollEnd']);

      setUpMode(touchMode: false);
      c.pointerDown(1, const Offset(100, 100), clock.now);
      c.pointerDown(2, const Offset(200, 100), clock.advance(10));
      c.pointerMove(1, const Offset(60, 100), clock.advance(16));
      c.pointerMove(2, const Offset(240, 100), clock.advance(1));
      c.pointerUp(1, const Offset(60, 100), clock.advance(16));
      c.pointerUp(2, const Offset(240, 100), clock.advance(1));
      expect(sink.actions, ['zoom', 'pan']);
    });
  });

  group('touch mode', () {
    setUp(() => setUpMode(touchMode: true));

    test('tap clicks under the finger, and a second tap reuses the spot', () {
      c.pointerDown(1, const Offset(100, 100), clock.now);
      c.pointerUp(1, const Offset(100, 100), clock.advance(60));
      c.pointerDown(2, const Offset(108, 104), clock.advance(100));
      c.pointerUp(2, const Offset(108, 104), clock.advance(60));
      expect(sink.events.where((e) => !e.startsWith('hint')).toList(),
          ['moveTo 100,100', 'click left', 'moveTo 100,100', 'click left']);
    });

    test('long hold right-clicks where the finger rests', () {
      c.pointerDown(1, const Offset(50, 80), clock.now);
      clock.advance(720);
      expect(sink.events, contains('hint rightClick'));
      c.pointerUp(1, const Offset(50, 80), clock.advance(30));
      expect(sink.actions, ['moveTo 50,80', 'click right']);
    });

    test('a quick swipe scrolls instead of dragging', () {
      c.pointerDown(1, const Offset(100, 300), clock.now);
      c.pointerMove(1, const Offset(100, 200), clock.advance(40));
      c.pointerUp(1, const Offset(100, 180), clock.advance(20));
      expect(sink.actions, ['scroll', 'scrollEnd']);
    });

    test('short hold then move drags from where the finger landed', () {
      c.pointerDown(1, const Offset(100, 100), clock.now);
      clock.advance(320);
      c.pointerMove(1, const Offset(100, 160), clock.advance(20));
      c.pointerUp(1, const Offset(100, 160), clock.advance(20));
      expect(sink.actions, ['moveTo 100,100', 'down left', 'dragTo', 'up left']);
    });

    test('nothing is sent for a tap outside the remote screen', () {
      sink.touchable = false;
      c.pointerDown(1, const Offset(5, 5), clock.now);
      c.pointerUp(1, const Offset(5, 5), clock.advance(60));
      expect(sink.actions, isEmpty);
    });
  });

  test('three-finger swipes map to each desktop\'s own gestures', () {
    final up = swipeShortcut(TouchSwipe.up, kPeerPlatformMacOS)!;
    expect([up.key, up.ctrl], ['VK_UP', true]);
    final left = swipeShortcut(TouchSwipe.left, kPeerPlatformMacOS)!;
    expect([left.key, left.ctrl], ['VK_RIGHT', true]);
    final win = swipeShortcut(TouchSwipe.up, kPeerPlatformWindows)!;
    expect([win.key, win.command], ['VK_TAB', true]);
    expect(swipeShortcut(TouchSwipe.up, 'Android'), isNull);
  });
}
