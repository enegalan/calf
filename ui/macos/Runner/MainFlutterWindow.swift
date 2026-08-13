import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let minSize = NSSize(width: 940, height: 600)
    self.minSize = minSize

    // Clamp before setFrame: minSize alone does not enlarge an undersized nib frame.
    var windowFrame = self.frame
    if windowFrame.size.width < minSize.width {
      windowFrame.size.width = minSize.width
    }
    if windowFrame.size.height < minSize.height {
      windowFrame.size.height = minSize.height
    }

    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()
  }
}
