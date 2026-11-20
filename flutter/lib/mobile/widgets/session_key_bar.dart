import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../common.dart';
import '../../consts.dart';
import '../../models/model.dart';
import '../../models/platform_model.dart';
import 'session_panel.dart';

const kSessionKeyModifiers = ['ctrl', 'alt', 'shift', 'command'];

/// What the on-screen keys ask the session to do.
abstract class SessionKeySink {
  bool modifierOn(String name);

  /// On until switched off, instead of for the next key or click only.
  bool modifierLocked(String name);
  void setModifier(String name, {required bool on, bool locked = false});

  /// Presses a KEY_MAP key with the modifiers that are on.
  void key(String name);
  void shortcut(SessionShortcut shortcut);
}

class InputModelKeySink implements SessionKeySink {
  InputModelKeySink(this.ffi);
  final FFI ffi;

  @override
  bool modifierOn(String name) {
    final input = ffi.inputModel;
    switch (name) {
      case 'ctrl':
        return input.ctrl;
      case 'alt':
        return input.alt;
      case 'shift':
        return input.shift;
      default:
        return input.command;
    }
  }

  @override
  bool modifierLocked(String name) =>
      modifierOn(name) && !ffi.inputModel.touchOneShotModifiers.contains(name);

  @override
  void setModifier(String name, {required bool on, bool locked = false}) {
    final input = ffi.inputModel;
    switch (name) {
      case 'ctrl':
        input.ctrl = on;
        break;
      case 'alt':
        input.alt = on;
        break;
      case 'shift':
        input.shift = on;
        break;
      default:
        input.command = on;
    }
    if (on && !locked) {
      input.touchOneShotModifiers.add(name);
    } else {
      input.touchOneShotModifiers.remove(name);
    }
    input.touchModifiersChanged.value++;
  }

  @override
  void key(String name) => ffi.inputModel.inputKey(name);

  @override
  void shortcut(SessionShortcut shortcut) => sendSessionShortcut(ffi, shortcut);
}

/// Types [text] on the remote computer, pressing Return for each line break
/// and once more at the end when [enter] is set. Each call is awaited so the
/// lines and the Returns arrive in order.
Future<void> sendTextToSession(FFI ffi, String text,
    {bool enter = false}) async {
  if (!ffi.inputModel.keyboardPerm) return;
  for (final part in splitTextForSession(text, enter: enter)) {
    if (part == '\n') {
      await bind.sessionInputKey(
          sessionId: ffi.sessionId,
          name: 'VK_RETURN',
          down: false,
          press: true,
          alt: false,
          ctrl: false,
          shift: false,
          command: false);
    } else {
      await bind.sessionInputString(sessionId: ffi.sessionId, value: part);
    }
  }
}

/// [text] as runs of characters to type and `\n` entries to send as Return.
List<String> splitTextForSession(String text, {bool enter = false}) {
  final lines = text.replaceAll('\r\n', '\n').replaceAll('\r', '\n').split('\n');
  final parts = <String>[];
  for (var i = 0; i < lines.length; i++) {
    if (lines[i].isNotEmpty) parts.add(lines[i]);
    if (i < lines.length - 1) parts.add('\n');
  }
  if (enter && parts.isNotEmpty) parts.add('\n');
  return parts;
}

/// One on-screen key. A [repeat] key held down keeps pressing, like a
/// hardware key.
class KeyCap extends StatefulWidget {
  const KeyCap({
    Key? key,
    this.label = '',
    this.icon,
    required this.onPressed,
    this.onLongPress,
    this.repeat = false,
    this.active = false,
    this.locked = false,
    this.minWidth = 40,
    this.fontSize = 14,
  }) : super(key: key);

  final String label;
  final IconData? icon;
  final VoidCallback onPressed;
  final VoidCallback? onLongPress;
  final bool repeat;
  final bool active;
  final bool locked;
  final double minWidth;
  final double fontSize;

  static const repeatInterval = Duration(milliseconds: 70);

  @override
  State<KeyCap> createState() => _KeyCapState();
}

class _KeyCapState extends State<KeyCap> {
  bool _down = false;
  Timer? _repeat;

