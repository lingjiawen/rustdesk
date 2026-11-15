import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../common.dart';
import '../../common/widgets/toolbar.dart';
import '../../consts.dart';
import '../../models/model.dart';
import '../../models/platform_model.dart';

/// A key combination sent to the remote computer from the session panel.
class SessionShortcut {
  const SessionShortcut(this.label, this.key,
      {this.ctrl = false,
      this.alt = false,
      this.shift = false,
      this.command = false,
      this.action,
      this.custom = false});

  /// Translation key for built-in shortcuts, the user's text for custom ones.
  final String label;

  /// A name from the Rust KEY_MAP, e.g. `VK_C`.
  final String key;
  final bool ctrl;
  final bool alt;
  final bool shift;
  final bool command;

  /// `lock` or `ctrl-alt-del`: sent with the dedicated session calls.
  final String? action;
  final bool custom;

  Map<String, dynamic> toJson() => {
        'label': label,
        'key': key,
        if (ctrl) 'ctrl': true,
        if (alt) 'alt': true,
        if (shift) 'shift': true,
        if (command) 'command': true,
      };

  static SessionShortcut? fromJson(dynamic json) {
    if (json is! Map) return null;
    final key = json['key'];
    if (key is! String || key.isEmpty) return null;
    return SessionShortcut(
      (json['label'] as String?)?.trim() ?? '',
      key,
      ctrl: json['ctrl'] == true,
      alt: json['alt'] == true,
      shift: json['shift'] == true,
      command: json['command'] == true,
      custom: true,
    );
  }

  /// "Ctrl+Shift+Esc" style text, with Mac key names for Mac peers.
  String describe({required bool mac}) {
    final parts = <String>[
      if (ctrl) mac ? '⌃' : 'Ctrl',
      if (alt) mac ? '⌥' : 'Alt',
      if (shift) mac ? '⇧' : 'Shift',
      if (command) mac ? '⌘' : 'Win',
      kShortcutKeyNames.entries
              .firstWhere((e) => e.value == key,
                  orElse: () => MapEntry(key.replaceFirst('VK_', ''), key))
              .key,
    ];
    return parts.join(mac ? '' : '+');
  }
}

const kOptionMobileCustomShortcuts = 'mobile-custom-shortcuts';

/// Keys offered when composing a custom shortcut, display name to KEY_MAP name.
final Map<String, String> kShortcutKeyNames = {
  for (var c = 'A'.codeUnitAt(0); c <= 'Z'.codeUnitAt(0); c++)
    String.fromCharCode(c): 'VK_${String.fromCharCode(c)}',
  for (var d = 0; d <= 9; d++) '$d': 'VK_$d',
  for (var f = 1; f <= 12; f++) 'F$f': 'VK_F$f',
  'Tab': 'VK_TAB',
  'Esc': 'VK_ESCAPE',
  'Enter': 'VK_RETURN',
  'Space': 'VK_SPACE',
  'Backspace': 'VK_BACK',
  'Delete': 'VK_DELETE',
  'Insert': 'VK_INSERT',
  'Home': 'VK_HOME',
  'End': 'VK_END',
  'PgUp': 'VK_PRIOR',
  'PgDn': 'VK_NEXT',
  '←': 'VK_LEFT',
  '→': 'VK_RIGHT',
  '↑': 'VK_UP',
  '↓': 'VK_DOWN',
};

