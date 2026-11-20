import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../common.dart';
import '../../common/shared_state.dart';
import '../../common/widgets/dialog.dart';
import '../../common/widgets/toolbar.dart';
import '../../consts.dart';
import '../../models/model.dart';
import '../../models/platform_model.dart';
import 'background_keep_alive.dart';
import 'panel_quick_actions.dart';
import 'phone_resolution.dart';
import 'session_recording.dart';
import 'session_screenshot.dart';
import 'session_video_texture.dart';
import 'touch_gesture_engine.dart';

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
    required this.openFnPad,
    required this.sendText,
    required this.toggleKeyboard,
    required this.controls,
    required this.toggleGameKeys,
    required this.toggleRecording,
    required this.toggleTouchMode,
    required this.toggleLandscape,
    required this.showGestureHelp,
    required this.toggleBar,
    required this.openFileTransfer,
    required this.openChat,
    required this.showDisplayOptions,
    required this.disconnect,
    required this.isLandscapeLocked,
    required this.isBarShown,
    required this.isGameKeysShown,
    required this.isRecording,
    this.videoTexture,
  });

  /// Null where the session's video cannot go through a native texture.
  final SessionVideoTexture? videoTexture;

  final VoidCallback openKeyboard;
  final VoidCallback openFnPad;
  final VoidCallback sendText;

  /// Opens the soft keyboard, or closes whichever of it and the function-key
  /// pad is open.
  final VoidCallback toggleKeyboard;

  /// The session's remaining actions, built with the session page's context
  /// so they still work after the panel has closed.
  final List<TTextMenu> Function() controls;
  final VoidCallback toggleGameKeys;
  final VoidCallback toggleRecording;
  final VoidCallback toggleTouchMode;
  final VoidCallback toggleLandscape;
  final VoidCallback showGestureHelp;
  final VoidCallback toggleBar;
  final VoidCallback openFileTransfer;
  final VoidCallback openChat;
  final VoidCallback showDisplayOptions;
  final VoidCallback disconnect;
  final bool Function() isLandscapeLocked;
  final bool Function() isBarShown;
  final bool Function() isGameKeysShown;
  final bool Function() isRecording;
}

/// A draggable, semi-transparent button that opens the session panel. It
/// rests on the nearest side edge so it covers as little as possible.
class SessionFloatingBall extends StatefulWidget {
  const SessionFloatingBall(
      {Key? key,
      required this.ffi,
      required this.id,
      required this.actions,
      this.bottomReserved = 0})
      : super(key: key);

  final FFI ffi;
  final String id;
  final SessionPanelActions actions;

  /// Height at the bottom the ball must stay above, e.g. the key bar.
  final double bottomReserved;

  @override
  State<SessionFloatingBall> createState() => _SessionFloatingBallState();
}

class _SessionFloatingBallState extends State<SessionFloatingBall> {
  static const double _size = 46;
  static const double _margin = 6;
  static const _idleAfter = Duration(seconds: 4);
  // The side it rests on and how far down, as fractions of the canvas.
  static Offset? _saved;
  Offset? _dragPos;
  bool _active = false;
  bool _idle = false;
  Timer? _idleTimer;

  Offset get _fraction => _saved ??= parseBallPosition(
      bind.mainGetLocalOption(key: kOptionMobileBallPosition));

  @override
  void initState() {
    super.initState();
    _wake();
  }

  @override
  void dispose() {
    _idleTimer?.cancel();
    super.dispose();
  }

