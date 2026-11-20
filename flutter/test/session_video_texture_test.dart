import 'package:flutter/material.dart';
import 'package:flutter_hbb/mobile/widgets/session_video_texture.dart';
import 'package:flutter_test/flutter_test.dart';

class _Host implements VideoTextureHost {
  final log = <String>[];
  var textures = 0;

  @override
  Future<({int id, int ptr})?> create() async {
    textures++;
    log.add('create');
    return (id: 7, ptr: 4096);
  }

  @override
  Future<void> accept(int id, int width, int height) async =>
      log.add('accept ${width}x$height');

  @override
  Future<void> destroy(int id) async => log.add('destroy $id');

  @override
  void attach(int ptr) => log.add('attach $ptr');
}

void main() {
  test('the texture takes over after a soft-rendered frame of its size',
      () async {
    final host = _Host();
    final texture = SessionVideoTexture(host, enabled: true);

    // The first frame of a connection has to be soft-rendered.
    texture.onSoftFrame(1920, 1080);
    await pumpEventQueue();
    expect(host.log, isEmpty);
    expect(texture.textureId.value, isNull);

    texture.setWaiting(false);
    await pumpEventQueue();
    expect(host.log, ['create', 'attach 4096', 'accept 1920x1080']);
    expect(texture.textureId.value, 7);

    // A frame of a new size was refused by the texture and soft-rendered.
    texture.onSoftFrame(2560, 1440);
    await pumpEventQueue();
    expect(host.log.last, 'accept 2560x1440');

    // A reconnection needs its first frame soft-rendered again.
    texture.setWaiting(true);
    await pumpEventQueue();
    expect(host.log.last, 'accept 0x0');
    texture.setWaiting(false);
    await pumpEventQueue();
    expect(host.log.last, 'accept 2560x1440');

    texture.setEnabled(false);
    await pumpEventQueue();
    expect(host.log.sublist(host.log.length - 2), ['attach 0', 'destroy 7']);
    expect(texture.textureId.value, isNull);
    expect(host.textures, 1);
  });

  test('falls back when the texture keeps refusing frames of its size',
      () async {
    final host = _Host();
    var failed = 0;
    final texture =
        SessionVideoTexture(host, enabled: true, onFailed: () => failed++);
    texture.setWaiting(false);
    texture.onSoftFrame(1280, 720);
    await pumpEventQueue();
    expect(texture.textureId.value, 7);

    for (var i = 0; i < 5; i++) {
      texture.onSoftFrame(1280, 720);
    }
    await pumpEventQueue();
    expect(failed, 0);

    texture.onSoftFrame(1280, 720);
    await pumpEventQueue();
    expect(failed, 1);
    expect(texture.enabled, isFalse);
    expect(texture.textureId.value, isNull);
    expect(host.log.last, 'destroy 7');
  });

  test('the texture lies where the image painter draws the image', () {
    // The painter scales the canvas by 0.5 and draws at whole image pixels.
    expect(videoTextureRect(-100.6, 40.2, 0.5, 1920, 1080),
        const Rect.fromLTWH(-50, 20, 960, 540));
    expect(videoTextureRect(double.nan, 0, 1, 10, 10), isNull);
  });
}