/// Everyday shortcuts for the remote OS. Editing keys use Cmd on a Mac and
/// Ctrl elsewhere.
List<SessionShortcut> defaultSessionShortcuts(String platform) {
  final mac = platform == kPeerPlatformMacOS;
  SessionShortcut edit(String label, String key, {bool shift = false}) =>
      SessionShortcut(label, key, ctrl: !mac, command: mac, shift: shift);
  final common = [
    edit('Copy', 'VK_C'),
    edit('Paste', 'VK_V'),
    edit('Cut', 'VK_X'),
    edit('Undo', 'VK_Z'),
    edit('Select all', 'VK_A'),
    edit('Save', 'VK_S'),
    edit('Find', 'VK_F'),
  ];
  if (mac) {
    return [
      ...common,
      const SessionShortcut('Switch window', 'VK_TAB', command: true),
      const SessionShortcut('Close window', 'VK_W', command: true),
      const SessionShortcut('Quit app', 'VK_Q', command: true),
      const SessionShortcut('Spotlight', 'VK_SPACE', command: true),
      const SessionShortcut('Force quit', 'VK_ESCAPE',
          command: true, alt: true),
      const SessionShortcut('Screenshot', 'VK_4', command: true, shift: true),
      const SessionShortcut('Insert Lock', '', action: 'lock'),
    ];
  }
  if (platform == kPeerPlatformWindows) {
    return [
      ...common,
      const SessionShortcut('Switch window', 'VK_TAB', alt: true),
      const SessionShortcut('Close window', 'VK_F4', alt: true),
      const SessionShortcut('Show desktop', 'VK_D', command: true),
      const SessionShortcut('Task Manager', 'VK_ESCAPE',
          ctrl: true, shift: true),
      const SessionShortcut('Screenshot', 'VK_S', command: true, shift: true),
      const SessionShortcut('Insert Ctrl + Alt + Del', '',
          action: 'ctrl-alt-del'),
      const SessionShortcut('Insert Lock', '', action: 'lock'),
    ];
  }
  return [
    ...common,
    const SessionShortcut('Switch window', 'VK_TAB', alt: true),
    const SessionShortcut('Close window', 'VK_F4', alt: true),
    const SessionShortcut('Insert Ctrl + Alt + Del', '',
        action: 'ctrl-alt-del'),
    const SessionShortcut('Insert Lock', '', action: 'lock'),
  ];
}

List<SessionShortcut> loadCustomShortcuts() {
  try {
    final list =
        jsonDecode(bind.mainGetLocalOption(key: kOptionMobileCustomShortcuts));
    if (list is! List) return [];
    return list.map(SessionShortcut.fromJson).whereType<SessionShortcut>().toList();
  } catch (_) {
    return [];
  }
}

Future<void> saveCustomShortcuts(List<SessionShortcut> list) =>
    bind.mainSetLocalOption(
        key: kOptionMobileCustomShortcuts,
        value: jsonEncode(list.map((e) => e.toJson()).toList()));

void sendSessionShortcut(FFI ffi, SessionShortcut s) {
  if (!ffi.inputModel.keyboardPerm) return;
  final sessionId = ffi.sessionId;
  switch (s.action) {
    case 'lock':
      bind.sessionLockScreen(sessionId: sessionId);
      return;
    case 'ctrl-alt-del':
      bind.sessionCtrlAltDel(sessionId: sessionId);
      return;
  }
  bind.sessionInputKey(
      sessionId: sessionId,
      name: s.key,
      down: false,
      press: true,
      alt: s.alt,
      ctrl: s.ctrl,
      shift: s.shift,
      command: s.command);
}

/// Entry points the panel needs from the session page.
class SessionPanelActions {
  SessionPanelActions({
    required this.openKeyboard,
    required this.toggleTouchMode,
    required this.toggleLandscape,
    required this.showGestureHelp,
    required this.toggleBar,
    required this.openFileTransfer,
    required this.openChat,
    required this.showDisplayOptions,
    required this.showMoreActions,
    required this.disconnect,
    required this.isLandscapeLocked,
    required this.isBarShown,
  });

  final VoidCallback openKeyboard;
  final VoidCallback toggleTouchMode;
  final VoidCallback toggleLandscape;
  final VoidCallback showGestureHelp;
  final VoidCallback toggleBar;
  final VoidCallback openFileTransfer;
  final VoidCallback openChat;
  final VoidCallback showDisplayOptions;
  final VoidCallback showMoreActions;
  final VoidCallback disconnect;
  final bool Function() isLandscapeLocked;
  final bool Function() isBarShown;
}

/// A draggable, semi-transparent button that opens the session panel. It
/// rests on the nearest side edge so it covers as little as possible.
class SessionFloatingBall extends StatefulWidget {
  const SessionFloatingBall(
      {Key? key, required this.ffi, required this.id, required this.actions})
      : super(key: key);

  final FFI ffi;
  final String id;
  final SessionPanelActions actions;

  @override
  State<SessionFloatingBall> createState() => _SessionFloatingBallState();
}

