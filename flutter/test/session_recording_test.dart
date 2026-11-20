import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_hbb/mobile/widgets/session_recording.dart';
import 'package:flutter_test/flutter_test.dart';

Uint8List box(String type, List<int> payload) {
  final size = ByteData(4)..setUint32(0, payload.length + 8);
  return Uint8List.fromList(
      [...size.buffer.asUint8List(), ...type.codeUnits, ...payload]);
}

/// A `moov` box with one video track whose sample entry is named [entry].
Uint8List moov(String entry) {
  final stsd =
      box('stsd', [0, 0, 0, 0, 0, 0, 0, 1, ...box(entry, List.filled(78, 0))]);
  return box('moov', box('trak', box('mdia', box('minf', box('stbl', stsd)))));
}

int count(List<int> data, String text) =>
    text.allMatches(String.fromCharCodes(data)).length;

void main() {
  test('an H265 recording is renamed to what Apple players take', () async {
    final dir = await Directory.systemTemp.createTemp('recording_test');
    addTearDown(() => dir.delete(recursive: true));
    // The recorder leaves its first, provisional header inside the media
    // data; only the real one at the end may change.
    final media = box('mdat', moov('hev1'));
    final file = File('${dir.path}/h265.mp4');
    await file.writeAsBytes(
        [...box('ftyp', 'isom'.codeUnits), ...media, ...moov('hev1')]);
    await retagHevcForApple(file.path);
    final bytes = await file.readAsBytes();
    expect(bytes.sublist(12, 12 + media.length), media);
    expect(count(bytes.sublist(12 + media.length), 'hev1'), 0);
    expect(count(bytes.sublist(12 + media.length), 'hvc1'), 1);

    final h264 = File('${dir.path}/h264.mp4');
    final before = [...box('ftyp', 'isom'.codeUnits), ...moov('avc1')];
    await h264.writeAsBytes(before);
    await retagHevcForApple(h264.path);
    expect(await h264.readAsBytes(), before);
  });

  testWidgets('the badge shows the time recorded and stops on a tap',
      (tester) async {
    final since = ValueNotifier<DateTime?>(null);
    var stops = 0;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Center(
          child: SessionRecordingBadge(since: since, onStop: () => stops++),
        ),
      ),
    ));
    expect(find.byIcon(Icons.stop), findsNothing);

    since.value = DateTime.now().subtract(const Duration(seconds: 65));
    await tester.pump();
    await tester.tap(find.textContaining(RegExp(r'^01:0[56]$')));
    expect(stops, 1);
  });
}
