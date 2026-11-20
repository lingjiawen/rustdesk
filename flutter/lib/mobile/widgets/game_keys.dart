import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../common.dart';
import '../../models/input_model.dart';
import '../../models/model.dart';
import '../../models/platform_model.dart';
import 'session_panel.dart';
import 'touch_gesture_engine.dart';

const kOptionMobileGameKeys = 'mobile-game-keys';
const kGameKeyMouseLeft = 'MOUSE_LEFT';
const kGameKeyMouseRight = 'MOUSE_RIGHT';
const kGameKeyStickWasd = 'STICK_WASD';
const kGameKeyStickArrows = 'STICK_ARROWS';
const kGameKeyWheelUp = 'WHEEL_UP';
const kGameKeyWheelDown = 'WHEEL_DOWN';
const double kGameKeySizeSmall = 40;
const double kGameKeySizeMedium = 48;
const double kGameKeySizeLarge = 60;

/// How many times as wide as a key of the same size a joystick is.
const double kGameStickScale = 2.5;

/// Remote mouse movement per point of finger travel when looking around,
/// before the pointer speed setting.
const double kGameLookScale = 2;

/// What a game key can hold down, display name to key name.
final Map<String, String> kGameKeyNames = {
  ...kShortcutKeyNames,
  'Shift': 'VK_SHIFT',
  'Ctrl': 'VK_CONTROL',
  'Alt': 'VK_MENU',
  'LMB': kGameKeyMouseLeft,
  'RMB': kGameKeyMouseRight,
};

String gameKeyName(String key) => kGameKeyNames.entries
    .firstWhere((e) => e.value == key,
        orElse: () => MapEntry(key.replaceFirst('VK_', ''), key))
    .key;

/// The keys that are more than one key held down, and what tells them apart
/// in the list of keys.
const kGameSpecialKeys = {
  kGameKeyStickWasd: 'WASD',
  kGameKeyStickArrows: '↑←↓→',
  kGameKeyWheelUp: 'Wheel up',
  kGameKeyWheelDown: 'Wheel down',
};

String gameKeyTitle(String key, String Function(String) tr) => switch (key) {
      kGameKeyStickWasd ||
      kGameKeyStickArrows =>
        '${tr('Joystick')} ${kGameSpecialKeys[key]}',
      kGameKeyWheelUp || kGameKeyWheelDown => tr(kGameSpecialKeys[key]!),
      _ => gameKeyName(key),
    };

/// The keys a joystick holds down when pushed by [v] from its centre: none
/// near the centre, one along an axis, two on a diagonal.
Set<String> gameStickKeys(String stick, Offset v, double radius) {
  if (v.distance < radius * 0.25) return {};
  final keys = stick == kGameKeyStickArrows
      ? const ['VK_RIGHT', 'VK_UP', 'VK_LEFT', 'VK_DOWN']
      : const ['VK_D', 'VK_W', 'VK_A', 'VK_S'];
  // Eight sectors of 45 degrees, counted anticlockwise from "right".
  final sector = ((atan2(-v.dy, v.dx) / (pi / 4)).round() + 8) % 8;
  return {keys[(sector + 1) ~/ 2 % 4], if (sector.isOdd) keys[sector ~/ 2]};
}

/// An on-screen key that stays pressed for as long as a finger rests on it.
class GameKey {
  const GameKey(this.key, this.dx, this.dy,
      {this.right = false,
      this.top = false,
      this.size = kGameKeySizeMedium,
      this.label = '',
      this.ctrl = false,
      this.shift = false,
      this.alt = false,
      this.lock = false});

  final String key;

  /// Modifiers pressed together with the key.
  final bool ctrl, shift, alt;

  /// A tap presses the key and the next tap lets go of it.
  final bool lock;

  /// The user's own text; empty shows the key's name.
  final String label;

  /// How far the centre is from the left (or [right]) edge and from the
  /// bottom (or [top]) edge. Measuring from a corner keeps the key under the
  /// same thumb when the phone is turned.
  final double dx, dy;
  final bool right, top;
  final double size;

  bool get isStick => key == kGameKeyStickWasd || key == kGameKeyStickArrows;
  bool get isWheel => key == kGameKeyWheelUp || key == kGameKeyWheelDown;
  bool get isMouse => key == kGameKeyMouseLeft || key == kGameKeyMouseRight;

  /// Its width and height on screen.
  double get extent => isStick ? size * kGameStickScale : size;