class _SessionFloatingBallState extends State<SessionFloatingBall> {
  static const double _size = 46;
  static const double _margin = 6;
  // Remembered for the app's lifetime, as fractions of the canvas.
  static Offset _fraction = const Offset(1, 0.4);
  Offset? _dragPos;
  bool _active = false;

  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      child: LayoutBuilder(builder: (context, constraints) {
        final w = constraints.maxWidth;
        final h = constraints.maxHeight;
        final maxX = max(_margin, w - _size - _margin);
        final maxY = max(_margin, h - _size - _margin);
        final pos = _dragPos ??
            Offset(_margin + (maxX - _margin) * _fraction.dx,
                _margin + (maxY - _margin) * _fraction.dy);
        return Stack(children: [
          Positioned(
            left: pos.dx.clamp(_margin, maxX),
            top: pos.dy.clamp(_margin, maxY),
            child: GestureDetector(
              onTap: () => _openPanel(context),
              onPanStart: (_) => setState(() {
                _active = true;
                _dragPos = pos;
              }),
              onPanUpdate: (d) => setState(() {
                _dragPos = (_dragPos ?? pos) + d.delta;
              }),
              onPanEnd: (_) => setState(() {
                final p = _dragPos ?? pos;
                final toRight = p.dx + _size / 2 > w / 2;
                final y = ((p.dy - _margin) / max(1, maxY - _margin))
                    .clamp(0.0, 1.0);
                _fraction = Offset(toRight ? 1 : 0, y);
                _dragPos = null;
                _active = false;
              }),
              child: AnimatedOpacity(
                duration: const Duration(milliseconds: 150),
                opacity: _active ? 0.95 : 0.6,
                child: Container(
                  width: _size,
                  height: _size,
                  decoration: BoxDecoration(
                    color: Colors.black87,
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.white54, width: 1.5),
                  ),
                  child: const Icon(Icons.apps_rounded,
                      color: Colors.white, size: 26),
                ),
              ),
            ),
          ),
        ]);
      }),
    );
  }

  void _openPanel(BuildContext context) {
    HapticFeedback.selectionClick();
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (_) => SessionPanel(
          ffi: widget.ffi, id: widget.id, actions: widget.actions),
    );
  }
}

class SessionPanel extends StatefulWidget {
  const SessionPanel(
      {Key? key, required this.ffi, required this.id, required this.actions})
      : super(key: key);

  final FFI ffi;
  final String id;
  final SessionPanelActions actions;

  @override
  State<SessionPanel> createState() => _SessionPanelState();
}

class _SessionPanelState extends State<SessionPanel> {
  String? _quality;
  bool _showDetails = false;
  List<SessionShortcut> _custom = loadCustomShortcuts();
  Future<List<TToggleMenu>>? _toggles;

  FFI get ffi => widget.ffi;

  @override
  void initState() {
    super.initState();
    bind.sessionGetImageQuality(sessionId: ffi.sessionId).then((v) {
      if (mounted) setState(() => _quality = v);
    });
  }

  void _run(VoidCallback action) {
    Navigator.of(context).pop();
    action();
  }

