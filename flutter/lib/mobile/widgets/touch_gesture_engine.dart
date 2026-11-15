import 'dart:async';
import 'dart:math';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../common.dart';
import '../../models/input_model.dart';
import '../../models/model.dart';

/// Shown at the top-left while a held finger is ready to drag or right-click,
/// so the user knows what moving or releasing it will do.
enum TouchHint { drag, rightClick }

enum TouchButton { left, right, middle }

enum TouchHaptic { click, ready, heavy }

/// What the gesture classifier asks the remote session to do. Calls are
/// fire-and-forget; the implementation keeps them in order.
abstract class TouchGestureSink {
  /// Pointer mode: brings the cursor into view before the finger moves it.
  void prepareCursorMove();

  /// Pointer mode: moves the remote cursor by a finger delta.
  void moveCursorBy(Offset delta, Offset position);

  /// Touch mode: whether [position] is on the remote screen.
  bool canTouchAt(Offset position);

  /// Touch mode: puts the remote cursor under the finger.
  void moveCursorTo(Offset position);

  /// Touch mode: follows the finger while a button is held.
  void dragCursorTo(Offset delta, Offset position);

  void click(TouchButton button);
  void buttonDown(TouchButton button);
  void buttonUp(TouchButton button);

  /// Scrolls the remote content so it follows the finger.
  void scroll(Offset fingerDelta);
  void scrollEnd();

  void zoomCanvas(double ratio, Offset focal);
  void panCanvas(Offset delta);

  void showHint(TouchHint? hint);
  void haptic(TouchHaptic kind);
}

typedef TouchTimerFactory = Timer Function(
    Duration duration, void Function() callback);

enum _Phase {
  idle,
  oneDown,
  dragReady,
  rightReady,
  cursorMove,
  scroll,
  dragging,
  multi,
  pinch,
  twoScroll,
  twoPan,
  done,
}

/// Turns raw touch pointers into clicks, drags, scrolls and canvas zoom.
///
/// Unlike the arena-based recognizers, a tap is sent the moment the finger
/// lifts, so a click never waits for a possible double tap.
///
/// Pointer mode (like a trackpad): one finger moves the cursor, tap clicks,
/// two-finger tap right-clicks, two fingers scroll, pinch zooms the canvas,
/// double-tap-and-move or hold-and-move drags.
///
/// Touch mode (the finger is the cursor): tap clicks under the finger, a long
/// hold right-clicks, a short hold then move drags, one finger scrolls, two
/// fingers pan the canvas and pinch zooms it.
class TouchGestureClassifier {
  TouchGestureClassifier(this.sink,
      {this.touchMode = false, TouchTimerFactory? timerFactory})
      : _timerFactory = timerFactory ?? ((d, cb) => Timer(d, cb));

  final TouchGestureSink sink;
  bool touchMode;
  final TouchTimerFactory _timerFactory;

  static const double tapSlop = 10;
  static const double doubleTapSlop = 30;
  static const Duration doubleTapWindow = Duration(milliseconds: 350);
  static const Duration pointerDragDelay = Duration(milliseconds: 500);
  static const Duration pointerRightDelay = Duration(milliseconds: 1000);
  static const Duration touchDragDelay = Duration(milliseconds: 300);
  static const Duration touchRightDelay = Duration(milliseconds: 700);
  static const Duration multiFingerLanding = Duration(milliseconds: 200);
  static const Duration multiTapMaxDuration = Duration(milliseconds: 350);
  static const double pinchThreshold = 0.06;
  static const double panThreshold = 8;

  final Map<int, Offset> _pointers = {};
  _Phase _phase = _Phase.idle;

  Offset _start = Offset.zero;
  Duration _startTime = Duration.zero;
  bool _afterTap = false;
  int? _dragPointer;
  Timer? _dragTimer;
  Timer? _rightTimer;

  Offset? _lastTapPos;
  Duration? _lastTapTime;

  bool _multiTapEligible = false;
  int _maxPointers = 0;
  Offset _multiStartCentroid = Offset.zero;
  double _multiStartSpread = 0;
  Offset _lastCentroid = Offset.zero;
  double _lastSpread = 0;

