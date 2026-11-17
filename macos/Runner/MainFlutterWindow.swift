import AVFoundation
import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)
    registerSkinCameraPermission(with: flutterViewController)

    if let appDelegate = NSApplication.shared.delegate as? AppDelegate {
      appDelegate.macosUpdater = MacOSUpdater.register(with: flutterViewController)
    }

    super.awakeFromNib()
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
