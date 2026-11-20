import UIKit
import Flutter
import AVFoundation
import Photos

@main
@objc class AppDelegate: FlutterAppDelegate, UIDocumentInteractionControllerDelegate {
  private var documentController: UIDocumentInteractionController?
  private var videoTextures: [Int64: VideoTexture] = [:]

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    do {
      // Mix remote audio with other apps while still respecting silent mode.
      try AVAudioSession.sharedInstance().setCategory(.ambient)
    } catch {
      NSLog("Failed to configure audio mixing: %@", error.localizedDescription)
    }
    dummyMethodToEnforceBundling();
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  // With the UIScene life cycle, the FlutterViewController only exists once the scene
  // connects, and FlutterAppDelegate reaches its engine through `window`. A launch URL
  // also arrives with the scene instead of in launchOptions, so forward it to plugins here.
  func sceneWillConnect(window: UIWindow?, launchURL: URL?) {
    self.window = window
    GeneratedPluginRegistrant.register(with: self)
    registerFileChannel()
    registerVideoTextureChannel()
    registerBackgroundChannel()
    var launchOptions: [UIApplication.LaunchOptionsKey: Any] = [:]
    if let launchURL = launchURL {
      launchOptions[.url] = launchURL
    }
    _ = super.application(UIApplication.shared, didFinishLaunchingWithOptions: launchOptions)
  }
    
  // Lets the file manager open a received file in Quick Look, from where it
  // can be shared or saved to another app.
  private func registerFileChannel() {
    guard let controller = window?.rootViewController as? FlutterViewController else { return }
    let channel = FlutterMethodChannel(
      name: "rustdesk/ios_files", binaryMessenger: controller.binaryMessenger)
    channel.setMethodCallHandler { [weak self] call, result in
      if call.method == "temp_dir" {
        result(NSTemporaryDirectory())
        return
      }
      // Unlike reading the clipboard, asking how often it changed does not
      // make iOS ask the user for permission.
      if call.method == "pasteboard_change_count" {
        result(UIPasteboard.general.changeCount)
        return
      }
      if call.method == "save_image" || call.method == "save_video",
        let args = call.arguments as? [String: Any],
        let path = args["path"] as? String
      {
        self?.saveToPhotos(path, video: call.method == "save_video", result: result)
        return
      }
      guard call.method == "open_file",
        let args = call.arguments as? [String: Any],
        let path = args["path"] as? String
      else {
        result(FlutterMethodNotImplemented)
        return
      }
      result(self?.openFile(path, from: controller) ?? false)
    }
  }

  private func registerBackgroundChannel() {
    guard let controller = window?.rootViewController as? FlutterViewController else { return }
    let channel = FlutterMethodChannel(
      name: "rustdesk/ios_background", binaryMessenger: controller.binaryMessenger)
    channel.setMethodCallHandler { call, result in
      guard call.method == "keep_alive",
        let args = call.arguments as? [String: Any],
        let on = args["on"] as? Bool
      else {
        result(FlutterMethodNotImplemented)
        return
      }
      result(BackgroundKeepAlive.shared.set(on))
    }
  }