  /// Fades the ball once it has been left alone, so it hides less of the
  /// remote screen.
  void _wake() {
    _idleTimer?.cancel();
    _idle = false;
    _idleTimer = Timer(_idleAfter, () {
      if (mounted) setState(() => _idle = true);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      child: LayoutBuilder(builder: (context, constraints) {
        final w = constraints.maxWidth;
        final h = constraints.maxHeight;
        final maxX = max(_margin, w - _size - _margin);
        final maxY =
            max(_margin, h - _size - _margin - widget.bottomReserved);
        final pos = _dragPos ??
            Offset(_margin + (maxX - _margin) * _fraction.dx,
                _margin + (maxY - _margin) * _fraction.dy);
        return Stack(children: [
          Positioned(
            left: pos.dx.clamp(_margin, maxX),
            top: pos.dy.clamp(_margin, maxY),
            child: GestureDetector(
              onTap: () {
                setState(_wake);
                _openPanel(context);
              },
              onLongPress: () {
                HapticFeedback.mediumImpact();
                setState(_wake);
                widget.actions.toggleKeyboard();
              },
              onPanStart: (_) => setState(() {
                _wake();
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
                final fraction = Offset(toRight ? 1 : 0, y);
                _saved = fraction;
                bind.mainSetLocalOption(
                    key: kOptionMobileBallPosition,
                    value: formatBallPosition(fraction));
                _dragPos = null;
                _active = false;
                _wake();
              }),
              child: AnimatedOpacity(
                duration: const Duration(milliseconds: 250),
                opacity: _active ? 0.95 : (_idle ? 0.3 : 0.6),
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

/// Frame rates offered in the panel.
const kSessionFpsChoices = [30, 60, 120];

/// The rates worth asking for on a screen that refreshes [refreshRate] times a
/// second, 0 when that is unknown. Frames the screen cannot show are sent and
/// decoded for nothing.
List<int> sessionFpsChoices(double refreshRate) => [
      for (final fps in kSessionFpsChoices)
        if (fps <= 60 || refreshRate <= 0 || fps <= refreshRate + 1) fps
    ];

/// The refresh rate of the screen the app is on, 0 when unknown.
double screenRefreshRate() {
  final views = WidgetsBinding.instance.platformDispatcher.views;
  return views.isEmpty ? 0 : views.first.display.refreshRate;
}

/// Brings a saved frame rate that the screen cannot show down to one it can.
Future<void> capSessionFpsToScreen(FFI ffi) async {
  final sessionId = ffi.sessionId;
  final quality = await bind.sessionGetImageQuality(sessionId: sessionId);
  if (quality != kRemoteImageQualityCustom) return;
  final saved = parseSessionFps(
      await bind.sessionGetOption(sessionId: sessionId, arg: 'custom-fps'));
  final most = sessionFpsChoices(screenRefreshRate()).last;
  if (saved > most) {
    await bind.sessionSetCustomFps(sessionId: sessionId, fps: most);
  }
}

/// What to give up first when the connection cannot carry everything.
///
/// The remote side lowers the bitrate before the frame rate, and how far it
/// lets the bitrate drop depends on the image quality asked for: least for
/// the best quality, most for the low one. The modes are the two ends of that.
enum SessionMode { speed, hd }

/// The mode the settings amount to, if any.
SessionMode? sessionModeOf(String? quality, int customQuality) {
  final preset = quality == kRemoteImageQualityCustom
      ? presetForCustomQuality(customQuality)
      : quality;
  if (preset == kRemoteImageQualityBest) return SessionMode.hd;
  if (preset == kRemoteImageQualityLow) return SessionMode.speed;
  return null;
}

/// The frame rate the modes ask for.
int sessionModeFps(double refreshRate) =>
    sessionFpsChoices(refreshRate).lastWhere((fps) => fps <= 60);

/// The custom quality that asks the remote for the same bitrate as a preset.
/// The remote takes a custom quality of 50 as the bitrate ratio 1, and its
/// presets are the ratios 0.5, 0.67 and 1.5.
int customQualityForPreset(String preset) => switch (preset) {
      kRemoteImageQualityLow => 25,
      kRemoteImageQualityBest => 75,
      _ => 34,
    };

String presetForCustomQuality(int quality) => quality < 30
    ? kRemoteImageQualityLow
    : (quality < 55 ? kRemoteImageQualityBalanced : kRemoteImageQualityBest);

/// Reads the saved `custom-fps` option as the nearest rate on offer.
int parseSessionFps(String? value) {
  final fps = int.tryParse(value ?? '') ?? kDefaultFps.toInt();
  return kSessionFpsChoices.reduce(
      (a, b) => (a - fps).abs() <= (b - fps).abs() ? a : b);
}

const kOptionMobileBallPosition = 'mobile-ball-position';

/// Reads a saved ball position: the side (0 left, 1 right) and how far down
/// (0 to 1). Anything unreadable gives the default, right side above centre.
Offset parseBallPosition(String value) {
  const fallback = Offset(1, 0.4);
  final parts = value.split(',');
  if (parts.length != 2) return fallback;
  final x = double.tryParse(parts[0]);
  final y = double.tryParse(parts[1]);
  if (x == null || y == null || !x.isFinite || !y.isFinite) return fallback;
  return Offset(x < 0.5 ? 0 : 1, y.clamp(0.0, 1.0));
}

String formatBallPosition(Offset fraction) =>
    '${fraction.dx.round()},${fraction.dy.toStringAsFixed(3)}';

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
  List<TTextMenu> _controls = const [];
  double _pointerSpeed = loadPointerSpeed();
  List<PanelActionEntry> _actionOrder = parsePanelActions(
      bind.mainGetLocalOption(key: kOptionMobilePanelActions));
  int _customQuality = 0;
  int _fps = kDefaultFps.toInt();
  bool _fpsAllowed = false;
  bool? _customOpen;

  /// The quality and frame rate chips. A mode sets both, so they stay folded
  /// away until asked for, or while the settings are no mode's.
  bool get _showQualityDetails =>
      _customOpen ??
      (_quality != null && sessionModeOf(_quality, _customQuality) == null);

  FFI get ffi => widget.ffi;

  @override
  void initState() {
    super.initState();
    _controls = widget.actions.controls();
    _loadQuality();
  }

  Future<void> _loadQuality() async {
    final sessionId = ffi.sessionId;
    final quality = await bind.sessionGetImageQuality(sessionId: sessionId);
    var custom = 0;
    var fps = kDefaultFps.toInt();
    if (quality == kRemoteImageQualityCustom) {
      final values =
          await bind.sessionGetCustomImageQuality(sessionId: sessionId);
      custom = values == null || values.isEmpty ? 50 : values[0];
      fps = parseSessionFps(
          await bind.sessionGetOption(sessionId: sessionId, arg: 'custom-fps'));
    }
    // The same limits as the custom image quality dialog.
    final allowed = versionCmp(ffi.ffiModel.pi.version, '1.2.2') >= 0 &&
        !(await bind.mainIsUsingPublicServer() && ffi.ffiModel.direct != true);
    if (!mounted) return;
    setState(() {
      _quality = quality;
      _customQuality = custom;
      _fps = fps;
      _fpsAllowed = allowed;
    });
  }

  /// The preset whose chip is lit; a custom quality lights the nearest one.
  String? get _preset => _quality == kRemoteImageQualityCustom
      ? presetForCustomQuality(_customQuality)
      : _quality;

  /// A preset always runs at the default frame rate on the remote, so any
  /// other rate is asked for as a custom quality of the same bitrate.
  Future<void> _setQuality(String preset) async {
    final sessionId = ffi.sessionId;
    if (_fps == kDefaultFps || !_fpsAllowed) {
      await bind.sessionSetImageQuality(sessionId: sessionId, value: preset);
      if (mounted) setState(() => _quality = preset);
      return;
    }
    final custom = customQualityForPreset(preset);
    await bind.sessionSetImageQuality(
        sessionId: sessionId, value: kRemoteImageQualityCustom);
    await bind.sessionSetCustomImageQuality(sessionId: sessionId, value: custom);
    await bind.sessionSetCustomFps(sessionId: sessionId, fps: _fps);
    if (!mounted) return;
    setState(() {
      _quality = kRemoteImageQualityCustom;
      _customQuality = custom;
    });
  }

  Future<void> _setMode(SessionMode mode) async {
    final sessionId = ffi.sessionId;
    final preset = mode == SessionMode.hd
        ? kRemoteImageQualityBest
        : kRemoteImageQualityLow;
    if (!_fpsAllowed) {
      await bind.sessionSetImageQuality(sessionId: sessionId, value: preset);
      if (!mounted) return;
      setState(() {
        _quality = preset;
        _fps = kDefaultFps.toInt();
      });
      return;
    }
    final custom = customQualityForPreset(preset);
    final fps = sessionModeFps(screenRefreshRate());
    await bind.sessionSetImageQuality(
        sessionId: sessionId, value: kRemoteImageQualityCustom);
    await bind.sessionSetCustomImageQuality(sessionId: sessionId, value: custom);
    await bind.sessionSetCustomFps(sessionId: sessionId, fps: fps);
    if (!mounted) return;
    setState(() {
      _quality = kRemoteImageQualityCustom;
      _customQuality = custom;
      _fps = fps;
    });
  }

  Widget _buildMode() {
    final mode = sessionModeOf(_quality, _customQuality);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 8,
          children: [
            for (final (value, label) in [
              (SessionMode.speed, 'Speed mode'),
              (SessionMode.hd, 'HD mode'),
            ])
              ChoiceChip(
                label: Text(translate(label)),
                selected: mode == value,
                onSelected: (_) => _setMode(value),
              ),
            ChoiceChip(
              label: Text(translate('Custom')),
              selected: _showQualityDetails,
              onSelected: (on) => setState(() => _customOpen = on),
            ),
          ],
        ),
        if (mode != null)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              translate(mode == SessionMode.speed
                  ? 'speed-mode-tip'
                  : 'hd-mode-tip'),
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
      ],
    );
  }

  Future<void> _setFps(int fps) async {
    final sessionId = ffi.sessionId;
    if (_quality != kRemoteImageQualityCustom) {
      if (fps == kDefaultFps) return;
      final custom = customQualityForPreset(_quality ?? '');
      await bind.sessionSetImageQuality(
          sessionId: sessionId, value: kRemoteImageQualityCustom);
      await bind.sessionSetCustomImageQuality(
          sessionId: sessionId, value: custom);
      _quality = kRemoteImageQualityCustom;
      _customQuality = custom;
    }
    await bind.sessionSetCustomFps(sessionId: sessionId, fps: fps);
    if (mounted) setState(() => _fps = fps);
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
              ..._buildDisplays(context),
              _sectionTitle(context, translate('Mode')),
              _buildMode(),
              if (_showQualityDetails) ...[
                _sectionTitle(context, translate('Image Quality')),
                _buildQuality(),
                if (_fpsAllowed) ...[
                  _sectionTitle(context, translate('FPS')),
                  _buildFps(),
                ],
              ],
              if (!ffi.ffiModel.touchMode) ...[
                _sectionTitle(context, translate('Pointer speed')),
                _buildPointerSpeed(),
              ],
              _sectionTitle(context, translate('Shortcuts')),
              _buildShortcuts(context),
              _sectionTitle(context, translate('Session options')),
              _buildToggles(),
              if (_controls.isNotEmpty) ...[
                _sectionTitle(context, translate('More')),
                _buildControls(),
              ],
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
          if (data.decodeMs != null)
            (translate('Decode and convert'), '${data.decodeMs} ms'),
          if (data.presentMs != null)
            (translate('Hand over to display'), '${data.presentMs} ms'),
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
    final keyboard = ffi.ffiModel.keyboard && !ffi.ffiModel.viewOnly;
    final privacyState = PrivacyModeState.find(widget.id);
    // Offered under the same conditions as in the display settings.
    final privacy = (ffi.ffiModel.pi.features.privacyMode &&
                ffi.ffiModel.keyboard) ||
            privacyState.value.isNotEmpty
        ? toolbarPrivacyMode(privacyState, context, widget.id, ffi)
            .where((m) => m.onChanged != null)
            .toList()
        : <TToggleMenu>[];
    // What each action does now, and whether it is lit. An action missing
    // here is not available in this session.
    final live = <String, (VoidCallback, bool)>{
      'keyboard': (() => _run(a.openKeyboard), false),
      'fn-keys': (() => _run(a.openFnPad), false),
      'send-text': (() => _run(a.sendText), false),
      'touch-mode': (
        () {
          a.toggleTouchMode();
          setState(() {});
        },
        false
      ),
      if (keyboard && !ffi.ffiModel.isPeerAndroid)
        'game-keys': (() => _run(a.toggleGameKeys), a.isGameKeysShown()),
      if (isSessionScreenshotSupported(ffi))
        'screenshot': (() => _run(() => takeSessionScreenshot(ffi)), false),
      if (a.isRecording() || isSessionRecordingOffered(ffi))
        'record': (() => _run(a.toggleRecording), a.isRecording()),
      if (privacy.isNotEmpty)
        'privacy-mode': (
          () => _togglePrivacyMode(privacy),
          privacy.any((m) => m.value)
        ),
      if (keyboard)
        'lock': (
          () => _run(() => bind.sessionLockScreen(sessionId: ffi.sessionId)),
          false
        ),
      if (ffi.ffiModel.permissions['restart'] != false &&
          const [kPeerPlatformLinux, kPeerPlatformWindows, kPeerPlatformMacOS]
              .contains(ffi.ffiModel.pi.platform))
        'restart': (
          () => _run(() => showRestartRemoteDevice(
              ffi.ffiModel.pi, widget.id, ffi.sessionId, ffi.dialogManager)),
          false
        ),
      'landscape': (() => _run(a.toggleLandscape), a.isLandscapeLocked()),
      'gestures': (() => _run(a.showGestureHelp), false),
      'file-transfer': (() => _run(a.openFileTransfer), false),
      'chat': (() => _run(a.openChat), false),
      'display-settings': (() => _run(a.showDisplayOptions), false),
    };
    final items = <(IconData, String, VoidCallback, bool)>[
      for (final entry in _actionOrder)
        if (entry.shown && live.containsKey(entry.id))
          () {
            final (_, icon, label) =
                kPanelQuickActions.firstWhere((e) => e.$1 == entry.id);
            final (onTap, lit) = live[entry.id]!;
            return switch (entry.id) {
              'touch-mode' => (
                  touch ? Icons.touch_app : Icons.mouse,
                  translate(touch ? 'Touch mode' : 'Trackpad mode'),
                  onTap,
                  lit
                ),
              'record' => (
                  lit ? Icons.stop_circle_outlined : icon,
                  translate(lit ? 'Stop session recording' : label),
                  onTap,
                  lit
                ),
              'landscape' => (
                  lit ? Icons.screen_lock_rotation : icon,
                  translate(label),
                  onTap,
                  false
                ),
              _ => (icon, translate(label), onTap, lit),
            };
          }(),
      (Icons.close, translate('Disconnect'), () => _run(a.disconnect), false),
    ];
    final accent = Theme.of(context).colorScheme.primary;
    return LayoutBuilder(builder: (context, constraints) {
      final columns = constraints.maxWidth >= 520 ? 10 : 5;
      final width = constraints.maxWidth / columns;
      return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Wrap(
        children: [
          for (final (icon, label, onTap, lit) in items)
            SizedBox(
              width: width,
              child: InkWell(
                borderRadius: BorderRadius.circular(10),
                onTap: onTap,
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Column(
                    children: [
                      Icon(icon, size: 26, color: lit ? accent : null),
                      const SizedBox(height: 4),
                      Text(label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: 12, color: lit ? accent : null)),
                    ],
                  ),
                ),
              ),
            ),
        ],
        ),
        Row(
          children: [
            Expanded(
              child: Text(translate('floating-ball-tip'),
                  style: TextStyle(
                      fontSize: 12, color: Theme.of(context).hintColor)),
            ),
            TextButton(
              style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap),
              onPressed: _editActions,
              child: Text(translate('Edit')),
            ),
          ],
        ),
      ]);
    });
  }

  Future<void> _editActions() async {
    final next = await showPanelActionsEditor(context, _actionOrder);
    if (next == null) return;
    await bind.mainSetLocalOption(
        key: kOptionMobilePanelActions, value: formatPanelActions(next));
    if (mounted) setState(() => _actionOrder = next);
  }

  /// Turns privacy mode off if it is on. To turn it on, a remote offering
  /// several ways of doing it is asked which.
  Future<void> _togglePrivacyMode(List<TToggleMenu> menus) async {
    final active = menus.where((m) => m.value).toList();
    var target = active.isNotEmpty ? active.first : menus.first;
    if (active.isEmpty && menus.length > 1) {
      final picked = await showDialog<TToggleMenu>(
        context: context,
        builder: (context) => SimpleDialog(
          title: Text(translate('Privacy mode')),
          children: [
            for (final m in menus)
              SimpleDialogOption(
                  onPressed: () => Navigator.pop(context, m), child: m.child),
          ],
        ),
      );
      if (picked == null || !mounted) return;
      target = picked;
    }
    _run(() => target.onChanged?.call(active.isEmpty));
  }

  /// One chip per remote display, the way Sunlogin offers "switch screen"
  /// among its quick actions.
  List<Widget> _buildDisplays(BuildContext context) {
    final pi = ffi.ffiModel.pi;
    final privacyMode = PrivacyModeState.find(widget.id);
    if (pi.displays.length <= 1 ||
        pi.currentDisplay == kAllDisplayValue ||
        (privacyMode.value.isNotEmpty &&
            !allowDisplaySwitchInPrivacyMode(pi, privacyMode.value))) {
      return const [];
    }
    return [
      _sectionTitle(context, translate('Monitor')),
      Wrap(
        spacing: 8,
        children: [
          for (var i = 0; i < pi.displays.length; i++)
            ChoiceChip(
              avatar: const Icon(Icons.monitor, size: 18),
              label: Text('${i + 1}'),
              selected: i == pi.currentDisplay,
              onSelected: (_) {
                if (i == pi.currentDisplay) return;
                _run(() => openMonitorInTheSameTab(i, ffi, pi));
              },
            ),
        ],
      ),
    ];
  }

  Widget _buildPointerSpeed() {
    return Row(
      children: [
        Text(translate('Slow'), style: const TextStyle(fontSize: 12)),
        Expanded(
          child: Slider(
            value: _pointerSpeed,
            min: kPointerSpeedMin,
            max: kPointerSpeedMax,
            divisions: 6,
            label: '${_pointerSpeed.toStringAsFixed(2)}x',
            onChanged: (v) => setState(() => _pointerSpeed = v),
            onChangeEnd: (v) => bind.mainSetLocalOption(
                key: kOptionMobilePointerSpeed, value: v.toString()),
          ),
        ),
        Text(translate('Fast'), style: const TextStyle(fontSize: 12)),
      ],
    );
  }

  Widget _buildControls() {
    return Column(
      children: [
        for (final m in _controls)
          ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            visualDensity: VisualDensity.compact,
            title: m.getChild(),
            onTap: m.onPressed == null ? null : () => _run(m.onPressed!),
          ),
      ],
    );
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
            selected: _preset == value,
            onSelected: (_) => _setQuality(value),
          ),
      ],
    );
  }

  Widget _buildFps() {
    return Wrap(
      spacing: 8,
      children: [
        for (final fps in sessionFpsChoices(screenRefreshRate()))
          ChoiceChip(
            label: Text('$fps'),
            selected: _fps == fps,
            onSelected: (_) => _setFps(fps),
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
        final videoTexture = widget.actions.videoTexture;
        return Column(
          children: [
            SwitchListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: Text(translate('Toolbar')),
              value: widget.actions.isBarShown(),
              onChanged: (_) => setState(widget.actions.toggleBar),
            ),
            if (isIOS)
              SwitchListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: Text(translate('Keep running in background')),
                subtitle: Text(translate('background-keep-alive-tip')),
                value: BackgroundKeepAlive.enabled,
                onChanged: (on) async {
                  await BackgroundKeepAlive.setEnabled(on);
                  if (mounted) setState(() {});
                },
              ),
            if (isIOS)
              SwitchListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: Text(translate('Phone-friendly resolution')),
                subtitle: Text(translate('phone-resolution-tip')),
                value: isPhoneResolutionEnabled(),
                onChanged: (on) async {
                  await bind.mainSetLocalOption(
                      key: kOptionMobilePhoneResolution, value: on ? 'Y' : '');
                  if (on) {
                    await applyPhoneResolution(ffi);
                  } else {
                    await restoreRemoteResolution(ffi);
                  }
                  if (mounted) setState(() {});
                },
              ),
            if (videoTexture != null)
              SwitchListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: Text(translate('Low-latency rendering')),
                subtitle: Text(translate('texture-render-tip')),
                value: videoTexture.enabled,
                onChanged: (on) {
                  bind.mainSetLocalOption(
                      key: kOptionMobileTextureRender, value: on ? 'Y' : 'N');
                  setState(() => videoTexture.setEnabled(on));
                },
              ),
            if (videoTexture != null)
              SwitchListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: Text(translate('Zero-copy display')),
                subtitle: Text(translate('zero-copy-tip')),
                value:
                    bind.mainGetLocalOption(key: kOptionMobileZeroCopy) == 'Y',
                onChanged: (on) async {
                  await bind.mainSetLocalOption(
                      key: kOptionMobileZeroCopy, value: on ? 'Y' : '');
                  if (mounted) setState(() {});
                },
              ),
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
            option(false, Icons.mouse, translate('Trackpad mode'), [
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