  void _setDown(bool down) {
    if (mounted && _down != down) setState(() => _down = down);
  }

  void _release() {
    _repeat?.cancel();
    _repeat = null;
    _setDown(false);
  }

  @override
  void dispose() {
    _repeat?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final held = widget.repeat || widget.onLongPress != null;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (_) => _setDown(true),
      onTapUp: (_) => _setDown(false),
      onTapCancel: () => _setDown(false),
      onTap: () {
        HapticFeedback.selectionClick();
        widget.onPressed();
      },
      onLongPressStart: !held
          ? null
          : (_) {
              HapticFeedback.mediumImpact();
              _setDown(true);
              if (!widget.repeat) {
                widget.onLongPress?.call();
                return;
              }
              widget.onPressed();
              _repeat?.cancel();
              _repeat = Timer.periodic(
                  KeyCap.repeatInterval, (_) => widget.onPressed());
            },
      onLongPressEnd: !held ? null : (_) => _release(),
      onLongPressCancel: !held ? null : _release,
      child: Container(
        constraints: BoxConstraints(minWidth: widget.minWidth),
        padding: const EdgeInsets.symmetric(horizontal: 8),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: widget.active
              ? MyTheme.accent
              : (_down ? Colors.white38 : Colors.white12),
          borderRadius: BorderRadius.circular(7),
          border: widget.locked
              ? Border.all(color: Colors.white, width: 1.5)
              : null,
        ),
        child: widget.icon != null
            ? Icon(widget.icon, size: 20, color: Colors.white)
            : FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(widget.label,
                    maxLines: 1,
                    style: TextStyle(
                        color: Colors.white, fontSize: widget.fontSize)),
              ),
      ),
    );
  }
}

const _kKeyAreaColor = Color(0xF2161618);

/// The row of keys that sits on top of the soft keyboard: modifiers and the
/// keys a phone keyboard lacks, with the switch to the function-key pad on
/// the left and "hide" on the right where the thumbs are.
class SessionKeyBar extends StatelessWidget {
  const SessionKeyBar({
    Key? key,
    required this.sink,
    required this.platform,
    required this.padShown,
    required this.pinned,
    required this.onTogglePad,
    required this.onTogglePin,
    required this.onHide,
    required this.onSendText,
    required this.onPasteClipboard,
  }) : super(key: key);

  final SessionKeySink sink;
  final String platform;
  final bool padShown;
  final bool pinned;
  final VoidCallback onTogglePad;
  final VoidCallback onTogglePin;
  final VoidCallback onHide;
  final VoidCallback onSendText;
  final VoidCallback onPasteClipboard;

  static const double height = 48;

  @override
  Widget build(BuildContext context) {
    final mac = platform == kPeerPlatformMacOS;
    final winOrLinux =
        platform == kPeerPlatformWindows || platform == kPeerPlatformLinux;
    // Tap: for the next key or click only. Long press: stays on, shown with a
    // border, until tapped again.
    Widget mod(String label, String name) => KeyCap(
          label: label,
          active: sink.modifierOn(name),
          locked: sink.modifierLocked(name),
          onPressed: () => sink.setModifier(name, on: !sink.modifierOn(name)),
          onLongPress: () => sink.setModifier(name, on: true, locked: true),
        );
    Widget key(String label, String name,
            {IconData? icon, bool repeat = false}) =>
        KeyCap(
            label: label,
            icon: icon,
            repeat: repeat,
            onPressed: () => sink.key(name));
    final keys = <Widget>[
      mod('Ctrl', 'ctrl'),
      mod(mac ? 'Opt' : 'Alt', 'alt'),
      mod('Shift', 'shift'),
      mod(mac ? 'Cmd' : 'Win', 'command'),
      key('Esc', 'VK_ESCAPE'),
      key('Tab', 'VK_TAB'),
      key('', 'VK_LEFT', icon: Icons.keyboard_arrow_left, repeat: true),
      key('', 'VK_UP', icon: Icons.keyboard_arrow_up, repeat: true),
      key('', 'VK_DOWN', icon: Icons.keyboard_arrow_down, repeat: true),
      key('', 'VK_RIGHT', icon: Icons.keyboard_arrow_right, repeat: true),
      key('Home', 'VK_HOME'),
      key('End', 'VK_END'),
      key('PgUp', 'VK_PRIOR', repeat: true),
      key('PgDn', 'VK_NEXT', repeat: true),
      key('Del', 'VK_DELETE', repeat: true),
      if (winOrLinux) key('PrtScr', 'VK_SNAPSHOT'),
      if (winOrLinux) key('Menu', 'Apps'),
      KeyCap(icon: Icons.edit_note, onPressed: onSendText),
      KeyCap(icon: Icons.content_paste_go, onPressed: onPasteClipboard),
      KeyCap(icon: Icons.push_pin, active: pinned, onPressed: onTogglePin),
    ];
    return Container(
      height: height,
      color: _kKeyAreaColor,
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        children: [
          const SizedBox(width: 6),
          KeyCap(
            label: 'Fn',
            icon: padShown ? Icons.keyboard : null,
            active: padShown,
            onPressed: onTogglePad,
          ),
          const SizedBox(width: 6),
          Expanded(
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: keys.length,
              separatorBuilder: (_, __) => const SizedBox(width: 4),
              itemBuilder: (_, i) => keys[i],
            ),
          ),
          const SizedBox(width: 6),
          KeyCap(icon: Icons.keyboard_hide, onPressed: onHide),
          const SizedBox(width: 6),
        ],
      ),
    );
  }
}