  String get text => label.isNotEmpty
      ? label
      : [if (ctrl) 'Ctrl', if (shift) 'Shift', if (alt) 'Alt', gameKeyName(key)]
          .join('+');

  Offset center(Size area) => _inside(
      Offset(right ? area.width - dx : dx, top ? dy : area.height - dy), area);

  Offset _inside(Offset c, Size area) {
    final r = extent / 2;
    return Offset(c.dx.clamp(r, max(r, area.width - r)),
        c.dy.clamp(r, max(r, area.height - r)));
  }

  GameKey movedTo(Offset center, Size area) {
    final c = _inside(center, area);
    final right = c.dx > area.width / 2;
    final top = c.dy < area.height / 2;
    return GameKey(
        key, right ? area.width - c.dx : c.dx, top ? c.dy : area.height - c.dy,
        right: right,
        top: top,
        size: size,
        label: label,
        ctrl: ctrl,
        shift: shift,
        alt: alt,
        lock: lock);
  }

  GameKey changed(
          {required String key,
          required String label,
          required double size,
          bool ctrl = false,
          bool shift = false,
          bool alt = false,
          bool lock = false}) =>
      GameKey(key, dx, dy,
          right: right,
          top: top,
          size: size,
          label: label,
          ctrl: ctrl,
          shift: shift,
          alt: alt,
          lock: lock);

  Map<String, dynamic> toJson() => {
        'key': key,
        'dx': dx,
        'dy': dy,
        if (right) 'right': true,
        if (top) 'top': true,
        'size': size,
        if (label.isNotEmpty) 'label': label,
        if (ctrl) 'ctrl': true,
        if (shift) 'shift': true,
        if (alt) 'alt': true,
        if (lock) 'lock': true,
      };

  static GameKey? fromJson(dynamic json) {
    if (json is! Map) return null;
    final key = json['key'];
    final dx = json['dx'];
    final dy = json['dy'];
    final size = json['size'];
    final label = json['label'];
    if (key is! String ||
        !(kGameKeyNames.containsValue(key) ||
            kGameSpecialKeys.containsKey(key)) ||
        dx is! num ||
        dy is! num ||
        !dx.isFinite ||
        !dy.isFinite) {
      return null;
    }
    return GameKey(key, dx.toDouble(), dy.toDouble(),
        right: json['right'] == true,
        top: json['top'] == true,
        size: size is num && size.isFinite
            ? size.toDouble().clamp(kGameKeySizeSmall, kGameKeySizeLarge)
            : kGameKeySizeMedium,
        label: label is String ? label : '',
        ctrl: json['ctrl'] == true,
        shift: json['shift'] == true,
        alt: json['alt'] == true,
        lock: json['lock'] == true);
  }
}

/// Movement under the left thumb, actions and the mouse buttons under the
/// right one.
List<GameKey> defaultGameKeys() => const [
      GameKey('VK_ESCAPE', 36, 36, top: true),
      GameKey('VK_Q', 36, 124),
      GameKey('VK_W', 92, 124),
      GameKey('VK_E', 148, 124),
      GameKey('VK_A', 36, 68),
      GameKey('VK_S', 92, 68),
      GameKey('VK_D', 148, 68),
      GameKey('VK_R', 148, 124, right: true),
      GameKey(kGameKeyMouseRight, 92, 124, right: true),
      GameKey(kGameKeyMouseLeft, 36, 124, right: true),
      GameKey('VK_CONTROL', 148, 68, right: true),
      GameKey('VK_SHIFT', 92, 68, right: true),
      GameKey('VK_SPACE', 36, 68, right: true),
    ];

/// A named set of game keys, e.g. one per game.
class GameKeyLayout {
  const GameKeyLayout(this.name, this.keys, {this.look = false});

  /// Empty for a layout the user has not named.
  final String name;
  final List<GameKey> keys;

  /// A finger dragged between the keys turns the view, as moving the mouse
  /// does in a game that has taken hold of it, instead of moving the pointer.
  final bool look;

  GameKeyLayout copy({String? name, List<GameKey>? keys, bool? look}) =>
      GameKeyLayout(name ?? this.name, keys ?? this.keys,
          look: look ?? this.look);
}

String gameKeyLayoutName(GameKeyLayout layout, String Function(String) tr) =>
    layout.name.isEmpty ? tr('Default') : layout.name;

/// The saved layouts and which of them is in use. There is always one.
class GameKeyLayouts {
  const GameKeyLayouts(this.layouts, [this.current = 0]);

  final List<GameKeyLayout> layouts;
  final int current;

  GameKeyLayout get layout => layouts[current];

