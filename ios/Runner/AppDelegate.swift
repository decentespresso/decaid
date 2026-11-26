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
    let registry = engineBridge.pluginRegistry
    if let registrar = registry.registrar(forPlugin: "SecurityScopedFile") {
      SecurityScopedFilePlugin.register(with: registrar)
    }
    if let registrar = registry.registrar(forPlugin: "RecoveryProcessIdentity") {
      RecoveryProcessIdentityPlugin.register(with: registrar)
    }
    if let registrar = registry.registrar(forPlugin: "RecoveryPluginAdmission") {
      PluginAdmission.register(with: registrar, registry: registry)
    }
  }
}

/// Defers the generated plugin registrant until Dart asks for normal startup.
///
/// Only the app-owned recovery channels attach at engine creation, so a blocked
/// or uncertain recovery state never reaches a plugin's attach-time SDK
/// initialisation. The generated registrant stays the single plugin list, and an
/// engine that was already admitted answers success, so repeated calls are safe.
final class PluginAdmission {
  private static let lock = NSLock()
  private static var admittedEngines = Set<ObjectIdentifier>()

  private let registry: FlutterPluginRegistry

  private init(registry: FlutterPluginRegistry) {
    self.registry = registry
  }

  static func register(
    with registrar: FlutterPluginRegistrar,
    registry: FlutterPluginRegistry
  ) {
    let admission = PluginAdmission(registry: registry)
    let channel = FlutterMethodChannel(
      name: "com.reaprime/recovery_plugins",
      binaryMessenger: registrar.messenger()
    )
    channel.setMethodCallHandler { call, result in
      admission.handle(call, result: result)
    }
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
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
    let engine = ObjectIdentifier(registry as AnyObject)
    guard !Self.admittedEngines.contains(engine) else { return }
    GeneratedPluginRegistrant.register(with: registry)
    Self.admittedEngines.insert(engine)
  }
}

/// Process-level identity for new-owner recovery ownership.
///
/// The kernel start time of this process is the same for every Flutter engine in
/// the process and differs after a relaunch, so recovery state can be owned by
/// exactly one engine without depending on Dart isolate state. When the kernel
/// cannot report it the channel fails instead of inventing an identity.
enum RecoveryProcessIdentity {
  static func value() -> String? {
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    let status = sysctl(&mib, u_int(mib.count), &info, &size, nil, 0)
    guard status == 0, size == MemoryLayout<kinfo_proc>.stride else { return nil }
    let start = info.kp_proc.p_un.__p_starttime
    guard start.tv_sec != 0 else { return nil }
    return "darwin:\(info.kp_proc.p_pid):\(start.tv_sec).\(start.tv_usec)"
  }
}

class RecoveryProcessIdentityPlugin: NSObject, FlutterPlugin {
  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: "com.reaprime/recovery_identity",
      binaryMessenger: registrar.messenger()
    )
    registrar.addMethodCallDelegate(RecoveryProcessIdentityPlugin(), channel: channel)
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
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