  bool get isIdle => _phase == _Phase.idle;

  void pointerDown(int pointer, Offset position, Duration time) {
    _pointers[pointer] = position;
    if (_pointers.length == 1) {
      _beginOneFinger(position, time);
      return;
    }
    switch (_phase) {
      case _Phase.dragging:
      case _Phase.done:
        return;
      case _Phase.oneDown:
      case _Phase.dragReady:
      case _Phase.rightReady:
      case _Phase.cursorMove:
      case _Phase.scroll:
        _multiTapEligible = _phase == _Phase.oneDown &&
            time - _startTime <= multiFingerLanding;
        _cancelTimers();
        sink.showHint(null);
        if (_phase == _Phase.scroll) sink.scrollEnd();
        _phase = _Phase.multi;
        _maxPointers = _pointers.length;
        _resetMultiBaseline(start: true);
        return;
      case _Phase.multi:
        if (time - _startTime > multiFingerLanding) _multiTapEligible = false;
        _maxPointers = max(_maxPointers, _pointers.length);
        _resetMultiBaseline(start: true);
        return;
      case _Phase.pinch:
      case _Phase.twoScroll:
      case _Phase.twoPan:
        _resetMultiBaseline(start: false);
        return;
      case _Phase.idle:
        _beginOneFinger(position, time);
        return;
    }
  }

  void pointerMove(int pointer, Offset position, Duration time) {
    final previous = _pointers[pointer];
    if (previous == null) return;
    _pointers[pointer] = position;
    switch (_phase) {
      case _Phase.oneDown:
        if ((position - _start).distance <= tapSlop) return;
        _cancelTimers();
        if (touchMode) {
          _phase = _Phase.scroll;
          sink.scroll(position - _start);
        } else if (_afterTap) {
          _startDrag(pointer, position);
        } else {
          _phase = _Phase.cursorMove;
          sink.prepareCursorMove();
          sink.moveCursorBy(position - _start, position);
        }
        return;
      case _Phase.dragReady:
      case _Phase.rightReady:
        if ((position - _start).distance <= tapSlop) return;
        _cancelTimers();
        _startDrag(pointer, position);
        return;
      case _Phase.cursorMove:
        sink.moveCursorBy(position - previous, position);
        return;
      case _Phase.scroll:
        sink.scroll(position - previous);
        return;
      case _Phase.dragging:
        if (pointer != _dragPointer) return;
        if (touchMode) {
          sink.dragCursorTo(position - previous, position);
        } else {
          sink.moveCursorBy(position - previous, position);
        }
        return;
      case _Phase.multi:
      case _Phase.pinch:
      case _Phase.twoScroll:
      case _Phase.twoPan:
        _updateMulti();
        return;
      case _Phase.idle:
      case _Phase.done:
        return;
    }
  }

  void pointerUp(int pointer, Offset position, Duration time) {
    if (!_pointers.containsKey(pointer)) return;
    _pointers.remove(pointer);
    switch (_phase) {
      case _Phase.oneDown:
      case _Phase.dragReady:
        _cancelTimers();
        sink.showHint(null);
        _tap(time);
        _phase = _Phase.idle;
        break;
      case _Phase.rightReady:
        _cancelTimers();
        sink.showHint(null);
        if (touchMode) sink.moveCursorTo(_start);
        sink.click(TouchButton.right);
        _phase = _Phase.idle;
        break;
      case _Phase.cursorMove:
        _phase = _Phase.idle;
        break;
      case _Phase.scroll:
        sink.scrollEnd();
        _phase = _Phase.idle;
        break;
      case _Phase.dragging:
        if (pointer == _dragPointer) {
          sink.buttonUp(TouchButton.left);
          sink.showHint(null);
          _dragPointer = null;
          _phase = _pointers.isEmpty ? _Phase.idle : _Phase.done;
        }
        break;
      case _Phase.multi:
        if (_pointers.isEmpty) {
          if (_multiTapEligible && time - _startTime <= multiTapMaxDuration) {
            _multiFingerTap(_multiStartCentroid);
          }
          _phase = _Phase.idle;
        } else {
          _resetMultiBaseline(start: false);
        }
        break;
      case _Phase.pinch:
      case _Phase.twoPan:
      case _Phase.twoScroll:
        if (_pointers.length < 2) {
          if (_phase == _Phase.twoScroll) sink.scrollEnd();
          _phase = _pointers.isEmpty ? _Phase.idle : _Phase.done;
        } else {
          _resetMultiBaseline(start: false);
        }
        break;
      case _Phase.done:
        if (_pointers.isEmpty) _phase = _Phase.idle;
        break;
      case _Phase.idle:
        break;
    }
  }