  GameKeyLayouts select(int i) => GameKeyLayouts(layouts, i);

  GameKeyLayouts withKeys(List<GameKey> keys) =>
      _put(current, layout.copy(keys: keys));

  GameKeyLayouts withLook(bool look) => _put(current, layout.copy(look: look));

  GameKeyLayouts renamed(int i, String name) =>
      _put(i, layouts[i].copy(name: name));

  /// Adds a copy of the layout in use and switches to it.
  GameKeyLayouts added(String name) => GameKeyLayouts([
        ...layouts,
        layout.copy(name: name, keys: [...layout.keys])
      ], layouts.length);

  GameKeyLayouts removed(int i) {
    if (layouts.length < 2) return this;
    final rest = [...layouts]..removeAt(i);
    return GameKeyLayouts(
        rest, min(current > i ? current - 1 : current, rest.length - 1));
  }

  GameKeyLayouts _put(int i, GameKeyLayout layout) =>
      GameKeyLayouts([...layouts]..[i] = layout, current);

  Map<String, dynamic> toJson() => {
        'current': current,
        'layouts': [
          for (final l in layouts)
            {
              'name': l.name,
              'keys': l.keys.map((k) => k.toJson()).toList(),
              if (l.look) 'look': true,
            }
        ],
      };
}

List<GameKey> _keysFromJson(dynamic json) {
  if (json is List) {
    final keys = json.map(GameKey.fromJson).whereType<GameKey>().toList();
    if (keys.isNotEmpty) return keys;
  }
  return defaultGameKeys();
}

/// Reads the saved layouts. A bare list of keys, which is what was saved
/// while there was only one layout, becomes the unnamed layout; anything
/// unreadable or empty gives the default keys.
GameKeyLayouts parseGameKeyLayouts(String saved) {
  dynamic json;
  try {
    json = jsonDecode(saved);
  } catch (_) {}
  if (json is Map && json['layouts'] is List) {
    final layouts = [
      for (final l in json['layouts'])
        if (l is Map)
          GameKeyLayout(
              l['name'] is String ? l['name'] : '', _keysFromJson(l['keys']),
              look: l['look'] == true)
    ];
    final current = json['current'];
    if (layouts.isNotEmpty) {
      return GameKeyLayouts(
          layouts,
          current is int && current >= 0 && current < layouts.length
              ? current
              : 0);
    }
  }
  return GameKeyLayouts([GameKeyLayout('', _keysFromJson(json))]);
}

GameKeyLayouts loadGameKeyLayouts() =>
    parseGameKeyLayouts(bind.mainGetLocalOption(key: kOptionMobileGameKeys));

Future<void> saveGameKeyLayouts(GameKeyLayouts layouts) =>
    bind.mainSetLocalOption(
        key: kOptionMobileGameKeys, value: jsonEncode(layouts.toJson()));

abstract class GameKeySink {
  /// Presses or releases a key or a mouse button, a key together with the
  /// modifiers named.
  void press(String key, bool down,
      {bool ctrl = false, bool shift = false, bool alt = false});

  /// Moves the mouse by a finger's travel without giving it a position.
  void look(double dx, double dy);

  /// Turns the wheel one notch, up when [notches] is positive.
  void scroll(int notches);
}

class InputModelGameKeySink implements GameKeySink {
  InputModelGameKeySink(this.ffi);
  final FFI ffi;
  Future<void> _queue = Future.value();
  double _lookX = 0, _lookY = 0;
  Timer? _lookTimer;

  @override
  void press(String key, bool down,
      {bool ctrl = false, bool shift = false, bool alt = false}) {
    // Bridge calls run on a thread pool, so a quick tap sent as two
    // independent calls could reach the remote as up before down.
    _queue = _queue
        .then((_) => _send(key, down, ctrl, shift, alt))
        .catchError((_) {});
  }

  Future<void> _send(
      String key, bool down, bool ctrl, bool shift, bool alt) async {
    final input = ffi.inputModel;
    if (key == kGameKeyMouseLeft || key == kGameKeyMouseRight) {
      await input.sendMouse(down ? 'down' : 'up',
          key == kGameKeyMouseLeft ? MouseButtons.left : MouseButtons.right);
      return;
    }
    if (!input.keyboardPerm) return;
    if (!down) _holdModifier(key, false);
    // The remote presses the modifiers named on a key going down and lets
    // go of them again right after it.
    await bind.sessionInputKey(
        sessionId: ffi.sessionId,
        name: key,
        down: down,
        press: false,
        alt: input.alt || (down && alt),
        ctrl: input.ctrl || (down && ctrl),
        shift: input.shift || (down && shift),
        command: input.command);
    if (down) _holdModifier(key, true);
  }

