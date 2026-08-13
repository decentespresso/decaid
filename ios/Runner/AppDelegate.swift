import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "SecurityScopedFile") {
      SecurityScopedFilePlugin.register(with: registrar)
    }
  }
}

class SecurityScopedFilePlugin: NSObject, FlutterPlugin {
  private static var active: [String: URL] = [:]

  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: "com.reaprime/security_scoped",
      binaryMessenger: registrar.messenger()
    )
    registrar.addMethodCallDelegate(SecurityScopedFilePlugin(), channel: channel)
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let path = call.arguments as? String else {
      result(FlutterError(code: "badArguments", message: "expected path string", details: nil))
      return
    }
    let url = URL(fileURLWithPath: path)
    switch call.method {
    case "startAccessing":
      guard Self.active[path] == nil else {
        result(true)
        return
      }
      let ok = url.startAccessingSecurityScopedResource()
      if ok {
        Self.active[path] = url
      }
      result(ok)
    case "stopAccessing":
      if let url = Self.active.removeValue(forKey: path) {
        url.stopAccessingSecurityScopedResource()
      }
      result(true)
    default:
      result(FlutterMethodNotImplemented)
    }
  }
}
