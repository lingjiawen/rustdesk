import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_hbb/models/platform_model.dart';
import 'package:flutter_hbb/models/user_model.dart';
import 'package:get/get.dart';

import '../common.dart';

class ServerProfile {
  String name;
  String idServer;
  String relayServer;
  String apiServer;
  String key;

  ServerProfile({
    required this.name,
    this.idServer = '',
    this.relayServer = '',
    this.apiServer = '',
    this.key = '',
  });

  factory ServerProfile.fromJson(Map<String, dynamic> json) {
    return ServerProfile(
      name: (json['name'] ?? '').toString().trim(),
      idServer: (json['id'] ?? '').toString().trim(),
      relayServer: (json['relay'] ?? '').toString().trim(),
      apiServer: (json['api'] ?? '').toString().trim(),
      key: (json['key'] ?? '').toString().trim(),
    );
  }

  Map<String, String> toJson() => {
        'name': name,
        'id': idServer,
        'relay': relayServer,
        'api': apiServer,
        'key': key,
      };
}

/// Named ID/relay/API profiles. Each one keeps its own login token so the
/// account chip can show `username@name` and switch without typing again.
class ServerProfiles {
  static const kProfiles = 'server_profiles';
  static const kActive = 'active_server_name';
  static const kSessions = 'server_sessions';

  static final RxString activeName = ''.obs;
  static final RxList<ServerProfile> profiles = <ServerProfile>[].obs;
  static final Map<String, Map<String, String>> sessions = {};

  static Future<void> load() async {
    UserModel.onLocalReset = forgetActiveSession;
    profiles.assignAll(_decodeProfiles(bind.mainGetLocalOption(key: kProfiles)));
    activeName.value = bind.mainGetLocalOption(key: kActive).trim();
    sessions
      ..clear()
      ..addAll(_decodeSessions(bind.mainGetLocalOption(key: kSessions)));
  }

  static ServerProfile? find(String name) {
    final trimmed = name.trim();
    for (final profile in profiles) {
      if (profile.name == trimmed) return profile;
    }
    return null;
  }

  static String? sessionUser(String name) {
    final raw = sessions[name.trim()]?['user_info'] ?? '';
    if (raw.isEmpty) return null;
    try {
      final map = jsonDecode(raw);
      if (map is Map) {
        final user = (map['name'] ?? '').toString().trim();
        if (user.isNotEmpty) return user;
      }
    } catch (e) {
      debugPrint('server profile session user: $e');
    }
    return null;
  }

  /// `camenling@auth` when logged in and a name is selected.
  static String headerLabel() {
    if (!gFFI.userModel.isLogin) return '未登录';
    final user = gFFI.userModel.userName.value.trim();
    if (user.isEmpty) return '未登录';
    final name = activeName.value.trim();
    if (name.isEmpty) return user;
    return '$user@$name';
  }

  static String labelFor(String name) {
    final user = sessionUser(name);
    if (user == null) return name;
    return '$user@$name';
  }

  static String? validateName(String name) {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return '请填写名称';
    if (trimmed.contains('@')) return '名称不能包含 @';
    return null;
  }

  static Future<String?> upsert(ServerProfile profile) async {
    final name = profile.name.trim();
    final err = validateName(name);
    if (err != null) return err;
    profile.name = name;
    final previous = find(name);
    if (previous != null &&
        (previous.apiServer != profile.apiServer ||
            previous.idServer != profile.idServer ||
            previous.relayServer != profile.relayServer ||
            previous.key != profile.key)) {
      sessions.remove(name);
      await _saveSessions();
    }
    final next = profiles.toList();
    final index = next.indexWhere((e) => e.name == name);
    if (index >= 0) {
      next[index] = profile;
    } else {
      next.add(profile);
    }
    profiles.assignAll(next);
    await _saveProfiles();
    activeName.value = name;
    await bind.mainSetLocalOption(key: kActive, value: name);
    await capture();
    return null;
  }

  static Future<void> remove(String name) async {
    final trimmed = name.trim();
    profiles.removeWhere((e) => e.name == trimmed);
    sessions.remove(trimmed);
    await _saveProfiles();
    await _saveSessions();
    if (activeName.value == trimmed) {
      activeName.value = '';
      await bind.mainSetLocalOption(key: kActive, value: '');
    }
  }

  /// Apply [name] and restore that profile's saved login.
  /// Returns true when a saved account was restored.
  static Future<bool> switchTo(String name) async {
    final trimmed = name.trim();
    final profile = find(trimmed);
    if (profile == null) return false;
    if (trimmed == activeName.value.trim()) {
      await _writeEndpoints(profile);
      return gFFI.userModel.isLogin;
    }
    await capture();
    await _writeEndpoints(profile);
    activeName.value = trimmed;
    await bind.mainSetLocalOption(key: kActive, value: trimmed);
    final token = sessions[trimmed]?['access_token'] ?? '';
    if (token.isNotEmpty) {
      await bind.mainSetLocalOption(key: 'access_token', value: token);
      await bind.mainSetLocalOption(
          key: 'user_info', value: sessions[trimmed]?['user_info'] ?? '');
      gFFI.userModel.applyLocalUserInfo();
      gFFI.userModel.refreshCurrentUser();
      return true;
    }
    await gFFI.userModel.reset(resetOther: true);
    return false;
  }

  /// Drop the saved login on the current server and log out, so another
  /// account can sign in on the same server.
  static Future<void> reloginHere() async {
    await forgetActiveSession();
    await gFFI.userModel.logOut();
  }

  static Future<void> capture() async {
    final name = activeName.value.trim();
    if (name.isEmpty) return;
    final token = bind.mainGetLocalOption(key: 'access_token');
    if (token.isEmpty) return;
    sessions[name] = {
      'access_token': token,
      'user_info': bind.mainGetLocalOption(key: 'user_info'),
    };
    await _saveSessions();
  }

  static Future<void> forgetActiveSession() async {
    final name = activeName.value.trim();
    if (name.isEmpty) return;
    if (sessions.remove(name) != null) {
      await _saveSessions();
    }
  }

  static Future<void> _writeEndpoints(ServerProfile profile) async {
    await bind.mainSetOption(
        key: 'custom-rendezvous-server', value: profile.idServer);
    await bind.mainSetOption(key: 'relay-server', value: profile.relayServer);
    await bind.mainSetOption(key: 'api-server', value: profile.apiServer);
    await bind.mainSetOption(key: 'key', value: profile.key);
  }

  static List<ServerProfile> _decodeProfiles(String raw) {
    if (raw.isEmpty) return [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return [];
      return decoded
          .whereType<Map>()
          .map((e) => ServerProfile.fromJson(Map<String, dynamic>.from(e)))
          .where((e) => e.name.isNotEmpty)
          .toList();
    } catch (e) {
      debugPrint('server profiles: $e');
      return [];
    }
  }

  static Map<String, Map<String, String>> _decodeSessions(String raw) {
    if (raw.isEmpty) return {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return {};
      final out = <String, Map<String, String>>{};
      decoded.forEach((key, value) {
        if (value is Map) {
          out[key.toString()] = value.map(
              (k, v) => MapEntry(k.toString(), v?.toString() ?? ''));
        }
      });
      return out;
    } catch (e) {
      debugPrint('server sessions: $e');
      return {};
    }
  }

  static Future<void> _saveProfiles() async {
    await bind.mainSetLocalOption(
        key: kProfiles,
        value: jsonEncode(profiles.map((e) => e.toJson()).toList()));
  }

  static Future<void> _saveSessions() async {
    await bind.mainSetLocalOption(
        key: kSessions, value: jsonEncode(sessions));
  }
}
