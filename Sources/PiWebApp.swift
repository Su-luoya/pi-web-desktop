import Cocoa
import WebKit

private enum ServiceState {
    case checking
    case starting
    case running
    case stopped
    case failed(String)
}

final class AppDelegate: NSObject, NSApplicationDelegate, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate, NSWindowDelegate {
    private var window: NSWindow!
    private var webView: WKWebView!
    private var statusMenuItem: NSMenuItem?
    private var serviceProcess: Process?
    private var logHandle: FileHandle?
    private var startupAttempts = 0
    private var didLaunchService = false
    private var restartAttempts = 0
    private var healthTimer: Timer?
    private var isQuitting = false
    private var isStoppingService = false
    private var terminationDecisionPending = false
    private var hasInstanceLock = false
    private var eventMonitor: Any?
    private var screenParametersObserver: NSObjectProtocol?
    private var screenFitWorkItem: DispatchWorkItem?
    private var isFullScreenTransition = false
    private var currentState: ServiceState = .checking
    private var findBar: NSView?
    private var findField: NSSearchField?
    private var preferencesWindowController: PreferencesWindowController?
    private var configuration = ServiceConfiguration.load()

    private var startURL: URL { configuration.serviceURL }
    private let supportURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Pi Web Desktop", isDirectory: true)
    private let logURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/Pi Web Desktop.log")
    private let serviceWorkingDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Pi Web Desktop/Workspace", isDirectory: true)
    private let maxStartupAttempts = 150

    private var managedPIDURL: URL { supportURL.appendingPathComponent("service.pid") }
    private var appPIDURL: URL { supportURL.appendingPathComponent("app.pid") }
    private var instanceLockURL: URL { supportURL.appendingPathComponent("instance.lock") }
    private var instanceLockHandle: FileHandle?

    func applicationDidFinishLaunching(_ notification: Notification) {
        try? FileManager.default.createDirectory(at: supportURL, withIntermediateDirectories: true)
        guard acquireSingleInstanceLock() else {
            NSApp.terminate(nil)
            return
        }
        try? "\(ProcessInfo.processInfo.processIdentifier)\n".write(to: appPIDURL, atomically: true, encoding: .utf8)
        NSApp.mainMenu = nil
        installQuitShortcuts()
        installScreenChangeObserver()
        installMainMenu()
        createWindow()
        setState(.checking)
        showLoadingPage(message: "正在检查 Pi Web 服务…")
        if configuration.autoStart {
            ensureServerIsRunning()
        } else {
            checkServer { [weak self] ready in
                DispatchQueue.main.async {
                    guard let self else { return }
                    if ready {
                        self.setState(.running)
                        self.loadPiWeb()
                    } else {
                        self.setState(.stopped)
                        self.showErrorPage(message: "Pi Web 服务未运行。")
                    }
                }
            }
        }
        startHealthMonitor()
    }

    func applicationWillTerminate(_ notification: Notification) {
        healthTimer?.invalidate()
        try? FileManager.default.removeItem(at: appPIDURL)
        try? logHandle?.close()
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
            self.eventMonitor = nil
        }
        if let screenParametersObserver {
            NotificationCenter.default.removeObserver(screenParametersObserver)
            self.screenParametersObserver = nil
        }
        screenFitWorkItem?.cancel()
        screenFitWorkItem = nil
        if hasInstanceLock { instanceLockHandle = nil }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !isQuitting else { return .terminateNow }
        guard !terminationDecisionPending else { return .terminateLater }