class _PadKey {
  const _PadKey(this.label,
      {this.key, this.shortcut, this.icon, this.flex = 2, this.repeat = false});
  final String label;
  final String? key;
  final SessionShortcut? shortcut;
  final IconData? icon;
  final int flex;
  final bool repeat;
}

/// The function-key pad shown in place of the soft keyboard: F1 to F12,
/// navigation, arrows and the everyday edit shortcuts as one grid.
class SessionFnPad extends StatelessWidget {
  const SessionFnPad({
    Key? key,
    required this.sink,
    required this.platform,
    this.tr = translate,
  }) : super(key: key);

  final SessionKeySink sink;
  final String platform;
  final String Function(String) tr;

  /// Wider than this, the keys are laid out in three long rows so the pad
  /// stays low on a phone held sideways.
  static const double wideLayoutWidth = 560;

  List<List<_PadKey>> _rows(bool wide) {
    final mac = platform == kPeerPlatformMacOS;
    _PadKey edit(String label, String key, {bool shift = false}) => _PadKey(
        tr(label),
        shortcut:
            SessionShortcut(label, key, ctrl: !mac, command: mac, shift: shift));
    _PadKey f(int n) => _PadKey('F$n', key: 'VK_F$n');
    const esc = _PadKey('Esc', key: 'VK_ESCAPE');
    const tab = _PadKey('Tab', key: 'VK_TAB');
    const back = _PadKey('',
        key: 'VK_BACK', icon: Icons.backspace_outlined, repeat: true);
    const del = _PadKey('Del', key: 'VK_DELETE', repeat: true);
    const home = _PadKey('Home', key: 'VK_HOME');
    const end = _PadKey('End', key: 'VK_END');
    const pgUp = _PadKey('PgUp', key: 'VK_PRIOR', repeat: true);
    const pgDn = _PadKey('PgDn', key: 'VK_NEXT', repeat: true);
    const enter = _PadKey('',
        key: 'VK_RETURN', icon: Icons.keyboard_return, repeat: true);
    final extra = mac
        ? edit('Redo', 'VK_Z', shift: true)
        : const _PadKey('Ins', key: 'VK_INSERT');
    _PadKey arrow(String key, IconData icon, {int flex = 2}) =>
        _PadKey('', key: key, icon: icon, flex: flex, repeat: true);
    final edits = [
      edit('Select all', 'VK_A'),
      edit('Copy', 'VK_C'),
      edit('Paste', 'VK_V'),
      edit('Cut', 'VK_X'),
      edit('Undo', 'VK_Z'),
    ];
    final save = edit('Save', 'VK_S');
    final find = edit('Find', 'VK_F');
    if (wide) {
      return [
        [esc, for (var n = 1; n <= 12; n++) f(n), back],
        [tab, ...edits, save, find, extra, del, home, end, pgUp, pgDn],
        [
          const _PadKey('Space', key: 'VK_SPACE', flex: 10, repeat: true),
          const _PadKey('',
              key: 'VK_RETURN',
              icon: Icons.keyboard_return,
              flex: 6,
              repeat: true),
          arrow('VK_LEFT', Icons.keyboard_arrow_left, flex: 3),
          arrow('VK_UP', Icons.keyboard_arrow_up, flex: 3),
          arrow('VK_DOWN', Icons.keyboard_arrow_down, flex: 3),
          arrow('VK_RIGHT', Icons.keyboard_arrow_right, flex: 3),
        ],
      ];
    }
    return [
      [esc, for (var n = 1; n <= 6; n++) f(n)],
      [tab, for (var n = 7; n <= 12; n++) f(n)],
      [...edits, extra, back],
      [home, end, pgUp, pgDn, del, arrow('VK_UP', Icons.keyboard_arrow_up), enter],
      [
        save,
        find,
        const _PadKey('Space', key: 'VK_SPACE', flex: 4, repeat: true),
        arrow('VK_LEFT', Icons.keyboard_arrow_left),
        arrow('VK_DOWN', Icons.keyboard_arrow_down),
        arrow('VK_RIGHT', Icons.keyboard_arrow_right),
      ],
    ];
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, constraints) {
      final wide = constraints.maxWidth >= wideLayoutWidth;
      final rowHeight = wide ? 40.0 : 46.0;
      return Container(
        color: _kKeyAreaColor,
        padding: const EdgeInsets.fromLTRB(3, 0, 3, 5),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final row in _rows(wide))
              SizedBox(
                height: rowHeight,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (final k in row)
                      Expanded(
                        flex: k.flex,
                        child: Padding(
                          padding: const EdgeInsets.all(3),
                          child: KeyCap(
                            label: k.label,
                            icon: k.icon,
                            repeat: k.repeat,
                            minWidth: 0,
                            fontSize: 13,
                            onPressed: () {
                              final shortcut = k.shortcut;
                              if (shortcut != null) {
                                sink.shortcut(shortcut);
                              } else {
                                sink.key(k.key!);
                              }
                            },
                          ),
                        ),
                      ),
                  ],
                ),
              ),
          ],
        ),
      );
    });
  }
}

