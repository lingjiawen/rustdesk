import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../common.dart';
import '../../models/model.dart';
import '../../models/platform_model.dart';

const kOptionMobileTextureRender = 'mobile-texture-render';

/// Makes the decoder leave frames on the GPU for the texture to show as they
/// are. Read when a decoder is created, so it takes a new connection to apply.
const kOptionMobileZeroCopy = 'mobile-zero-copy';

/// A soft-rendered frame or two may already be on their way when a texture
/// starts taking frames of their size. More than this many mean it does not
/// take them.
const _kStraySoftFrames = 5;

/// The native half of a video texture.
abstract class VideoTextureHost {
  /// A new texture: Flutter draws it by `id`, the video decoder writes to it
  /// by `ptr`.
  Future<({int id, int ptr})?> create();

  /// The only frame size the texture takes from now on; none when [width] is
  /// 0. Frames it does not take are soft-rendered.
  Future<void> accept(int id, int width, int height);

  Future<void> destroy(int id);

  /// Sends the session's frames to the texture at [ptr], or all of them back
  /// to the soft renderer when it is 0.
  void attach(int ptr);
}

class _IosVideoTextureHost implements VideoTextureHost {
  _IosVideoTextureHost(this.sessionId);

  static const _channel = MethodChannel('rustdesk/ios_video_texture');
  final SessionID sessionId;

  @override
  Future<({int id, int ptr})?> create() async {
    final made = await _channel.invokeMapMethod<String, dynamic>('create');
    final id = made?['id'];
    final ptr = made?['ptr'];
    if (id is! int || ptr is! int || ptr == 0) return null;
    return (id: id, ptr: ptr);
  }

  @override
  Future<void> accept(int id, int width, int height) => _channel
      .invokeMethod('accept', {'id': id, 'width': width, 'height': height});

  @override
  Future<void> destroy(int id) => _channel.invokeMethod('destroy', {'id': id});

  @override
  void attach(int ptr) =>
      platformFFI.registerPixelbufferTexture(sessionId, 0, ptr);
}

/// Shows a session's video through a native texture instead of decoding every
/// frame into an image in Dart.
///
/// The soft renderer stays in charge of the layout: the canvas, the gestures
/// and the cursor all go by the size of the last image it produced. So the
/// first frame of a connection, and the first one of any new size, are still
/// soft-rendered, and the texture is drawn over that image, in its place.
class SessionVideoTexture {
  SessionVideoTexture(this.host, {required bool enabled, this.onFailed})
      : _enabled = enabled;

  factory SessionVideoTexture.forSession(FFI ffi) {
    final texture = SessionVideoTexture(
      _IosVideoTextureHost(ffi.sessionId),
      enabled: bind.mainGetLocalOption(key: kOptionMobileTextureRender) != 'N',
      onFailed: () => showToast(translate('texture-render-failed-tip')),
    );
    void onImage() {
      final image = ffi.imageModel.image;
      if (image != null) texture.onSoftFrame(image.width, image.height);
    }

    ffi.imageModel.addListener(onImage);
    final waiting = ffi.ffiModel.waitForFirstImage;
    texture.setWaiting(waiting.value);
    final subscription = waiting.listen(texture.setWaiting);
    texture._detach = () {
      ffi.imageModel.removeListener(onImage);
      subscription.cancel();
    };
    return texture;
  }

  final VideoTextureHost host;
  final VoidCallback? onFailed;

  /// The texture to draw over the soft-rendered image, while there is one.
  final textureId = ValueNotifier<int?>(null);

  bool _enabled;
  bool _failed = false;
  bool _waiting = true;
  bool _disposed = false;
  ({int width, int height})? _frame;
  ({int width, int height})? _accepted;
  ({int id, int ptr})? _texture;
  int _strays = 0;
  bool _busy = false;
  bool _dirty = false;
  VoidCallback? _detach;

  bool get enabled => _enabled && !_failed;

  void setEnabled(bool on) {
    _enabled = on;
    _failed = false;
    _sync();
  }

  /// A frame of this size was soft-rendered.
  void onSoftFrame(int width, int height) {
    final size = (width: width, height: height);
    if (_accepted == size && ++_strays > _kStraySoftFrames) _fail();
    _frame = size;
    if (_enabled) _sync();
  }

  /// Whether the session waits for the first frame of a connection, which
  /// has to be soft-rendered for the session to notice it.
  void setWaiting(bool waiting) {
    _waiting = waiting;
    _sync();
  }

  Future<void> dispose() {
    _disposed = true;
    _detach?.call();
    return _sync();
  }

  void _fail() {
    if (_failed) return;
    _failed = true;
    onFailed?.call();
  }

  Future<void> _sync() async {
    _dirty = true;
    if (_busy) return;
    _busy = true;
    try {
      while (_dirty) {
        _dirty = false;
        await _step();
      }
    } catch (e) {
      debugPrint('Video texture: $e');
      _fail();
    } finally {
      _busy = false;
    }
  }

  Future<void> _step() async {
    var texture = _texture;
    if (!_enabled || _failed || _disposed) {
      if (texture == null) return;
      _texture = null;
      _accepted = null;
      textureId.value = null;
      host.attach(0);
      await host.destroy(texture.id);
      return;
    }
    final size = _waiting ? null : _frame;
    if (size == null) {
      if (texture != null && _accepted != null) {
        _accepted = null;
        await host.accept(texture.id, 0, 0);
      }
      return;
    }
    if (texture == null) {
      texture = await host.create();
      if (texture == null) {
        _fail();
        return;
      }
      _texture = texture;
      host.attach(texture.ptr);
      textureId.value = texture.id;
    }
    if (_accepted != size) {
      _strays = 0;
      _accepted = size;
      await host.accept(texture.id, size.width, size.height);
    }
  }
}

/// Where `ImagePainter` draws an image of [width] x [height] given the same
/// [x], [y] and [scale]: it scales the canvas and draws at whole image pixels.
Rect? videoTextureRect(double x, double y, double scale, int width, int height) {
  if (!x.isFinite || !y.isFinite || !scale.isFinite || scale <= 0) return null;
  return Rect.fromLTWH(
      x.toInt() * scale, y.toInt() * scale, width * scale, height * scale);
}

/// Draws the session's texture over [child], the `ImagePaint` whose image it
/// stands in for. Until the texture has a frame it shows nothing, and the
/// image stays visible.
class SessionVideoTextureLayer extends StatelessWidget {
  const SessionVideoTextureLayer(
      {Key? key,
      required this.texture,
      required this.ffiModel,
      required this.child})
      : super(key: key);

  final SessionVideoTexture? texture;
  final FfiModel ffiModel;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final texture = this.texture;
    if (texture == null) return child;
    return ValueListenableBuilder<int?>(
      valueListenable: texture.textureId,
      builder: (context, id, _) {
        if (id == null) return child;
        final image = Provider.of<ImageModel>(context).image;
        final c = Provider.of<CanvasModel>(context);
        if (image == null) return child;
        // The same geometry as `ImagePaint`.
        var s = c.scale;
        if (ffiModel.isPeerLinux) {
          final displays = ffiModel.pi.getCurDisplays();
          if (displays.isNotEmpty) {
            s = s / displays[0].scale;
          }
        }
        final rect = videoTextureRect(c.x / s, (c.y + c.getAdjustY()) / s, s,
            image.width, image.height);
        if (rect == null) return child;
        return Stack(clipBehavior: Clip.none, children: [
          child,
          Positioned.fromRect(rect: rect, child: Texture(textureId: id)),
        ]);
      },
    );
  }
}