  @override
  void look(double dx, double dy) {
    _lookX += dx;
    _lookY += dy;
    // Finger samples come faster than is worth sending one by one.
    _lookTimer ??= Timer(const Duration(milliseconds: 8), _sendLook);
  }

  void _sendLook() {
    _lookTimer = null;
    final input = ffi.inputModel;
    final scale = kGameLookScale * loadPointerSpeed();
    final x = (_lookX * scale).truncate();
    final y = (_lookY * scale).truncate();
    _lookX -= x / scale;
    _lookY -= y / scale;
    if ((x == 0 && y == 0) || !input.keyboardPerm) return;
    bind.sessionSendMouse(
        sessionId: ffi.sessionId,
        msg: jsonEncode(
            input.modify({'type': 'move_relative', 'x': '$x', 'y': '$y'})));
  }

  @override
  void scroll(int notches) => ffi.inputModel.scroll(notches);

  /// The remote lets go of a modifier that the next key or mouse event does
  /// not name, so a held one is named on every event until it is released.
  void _holdModifier(String key, bool on) {
    final input = ffi.inputModel;
    switch (key) {
      case 'VK_SHIFT':
        input.shift = on;
      case 'VK_CONTROL':
        input.ctrl = on;
      case 'VK_MENU':
        input.alt = on;
      default:
        return;
    }
    input.touchOneShotModifiers.remove(const {
      'VK_SHIFT': 'shift',
      'VK_CONTROL': 'ctrl',
      'VK_MENU': 'alt'
    }[key]);
    input.touchModifiersChanged.value++;
  }
}

/// Game keys laid over the remote screen. Touches between the keys fall
/// through to the screen underneath, so one thumb can hold a key while the
/// other moves the pointer.
class GameKeysOverlay extends StatefulWidget {
  const GameKeysOverlay(
      {Key? key,
      required this.sink,
      required this.layouts,
      required this.onChanged,
      required this.onClose,
      this.lookSupported = false,
      this.bottomReserved = 0,
      this.tr = translate})
      : super(key: key);

  final GameKeySink sink;

  /// Whether the remote can move its mouse without a position.
  final bool lookSupported;

  /// The layouts to start with.
  final GameKeyLayouts layouts;
  final ValueChanged<GameKeyLayouts> onChanged;
  final VoidCallback onClose;

  /// Height at the bottom the keys must stay above, e.g. the key bar.
  final double bottomReserved;
  final String Function(String) tr;

  @override
  State<GameKeysOverlay> createState() => _GameKeysOverlayState();
}

class _GameKeysOverlayState extends State<GameKeysOverlay> {
  late var _layouts = widget.layouts;
  late var _keys = [..._layouts.layout.keys];
  bool _editing = false;
  // The state of each key, by its place in [_keys]: the fingers resting on
  // it, whether a tap left it pressed, where its joystick is pushed, and the
  // timer that keeps its wheel turning.
  final _fingers = <int, Set<int>>{};
  final _locked = <int>{};
  final _sticks = <int, ({int pointer, Offset knob, Set<String> keys})>{};
  final _wheels = <int, Timer>{};
  int? _dragging;
  Offset _dragCenter = Offset.zero;

  bool get _looking =>
      widget.lookSupported && _layouts.layout.look && !_editing;

  @override
  void dispose() {
    _releaseAll();
    super.dispose();
  }

  void _releaseAll() {
    for (final i in {..._fingers.keys, ..._locked}) {
      _press(i, false);
    }
    for (final stick in _sticks.values) {
      for (final key in stick.keys) {
        widget.sink.press(key, false);
      }
    }
    _fingers.clear();
    _locked.clear();
    _sticks.clear();
  }

  void _press(int i, bool down) {
    final k = _keys[i];
    if (!k.isWheel) {
      widget.sink.press(k.key, down, ctrl: k.ctrl, shift: k.shift, alt: k.alt);
      return;
    }
    _wheels.remove(i)?.cancel();
    if (!down) return;
    final notch = k.key == kGameKeyWheelUp ? 1 : -1;
    widget.sink.scroll(notch);
    _wheels[i] = Timer.periodic(
        const Duration(milliseconds: 100), (_) => widget.sink.scroll(notch));
  }