  @override
  Widget build(BuildContext context) {
    _toggles ??= toolbarDisplayToggle(context, widget.id, ffi);
    final maxHeight = MediaQuery.of(context).size.height * 0.8;
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxHeight),
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 36,
                  height: 4,
                  decoration: BoxDecoration(
                      color: Theme.of(context).dividerColor,
                      borderRadius: BorderRadius.circular(2)),
                ),
              ),
              const SizedBox(height: 10),
              _buildStatus(context),
              if (_showDetails) _buildDetails(context),
              const SizedBox(height: 12),
              _buildActions(context),
              _sectionTitle(context, translate('Image Quality')),
              _buildQuality(),
              _sectionTitle(context, translate('Shortcuts')),
              _buildShortcuts(context),
              _sectionTitle(context, translate('Session options')),
              _buildToggles(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _sectionTitle(BuildContext context, String text) => Padding(
        padding: const EdgeInsets.only(top: 16, bottom: 8),
        child: Text(text,
            style: Theme.of(context)
                .textTheme
                .titleSmall
                ?.copyWith(fontWeight: FontWeight.w600)),
      );

  Widget _buildStatus(BuildContext context) {
    return AnimatedBuilder(
      animation: ffi.qualityMonitorModel,
      builder: (context, _) {
        final data = ffi.qualityMonitorModel.data;
        final direct = ffi.ffiModel.direct;
        final channel = sessionChannelLabel(ffi.ffiModel.cachedPeerData.streamType);
        final parts = <String>[
          if (direct != null)
            translate(direct ? 'Direct' : 'Relay') +
                (channel.isEmpty ? '' : ' ($channel)'),
          if (data.delay != null) '${data.delay} ms',
          if (data.fps != null) '${data.fps} fps',
          if (data.codecFormat != null) data.codecFormat!,
        ];
        final hint = Theme.of(context).hintColor;
        return InkWell(
          onTap: () => setState(() => _showDetails = !_showDetails),
          borderRadius: BorderRadius.circular(8),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              children: [
                Icon(direct == false ? Icons.cloud_outlined : Icons.lan_outlined,
                    size: 18, color: hint),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(parts.isEmpty ? widget.id : parts.join(' · '),
                      style: TextStyle(color: hint)),
                ),
                Icon(_showDetails ? Icons.expand_less : Icons.expand_more,
                    size: 20, color: hint),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildDetails(BuildContext context) {
    return AnimatedBuilder(
      animation: ffi.qualityMonitorModel,
      builder: (context, _) {
        final data = ffi.qualityMonitorModel.data;
        final secure = ffi.ffiModel.secure;
        final direct = ffi.ffiModel.direct;
        final net = readNetworkInfo(bind.mainGetNetworkInfo());
        final rows = <(String, String)>[
          if (secure != null && direct != null)
            (
              translate('Connection'),
              getConnectionText(
                  secure, direct, ffi.ffiModel.cachedPeerData.streamType)
            ),
          if (data.delay != null) (translate('Delay'), '${data.delay} ms'),
          if (data.speed != null) (translate('Speed'), data.speed!),
          if (data.fps != null) (translate('FPS'), data.fps!),
          if (data.targetBitrate != null)
            (translate('Bitrate'), data.targetBitrate!),
          if (data.codecFormat != null)
            (
              translate('Codec'),
              [data.codecFormat!, if (data.chroma != null) data.chroma!]
                  .join(' ')
            ),
          (translate('NAT type of this device'), translate(net.natLabel)),
          (
            translate('Public IPv6 on this device'),
            translate(net.ipv6 ? 'Available' : 'Not available')
          ),
          ('ID', widget.id),
        ];
        final theme = Theme.of(context);
        return Container(
          margin: const EdgeInsets.only(top: 6),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHighest.withAlpha(128),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Column(
            children: rows
                .map((r) => Padding(
                      padding: const EdgeInsets.symmetric(vertical: 3),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          SizedBox(
                            width: 112,
                            child: Text(r.$1,
                                style: TextStyle(color: theme.hintColor)),
                          ),
                          Expanded(child: SelectableText(r.$2)),
                        ],
                      ),
                    ))
                .toList(),
          ),
        );
      },
    );
  }

  Widget _buildActions(BuildContext context) {
    final a = widget.actions;
    final touch = ffi.ffiModel.touchMode;
    final items = <(IconData, String, VoidCallback)>[
      (Icons.keyboard, translate('Keyboard'), () => _run(a.openKeyboard)),
      (
        touch ? Icons.touch_app : Icons.mouse,
        translate(touch ? 'Touch mode' : 'Mouse mode'),
        () {
          a.toggleTouchMode();
          setState(() {});
        }
      ),
      (
        a.isLandscapeLocked() ? Icons.screen_lock_rotation : Icons.screen_rotation,
        translate('Landscape'),
        () => _run(a.toggleLandscape)
      ),
      (Icons.gesture, translate('Gestures'), () => _run(a.showGestureHelp)),
      (
        a.isBarShown() ? Icons.keyboard_arrow_down : Icons.keyboard_arrow_up,
        translate('Toolbar'),
        () => _run(a.toggleBar)
      ),
      (Icons.folder_outlined, translate('Transfer file'),
          () => _run(a.openFileTransfer)),
      (Icons.chat_bubble_outline, translate('Chat'), () => _run(a.openChat)),
      (Icons.tv, translate('Display Settings'),
          () => _run(a.showDisplayOptions)),
      (Icons.more_horiz, translate('More'), () => _run(a.showMoreActions)),
      (Icons.close, translate('Disconnect'), () => _run(a.disconnect)),
    ];
    return LayoutBuilder(builder: (context, constraints) {
      final columns = constraints.maxWidth >= 520 ? 10 : 5;
      final width = constraints.maxWidth / columns;
      return Wrap(
        children: [
          for (final (icon, label, onTap) in items)
            SizedBox(
              width: width,
              child: InkWell(
                borderRadius: BorderRadius.circular(10),
                onTap: onTap,
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Column(
                    children: [
                      Icon(icon, size: 26),
                      const SizedBox(height: 4),
                      Text(label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 12)),
                    ],
                  ),
                ),
              ),
            ),
        ],
      );
    });
  }

  Widget _buildQuality() {
    final options = <(String, String)>[
      (kRemoteImageQualityLow, translate('Smooth')),
      (kRemoteImageQualityBalanced, translate('Balanced')),
      (kRemoteImageQualityBest, translate('Good image quality')),
    ];
    return Wrap(
      spacing: 8,
      children: [
        for (final (value, label) in options)
          ChoiceChip(
            label: Text(label),
            selected: _quality == value,
            onSelected: (_) async {
              await bind.sessionSetImageQuality(
                  sessionId: ffi.sessionId, value: value);
              if (mounted) setState(() => _quality = value);
            },
          ),
      ],
    );
  }

  Widget _buildShortcuts(BuildContext context) {
    final mac = ffi.ffiModel.pi.platform == kPeerPlatformMacOS;
    final builtIn = defaultSessionShortcuts(ffi.ffiModel.pi.platform);
    Widget chip(SessionShortcut s) {
      final label = s.custom ? s.label : translate(s.label);
      final keys = s.action == null ? s.describe(mac: mac) : '';
      return GestureDetector(
        onLongPress: s.custom ? () => _removeCustom(s) : null,
        child: ActionChip(
          label: Text(keys.isEmpty || label == keys ? label : '$label  $keys',
              style: const TextStyle(fontSize: 13)),
          onPressed: () {
            HapticFeedback.selectionClick();
            sendSessionShortcut(ffi, s);
          },
        ),
      );
    }

    return Wrap(
      spacing: 8,
      runSpacing: 4,
      children: [
        ...builtIn.map(chip),
        ..._custom.map(chip),
        ActionChip(
          avatar: const Icon(Icons.add, size: 18),
          label: Text(translate('Add shortcut')),
          onPressed: () => _addCustom(context, mac),
        ),
      ],
    );
  }

  Future<void> _removeCustom(SessionShortcut s) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        content: Text('${translate('Delete')} "${s.label}"?'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(translate('Cancel'))),
          TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(translate('Delete'))),
        ],
      ),
    );
    if (ok != true) return;
    final next = _custom.where((e) => !identical(e, s)).toList();
    await saveCustomShortcuts(next);
    if (mounted) setState(() => _custom = next);
  }

  Future<void> _addCustom(BuildContext context, bool mac) async {
    final created = await showDialog<SessionShortcut>(
      context: context,
      builder: (context) => _CustomShortcutDialog(mac: mac),
    );
    if (created == null) return;
    final next = [..._custom, created];
    await saveCustomShortcuts(next);
    if (mounted) setState(() => _custom = next);
  }

  Widget _buildToggles() {
    return FutureBuilder<List<TToggleMenu>>(
      future: _toggles,
      builder: (context, snapshot) {
        final toggles = snapshot.data ?? const <TToggleMenu>[];
        return Column(
          children: [
            for (final t in toggles)
              SwitchListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: t.child,
                value: t.value,
                onChanged: t.onChanged == null
                    ? null
                    : (v) {
                        t.onChanged!(v);
                        // The toggles apply asynchronously; read them back
                        // once the option has been written.
                        Future.delayed(const Duration(milliseconds: 200), () {
                          if (!mounted) return;
                          setState(() {
                            _toggles =
                                toolbarDisplayToggle(context, widget.id, ffi);
                          });
                        });
                      },
              ),
          ],
        );
      },
    );
  }
}