  void pointerCancel(int pointer) {
    if (!_pointers.containsKey(pointer)) return;
    _pointers.remove(pointer);
    if (_phase == _Phase.dragging && pointer == _dragPointer) {
      sink.buttonUp(TouchButton.left);
      _dragPointer = null;
    }
    if (_phase == _Phase.scroll || _phase == _Phase.twoScroll) {
      sink.scrollEnd();
    }
    _cancelTimers();
    sink.showHint(null);
    _phase = _pointers.isEmpty ? _Phase.idle : _Phase.done;
  }

  /// Ends whatever is in progress, releasing a held button.
  void reset() {
    if (_phase == _Phase.dragging) sink.buttonUp(TouchButton.left);
    if (_phase == _Phase.scroll || _phase == _Phase.twoScroll) {
      sink.scrollEnd();
    }
    _cancelTimers();
    sink.showHint(null);
    _pointers.clear();
    _dragPointer = null;
    _phase = _Phase.idle;
  }

  void _beginOneFinger(Offset position, Duration time) {
    _cancelTimers();
    _phase = _Phase.oneDown;
    _start = position;
    _startTime = time;
    final lastTapTime = _lastTapTime;
    final lastTapPos = _lastTapPos;
    _afterTap = lastTapTime != null &&
        lastTapPos != null &&
        time - lastTapTime <= doubleTapWindow &&
        (position - lastTapPos).distance <= doubleTapSlop;
    _dragTimer = _timerFactory(
        touchMode ? touchDragDelay : pointerDragDelay, _onDragReady);
    _rightTimer = _timerFactory(
        touchMode ? touchRightDelay : pointerRightDelay, _onRightReady);
  }

  void _onDragReady() {
    if (_phase != _Phase.oneDown) return;
    _phase = _Phase.dragReady;
    sink.showHint(TouchHint.drag);
    sink.haptic(TouchHaptic.ready);
  }

  void _onRightReady() {
    if (_phase != _Phase.oneDown && _phase != _Phase.dragReady) return;
    _phase = _Phase.rightReady;
    sink.showHint(TouchHint.rightClick);
    sink.haptic(TouchHaptic.heavy);
  }

  void _startDrag(int pointer, Offset position) {
    if (touchMode) {
      if (!sink.canTouchAt(_start)) {
        sink.showHint(null);
        _phase = _Phase.done;
        return;
      }
      sink.moveCursorTo(_start);
    }
    _phase = _Phase.dragging;
    _dragPointer = pointer;
    sink.showHint(TouchHint.drag);
    sink.buttonDown(TouchButton.left);
    sink.haptic(TouchHaptic.ready);
    if (touchMode) {
      sink.dragCursorTo(position - _start, position);
    } else {
      sink.moveCursorBy(position - _start, position);
    }
  }

  void _tap(Duration time) {
    var position = _start;
    final lastTapTime = _lastTapTime;
    final lastTapPos = _lastTapPos;
    // Two taps on the same spot must land on the same remote pixel, or the
    // remote OS will not see a double click.
    if (touchMode &&
        lastTapTime != null &&
        lastTapPos != null &&
        time - lastTapTime <= doubleTapWindow &&
        (position - lastTapPos).distance <= doubleTapSlop) {
      position = lastTapPos;
    }
    if (touchMode) {
      if (!sink.canTouchAt(position)) return;
      sink.moveCursorTo(position);
    }
    sink.click(TouchButton.left);
    sink.haptic(TouchHaptic.click);
    _lastTapPos = position;
    _lastTapTime = time;
  }

