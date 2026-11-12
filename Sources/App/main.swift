import Cocoa

/// Executable entry point of the Pi Web desktop app.

private let app = NSApplication.shared
// `AppDelegate` 是 `@MainActor` 隔离的，而 main.swift 的顶层代码在 Swift 5 语言模式下
// 是 nonisolated；顶层代码本来就运行在主线程上，所以直接断言隔离。
private let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
// A regular foreground application is required for macOS to present the
// application's native text menu bar and to receive the standard window
// commands (including full screen) reliably.
app.setActivationPolicy(.regular)
app.run()
