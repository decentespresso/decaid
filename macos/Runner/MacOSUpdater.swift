import Cocoa
import FlutterMacOS
import Sparkle

/// Minimal surface MacOSUpdater needs from Sparkle's updater controller.
/// Protocol so RunnerTests can drive MacOSUpdater without launching Sparkle's
/// installer machinery.
@MainActor
protocol SPUUpdaterControlling: AnyObject {
  /// Pre-flight check that the host bundle is configured for Sparkle.
  func validateConfiguration() throws
  func startUpdater()
  func checkForUpdates()
  var automaticallyChecksForUpdates: Bool { get set }
  func resetUpdateCycleAfterShortDelay()
}

/// Production controller wrapping Sparkle's standard updater controller.
@MainActor
final class SparkleUpdaterController: SPUUpdaterControlling {
  private let standard: SPUStandardUpdaterController

  init(updaterDelegate: SPUUpdaterDelegate?) {
    standard = SPUStandardUpdaterController(
      startingUpdater: false,
      updaterDelegate: updaterDelegate,
      userDriverDelegate: nil)
  }

  func validateConfiguration() throws {
    guard let info = Bundle.main.infoDictionary,
          info["SUFeedURL"] != nil,
          info["SUPublicEDKey"] != nil else {
      throw MacOSUpdaterError.missingInfoPlistKeys
    }
  }

  func startUpdater() {
    standard.startUpdater()
  }

  func checkForUpdates() {
    standard.checkForUpdates(nil)
  }

  var automaticallyChecksForUpdates: Bool {
    get { standard.updater.automaticallyChecksForUpdates }
    set { standard.updater.automaticallyChecksForUpdates = newValue }
  }

  func resetUpdateCycleAfterShortDelay() {
    standard.updater.resetUpdateCycleAfterShortDelay()
  }
}

enum MacOSUpdaterError: LocalizedError {
  case missingInfoPlistKeys

  var errorDescription: String? {
    switch self {
    case .missingInfoPlistKeys:
      return "Sparkle is not configured: SUFeedURL and SUPublicEDKey are required in Info.plist"
    }
  }
}

/// Coordinates Sparkle with Decaid's Flutter settings. The Flutter side
/// (net.tadel.reaprime/macos_updater) is the only entry point; no update
/// replacement logic lives in Dart.
@MainActor
final class MacOSUpdater: NSObject, SPUUpdaterDelegate {
  static let channelName = "net.tadel.reaprime/macos_updater"
  static let automaticChecksMigrationKey =
    "net.tadel.reaprime.sparkleAutomaticChecksMigrated"

  private let injectedController: SPUUpdaterControlling?
  private lazy var controller: SPUUpdaterControlling = {
    injectedController ?? SparkleUpdaterController(updaterDelegate: self)
  }()
  private var methodChannel: FlutterMethodChannel?
  private var allowedChannels: Set<String> = []
  private var configured = false

  init(controller: SPUUpdaterControlling? = nil) {
    injectedController = controller
    super.init()
  }

  /// Sparkle always includes the default channel, so Stable needs no entries.
  nonisolated static func allowedChannels(for channel: String) -> Set<String> {
    channel == "beta" ? ["beta"] : []
  }

  /// Registers the method channel and returns the updater; the caller keeps it
  /// alive (the AppDelegate owns it).
  @discardableResult
  static func register(with flutterViewController: FlutterViewController) -> MacOSUpdater {
    let updater = MacOSUpdater()
    updater.methodChannel = FlutterMethodChannel(
      name: channelName,
      binaryMessenger: flutterViewController.engine.binaryMessenger)
    updater.methodChannel?.setMethodCallHandler { [weak updater] call, result in
      updater?.handle(call, result: result)
    }
    return updater
  }

  /// Starts the updater and applies the persisted Flutter settings. Idempotent;
  /// safe to call again after a channel change or a settings reload.
  func configure(automaticChecks: Bool, channel: String) throws {
    try controller.validateConfiguration()
    if !configured {
      controller.startUpdater()
      configured = true
    }
    if !UserDefaults.standard.bool(forKey: Self.automaticChecksMigrationKey) {
      controller.automaticallyChecksForUpdates = automaticChecks
      UserDefaults.standard.set(true, forKey: Self.automaticChecksMigrationKey)
    }
    allowedChannels = Self.allowedChannels(for: channel)
  }

  func setAutomaticChecks(_ enabled: Bool) {
    guard UserDefaults.standard.bool(forKey: Self.automaticChecksMigrationKey) else {
      return
    }
    controller.automaticallyChecksForUpdates = enabled
  }

  func setChannel(_ channel: String) {
    let next = Self.allowedChannels(for: channel)
    guard next != allowedChannels else { return }
    allowedChannels = next
    controller.resetUpdateCycleAfterShortDelay()
  }

  func checkForUpdates() {
    guard configured else { return }
    controller.checkForUpdates()
  }


  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "configure":
      let args = call.arguments as? [String: Any]
      guard let automaticChecks = args?["automaticChecks"] as? Bool,
            let channel = args?["channel"] as? String else {
        result(FlutterError(
          code: "bad_arguments",
          message: "configure requires automaticChecks (bool) and channel (string)",
          details: nil))
        return
      }
      do {
        try configure(automaticChecks: automaticChecks, channel: channel)
        result(nil)
      } catch {
        result(FlutterError(code: "configure_failed", message: error.localizedDescription, details: nil))
      }
    case "setAutomaticChecks":
      let enabled = (call.arguments as? [String: Any])?["enabled"] as? Bool
      guard let enabled else {
        result(FlutterError(code: "bad_arguments", message: "setAutomaticChecks requires enabled (bool)", details: nil))
        return
      }
      setAutomaticChecks(enabled)
      result(nil)
    case "setChannel":
      let channel = (call.arguments as? [String: Any])?["channel"] as? String
      guard let channel else {
        result(FlutterError(code: "bad_arguments", message: "setChannel requires channel (string)", details: nil))
        return
      }
      setChannel(channel)
      result(nil)
    case "checkForUpdates":
      checkForUpdates()
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }


  func allowedChannels(for updater: SPUUpdater) -> Set<String> {
    allowedChannels
  }
}