class _CustomShortcutDialog extends StatefulWidget {
  const _CustomShortcutDialog({required this.mac});
  final bool mac;

  @override
  State<_CustomShortcutDialog> createState() => _CustomShortcutDialogState();
}

class _CustomShortcutDialogState extends State<_CustomShortcutDialog> {
  bool _ctrl = false, _alt = false, _shift = false, _command = false;
  String _key = 'VK_A';
  final _label = TextEditingController();

  @override
  void dispose() {
    _label.dispose();
    super.dispose();
  }

  SessionShortcut get _shortcut => SessionShortcut(_label.text.trim(), _key,
      ctrl: _ctrl, alt: _alt, shift: _shift, command: _command, custom: true);

  @override
  Widget build(BuildContext context) {
    Widget mod(String text, bool value, ValueChanged<bool> set) => FilterChip(
          label: Text(text),
          selected: value,
          onSelected: (v) => setState(() => set(v)),
        );
    return AlertDialog(
      title: Text(translate('Add shortcut')),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(spacing: 6, children: [
            mod(widget.mac ? '⌃ Control' : 'Ctrl', _ctrl, (v) => _ctrl = v),
            mod(widget.mac ? '⌥ Option' : 'Alt', _alt, (v) => _alt = v),
            mod(widget.mac ? '⇧ Shift' : 'Shift', _shift, (v) => _shift = v),
            mod(widget.mac ? '⌘ Command' : 'Win', _command,
                (v) => _command = v),
          ]),
          const SizedBox(height: 8),
          DropdownButton<String>(
            value: _key,
            isExpanded: true,
            items: [
              for (final e in kShortcutKeyNames.entries)
                DropdownMenuItem(value: e.value, child: Text(e.key)),
            ],
            onChanged: (v) => setState(() => _key = v ?? _key),
          ),
          TextField(
            controller: _label,
            decoration: InputDecoration(
                labelText: translate('Name'),
                hintText: _shortcut.describe(mac: widget.mac)),
          ),
        ],
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(translate('Cancel'))),
        TextButton(
          onPressed: () {
            final s = _shortcut;
            Navigator.pop(
                context,
                s.label.isEmpty
                    ? SessionShortcut(s.describe(mac: widget.mac), s.key,
                        ctrl: s.ctrl,
                        alt: s.alt,
                        shift: s.shift,
                        command: s.command,
                        custom: true)
                    : s);
          },
          child: Text(translate('OK')),
        ),
      ],
    );
  }
}

