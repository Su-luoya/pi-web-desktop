import Cocoa

/// Executable entry point of the Pi Web desktop app.

private let app = NSApplication.shared
private let delegate = AppDelegate()
app.delegate = delegate
// A regular foreground application is required for macOS to present the
// application's native text menu bar and to receive the standard window
// commands (including full screen) reliably.
app.setActivationPolicy(.regular)
app.run()