  void _finger(int i, int pointer, bool down) {
    if (_keys[i].lock) {
      if (!down) return;
      HapticFeedback.lightImpact();
      final on = !_locked.remove(i);
      if (on) _locked.add(i);
      _press(i, on);
      setState(() {});
      return;
    }
    final fingers = _fingers.putIfAbsent(i, () => {});
    final wasHeld = fingers.isNotEmpty;
    down ? fingers.add(pointer) : fingers.remove(pointer);
    if (fingers.isEmpty) _fingers.remove(i);
    if (wasHeld == fingers.isNotEmpty) return;
    if (down) HapticFeedback.lightImpact();
    _press(i, down);
    setState(() {});
  }

  /// Follows the first finger on the joystick at [i]; [held] is false when
  /// that finger lifts.
  void _stick(int i, PointerEvent e, bool held) {
    final now = _sticks[i];
    if (now == null ? e is! PointerDownEvent : now.pointer != e.pointer) {
      return;
    }
    final k = _keys[i];
    final r = k.extent / 2;
    final v = e.localPosition - Offset(r, r);
    final keys = held ? gameStickKeys(k.key, v, r) : const <String>{};
    final had = now?.keys ?? const <String>{};
    for (final key in had.difference(keys)) {
      widget.sink.press(key, false);
    }
    for (final key in keys.difference(had)) {
      widget.sink.press(key, true);
    }
    if (had.isEmpty && keys.isNotEmpty) HapticFeedback.lightImpact();
    setState(() {
      if (held) {
        final reach = r * 0.55;
        _sticks[i] = (
          pointer: e.pointer,
          knob: v.distance > reach ? v / v.distance * reach : v,
          keys: keys
        );
      } else {
        _sticks.remove(i);
      }
    });
  }

  void _changed() {
    _layouts = _layouts.withKeys([..._keys]);
    widget.onChanged(_layouts);
  }

  void _toggleLook() {
    setState(() => _layouts = _layouts.withLook(!_layouts.layout.look));
    widget.onChanged(_layouts);
    if (_layouts.layout.look && !_editing) {
      showToast(widget.tr('game-keys-look-tip'));
    }
  }