  void _multiFingerTap(Offset centroid) {
    final button = _maxPointers == 2
        ? TouchButton.right
        : _maxPointers == 3
            ? TouchButton.middle
            : null;
    if (button == null) return;
    if (touchMode) {
      if (!sink.canTouchAt(centroid)) return;
      sink.moveCursorTo(centroid);
    }
    sink.click(button);
    sink.haptic(TouchHaptic.heavy);
  }

  void _updateMulti() {
    final centroid = _centroid();
    final spread = _spread(centroid);
    if (_phase == _Phase.multi) {
      final moved = (centroid - _multiStartCentroid).distance;
      final ratio = _multiStartSpread > 0 ? spread / _multiStartSpread : 1.0;
      if (_pointers.length == 2 && (ratio - 1).abs() > pinchThreshold) {
        _phase = _Phase.pinch;
      } else if (moved > panThreshold) {
        if (_pointers.length == 2) {
          _phase = touchMode ? _Phase.twoPan : _Phase.twoScroll;
        } else {
          _phase = _Phase.done;
          return;
        }
      } else {
        return;
      }
      _multiTapEligible = false;
    }
    switch (_phase) {
      case _Phase.pinch:
        if (_lastSpread > 0 && spread > 0) {
          sink.zoomCanvas(spread / _lastSpread, centroid);
        }
        sink.panCanvas(centroid - _lastCentroid);
        break;
      case _Phase.twoScroll:
        sink.scroll(centroid - _lastCentroid);
        break;
      case _Phase.twoPan:
        sink.panCanvas(centroid - _lastCentroid);
        break;
      default:
        break;
    }
    _lastCentroid = centroid;
    _lastSpread = spread;
  }

  void _resetMultiBaseline({required bool start}) {
    final centroid = _centroid();
    final spread = _spread(centroid);
    if (start) {
      _multiStartCentroid = centroid;
      _multiStartSpread = spread;
    }
    _lastCentroid = centroid;
    _lastSpread = spread;
  }

  Offset _centroid() {
    if (_pointers.isEmpty) return Offset.zero;
    var sum = Offset.zero;
    for (final p in _pointers.values) {
      sum += p;
    }
    return sum / _pointers.length.toDouble();
  }

  double _spread(Offset centroid) {
    if (_pointers.length < 2) return 0;
    var sum = 0.0;
    for (final p in _pointers.values) {
      sum += (p - centroid).distance;
    }
    return sum / _pointers.length;
  }

  void _cancelTimers() {
    _dragTimer?.cancel();
    _rightTimer?.cancel();
    _dragTimer = null;
    _rightTimer = null;
  }
}

/// Receives touches on the remote canvas and drives the session with
/// [TouchGestureClassifier]. Mouse and trackpad pointers are left to the
/// physical-input handlers above it.
class TouchGestureLayer extends StatefulWidget {
  const TouchGestureLayer({Key? key, required this.ffi, required this.child})
      : super(key: key);

  final FFI ffi;
  final Widget child;

  @override
  State<TouchGestureLayer> createState() => _TouchGestureLayerState();
}

