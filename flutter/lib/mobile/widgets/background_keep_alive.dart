import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../../common.dart';
import '../../models/platform_model.dart';

const kOptionMobileBackgroundKeepAlive = 'mobile-background-keep-alive';

/// The remote side drops a connection it has not heard from for 30 seconds.
const _kConnectionLostAfter = Duration(seconds: 28);

/// Keeps the app, and with it the open sessions, running in the background
/// when the user asks for it.
class BackgroundKeepAlive {
  static const _channel = MethodChannel('rustdesk/ios_background');
  static int _sessions = 0;

  static bool get enabled =>
      bind.mainGetLocalOption(key: kOptionMobileBackgroundKeepAlive) == 'Y';

  static void sessionOpened() {
    _sessions++;
    _apply();
  }

  static void sessionClosed() {
    if (_sessions > 0) _sessions--;
    _apply();
  }

  static Future<void> setEnabled(bool on) async {
    await bind.mainSetLocalOption(
        key: kOptionMobileBackgroundKeepAlive, value: on ? 'Y' : '');
    await _apply();
  }

  static Future<void> _apply() async {
    if (!isIOS) return;
    try {
      await _channel
          .invokeMethod('keep_alive', {'on': _sessions > 0 && enabled});
    } catch (e) {
      debugPrint('Failed to set background keep-alive: $e');
    }
  }
}

/// Tells whether a session's connection outlived a stay in the background.
///
/// The remote side drops a connection it has not heard from for 30 seconds.
/// So what counts is how long the app was suspended, not how long it was out
/// of sight: iOS lets it run on for about 30 seconds first, and with
/// [BackgroundKeepAlive] for as long as it stays away.
class SessionBackgroundGuard {
  SessionBackgroundGuard({DateTime Function()? now})
      : _now = now ?? DateTime.now;

  final DateTime Function() _now;
  DateTime? _lastAlive;
  Timer? _aliveTimer;

  void onBackground() {
    if (_aliveTimer != null) return;
    _lastAlive = _now();
    // Stops ticking while the app is suspended.
    _aliveTimer = Timer.periodic(
        const Duration(seconds: 1), (_) => _lastAlive = _now());
  }

  /// Returns whether the connection was lost meanwhile and has to be replaced.
  bool onForeground() {
    final lastAlive = _lastAlive;
    dispose();
    _lastAlive = null;
    return lastAlive != null &&
        _now().difference(lastAlive) > _kConnectionLostAfter;
  }

  void dispose() {
    _aliveTimer?.cancel();
    _aliveTimer = null;
  }
}
