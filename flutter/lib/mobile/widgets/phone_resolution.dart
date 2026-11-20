import '../../models/model.dart';
import '../../models/platform_model.dart';

const kOptionMobilePhoneResolution = 'mobile-phone-resolution';

bool isPhoneResolutionEnabled() =>
    bind.mainGetLocalOption(key: kOptionMobilePhoneResolution) == 'Y';

/// Of the resolutions a remote display offers, the one to use while a phone
/// is looking at it, if any: the same shape as its own [width] x [height],
/// and nearest to 55% of the area. A desktop sends more pixels than a phone
/// can show, and every stage from the encoder to the screen costs by the
/// pixel; at about half of them the picture is still sharp on a phone, and
/// what is on it is larger.
Resolution? pickPhoneResolution(
    Iterable<Resolution> offered, int width, int height) {
  if (width <= 0 || height <= 0) return null;
  Resolution? best;
  var bestDistance = double.infinity;
  for (final r in offered) {
    if (r.width <= 0 || r.height <= 0) continue;
    final shape = (r.width / r.height) / (width / height);
    if ((shape - 1).abs() > 0.02) continue;
    final area = (r.width * r.height) / (width * height);
    if (area < 0.35 || area > 0.8) continue;
    final distance = (area - 0.55).abs();
    if (distance < bestDistance) {
      best = r;
      bestDistance = distance;
    }
  }
  return best;
}

Display? _display(FFI ffi) {
  final display = ffi.ffiModel.pi.tryGetDisplayIfNotAllDisplay();
  if (display == null ||
      !display.isOriginalResolutionSet ||
      display.isVirtualDisplayResolution) {
    return null;
  }
  return display;
}

/// Asks the remote display for its phone resolution, unless its resolution
/// has already been changed. The remote side puts the original one back when
/// the session ends.
Future<void> applyPhoneResolution(FFI ffi) async {
  final display = _display(ffi);
  if (display == null || !display.isOriginalResolution) return;
  final pi = ffi.ffiModel.pi;
  final pick = pickPhoneResolution(
      pi.resolutions, display.originalWidth, display.originalHeight);
  if (pick == null) return;
  await bind.sessionChangeResolution(
      sessionId: ffi.sessionId,
      display: pi.currentDisplay,
      width: pick.width,
      height: pick.height);
}

Future<void> restoreRemoteResolution(FFI ffi) async {
  final display = _display(ffi);
  if (display == null || display.isOriginalResolution) return;
  await bind.sessionChangeResolution(
      sessionId: ffi.sessionId,
      display: ffi.ffiModel.pi.currentDisplay,
      width: display.originalWidth,
      height: display.originalHeight);
}