  private func registerVideoTextureChannel() {
    guard let controller = window?.rootViewController as? FlutterViewController else { return }
    let channel = FlutterMethodChannel(
      name: "rustdesk/ios_video_texture", binaryMessenger: controller.binaryMessenger)
    channel.setMethodCallHandler { [weak self, weak controller] call, result in
      guard let self = self, let controller = controller else {
        result(nil)
        return
      }
      let args = call.arguments as? [String: Any]
      let id = (args?["id"] as? NSNumber)?.int64Value
      switch call.method {
      case "create":
        let texture = VideoTexture()
        texture.registry = controller
        texture.textureId = controller.register(texture)
        self.videoTextures[texture.textureId] = texture
        result([
          "id": texture.textureId,
          "ptr": Int(bitPattern: Unmanaged.passUnretained(texture).toOpaque()),
        ])
      case "accept":
        if let id = id, let texture = self.videoTextures[id] {
          texture.accept(
            width: (args?["width"] as? NSNumber)?.intValue ?? 0,
            height: (args?["height"] as? NSNumber)?.intValue ?? 0)
        }
        result(nil)
      case "destroy":
        if let id = id, let texture = self.videoTextures.removeValue(forKey: id) {
          controller.unregisterTexture(id)
          // The decoder is told to stop before this is called. Should a frame
          // still be on its way, the texture outlives it.
          DispatchQueue.main.asyncAfter(deadline: .now() + 5) { _ = texture }
        }
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  // Moves a picture or a recording into the photo library, which needs only
  // the add-only permission. Replies "" when saved, "denied" without
  // permission. A recording that could not be saved stays where it is, in a
  // folder the Files app shows.
  private func saveToPhotos(_ path: String, video: Bool, result: @escaping FlutterResult) {
    let url = URL(fileURLWithPath: path)
    let reply: (String) -> Void = { text in
      if !video || text.isEmpty {
        try? FileManager.default.removeItem(at: url)
      }
      DispatchQueue.main.async { result(text) }
    }
    PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
      guard status == .authorized || status == .limited else {
        reply("denied")
        return
      }
      PHPhotoLibrary.shared().performChanges({
        PHAssetCreationRequest.forAsset().addResource(
          with: video ? .video : .photo, fileURL: url, options: nil)
      }) { ok, error in
        reply(ok ? "" : (error?.localizedDescription ?? "Failed"))
      }
    }
  }

  private func openFile(_ path: String, from controller: UIViewController) -> Bool {
    let doc = UIDocumentInteractionController(url: URL(fileURLWithPath: path))
    doc.delegate = self
    documentController = doc
    if doc.presentPreview(animated: true) { return true }
    return doc.presentOptionsMenu(from: controller.view.bounds, in: controller.view, animated: true)
  }

  func documentInteractionControllerViewControllerForPreview(
    _ controller: UIDocumentInteractionController
  ) -> UIViewController {
    return window?.rootViewController ?? UIViewController()
  }

  public func dummyMethodToEnforceBundling() {
      dummy_method_to_enforce_bundling();
    session_get_rgba(nil, 0);
  }
}

// Keeps the app, and with it a remote session, running in the background by
// playing silence. Without it iOS suspends the app after about 30 seconds.
final class BackgroundKeepAlive {
  static let shared = BackgroundKeepAlive()

  private var player: AVAudioPlayer?
  private var interruptions: NSObjectProtocol?

  // Plays from the moment it is turned on, not from when the app leaves the
  // foreground: playback that starts in the background can be refused.
  func set(_ on: Bool) -> Bool {
    if !on {
      stop()
      return true
    }
    if interruptions == nil {
      interruptions = NotificationCenter.default.addObserver(
        forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
      ) { [weak self] note in
        guard let self = self, self.player != nil,
          let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
          AVAudioSession.InterruptionType(rawValue: raw) == .ended
        else { return }
        _ = self.start()
      }
    }
    return start()
  }

  private func start() -> Bool {
    do {
      let session = AVAudioSession.sharedInstance()
      // Only the playback category may go on playing in the background.
      try session.setCategory(.playback, mode: .default, options: .mixWithOthers)
      try session.setActive(true)
      if player == nil {
        let silence = try AVAudioPlayer(data: BackgroundKeepAlive.silence())
        silence.numberOfLoops = -1
        silence.volume = 0
        player = silence
      }
      return player?.play() ?? false
    } catch {
      NSLog("Failed to keep running in the background: %@", error.localizedDescription)
      return false
    }
  }

  private func stop() {
    guard let player = player else { return }
    player.stop()
    self.player = nil
    try? AVAudioSession.sharedInstance().setCategory(.ambient)
  }

  // One second of silence as a WAV file.
  private static func silence() -> Data {
    let rate: UInt32 = 8000
    let bytes = rate * 2
    var data = Data()
    func append<T: FixedWidthInteger>(_ value: T) {
      withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }
    data.append(contentsOf: Array("RIFF".utf8))
    append(36 + bytes)
    data.append(contentsOf: Array("WAVEfmt ".utf8))
    append(UInt32(16))
    append(UInt16(1))
    append(UInt16(1))
    append(rate)
    append(rate * 2)
    append(UInt16(2))
    append(UInt16(16))
    data.append(contentsOf: Array("data".utf8))
    append(bytes)
    data.append(Data(count: Int(bytes)))
    return data
  }
}

// Shows the remote screen without passing each frame through Dart: the video
// decoder writes a frame into a pixel buffer, which Flutter draws as a texture.
final class VideoTexture: NSObject, FlutterTexture {
  var textureId: Int64 = 0
  weak var registry: FlutterTextureRegistry?

  private let lock = NSLock()
  private var latest: CVPixelBuffer?
  private var pool: CVPixelBufferPool?
  private var width = 0
  private var height = 0

  // The only frame size taken from now on; none when zero. Flutter lays the
  // texture out by the size of the last frame it decoded itself, so a frame
  // of any other size has to go there first.
  func accept(width: Int, height: Int) {
    lock.lock()
    defer { lock.unlock() }
    if width != self.width || height != self.height {
      pool = nil
    }
    self.width = width
    self.height = height
  }

  func copyPixelBuffer() -> Unmanaged<CVPixelBuffer>? {
    lock.lock()
    defer { lock.unlock() }
    guard let latest = latest else { return nil }
    return Unmanaged.passRetained(latest)
  }

  // Called on the video decoding thread with BGRA rows. False when the frame
  // is not taken.
  func take(_ buffer: UnsafePointer<UInt8>, len: Int, width: Int, height: Int) -> Bool {
    guard let frame = newFrame(len: len, width: width, height: height) else { return false }
    let stride = len / height
    CVPixelBufferLockBaseAddress(frame, [])
    guard let base = CVPixelBufferGetBaseAddress(frame) else {
      CVPixelBufferUnlockBaseAddress(frame, [])
      return false
    }
    let rowBytes = CVPixelBufferGetBytesPerRow(frame)
    if rowBytes == stride {
      memcpy(base, buffer, stride * height)
    } else {
      let bytes = min(rowBytes, stride)
      for row in 0..<height {
        memcpy(base + row * rowBytes, buffer + row * stride, bytes)
      }
    }
    CVPixelBufferUnlockBaseAddress(frame, [])
    lock.lock()
    latest = frame
    lock.unlock()
    // The registry is only safe to use on the main thread.
    DispatchQueue.main.async { [weak self] in
      guard let self = self else { return }
      self.registry?.textureFrameAvailable(self.textureId)
    }
    return true
  }

  // The same for a frame the decoder left on the GPU: shown as it is, with
  // nothing copied.
  func take(pixelBuffer: CVPixelBuffer) -> Bool {
    lock.lock()
    guard width > 0, CVPixelBufferGetWidth(pixelBuffer) == width,
      CVPixelBufferGetHeight(pixelBuffer) == height
    else {
      lock.unlock()
      return false
    }
    latest = pixelBuffer
    lock.unlock()
    DispatchQueue.main.async { [weak self] in
      guard let self = self else { return }
      self.registry?.textureFrameAvailable(self.textureId)
    }
    return true
  }

  private func newFrame(len: Int, width: Int, height: Int) -> CVPixelBuffer? {
    lock.lock()
    defer { lock.unlock() }
    guard width > 0, height > 0, width == self.width, height == self.height,
      len / height >= width * 4
    else { return nil }
    if pool == nil {
      let attributes: [CFString: Any] = [
        kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey: width,
        kCVPixelBufferHeightKey: height,
        kCVPixelBufferMetalCompatibilityKey: true,
        kCVPixelBufferIOSurfacePropertiesKey: [String: Any](),
      ]
      CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes as CFDictionary, &pool)
    }
    guard let pool = pool else { return nil }
    var frame: CVPixelBuffer?
    CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &frame)
    return frame
  }
}

// Called by the Rust video renderer (`src/flutter.rs`).
@_cdecl("rustdesk_ios_video_texture_on_rgba")
public func rustdeskIosVideoTextureOnRgba(
  _ texture: UnsafeMutableRawPointer?, _ buffer: UnsafePointer<UInt8>?, _ len: Int32,
  _ width: Int32, _ height: Int32
) -> Bool {
  guard let texture = texture, let buffer = buffer else { return false }
  return Unmanaged<VideoTexture>.fromOpaque(texture).takeUnretainedValue()
    .take(buffer, len: Int(len), width: Int(width), height: Int(height))
}

@_cdecl("rustdesk_ios_video_texture_on_pixel_buffer")
public func rustdeskIosVideoTextureOnPixelBuffer(
  _ texture: UnsafeMutableRawPointer?, _ pixelBuffer: UnsafeMutableRawPointer?
) -> Bool {
  guard let texture = texture, let pixelBuffer = pixelBuffer else { return false }
  return Unmanaged<VideoTexture>.fromOpaque(texture).takeUnretainedValue()
    .take(pixelBuffer: Unmanaged<CVPixelBuffer>.fromOpaque(pixelBuffer).takeUnretainedValue())
}