  Future<void> _pickLayout() async {
    final next = await showDialog<GameKeyLayouts>(
      context: context,
      builder: (_) => _GameKeyLayoutsDialog(initial: _layouts, tr: widget.tr),
    );
    if (next == null || !mounted) return;
    setState(() {
      _releaseAll();
      _layouts = next;
      _keys = [...next.layout.keys];
    });
    widget.onChanged(next);
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, constraints) {
      final area = Size(constraints.maxWidth,
          max(0.0, constraints.maxHeight - widget.bottomReserved));
      return Stack(children: [
        if (_looking)
          Positioned(
            left: 0,
            top: 0,
            right: 0,
            height: area.height,
            child: Listener(
              behavior: HitTestBehavior.opaque,
              onPointerMove: (e) => widget.sink.look(e.delta.dx, e.delta.dy),
            ),
          ),
        for (var i = 0; i < _keys.length; i++) _buildKey(i, area),
        Positioned(top: 6, left: 0, right: 0, child: _buildToolbar(area)),
      ]);
    });
  }

  Widget _buildKey(int i, Size area) {
    final k = _keys[i];
    final c = _dragging == i ? _dragCenter : k.center(area);
    final stick = _sticks[i];
    final border = Border.all(
        color: Colors.white.withAlpha(_editing ? 255 : 160), width: 1.5);
    Widget disc(bool lit, Widget child) => Container(
          alignment: Alignment.center,
          padding: const EdgeInsets.all(4),
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: lit
                ? MyTheme.accent.withAlpha(210)
                : Colors.black.withAlpha(_editing ? 140 : 80),
            border: border,
          ),
          child: FittedBox(fit: BoxFit.scaleDown, child: child),
        );
    Widget text(String text, double fontSize) => Text(text,
        maxLines: 1,
        style: TextStyle(
            color: Colors.white,
            fontSize: fontSize,
            fontWeight: FontWeight.w600));
    final cap = k.isStick
        ? Container(
            alignment: Alignment.center,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: Colors.black.withAlpha(_editing ? 100 : 45),
              border: border,
            ),
            child: Transform.translate(
              offset: stick?.knob ?? Offset.zero,
              child: SizedBox.square(
                dimension: k.extent * 0.42,
                child: disc(
                    stick != null && stick.keys.isNotEmpty,
                    text(k.label.isEmpty ? kGameSpecialKeys[k.key]! : k.label,
                        12)),
              ),
            ),
          )
        : disc(
            _fingers.containsKey(i) || _locked.contains(i),
            k.isWheel && k.label.isEmpty
                ? Icon(
                    k.key == kGameKeyWheelUp
                        ? Icons.keyboard_double_arrow_up
                        : Icons.keyboard_double_arrow_down,
                    color: Colors.white,
                    size: 24)
                : text(k.text, 15));
    return Positioned(
      left: c.dx - k.extent / 2,
      top: c.dy - k.extent / 2,
      width: k.extent,
      height: k.extent,
      child: _editing
          ? GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => _edit(i, area),
              onPanStart: (_) => setState(() {
                    _dragging = i;
                    _dragCenter = c;
                  }),
              onPanUpdate: (d) => setState(() => _dragCenter += d.delta),
              onPanEnd: (_) {
                setState(() {
                  _keys[i] = k.movedTo(_dragCenter, area);
                  _dragging = null;
                });
                _changed();
              },
              onPanCancel: () => setState(() => _dragging = null),
              child: cap)
          : k.isStick
              ? Listener(
                  behavior: HitTestBehavior.opaque,
                  onPointerDown: (e) => _stick(i, e, true),
                  onPointerMove: (e) => _stick(i, e, true),
                  onPointerUp: (e) => _stick(i, e, false),
                  onPointerCancel: (e) => _stick(i, e, false),
                  child: cap)
              : Listener(
                  behavior: HitTestBehavior.opaque,
                  onPointerDown: (e) => _finger(i, e.pointer, true),
                  // Aiming goes on while a mouse button is held to fire.
                  onPointerMove: _looking && k.isMouse
                      ? (e) => widget.sink.look(e.delta.dx, e.delta.dy)
                      : null,
                  onPointerUp: (e) => _finger(i, e.pointer, false),
                  onPointerCancel: (e) => _finger(i, e.pointer, false),
                  child: cap),
    );
  }

  Widget _buildToolbar(Size area) {
    Widget button(IconData icon, VoidCallback onTap) => GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
            child: Icon(icon, size: 20, color: Colors.white),
          ),
        );
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Opacity(
          opacity: _editing ? 0.95 : 0.5,
          child: Container(
            decoration: BoxDecoration(
                color: Colors.black87, borderRadius: BorderRadius.circular(18)),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: _editing
                  ? [
                      button(Icons.add, () => _edit(null, area)),
                      if (widget.lookSupported)
                        GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: _toggleLook,
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 9, vertical: 7),
                            child:
                                Row(mainAxisSize: MainAxisSize.min, children: [
                              Icon(
                                  _layouts.layout.look
                                      ? Icons.check_box
                                      : Icons.check_box_outline_blank,
                                  size: 18,
                                  color: Colors.white),
                              const SizedBox(width: 4),
                              Text(widget.tr('Mouse look'),
                                  style: const TextStyle(
                                      color: Colors.white, fontSize: 13)),
                            ]),
                          ),
                        ),
                      button(Icons.restart_alt, () {
                        setState(() => _keys = defaultGameKeys());
                        _changed();
                      }),
                      button(
                          Icons.check, () => setState(() => _editing = false)),
                    ]
                  : [
                      GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: _pickLayout,
                        child: Padding(
                          padding: const EdgeInsets.only(
                              left: 14, top: 7, bottom: 7),
                          child: Row(mainAxisSize: MainAxisSize.min, children: [
                            ConstrainedBox(
                              constraints: const BoxConstraints(maxWidth: 110),
                              child: Text(
                                  gameKeyLayoutName(_layouts.layout, widget.tr),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                      color: Colors.white, fontSize: 13)),
                            ),
                            const Icon(Icons.arrow_drop_down,
                                size: 18, color: Colors.white),
                          ]),
                        ),
                      ),
                      if (widget.lookSupported)
                        button(
                            _layouts.layout.look
                                ? Icons.control_camera
                                : Icons.mouse_outlined,
                            _toggleLook),
                      button(
                          Icons.tune,
                          () => setState(() {
                                _releaseAll();
                                _editing = true;
                              })),
                      button(Icons.close, widget.onClose),
                    ],
            ),
          ),
        ),
        if (_editing)
          IgnorePointer(
            child: Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                  [
                    widget.tr('game-keys-edit-tip'),
                    if (widget.lookSupported && _layouts.layout.look)
                      widget.tr('game-keys-look-tip'),
                  ].join('\n'),
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 12,
                      shadows: [Shadow(blurRadius: 3)])),
            ),
          ),
      ],
    );
  }

  /// Changes or deletes the key at [i]; null adds one in the middle of the
  /// screen.
  Future<void> _edit(int? i, Size area) async {
    final result = await showDialog<_GameKeyEdit>(
      context: context,
      builder: (_) =>
          _GameKeyDialog(initial: i == null ? null : _keys[i], tr: widget.tr),
    );
    if (result == null || !mounted) return;
    setState(() {
      if (result.delete) {
        if (i != null) _keys.removeAt(i);
      } else if (i == null) {
        _keys.add(GameKey(result.key, 0, 0,
                size: result.size,
                label: result.label,
                ctrl: result.ctrl,
                shift: result.shift,
                alt: result.alt,
                lock: result.lock)
            .movedTo(Offset(area.width / 2, area.height / 2), area));
      } else {
        _keys[i] = _keys[i].changed(
            key: result.key,
            label: result.label,
            size: result.size,
            ctrl: result.ctrl,
            shift: result.shift,
            alt: result.alt,
            lock: result.lock);
      }
    });
    _changed();
  }
}

