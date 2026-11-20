/// Sends what the user copies on the phone to the remote side.
///
/// iOS asks the user every time an app reads clipboard content that another
/// app or another device put there, also when the last answer was no. So the
/// clipboard is read once for each change, and not at all for a change this
/// session caused: with Handoff, the remote Mac's clipboard comes back to the
/// phone by itself a moment after either side has synced a text.
class IosClipboardWatcher {
  IosClipboardWatcher({
    required this.changeCount,
    required this.hasText,
    required this.readText,
    required this.send,
    required this.isForeground,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  /// How often the clipboard has changed, null when unknown. Free to ask.
  final Future<int?> Function() changeCount;

  /// Whether there is text on the clipboard. Free to ask.
  final Future<bool> Function() hasText;

  /// The text on the clipboard. This is what makes iOS ask the user.
  final Future<String> Function() readText;
  final void Function(String text) send;
  final bool Function() isForeground;
  final DateTime Function() _now;

  static const _echoWindow = Duration(seconds: 4);

  int? _seen;
  String _lastText = '';
  DateTime? _quietUntil;
  bool _busy = false;

  Future<void> poll() async {
    if (_busy || !isForeground()) return;
    _busy = true;
    try {
      final count = await changeCount();
      if (count == null || count == _seen) return;
      _seen = count;
      final quietUntil = _quietUntil;
      if (quietUntil != null && _now().isBefore(quietUntil)) return;
      if (!await hasText()) return;
      final text = await readText();
      if (text.isEmpty || text == _lastText) return;
      _lastText = text;
      _quietUntil = _now().add(_echoWindow);
      send(text);
    } catch (_) {
    } finally {
      _busy = false;
    }
  }

  /// The session itself has just put [text] on the clipboard.
  Future<void> wroteLocal(String text) async {
    _lastText = text;
    _quietUntil = _now().add(_echoWindow);
    try {
      _seen = await changeCount() ?? _seen;
    } catch (_) {}
  }
}