/// The key bar and, under it, the function-key pad, laid out at the bottom
/// of the session. It is shown with the soft keyboard or the pad, while it
/// is pinned, and while an on-screen modifier waits for a click.
class SessionKeyArea extends StatefulWidget {
  const SessionKeyArea({
    Key? key,
    required this.sink,
    required this.platform,
    required this.keyboardVisible,
    required this.padShown,
    required this.onTogglePad,
    required this.onHide,
    required this.onSendText,
    required this.onPasteClipboard,
    required this.onLayout,
    this.tr = translate,
  }) : super(key: key);

  final SessionKeySink sink;
  final String platform;
  final bool keyboardVisible;
  final bool padShown;
  final VoidCallback onTogglePad;
  final VoidCallback onHide;
  final VoidCallback onSendText;
  final VoidCallback onPasteClipboard;

  /// The height the area covers at the bottom of the session, and whether it
  /// is shown at all. Called from build when hidden, so it must not rebuild.
  final void Function(double height, bool visible) onLayout;
  final String Function(String) tr;

  @override
  State<SessionKeyArea> createState() => _SessionKeyAreaState();
}

class _SessionKeyAreaState extends State<SessionKeyArea> {
  bool _pin = false;
  final _key = GlobalKey();

  // A physical modifier held down must not open the bar.
  bool get _touchModifier {
    final keyboard = HardwareKeyboard.instance;
    final sink = widget.sink;
    return (sink.modifierOn('ctrl') && !keyboard.isControlPressed) ||
        (sink.modifierOn('alt') && !keyboard.isAltPressed) ||
        (sink.modifierOn('shift') && !keyboard.isShiftPressed) ||
        (sink.modifierOn('command') && !keyboard.isMetaPressed);
  }

