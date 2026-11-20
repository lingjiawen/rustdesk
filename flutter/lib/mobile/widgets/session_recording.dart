import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../common.dart';
import '../../consts.dart';
import '../../models/model.dart';
import '../../models/platform_model.dart';

const _iosFiles = MethodChannel('rustdesk/ios_files');

bool isSessionRecordingOffered(FFI ffi) =>
    bind.mainGetLocalOption(key: kOptionHideRecordingButton) != 'Y' &&
    ffi.ffiModel.permissions['recording'] != false;

/// Starts and stops recording the session, and moves each finished recording
/// to the photo library.
class SessionRecordingWatcher {
  SessionRecordingWatcher(this.ffi) {
    ffi.recordingModel.addListener(_update);
  }

  final FFI ffi;

  /// When the recording in progress began; null while there is none.
  final since = ValueNotifier<DateTime?>(null);

  /// `RecordingModel.toggle` does nothing on iOS.
  Future<void> toggle() async {
    final start = since.value == null;
    // A recording can only begin with a key frame.
    if (start) await sessionRefreshVideo(ffi.sessionId, ffi.ffiModel.pi);
    await bind.sessionRecordScreen(sessionId: ffi.sessionId, start: start);
  }

  void _update() {
    final began = since.value;
    if (ffi.recordingModel.start == (began != null)) return;
    if (began != null) exportSessionRecordings(began);
    since.value = began == null ? DateTime.now() : null;
  }

  void dispose() {
    ffi.recordingModel.removeListener(_update);
    final began = since.value;
    if (began != null) exportSessionRecordings(began, sessionClosed: true);
    since.dispose();
  }
}

/// How long the session has been recording. A tap stops it.
class SessionRecordingBadge extends StatelessWidget {
  const SessionRecordingBadge(
      {Key? key, required this.since, required this.onStop})
      : super(key: key);

  final ValueListenable<DateTime?> since;
  final VoidCallback onStop;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<DateTime?>(
      valueListenable: since,
      builder: (context, began, _) {
        if (began == null) return const SizedBox.shrink();
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onStop,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
                color: Colors.black.withAlpha(150),
                borderRadius: BorderRadius.circular(14)),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Container(
                width: 8,
                height: 8,
                decoration: const BoxDecoration(
                    color: Colors.red, shape: BoxShape.circle),
              ),
              const SizedBox(width: 6),
              StreamBuilder<void>(
                stream: Stream.periodic(const Duration(seconds: 1)),
                builder: (context, _) {
                  final s = DateTime.now().difference(began).inSeconds;
                  final mm = (s ~/ 60).toString().padLeft(2, '0');
                  final ss = (s % 60).toString().padLeft(2, '0');
                  return Text('$mm:$ss',
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 12,
                          fontFeatures: [FontFeature.tabularFigures()]));
                },
              ),
              const SizedBox(width: 6),
              const Icon(Icons.stop, size: 14, color: Colors.white),
            ]),
          ),
        );
      },
    );
  }
}

/// Where in an MP4 `moov` box, header included, the H265 sample entries are
/// named `hev1`.
List<int> findHev1SampleEntries(Uint8List moov) {
  const containers = {'moov', 'trak', 'mdia', 'minf', 'stbl'};
  final data = ByteData.sublistView(moov);
  String type(int at) => String.fromCharCodes(moov, at + 4, at + 8);
  final found = <int>[];
  void walk(int from, int end) {
    for (var at = from; at + 8 <= end;) {
      final size = data.getUint32(at);
      if (size < 8 || at + size > end) return;
      if (containers.contains(type(at))) {
        walk(at + 8, at + size);
      } else if (type(at) == 'stsd') {
        // Version, flags and the entry count come before the entries.
        for (var entry = at + 16; entry + 8 <= at + size;) {
          final entrySize = data.getUint32(entry);
          if (entrySize < 8) break;
          if (type(entry) == 'hev1') found.add(entry + 4);
          entry += entrySize;
        }
      }
      at += size;
    }
  }

  walk(0, moov.length);
  return found;
}

/// Renames a finished recording's H265 sample entries from `hev1`, which is
/// what the recorder writes, to `hvc1`. Apple's players and the photo library
/// refuse `hev1`; the video itself is the same under either name.
Future<void> retagHevcForApple(String path) async {
  // Opened for reading and writing, with nothing truncated.
  final file = await File(path).open(mode: FileMode.append);
  try {
    final length = await file.length();
    for (var at = 0; at + 8 <= length;) {
      await file.setPosition(at);
      final head = ByteData.sublistView(await file.read(16));
      if (head.lengthInBytes < 8) return;
      var size = head.getUint32(0);
      if (size == 0) size = length - at;
      if (size == 1 && head.lengthInBytes == 16) size = head.getUint64(8);
      if (size < 8) return;
      if (head.getUint32(4) == 0x6d6f6f76 /* moov */) {
        await file.setPosition(at);
        final moov = await file.read(size);
        for (final entry in findHev1SampleEntries(moov)) {
          await file.setPosition(at + entry);
          await file.writeString('hvc1');
        }
        return;
      }
      at += size;
    }
  } finally {
    await file.close();
  }
}

/// The recordings written since [since], once they have stopped growing.
Future<List<String>> _finishedRecordings(DateTime since) async {
  final dir = Directory(bind.mainVideoSaveDirectory(root: false));
  final from = since.subtract(const Duration(seconds: 1));
  Future<Map<String, int>> sizes() async {
    final found = <String, int>{};
    if (!await dir.exists()) return found;
    await for (final f in dir.list()) {
      final name = f.uri.pathSegments.last;
      if (f is! File ||
          !name.startsWith('outgoing_') ||
          !(name.endsWith('.mp4') || name.endsWith('.webm'))) {
        continue;
      }
      try {
        if (!(await f.lastModified()).isBefore(from)) {
          found[f.path] = await f.length();
        }
      } on FileSystemException {
        // The recorder removes a recording that is too short to keep.
      }
    }
    return found;
  }

  // The recorder closes its file a moment after the recording is stopped.
  var last = await sizes();
  for (var i = 0; i < 15; i++) {
    await Future.delayed(const Duration(milliseconds: 300));
    final now = await sizes();
    if (mapEquals(now, last)) break;
    last = now;
  }
  return last.keys.toList()..sort();
}

/// Moves the recordings made since [since] to the photo library, which takes
/// MP4 only. What cannot go there stays in the app's folder, which the Files
/// app shows.
Future<void> exportSessionRecordings(DateTime since,
    {bool sessionClosed = false}) async {
  var message = 'Saved to Photos';
  try {
    // A closing session takes a moment to let go of its recording.
    if (sessionClosed) await Future.delayed(const Duration(seconds: 1));
    final files = await _finishedRecordings(since);
    if (files.isEmpty) return;
    for (final path in files) {
      if (!path.endsWith('.mp4')) {
        message = 'recording-webm-tip';
        continue;
      }
      await retagHevcForApple(path);
      final result =
          await _iosFiles.invokeMethod<String>('save_video', {'path': path});
      if (result == 'denied') {
        message = 'recording-photos-denied-tip';
        break;
      }
      if (result != null && result.isNotEmpty) message = result;
    }
  } catch (e) {
    message = e.toString();
  }
  showToast(translate(message), timeout: const Duration(seconds: 5));
}
