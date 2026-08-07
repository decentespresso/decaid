import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

    if let appDelegate = NSApplication.shared.delegate as? AppDelegate {
      appDelegate.macosUpdater = MacOSUpdater.register(with: flutterViewController)
    }

    super.awakeFromNib()
  }
}