typedef _GameKeyEdit = ({
  String key,
  String label,
  double size,
  bool ctrl,
  bool shift,
  bool alt,
  bool lock,
  bool delete
});

class _GameKeyDialog extends StatefulWidget {
  const _GameKeyDialog({required this.initial, required this.tr});
  final GameKey? initial;
  final String Function(String) tr;

  @override
  State<_GameKeyDialog> createState() => _GameKeyDialogState();
}

class _GameKeyDialogState extends State<_GameKeyDialog> {
  late String _key = widget.initial?.key ?? 'VK_F';
  late double _size = widget.initial?.size ?? kGameKeySizeMedium;
  late final _label = TextEditingController(text: widget.initial?.label ?? '');
  late bool _ctrl = widget.initial?.ctrl ?? false;
  late bool _shift = widget.initial?.shift ?? false;
  late bool _alt = widget.initial?.alt ?? false;
  late bool _lock = widget.initial?.lock ?? false;

  /// A joystick or a wheel key can do neither of the two below.
  bool get _canLock => !kGameSpecialKeys.containsKey(_key);

  bool get _canCombine =>
      _canLock &&
      !const {
        kGameKeyMouseLeft,
        kGameKeyMouseRight,
        'VK_SHIFT',
        'VK_CONTROL',
        'VK_MENU'
      }.contains(_key);

  @override
  void dispose() {
    _label.dispose();
    super.dispose();
  }

  void _close({bool delete = false}) => Navigator.pop<_GameKeyEdit>(context, (
        key: _key,
        label: _label.text.trim(),
        size: _size,
        ctrl: _canCombine && _ctrl,
        shift: _canCombine && _shift,
        alt: _canCombine && _alt,
        lock: _canLock && _lock,
        delete: delete
      ));

  @override
  Widget build(BuildContext context) {
    final tr = widget.tr;
    return AlertDialog(
      title: Text(tr(widget.initial == null ? 'Add key' : 'Edit')),
      // The name field's keyboard leaves little room on a phone held sideways.
      scrollable: true,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          DropdownButton<String>(
            value: _key,
            isExpanded: true,
            items: [
              for (final key in kGameSpecialKeys.keys)
                DropdownMenuItem(
                    value: key, child: Text(gameKeyTitle(key, tr))),
              for (final e in kGameKeyNames.entries)
                DropdownMenuItem(value: e.value, child: Text(e.key)),
            ],
            onChanged: (v) => setState(() => _key = v ?? _key),
          ),
          TextField(
            controller: _label,
            decoration: InputDecoration(
                labelText: tr('Name'), hintText: gameKeyTitle(_key, tr)),
          ),
          const SizedBox(height: 12),
          Wrap(spacing: 8, children: [
            for (final (size, label) in const [
              (kGameKeySizeSmall, 'Small'),
              (kGameKeySizeMedium, 'Medium'),
              (kGameKeySizeLarge, 'Large'),
            ])
              ChoiceChip(
                label: Text(tr(label)),
                selected: _size == size,
                onSelected: (_) => setState(() => _size = size),
              ),
          ]),
          const SizedBox(height: 4),
          if (_canCombine)
            Wrap(spacing: 8, children: [
              FilterChip(
                label: const Text('Ctrl'),
                selected: _ctrl,
                onSelected: (v) => setState(() => _ctrl = v),
              ),
              FilterChip(
                label: const Text('Shift'),
                selected: _shift,
                onSelected: (v) => setState(() => _shift = v),
              ),
              FilterChip(
                label: const Text('Alt'),
                selected: _alt,
                onSelected: (v) => setState(() => _alt = v),
              ),
            ]),
          if (_canLock)
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              controlAffinity: ListTileControlAffinity.leading,
              value: _lock,
              onChanged: (v) => setState(() => _lock = v ?? false),
              title: Text(tr('Stay pressed until tapped again')),
            ),
        ],
      ),
      actions: [
        if (widget.initial != null)
          TextButton(
              onPressed: () => _close(delete: true), child: Text(tr('Delete'))),
        TextButton(
            onPressed: () => Navigator.pop(context), child: Text(tr('Cancel'))),
        TextButton(onPressed: _close, child: Text(tr('OK'))),
      ],
    );
  }
}