class _TouchGestureLayerState extends State<TouchGestureLayer>
    implements TouchGestureSink {
  late final TouchGestureClassifier _classifier =
      TouchGestureClassifier(this);
  TouchHint? _hint;
  Future<void> _queue = Future.value();

  FFI get ffi => widget.ffi;
  InputModel get inputModel => ffi.inputModel;

  static bool _isTouch(PointerEvent e) =>
      e.kind == PointerDeviceKind.touch ||
      e.kind == PointerDeviceKind.stylus ||
      e.kind == PointerDeviceKind.invertedStylus;

  void _enqueue(Future<void> Function() action) {
    _queue = _queue.then((_) => action()).catchError((e) {
      debugPrint('touch gesture action failed: $e');
    });
  }

  @override
  void dispose() {
    _classifier.reset();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.opaque,
      onPointerDown: (e) {
        if (!_isTouch(e)) return;
        if (_classifier.isIdle) {
          _classifier.touchMode = ffi.ffiModel.touchMode;
        }
        _classifier.pointerDown(e.pointer, e.localPosition, e.timeStamp);
      },
      onPointerMove: (e) {
        if (!_isTouch(e)) return;
        _classifier.pointerMove(e.pointer, e.localPosition, e.timeStamp);
      },
      onPointerUp: (e) {
        if (!_isTouch(e)) return;
        _classifier.pointerUp(e.pointer, e.localPosition, e.timeStamp);
      },
      onPointerCancel: (e) {
        if (!_isTouch(e)) return;
        _classifier.pointerCancel(e.pointer);
      },
      child: Stack(
        fit: StackFit.expand,
        children: [
          widget.child,
          if (_hint != null)
            Positioned(
              top: 8,
              left: 8,
              child: IgnorePointer(child: _buildHint(_hint!)),
            ),
        ],
      ),
    );
  }

  Widget _buildHint(TouchHint hint) {
    final text = hint == TouchHint.drag
        ? translate('touch-hint-drag')
        : translate('touch-hint-right-click');
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.6),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(text,
          style: const TextStyle(color: Colors.white, fontSize: 13)),
    );
  }

  static MouseButtons _button(TouchButton b) {
    switch (b) {
      case TouchButton.left:
        return MouseButtons.left;
      case TouchButton.right:
        return MouseButtons.right;
      case TouchButton.middle:
        return MouseButtons.wheel;
    }
  }

  bool get _canvasLocked => ffi.canvasModel.locked;

  @override
  void prepareCursorMove() {
    final size = context.size;
    if (size == null) return;
    _enqueue(() async {
      final offset = ffi.cursorModel.offset;
      final visible = ffi.cursorModel.getVisibleRect().inflate(1);
      if (!visible.contains(offset)) {
        await ffi.cursorModel.move(size.width / 2, size.height / 2);
      }
    });
  }

  @override
  void moveCursorBy(Offset delta, Offset position) {
    _enqueue(() => ffi.cursorModel.updatePan(delta, position, false));
  }

  @override
  bool canTouchAt(Offset position) =>
      !ffi.cursorModel.shouldBlock(position.dx, position.dy) &&
      ffi.cursorModel.isInRemoteRect(position);

  @override
  void moveCursorTo(Offset position) {
    _enqueue(() async {
      await ffi.cursorModel.move(position.dx, position.dy);
    });
  }

  @override
  void dragCursorTo(Offset delta, Offset position) {
    _enqueue(() => ffi.cursorModel.updatePan(delta, position, true));
  }

  @override
  void click(TouchButton button) {
    _enqueue(() => inputModel.tap(_button(button)));
  }

  @override
  void buttonDown(TouchButton button) {
    _enqueue(() => inputModel.sendMouse('down', _button(button)));
  }

  @override
  void buttonUp(TouchButton button) {
    _enqueue(() => inputModel.sendMouse('up', _button(button)));
  }

  @override
  void scroll(Offset fingerDelta) {
    // Scale by the canvas zoom so the remote content keeps up with the finger.
    final scale = ffi.canvasModel.scale.clamp(0.2, 4.0);
    final delta = fingerDelta / scale;
    _enqueue(() async => inputModel.sendTouchScroll(delta));
  }

  @override
  void scrollEnd() {
    _enqueue(() async => inputModel.endTouchScroll());
  }

  @override
  void zoomCanvas(double ratio, Offset focal) {
    if (_canvasLocked) return;
    ffi.canvasModel.updateScale(ratio, focal);
  }

  @override
  void panCanvas(Offset delta) {
    if (_canvasLocked) return;
    ffi.canvasModel.panX(delta.dx);
    ffi.canvasModel.panY(delta.dy);
  }

  @override
  void showHint(TouchHint? hint) {
    if (!mounted || _hint == hint) return;
    setState(() => _hint = hint);
  }

  @override
  void haptic(TouchHaptic kind) {
    switch (kind) {
      case TouchHaptic.click:
        HapticFeedback.selectionClick();
        break;
      case TouchHaptic.ready:
        HapticFeedback.lightImpact();
        break;
      case TouchHaptic.heavy:
        HapticFeedback.mediumImpact();
        break;
    }
  }
}
