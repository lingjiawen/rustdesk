import 'dart:async';

import 'package:flutter/services.dart';

import '../../common.dart';
import '../../consts.dart';
import '../../models/model.dart';
import '../../models/platform_model.dart';

const _iosFiles = MethodChannel('rustdesk/ios_files');

bool isSessionScreenshotSupported(FFI ffi) =>
    ffi.connType == ConnType.defaultConn &&
    bind.sessionGetCommonSync(
            sessionId: ffi.sessionId,
            key: 'is_screenshot_supported',
            param: '') ==
        'true';

/// Asks the remote for a picture of the display being shown. It arrives
/// later as a `screenshot` session event.
void takeSessionScreenshot(FFI ffi) {
  final model = ffi.ffiModel;
  if (model.timerScreenshot != null) return;
  if (model.pi.currentDisplay == kAllDisplayValue) {
    msgBox(
        ffi.sessionId,
        'custom-nook-nocancel-hasclose-info',
        'Take screenshot',
        'screenshot-merged-screen-not-supported-tip',
        '',
        ffi.dialogManager);
    return;
  }
  bind.sessionTakeScreenshot(
      sessionId: ffi.sessionId, display: model.pi.currentDisplay);
  model.timerScreenshot =
      Timer(const Duration(seconds: 30), () => model.timerScreenshot = null);
  showToast('${translate('Taking screenshot')} ...');
}

/// Saves the screenshot the remote just sent to the iOS photo library.
Future<void> saveSessionScreenshotToPhotos(SessionID sessionId) async {
  String result;
  try {
    final dir = await _iosFiles.invokeMethod<String>('temp_dir') ?? '';
    final path =
        '${dir}screenshot_${DateTime.now().millisecondsSinceEpoch}.png';
    result = await bind.sessionHandleScreenshot(
        sessionId: sessionId, action: '0:$path');
    if (result.isEmpty) {
      // The native side removes the file once it is in the library.
      result =
          await _iosFiles.invokeMethod<String>('save_image', {'path': path}) ??
              '';
    }
  } catch (e) {
    result = e.toString();
  }
  showToast(translate(switch (result) {
    '' => 'Saved to Photos',
    'denied' => 'screenshot-photos-denied-tip',
    _ => result,
  }));
}
