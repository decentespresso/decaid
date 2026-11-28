import AVFoundation
import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    registerPluginAdmission(with: flutterViewController)
    registerSkinCameraPermission(with: flutterViewController)
    registerRecoveryProcessIdentity(with: flutterViewController)

    if let appDelegate = NSApplication.shared.delegate as? AppDelegate {
      appDelegate.macosUpdater = MacOSUpdater.register(with: flutterViewController)
    }

    super.awakeFromNib()
  }

  private func registerPluginAdmission(with controller: FlutterViewController) {
    let admission = PluginAdmission(engine: controller.engine)
    let channel = FlutterMethodChannel(
      name: "com.reaprime/recovery_plugins",
      binaryMessenger: controller.engine.binaryMessenger
    )
    channel.setMethodCallHandler { call, result in
      admission.handle(call, result: result)
    }
  }

  private func registerRecoveryProcessIdentity(with controller: FlutterViewController) {
    let channel = FlutterMethodChannel(
      name: "com.reaprime/recovery_identity",
      binaryMessenger: controller.engine.binaryMessenger
    )
    channel.setMethodCallHandler { call, result in
      guard call.method == "processSessionId" else {
        result(FlutterMethodNotImplemented)
        return
      }
      guard let identity = RecoveryProcessIdentity.value() else {
        result(FlutterError(
          code: "UNAVAILABLE",
          message: "process start time is unavailable",
          details: nil
        ))
        return
      }
      result(identity)
    }
  }

  private func registerSkinCameraPermission(with controller: FlutterViewController) {
    let channel = FlutterMethodChannel(
      name: "com.reaprime/skin_camera",
      binaryMessenger: controller.engine.binaryMessenger
    )
    channel.setMethodCallHandler { call, result in
      guard call.method == "requestCamera" else {
        result(FlutterMethodNotImplemented)
        return
      }
      switch AVCaptureDevice.authorizationStatus(for: .video) {
      case .authorized:
        result(true)
      case .notDetermined:
        AVCaptureDevice.requestAccess(for: .video) { allowed in
          DispatchQueue.main.async { result(allowed) }
        }
      case .denied, .restricted:
        result(false)
      @unknown default:
        result(false)
      }
    }
  }
}

/// Defers the generated plugin registrant until Dart asks for normal startup.
///
/// The generated registrant configures a vendor SDK's default instance from the
/// bundled plist at registration time, and the nib load runs before Dart `main()`
/// reaches the recovery gate. The generated registrant stays the single plugin
/// list, and an engine that was already admitted answers success, so repeated
/// calls are safe.
final class PluginAdmission {
  private static let lock = NSLock()
  private static var admittedEngines = Set<ObjectIdentifier>()

  private let engine: FlutterEngine

  init(engine: FlutterEngine) {
    self.engine = engine
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard call.method == "admitPlugins" else {
      result(FlutterMethodNotImplemented)
      return
    }
    admitPlugins()
    result(nil)
  }

  private func admitPlugins() {
    Self.lock.lock()
    defer { Self.lock.unlock() }
    let key = ObjectIdentifier(engine)
    guard !Self.admittedEngines.contains(key) else { return }
    RegisterGeneratedPlugins(registry: engine)
    Self.admittedEngines.insert(key)
  }
}
