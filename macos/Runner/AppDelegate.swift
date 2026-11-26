import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  var macosUpdater: MacOSUpdater?

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
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