  void _report() {
    if (!mounted) return;
    final box = _key.currentContext?.findRenderObject();
    if (box is RenderBox && box.hasSize) {
      widget.onLayout(box.size.height, true);
    }
  }

  void _hide() {
    for (final name in kSessionKeyModifiers) {
      if (widget.sink.modifierOn(name)) {
        widget.sink.setModifier(name, on: false);
      }
    }
    setState(() => _pin = false);
    widget.onHide();
  }

  @override
  Widget build(BuildContext context) {
    final visible = widget.keyboardVisible ||
        widget.padShown ||
        _pin ||
        _touchModifier;
    if (!visible) {
      widget.onLayout(0, false);
      return const SizedBox.shrink();
    }
    // The soft keyboard is still sliding when this is built; measure once it
    // has settled.
    Future.delayed(const Duration(milliseconds: 500), _report);
    // Without the soft keyboard the keys would reach under the home
    // indicator; the session body does not keep clear of it by itself.
    final homeIndicator =
        MediaQueryData.fromView(View.of(context)).padding.bottom;
    return Container(
      key: _key,
      color: _kKeyAreaColor,
      padding: EdgeInsets.only(bottom: homeIndicator),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SessionKeyBar(
            sink: widget.sink,
            platform: widget.platform,
            padShown: widget.padShown,
            pinned: _pin,
            onTogglePad: widget.onTogglePad,
            onTogglePin: () => setState(() => _pin = !_pin),
            onHide: _hide,
            onSendText: widget.onSendText,
            onPasteClipboard: widget.onPasteClipboard,
          ),
          if (widget.padShown)
            SessionFnPad(
                sink: widget.sink, platform: widget.platform, tr: widget.tr),
        ],
      ),
    );
  }
}

/// A box to write or paste text in with the phone's own keyboard, then type
/// it on the remote computer in one go. Input methods, dictation and
/// autocorrect all work here because nothing is sent until "Send".
Future<void> showSendTextSheet(
  BuildContext context, {
  required void Function(String text, bool enter) onSend,
  String Function(String) tr = translate,
}) {
  return showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    // The remote screen stays readable, to watch the text arrive.
    barrierColor: Colors.black12,
    backgroundColor: Theme.of(context).colorScheme.surface,
    shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
    builder: (context) => _SendTextSheet(onSend: onSend, tr: tr),
  );
}

class _SendTextSheet extends StatefulWidget {
  const _SendTextSheet({required this.onSend, required this.tr});
  final void Function(String text, bool enter) onSend;
  final String Function(String) tr;

  @override
  State<_SendTextSheet> createState() => _SendTextSheetState();
}

class _SendTextSheetState extends State<_SendTextSheet> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _send(bool enter) {
    final text = _controller.text;
    if (text.isEmpty) return;
    widget.onSend(text, enter);
    // Stays open for the next line, the way a chat box does.
    _controller.clear();
  }

  @override
  Widget build(BuildContext context) {
    final tr = widget.tr;
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                controller: _controller,
                autofocus: true,
                minLines: 2,
                maxLines: 5,
                textInputAction: TextInputAction.newline,
                decoration: InputDecoration(
                  hintText: tr('send-text-hint'),
                  border: const OutlineInputBorder(),
                  isDense: true,
                ),
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  TextButton(
                    onPressed: () async {
                      final data =
                          await Clipboard.getData(Clipboard.kTextPlain);
                      final text = data?.text ?? '';
                      if (text.isEmpty) return;
                      final v = _controller.value;
                      final at = v.selection.isValid
                          ? v.selection.start
                          : v.text.length;
                      final end =
                          v.selection.isValid ? v.selection.end : v.text.length;
                      _controller.value = TextEditingValue(
                        text: v.text.replaceRange(at, end, text),
                        selection:
                            TextSelection.collapsed(offset: at + text.length),
                      );
                    },
                    child: Text(tr('Paste')),
                  ),
                  const Spacer(),
                  OutlinedButton(
                    onPressed: () => _send(false),
                    child: Text(tr('Send')),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: () => _send(true),
                    child: Text(tr('Send and Enter')),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