        switch configuration.quitBehavior {
        case .keepRunning:
            quitKeepingService(nil)
        case .stopService:
            quitAndStop(nil)
        case .ask:
            terminationDecisionPending = true
            let alert = NSAlert()
            alert.messageText = "退出 Pi Web"
            alert.informativeText = "是否在退出应用后继续保持 Pi Web 服务运行？"
            alert.addButton(withTitle: "保持服务运行")
            alert.addButton(withTitle: "退出并停止服务")
            alert.addButton(withTitle: "取消")
            alert.beginSheetModal(for: window) { [weak self] response in
                guard let self else { return }
                self.terminationDecisionPending = false
                switch response {
                case .alertFirstButtonReturn: self.quitKeepingService(nil)
                case .alertSecondButtonReturn: self.quitAndStop(nil)
                default: break
                }
            }
        }
        return .terminateLater
    }

    private func acquireSingleInstanceLock() -> Bool {
        let existingPID = (try? String(contentsOf: appPIDURL, encoding: .utf8))
            .flatMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        if let existingPID, existingPID > 1, kill(existingPID, 0) == 0 {
            return false
        }
        if FileManager.default.fileExists(atPath: instanceLockURL.path) {
            try? FileManager.default.removeItem(at: instanceLockURL)
        }
        FileManager.default.createFile(atPath: instanceLockURL.path, contents: nil)
        do {
            instanceLockHandle = try FileHandle(forWritingTo: instanceLockURL)
            hasInstanceLock = true
            return true
        } catch {
            return false
        }
    }

    private func installQuitShortcuts() {
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard modifiers.contains(.command) else { return event }

            switch event.charactersIgnoringModifiers?.lowercased() {
            case "q":
                // Command-Q means "退出并停止服务". Do not route it through
                // NSApp.terminate(), which would invoke the configurable
                // confirmation dialog when quitBehavior == .ask.
                self?.quitAndStop(nil)
                return nil
            case ",":
                self?.showPreferences(nil)
                return nil
            case "r" where modifiers.contains(.shift):
                self?.hardReloadPage(nil)
                return nil
            case "r":
                self?.reloadPage(nil)
                return nil
            case "f" where modifiers.contains(.control):
                self?.toggleFullScreen(nil)
                return nil
            default:
                return event
            }
        }
    }

    private func installScreenChangeObserver() {
        screenParametersObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // 屏幕旋转/分辨率变化时，windowDidChangeScreen 不一定会发送；
            // 等 AppKit 更新 NSScreen.visibleFrame 后再重新布局。
            self?.scheduleWindowFit()
        }
    }

    private func scheduleWindowFit() {
        screenFitWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.screenFitWorkItem = nil
            self.fitWindowToCurrentScreen()
        }
        screenFitWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: workItem)
    }

    // MARK: - Menus

    private func installMainMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu(title: "Pi Web Desktop")
        appMenu.addItem(withTitle: "关于 Pi Web Desktop", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "隐藏 Pi Web Desktop", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(withTitle: "隐藏其他应用", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "显示全部", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(withTitle: "设置…", action: #selector(showPreferences(_:)), keyEquivalent: ",")
        appMenu.addItem(withTitle: "启动服务", action: #selector(startServiceAction(_:)), keyEquivalent: "")
        appMenu.addItem(withTitle: "重启服务", action: #selector(restartServiceAction(_:)), keyEquivalent: "")
        appMenu.addItem(withTitle: "停止服务", action: #selector(stopServiceAction(_:)), keyEquivalent: "")
        appMenu.addItem(withTitle: "在浏览器中打开", action: #selector(openInBrowser(_:)), keyEquivalent: "")
        appMenu.addItem(withTitle: "复制本地地址", action: #selector(copyLocalAddress(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "退出 Pi Web Desktop（保持服务运行）", action: #selector(quitKeepingService(_:)), keyEquivalent: "")
        let quitAndStopItem = appMenu.addItem(withTitle: "退出 Pi Web Desktop", action: #selector(quitAndStop(_:)), keyEquivalent: "q")
        quitAndStopItem.keyEquivalentModifierMask = [.command]
        appMenuItem.submenu = appMenu

        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)
        let editMenu = NSMenu(title: "编辑")
        editMenu.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "在页面中查找…", action: #selector(showFindBar(_:)), keyEquivalent: "f")
        editMenuItem.submenu = editMenu

        let viewMenuItem = NSMenuItem()
        mainMenu.addItem(viewMenuItem)
        let viewMenu = NSMenu(title: "显示")
        viewMenu.addItem(withTitle: "重新加载", action: #selector(reloadPage(_:)), keyEquivalent: "r")
        let hardReload = viewMenu.addItem(withTitle: "强制重新加载", action: #selector(hardReloadPage(_:)), keyEquivalent: "r")
        hardReload.keyEquivalentModifierMask = [.command, .shift]
        viewMenu.addItem(.separator())
        viewMenu.addItem(withTitle: "放大", action: #selector(zoomIn(_:)), keyEquivalent: "+")
        viewMenu.addItem(withTitle: "缩小", action: #selector(zoomOut(_:)), keyEquivalent: "-")
        viewMenu.addItem(withTitle: "实际大小", action: #selector(resetZoom(_:)), keyEquivalent: "0")
        viewMenu.addItem(.separator())
        let fullScreenItem = viewMenu.addItem(withTitle: "进入全屏幕", action: #selector(toggleFullScreen(_:)), keyEquivalent: "f")
        fullScreenItem.keyEquivalentModifierMask = [.command, .control]
        viewMenuItem.submenu = viewMenu

        let serviceMenuItem = NSMenuItem()
        mainMenu.addItem(serviceMenuItem)
        let serviceMenu = NSMenu(title: "服务")
        statusMenuItem = serviceMenu.addItem(withTitle: "状态：正在检查…", action: nil, keyEquivalent: "")
        statusMenuItem?.isEnabled = false
        serviceMenu.addItem(.separator())
        serviceMenu.addItem(withTitle: "启动服务", action: #selector(startServiceAction(_:)), keyEquivalent: "")
        serviceMenu.addItem(withTitle: "重启服务", action: #selector(restartServiceAction(_:)), keyEquivalent: "")
        serviceMenu.addItem(withTitle: "停止服务", action: #selector(stopServiceAction(_:)), keyEquivalent: "")
        serviceMenu.addItem(withTitle: "设置…", action: #selector(showPreferences(_:)), keyEquivalent: "")
        serviceMenu.addItem(withTitle: "在浏览器中打开", action: #selector(openInBrowser(_:)), keyEquivalent: "")
        serviceMenu.addItem(withTitle: "复制本地地址", action: #selector(copyLocalAddress(_:)), keyEquivalent: "")
        serviceMenu.addItem(withTitle: "打开日志", action: #selector(openLog(_:)), keyEquivalent: "")
        serviceMenu.addItem(withTitle: "复制诊断信息", action: #selector(copyDiagnostics(_:)), keyEquivalent: "")
        serviceMenuItem.submenu = serviceMenu

        let windowMenuItem = NSMenuItem()
        mainMenu.addItem(windowMenuItem)
        let windowMenu = NSMenu(title: "窗口")
        windowMenu.addItem(withTitle: "最小化", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "缩放", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenu.addItem(withTitle: "全屏幕", action: #selector(toggleFullScreen(_:)), keyEquivalent: "f")
        windowMenu.item(at: 2)?.keyEquivalentModifierMask = [.command, .control]
        windowMenu.addItem(withTitle: "显示 Pi Web", action: #selector(showWindow(_:)), keyEquivalent: "")
        windowMenuItem.submenu = windowMenu
        NSApp.windowsMenu = windowMenu

        NSApp.mainMenu = mainMenu
    }


    // MARK: - Window and WebView

    private func preferredWindowFrame(for screen: NSScreen?) -> NSRect {
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 920)
        let isPortrait = visible.height > visible.width

        // 竖屏可用宽度本来就有限，使用完整的 visibleFrame，避免窗口
        // 因为默认尺寸、窗口自动保存尺寸或屏幕旋转后留下的旧 frame 变成
        // 一个看起来“没有全屏”的小窗口。
        if isPortrait {
            return visible
        }

        let desiredWidth = min(1440, max(900, visible.width * 0.86))
        let desiredHeight = min(920, max(620, visible.height * 0.82))
        let width = min(desiredWidth, max(560, visible.width))
        let height = min(desiredHeight, max(560, visible.height))
        return NSRect(
            x: visible.midX - width / 2,
            y: visible.midY - height / 2,
            width: width,
            height: height
        )
    }

    private func fitWindowToCurrentScreen() {
        guard let window, let screen = window.screen ?? NSScreen.main else { return }
        // Native full-screen mode owns the window frame. Do not overwrite it
        // while AppKit is entering or already in a full-screen Space.
        guard !isFullScreenTransition, !window.styleMask.contains(.fullScreen) else { return }
        let visible = screen.visibleFrame
        guard visible.width > 0, visible.height > 0 else { return }

        // 竖屏时必须覆盖整个可用桌面区域。原实现只在窗口过宽时缩小，
        // 而且还额外留了 20pt 边距；如果窗口之前已经较小，就永远不会
        // 被放大回去，因此在旋转显示器或恢复自动保存 frame 后会偶发露出桌面。
        if visible.height > visible.width {
            if window.frame != visible {
                window.setFrame(visible, display: true, animate: false)
            }
            return
        }

        var frame = window.frame
        frame.size.width = min(max(frame.size.width, window.minSize.width), visible.width)
        frame.size.height = min(max(frame.size.height, window.minSize.height), visible.height)
        frame.origin.x = min(max(frame.origin.x, visible.minX), visible.maxX - frame.width)
        frame.origin.y = min(max(frame.origin.y, visible.minY), visible.maxY - frame.height)
        if frame != window.frame {
            window.setFrame(frame, display: true, animate: false)
        }
    }

    private func createWindow() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.preferences.setValue(true, forKey: "developerExtrasEnabled")

        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsMagnification = true
        webView.allowsBackForwardNavigationGestures = true

        window = NSWindow(
            contentRect: preferredWindowFrame(for: NSScreen.main),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.delegate = self
        window.title = "Pi Web Desktop"
        window.titlebarAppearsTransparent = false
        // Keep the native green button and the standard Control-Command-F
        // shortcut available on a regular foreground application.
        window.collectionBehavior = [.fullScreenPrimary]
        window.minSize = NSSize(width: 560, height: 560)
        // 使用原生标题栏作为稳定的拖拽区域；网页内容不会被透明拖拽层遮挡。
        window.contentView = webView
        window.center()
        window.setFrameAutosaveName("PiWebMainWindow")
        window.makeKeyAndOrderFront(nil)
        fitWindowToCurrentScreen()
        if !NSApp.isActive {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }

    @objc private func showWindow(_ sender: Any?) {
        window.makeKeyAndOrderFront(nil)
        if !NSApp.isActive {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func windowDidChangeScreen(_ notification: Notification) {
        scheduleWindowFit()
    }

    @objc private func toggleFullScreen(_ sender: Any?) {
        window.toggleFullScreen(sender)
    }

    func windowWillEnterFullScreen(_ notification: Notification) {
        isFullScreenTransition = true
        screenFitWorkItem?.cancel()
        screenFitWorkItem = nil
    }

    func windowDidEnterFullScreen(_ notification: Notification) {
        isFullScreenTransition = false
    }

    func windowWillExitFullScreen(_ notification: Notification) {
        isFullScreenTransition = true
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        isFullScreenTransition = false
        // Re-apply the portrait layout only after AppKit has finished leaving
        // the full-screen Space and restored the normal window frame.
        scheduleWindowFit()
    }

    // MARK: - Service lifecycle

    private func resolvePiWebPath() -> String? {
        if let configured = configuration.piWebPath.nilIfEmpty {
            return FileManager.default.isExecutableFile(atPath: configured) ? configured : nil
        }
        let candidates = [
            "/opt/homebrew/bin/pi-web",
            "/usr/local/bin/pi-web",
            "\(FileManager.default.homeDirectoryForCurrentUser.path)/.npm-global/bin/pi-web"
        ]
        if let path = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return path
        }
        return shell(["/bin/zsh", "-lc", "command -v pi-web 2>/dev/null"])?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    private func ensureServerIsRunning() {
        checkServer { [weak self] ready in
            guard let self else { return }
            DispatchQueue.main.async {
                if ready {
                    self.setState(.running)
                    self.loadPiWeb()
                } else {
                    self.startManagedService()
                }
            }
        }
    }

    private func startManagedService() {
        guard !isStoppingService else { return }
        guard serviceProcess?.isRunning != true else {
            pollUntilReady()
            return
        }
        let path = configuration.piWebPath.nilIfEmpty ?? resolvePiWebPath()
        guard let piWebPath = path else {
            showStartupError("找不到 pi-web。请确认已执行 npm install -g @agegr/pi-web@latest。")
            return
        }

        do {
            try FileManager.default.createDirectory(at: serviceWorkingDirectory, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: logURL.path) {
                FileManager.default.createFile(atPath: logURL.path, contents: nil)
            }
            rotateLogsIfNeeded()
            let handle = try FileHandle(forWritingTo: logURL)
            try handle.seekToEnd()
            logHandle = handle

        let process = Process()
        process.executableURL = URL(fileURLWithPath: piWebPath)
        process.arguments = ["--hostname", configuration.hostname, "--port", String(configuration.port), "--no-open"]
        process.currentDirectoryURL = serviceWorkingDirectory
            var environment = ProcessInfo.processInfo.environment
            environment["PI_WEB_NO_OPEN"] = "1"
            if !configuration.allowedHosts.isEmpty {
                environment["PI_WEB_ALLOWED_HOSTS"] = configuration.allowedHosts
            } else {
                environment.removeValue(forKey: "PI_WEB_ALLOWED_HOSTS")
            }
            environment["PATH"] = "/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
            let proxyURL = configuration.httpProxy
            let httpsProxyURL = configuration.httpsProxy
            for (key, value) in [("HTTP_PROXY", proxyURL), ("http_proxy", proxyURL), ("HTTPS_PROXY", httpsProxyURL), ("https_proxy", httpsProxyURL)] {
                if value.isEmpty { environment.removeValue(forKey: key) } else { environment[key] = value }
            }
            if configuration.noProxy.isEmpty {
                environment.removeValue(forKey: "NO_PROXY")
                environment.removeValue(forKey: "no_proxy")
            } else {
                environment["NO_PROXY"] = configuration.noProxy
                environment["no_proxy"] = configuration.noProxy
            }
            process.environment = environment
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = handle
            process.standardError = handle
            process.terminationHandler = { [weak self] process in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.serviceProcess = nil
                    try? self.logHandle?.close()
                    self.logHandle = nil
                    if !self.isStoppingService && !self.isQuitting {
                        self.setState(.stopped)
                    }
                }
            }
            try process.run()
            serviceProcess = process
            didLaunchService = true
            startupAttempts = 0
            try "\(process.processIdentifier)\n".write(to: managedPIDURL, atomically: true, encoding: .utf8)
            setState(.starting)
            showLoadingPage(message: "正在启动 Pi Web…")
            pollUntilReady()
        } catch {
            showStartupError("无法启动 pi-web：\(error.localizedDescription)")
        }
    }

    private func pollUntilReady() {
        startupAttempts += 1
        guard startupAttempts <= maxStartupAttempts else {
            showStartupError("Pi Web 在 30 秒内未能启动。请查看日志：\(logURL.path)")
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self else { return }
            self.checkServer { ready in
                DispatchQueue.main.async {
                    if ready {
                        self.restartAttempts = 0
                        self.setState(.running)
                        self.loadPiWeb()
                    } else if let process = self.serviceProcess, !process.isRunning {
                        self.showStartupError("pi-web 进程已退出。请查看日志：\(self.logURL.path)")
                    } else {
                        self.pollUntilReady()
                    }
                }
            }
        }
    }

    private func stopService(completion: (() -> Void)? = nil) {
        isStoppingService = true
        let pid = managedServicePID()
        guard let pid else {
            isStoppingService = false
            setState(.stopped)
            completion?()
            return
        }
        DispatchQueue.global().async { [weak self] in
            _ = self?.shell(["/bin/kill", "-TERM", "\(pid)"])
            for _ in 0..<40 {
                if kill(pid, 0) != 0 { break }
                usleep(100_000)
            }
            if kill(pid, 0) == 0 {
                _ = self?.shell(["/bin/kill", "-KILL", "\(pid)"])
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.serviceProcess = nil
                self.didLaunchService = false
                self.isStoppingService = false
                try? FileManager.default.removeItem(at: self.managedPIDURL)
                self.setState(.stopped)
                completion?()
            }
        }
    }

    private func managedServicePID() -> pid_t? {
        if let process = serviceProcess, process.isRunning { return process.processIdentifier }
        guard let text = try? String(contentsOf: managedPIDURL, encoding: .utf8),
              let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)),
              pid > 1, kill(pid, 0) == 0,
              isPiWebProcess(pid) else {
            try? FileManager.default.removeItem(at: managedPIDURL)
            return nil
        }
        return pid
    }

    private func isPiWebProcess(_ pid: pid_t) -> Bool {
        let command = shell(["/bin/ps", "-o", "command=", "-p", "\(pid)"])?.lowercased() ?? ""
        return command.contains("pi-web")
    }

    private func rotateLogsIfNeeded() {
        let maxBytes = 10 * 1024 * 1024
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: logURL.path),
              let size = attributes[.size] as? NSNumber,
              size.intValue >= maxBytes else { return }

        let fileManager = FileManager.default
        let directory = logURL.deletingLastPathComponent()
        let base = logURL.deletingPathExtension().lastPathComponent
        let rotated = directory.appendingPathComponent("\(base).1.log")
        let previous = directory.appendingPathComponent("\(base).2.log")
        try? fileManager.removeItem(at: previous)
        try? fileManager.moveItem(at: rotated, to: previous)
        try? fileManager.moveItem(at: logURL, to: rotated)
        fileManager.createFile(atPath: logURL.path, contents: nil)
    }

    @objc private func showPreferences(_ sender: Any?) {
        let controller = PreferencesWindowController(configuration: configuration)
        controller.onSave = { [weak self] newConfiguration in
            guard let self else { return }
            let changed = self.configuration.runtimeSignature != newConfiguration.runtimeSignature
            let managed = changed && self.managedServicePID() != nil

            if managed {
                // 先停止旧参数启动的服务，再切换配置，避免旧端口和新端口同时留下实例。
                self.stopService { [weak self] in
                    guard let self else { return }
                    self.configuration = newConfiguration
                    self.reloadConfigurationAndService()
                }
            } else {
                self.configuration = newConfiguration
                if changed { self.reloadConfigurationAndService() }
                else { self.setState(self.currentState) }
            }
        }
        preferencesWindowController = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        if !NSApp.isActive {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private func reloadConfigurationAndService() {
        checkServer { [weak self] ready in
            DispatchQueue.main.async {
                guard let self else { return }
                if ready {
                    self.setState(.running)
                    self.loadPiWeb()
                } else if self.configuration.autoStart {
                    self.startManagedService()
                } else {
                    self.setState(.stopped)
                    self.showErrorPage(message: "设置已保存，服务尚未启动。")
                }
            }
        }
    }

    private func serviceListenerPID() -> String {
        let output = shell(["/usr/sbin/lsof", "-nP", "-t", "-iTCP:\(configuration.port)", "-sTCP:LISTEN"])?.split(whereSeparator: { $0.isNewline }).first.map(String.init)
        return output?.nilIfEmpty ?? "无"
    }

    private func checkServer(completion: @escaping (Bool) -> Void) {
        var request = URLRequest(url: startURL)
        request.timeoutInterval = 1
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.timeoutIntervalForRequest = 1
        sessionConfiguration.timeoutIntervalForResource = 1
        let session = URLSession(configuration: sessionConfiguration)
        session.dataTask(with: request) { _, response, _ in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            completion((200..<500).contains(status))
            session.finishTasksAndInvalidate()
        }.resume()
    }

    private func startHealthMonitor() {
        healthTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in
            guard let self, !self.isQuitting, !self.isStoppingService else { return }
            self.checkServer { ready in
                DispatchQueue.main.async {
                    if ready {
                        if case .running = self.currentState {
                            self.restartAttempts = 0
                        } else {
                            self.setState(.running)
                            self.restartAttempts = 0
                            self.loadPiWeb()
                        }
                    } else if case .running = self.currentState {
                        self.setState(.stopped)
                        self.showLoadingPage(message: "Pi Web 服务已断开，正在尝试恢复…")
                        if self.didLaunchService && self.restartAttempts < 1 {
                            self.restartAttempts += 1
                            self.startManagedService()
                        }
                    }
                }
            }
        }
    }

    private func setState(_ state: ServiceState) {
        currentState = state
        let text: String
        switch state {
        case .checking: text = "正在检查"
        case .starting: text = "正在启动"
        case .running: text = "正在运行"
        case .stopped: text = "已停止"
        case .failed(let message): text = "失败：\(message)"
        }
        statusMenuItem?.title = "状态：\(text)"
    }

    // MARK: - Actions

    @objc private func startServiceAction(_ sender: Any?) {
        checkServer { [weak self] ready in
            DispatchQueue.main.async {
                if ready { self?.setState(.running); self?.loadPiWeb() }
                else { self?.startManagedService() }
            }
        }
    }

    @objc private func restartServiceAction(_ sender: Any?) {
        if managedServicePID() != nil {
            stopService { [weak self] in self?.startManagedService() }
        } else {
            presentExternalServiceWarning(action: "重启") { [weak self] in
                self?.stopListenerProcessAndStart()
            }
        }
    }

    @objc private func stopServiceAction(_ sender: Any?) {
        if managedServicePID() != nil {
            stopService()
        } else {
            presentExternalServiceWarning(action: "停止") { [weak self] in
                self?.stopExternalListener()
            }
        }
    }

    private func presentExternalServiceWarning(action: String, proceed: @escaping () -> Void) {
        checkServer { [weak self] ready in
            DispatchQueue.main.async {
                guard let self else { return }
                if !ready {
                    if action == "重启" { self.startManagedService() }
                    else { self.setState(.stopped) }
                    return
                }
                let alert = NSAlert()
                alert.messageText = "这是外部启动的 Pi Web 服务"
                alert.informativeText = "该服务不是由本应用启动的。确定要\(action)它吗？"
                alert.addButton(withTitle: action)
                alert.addButton(withTitle: "取消")
                alert.alertStyle = .warning
                alert.beginSheetModal(for: self.window) { response in
                    if response == .alertFirstButtonReturn { proceed() }
                }
            }
        }
    }

    private func stopExternalListener() {
        let listener = Int32(serviceListenerPID().trimmingCharacters(in: .whitespacesAndNewlines))
        guard let listener, listener > 1, isPiWebProcess(listener) else { return }
        let parent = processParent(of: listener)
        let candidate = parent > 1 && isPiWebProcess(parent) ? parent : listener
        _ = shell(["/bin/kill", "-TERM", "\(candidate)"])
        setState(.stopped)
    }

    private func stopListenerProcessAndStart() {
        stopExternalListener()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.startManagedService() }
    }

    private func serviceProcessDescription() -> String {
        guard let pid = Int32(serviceListenerPID()), pid > 1 else { return "无" }
        return shell(["/bin/ps", "-o", "command=", "-p", "\(pid)"])?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "未知"
    }

    @objc private func openInBrowser(_ sender: Any?) { NSWorkspace.shared.open(startURL) }
    @objc private func copyLocalAddress(_ sender: Any?) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(startURL.absoluteString, forType: .string) }
    @objc private func openLog(_ sender: Any?) {
        if !FileManager.default.fileExists(atPath: logURL.path) { FileManager.default.createFile(atPath: logURL.path, contents: nil) }
        NSWorkspace.shared.open(logURL)
    }

    // 版本信息只有一个来源：bundle 的 Info.plist（由 Configuration/AppIdentity.xcconfig 生成）。
    // Swift 侧不保存第二套版本常量；读取失败时明确标注为开发构建。
    private var appVersionDescription: String {
        let info = Bundle.main.infoDictionary
        guard let shortVersion = (info?["CFBundleShortVersionString"] as? String)?.nilIfEmpty,
              let buildVersion = (info?["CFBundleVersion"] as? String)?.nilIfEmpty else {
            return "开发构建（Info.plist 缺少 CFBundleShortVersionString 或 CFBundleVersion）"
        }
        return "\(shortVersion) (\(buildVersion))"
    }

    @objc private func copyDiagnostics(_ sender: Any?) {
        let piWebPath = resolvePiWebPath() ?? "未找到"
        let piWebVersion = shell([piWebPath, "--version"])?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "未知"
        let nodeVersion = shell(["/usr/bin/env", "node", "--version"])?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "未知"
        let diagnostics = """
        Pi Web Desktop: \(appVersionDescription)
        pi-web: \(piWebVersion)
        Node.js: \(nodeVersion)
        服务地址: \(startURL.absoluteString)
        状态: \(statusDescription())
        监听 PID: \(serviceListenerPID())
        监听进程: \(serviceProcessDescription())
        托管 PID: \(managedServicePID().map(String.init) ?? "无（外部服务或未运行）")
        pi-web 路径: \(piWebPath)
        配置目录: ~/.pi/agent
        日志: \(logURL.path)
        """
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(diagnostics, forType: .string)
    }

    private func statusDescription() -> String {
        switch currentState {
        case .checking: return "正在检查"
        case .starting: return "正在启动"
        case .running: return managedServicePID() == nil ? "正在运行（外部服务）" : "正在运行（本应用管理）"
        case .stopped: return "已停止"
        case .failed(let message): return "失败：\(message)"
        }
    }

    @objc private func reloadPage(_ sender: Any?) { webView.reload() }
    @objc private func hardReloadPage(_ sender: Any?) { webView.reloadFromOrigin() }
    @objc private func zoomIn(_ sender: Any?) { webView.pageZoom = min(webView.pageZoom + 0.1, 3.0) }
    @objc private func zoomOut(_ sender: Any?) { webView.pageZoom = max(webView.pageZoom - 0.1, 0.5) }
    @objc private func resetZoom(_ sender: Any?) { webView.pageZoom = 1.0 }

    @objc private func showFindBar(_ sender: Any?) {
        if findBar == nil { createFindBar() }
        findBar?.isHidden = false
        window.makeFirstResponder(findField)
    }

    private func createFindBar() {
        guard let contentView = window.contentView else { return }
        let bar = NSVisualEffectView()
        bar.material = .headerView
        bar.blendingMode = .withinWindow
        bar.translatesAutoresizingMaskIntoConstraints = false
        let field = NSSearchField()
        field.placeholderString = "在页面中查找"
        field.target = self
        field.action = #selector(findText(_:))
        field.translatesAutoresizingMaskIntoConstraints = false
        let previous = NSButton(title: "‹", target: self, action: #selector(findPrevious(_:)))
        let next = NSButton(title: "›", target: self, action: #selector(findNext(_:)))
        let close = NSButton(title: "完成", target: self, action: #selector(closeFindBar(_:)))
        for button in [previous, next, close] { button.translatesAutoresizingMaskIntoConstraints = false; bar.addSubview(button) }
        bar.addSubview(field)
        contentView.addSubview(bar)
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: contentView.topAnchor), bar.trailingAnchor.constraint(equalTo: contentView.trailingAnchor), bar.heightAnchor.constraint(equalToConstant: 44), bar.widthAnchor.constraint(equalToConstant: 410),
            field.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 10), field.centerYAnchor.constraint(equalTo: bar.centerYAnchor), field.widthAnchor.constraint(equalToConstant: 250),
            previous.leadingAnchor.constraint(equalTo: field.trailingAnchor, constant: 4), previous.centerYAnchor.constraint(equalTo: bar.centerYAnchor), previous.widthAnchor.constraint(equalToConstant: 32),
            next.leadingAnchor.constraint(equalTo: previous.trailingAnchor, constant: 2), next.centerYAnchor.constraint(equalTo: bar.centerYAnchor), next.widthAnchor.constraint(equalToConstant: 32),
            close.leadingAnchor.constraint(equalTo: next.trailingAnchor, constant: 4), close.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -8), close.centerYAnchor.constraint(equalTo: bar.centerYAnchor)
        ])
        findBar = bar
        findField = field
    }

    @objc private func findText(_ sender: Any?) { performFind(backwards: false) }
    @objc private func findNext(_ sender: Any?) { performFind(backwards: false) }
    @objc private func findPrevious(_ sender: Any?) { performFind(backwards: true) }
    private func performFind(backwards: Bool) {
        guard let text = findField?.stringValue, !text.isEmpty else { return }
        if #available(macOS 11.0, *) {
            let configuration = WKFindConfiguration()
            configuration.backwards = backwards
            configuration.wraps = true
            webView.find(text, configuration: configuration) { _ in }
        }
    }
    @objc private func closeFindBar(_ sender: Any?) { findBar?.isHidden = true; window.makeFirstResponder(webView) }

    @objc private func quitKeepingService(_ sender: Any?) {
        guard !isQuitting else { return }
        isQuitting = true
        healthTimer?.invalidate()
        isStoppingService = false
        try? logHandle?.close()
        logHandle = nil
        // 不调用 stopService，也不删除 service.pid，让 pi-web 继续独立运行。
        NSApp.terminate(nil)
    }

    @objc private func quitApp(_ sender: Any?) {
        quitAndStop(sender)
    }

    @objc private func quitAndStop(_ sender: Any?) {
        guard !isQuitting else { return }
        isQuitting = true
        healthTimer?.invalidate()
        isStoppingService = true

        let finish = { [weak self] in
            guard let self else { return }
            self.stopRemainingListenerAndQuit()
        }

        if managedServicePID() != nil {
            stopService(completion: finish)
        } else {
            finish()
        }
    }

    private func stopRemainingListenerAndQuit() {
        let listener = Int32(serviceListenerPID().trimmingCharacters(in: .whitespacesAndNewlines))
        guard let listener, listener > 1, isPiWebProcess(listener) else {
            isStoppingService = false
            NSApp.terminate(nil)
            return
        }
        let parent = processParent(of: listener)
        let candidate = parent > 1 && isPiWebProcess(parent) ? parent : listener
        _ = shell(["/bin/kill", "-TERM", "\(candidate)"])
        if candidate != listener { _ = shell(["/bin/kill", "-TERM", "\(listener)"]) }
        waitForServerToStop(candidate: candidate, listener: listener, attempt: 0)
    }

    private func waitForServerToStop(candidate: pid_t, listener: pid_t, attempt: Int) {
        checkServer { [weak self] ready in
            DispatchQueue.main.async {
                guard let self else { return }
                if !ready {
                    self.isStoppingService = false
                    NSApp.terminate(nil)
                } else if attempt < 30 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        self.waitForServerToStop(candidate: candidate, listener: listener, attempt: attempt + 1)
                    }
                } else {
                    // 明确选择“退出并停止”时，同时结束包装进程和实际监听进程。
                    _ = self.shell(["/bin/kill", "-KILL", "\(candidate)"])
                    if candidate != listener { _ = self.shell(["/bin/kill", "-KILL", "\(listener)"]) }
                    self.isStoppingService = false
                    NSApp.terminate(nil)
                }
            }
        }
    }

    // MARK: - WebKit

    private func loadPiWeb() { webView.load(URLRequest(url: startURL, cachePolicy: .reloadIgnoringLocalCacheData)) }

    private func isLocalURL(_ url: URL) -> Bool {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return false }
        return ["127.0.0.1", "localhost", "::1"].contains(url.host?.lowercased() ?? "") && (url.port ?? configuration.port) == configuration.port
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        guard !isQuitting else { return }
        setState(.stopped)
        showErrorPage(message: "页面加载失败：\(error.localizedDescription)")
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        guard !isQuitting else { return }
        setState(.stopped)
        showErrorPage(message: "无法连接 Pi Web：\(error.localizedDescription)")
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else { decisionHandler(.cancel); return }
        let scheme = url.scheme?.lowercased() ?? ""
        if isLocalURL(url) || ["about", "blob", "data"].contains(scheme) {
            decisionHandler(.allow)
        } else {
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        if !navigationResponse.canShowMIMEType {
            if #available(macOS 11.3, *) { decisionHandler(.download) } else { decisionHandler(.cancel) }
        } else { decisionHandler(.allow) }
    }

    @available(macOS 11.3, *)
    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) { download.delegate = self }
    @available(macOS 11.3, *)
    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) { download.delegate = self }

    @available(macOS 11.3, *)
    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedFilename
        panel.beginSheetModal(for: window) { result in completionHandler(result == .OK ? panel.url : nil) }
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url {
            if isLocalURL(url) { webView.load(URLRequest(url: url)) } else { NSWorkspace.shared.open(url) }
        }
        return nil
    }

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.canChooseFiles = true
        panel.beginSheetModal(for: window) { response in completionHandler(response == .OK ? panel.urls : nil) }
    }

    // MARK: - Error and utility

    private func showErrorPage(message: String) {
        showLoadingPage(message: message)
    }

    private func showLoadingPage(message: String) {
        let safe = message.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
        let html = """
        <!doctype html><meta charset="utf-8"><style>
        html,body{height:100%;margin:0;background:#0b1020;color:#d7fff8;font:15px -apple-system,BlinkMacSystemFont,sans-serif}body{display:grid;place-items:center}.box{text-align:center}.pi{font:700 88px ui-monospace,monospace;color:#7fffe8;text-shadow:0 0 28px #21d9cc88}.msg{margin-top:18px;color:#a8b3cc}.dot{display:inline-block;animation:pulse 1s infinite alternate}@keyframes pulse{to{opacity:.25}}</style>
        <div class="box"><div class="pi">π</div><div class="msg">\(safe) <span class="dot">●</span></div></div>
        """
        webView.loadHTMLString(html, baseURL: nil)
    }

    private func showStartupError(_ message: String) {
        setState(.failed(message))
        showLoadingPage(message: "启动失败")
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Pi Web 启动失败"
        alert.informativeText = message
        alert.addButton(withTitle: "重试")
        alert.addButton(withTitle: "打开日志")
        alert.addButton(withTitle: "退出")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            switch response {
            case .alertFirstButtonReturn: self.ensureServerIsRunning()
            case .alertSecondButtonReturn: self.openLog(nil)
            default: self.quitApp(nil)
            }
        }
    }

    @discardableResult private func shell(_ arguments: [String]) -> String? {
        guard let executable = arguments.first else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = Array(arguments.dropFirst())
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run(); process.waitUntilExit() } catch { return nil }
        guard process.terminationStatus == 0 else { return nil }
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
    }

    private func processParent(of pid: pid_t) -> pid_t {
        let output = shell(["/bin/ps", "-o", "ppid=", "-p", "\(pid)"])?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return pid_t(output) ?? 0
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(startServiceAction(_:)): return managedServicePID() == nil
        case #selector(stopServiceAction(_:)), #selector(restartServiceAction(_:)): return true
        case #selector(toggleFullScreen(_:)):
            menuItem.title = window.styleMask.contains(.fullScreen) ? "退出全屏幕" : "进入全屏幕"
            return true
        default: return true
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