const kOptionMobileTouchModeChosen = 'mobile-touch-mode-chosen';

/// Asks once which way the user wants to control the remote screen, the way
/// Sunlogin does on first use. The choice can be changed in the panel later.
Future<void> maybeShowTouchModeChooser(BuildContext context, FFI ffi) async {
  if (bind.mainGetLocalOption(key: kOptionMobileTouchModeChosen) == 'Y') {
    return;
  }
  await bind.mainSetLocalOption(key: kOptionMobileTouchModeChosen, value: 'Y');
  if (!context.mounted) return;
  final touch = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (context) {
      Widget option(bool touchMode, IconData icon, String title,
              List<String> lines) =>
          InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: () => Navigator.pop(context, touchMode),
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              margin: const EdgeInsets.only(bottom: 10),
              decoration: BoxDecoration(
                border: Border.all(color: Theme.of(context).dividerColor),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(icon, size: 32),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(title,
                            style:
                                const TextStyle(fontWeight: FontWeight.w600)),
                        const SizedBox(height: 4),
                        for (final l in lines)
                          Text(l,
                              style: TextStyle(
                                  fontSize: 13,
                                  color: Theme.of(context).hintColor)),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          );
      return AlertDialog(
        title: Text(translate('touch-mode-chooser-title')),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            option(false, Icons.mouse, translate('Mouse mode'), [
              translate('touch-mode-chooser-mouse-1'),
              translate('touch-mode-chooser-mouse-2'),
            ]),
            option(true, Icons.touch_app, translate('Touch mode'), [
              translate('touch-mode-chooser-touch-1'),
              translate('touch-mode-chooser-touch-2'),
            ]),
            Text(translate('touch-mode-chooser-tip'),
                style: TextStyle(
                    fontSize: 12, color: Theme.of(context).hintColor)),
          ],
        ),
      );
    },
  );
  if (touch == null || touch == ffi.ffiModel.touchMode) return;
  ffi.ffiModel.toggleTouchMode();
  await bind.mainSetLocalOption(
      key: kOptionTouchMode, value: ffi.ffiModel.touchMode ? 'Y' : 'N');
}

/// The channel a session runs on, as `connection_ready` names it, for the
/// status line. A relay names no channel: "Relay" already says it.
String sessionChannelLabel(String streamType) =>
    streamType == 'Relay' ? '' : streamType;

class SessionNetworkInfo {
  /// A translation key.
  final String natLabel;
  final bool ipv6;
  const SessionNetworkInfo(this.natLabel, this.ipv6);
}

/// Reads `mainGetNetworkInfo`: `nat_type` is the rendezvous NatType number.
SessionNetworkInfo readNetworkInfo(String json) {
  try {
    final m = jsonDecode(json) as Map<String, dynamic>;
    final nat = switch (m['nat_type']) {
      1 => 'Asymmetric NAT',
      2 => 'Symmetric NAT',
      _ => 'Untested',
    };
    return SessionNetworkInfo(nat, m['ipv6'] == true);
  } catch (_) {
    return const SessionNetworkInfo('Untested', false);
  }
}