/// Switches between the layouts, and adds, renames or deletes them. Pops with
/// the new set, or with null when cancelled.
class _GameKeyLayoutsDialog extends StatefulWidget {
  const _GameKeyLayoutsDialog({required this.initial, required this.tr});
  final GameKeyLayouts initial;
  final String Function(String) tr;

  @override
  State<_GameKeyLayoutsDialog> createState() => _GameKeyLayoutsDialogState();
}

class _GameKeyLayoutsDialogState extends State<_GameKeyLayoutsDialog> {
  late var _layouts = widget.initial;

  Future<String?> _askName(String title, String initial) => showDialog<String>(
        context: context,
        builder: (_) =>
            _NameDialog(title: title, initial: initial, tr: widget.tr),
      );

  Future<void> _add() async {
    final tr = widget.tr;
    final name = await _askName(
        tr('New layout'), '${tr('Layout')} ${_layouts.layouts.length + 1}');
    if (name == null || !mounted) return;
    setState(() => _layouts = _layouts.added(name));
  }

  Future<void> _rename(int i) async {
    final name = await _askName(widget.tr('Rename'), _layouts.layouts[i].name);
    if (name == null || !mounted) return;
    setState(() => _layouts = _layouts.renamed(i, name));
  }

  @override
  Widget build(BuildContext context) {
    final tr = widget.tr;
    final layouts = _layouts.layouts;
    return AlertDialog(
      title: Text(tr('Key layouts')),
      contentPadding: const EdgeInsets.fromLTRB(8, 12, 8, 0),
      scrollable: true,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < layouts.length; i++)
            InkWell(
              onTap: () => Navigator.pop(context, _layouts.select(i)),
              child: Row(children: [
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: Icon(
                      i == _layouts.current
                          ? Icons.radio_button_checked
                          : Icons.radio_button_unchecked,
                      size: 20,
                      color: i == _layouts.current
                          ? Theme.of(context).colorScheme.primary
                          : null),
                ),
                Expanded(
                    child: Text(gameKeyLayoutName(layouts[i], tr),
                        maxLines: 1, overflow: TextOverflow.ellipsis)),
                IconButton(
                    icon: const Icon(Icons.edit_outlined, size: 20),
                    tooltip: tr('Rename'),
                    onPressed: () => _rename(i)),
                if (layouts.length > 1)
                  IconButton(
                      icon: const Icon(Icons.delete_outline, size: 20),
                      tooltip: tr('Delete'),
                      onPressed: () =>
                          setState(() => _layouts = _layouts.removed(i))),
              ]),
            ),
        ],
      ),
      actions: [
        TextButton(onPressed: _add, child: Text(tr('New layout'))),
        TextButton(
            onPressed: () => Navigator.pop(context), child: Text(tr('Cancel'))),
        TextButton(
            onPressed: () => Navigator.pop(context, _layouts),
            child: Text(tr('OK'))),
      ],
    );
  }
}

class _NameDialog extends StatefulWidget {
  const _NameDialog(
      {required this.title, required this.initial, required this.tr});
  final String title;
  final String initial;
  final String Function(String) tr;

  @override
  State<_NameDialog> createState() => _NameDialogState();
}

class _NameDialogState extends State<_NameDialog> {
  late final _name = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _close() => Navigator.pop(context, _name.text.trim());

  @override
  Widget build(BuildContext context) {
    final tr = widget.tr;
    return AlertDialog(
      title: Text(widget.title),
      scrollable: true,
      content: TextField(
        controller: _name,
        autofocus: true,
        decoration: InputDecoration(labelText: tr('Name')),
        onSubmitted: (_) => _close(),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context), child: Text(tr('Cancel'))),
        TextButton(onPressed: _close, child: Text(tr('OK'))),
      ],
    );
  }
}
