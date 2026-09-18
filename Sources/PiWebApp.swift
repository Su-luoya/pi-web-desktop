import Cocoa

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var window: NSWindow!
    private var webViewController: WebViewController!
    private var statusMenuItem: NSMenuItem?
    private var terminationDecisionPending = false
    private var hasInstanceLock = false
    private var eventMonitor: Any?
    private var screenParametersObserver: NSObjectProtocol?
    private var screenFitWorkItem: DispatchWorkItem?
    private var isFullScreenTransition = false
    private var currentState: ServiceState = .checking
    private var preferencesWindowController: PreferencesWindowController?

    private let appConfiguration: AppConfiguration
    private let commandRunner: CommandRunning
    private let processInspector: ProcessInspector
    private let serviceManager: ServiceManager

    private var startURL: URL { serviceManager.configuration.serviceURL }

    private var instanceLockHandle: FileHandle?

    init(
        appConfiguration: AppConfiguration = AppConfiguration.forCurrentProcess(),
        commandRunner: CommandRunning = SystemCommandRunner()
    ) {
        self.appConfiguration = appConfiguration
        self.commandRunner = commandRunner
        let processInspector = ProcessInspector(runner: commandRunner)
        self.processInspector = processInspector
        self.serviceManager = ServiceManager(
            configuration: appConfiguration.serviceConfiguration,
            appConfiguration: appConfiguration,
            processInspector: processInspector,
            commandRunner: commandRunner
        )
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if appConfiguration.isSmokeLaunch {
            runSmokeLaunch()
            return
        }
        try? FileManager.default.createDirectory(at: appConfiguration.supportURL, withIntermediateDirectories: true)
        guard acquireSingleInstanceLock() else {
            NSApp.terminate(nil)
            return
        }
        try? "\(ProcessInfo.processInfo.processIdentifier)\n".write(to: appConfiguration.appPIDURL, atomically: true, encoding: .utf8)
        NSApp.mainMenu = nil
        installQuitShortcuts()
        installScreenChangeObserver()
        installMainMenu()
        createWindow()
        installServiceManagerCallbacks()
        serviceManager.setState(.checking)
        webViewController.showLoadingPage(message: "正在检查 Pi Web 服务…")
        serviceManager.startAtLaunch()
    }

    // MARK: - Smoke launch

    /// `PI_WEB_DESKTOP_SMOKE=1` startup: temporary support directory, no
    /// single-instance lock and no service auto-start. Prints the fixed marker
    /// and exits 0 once the main window exists; any failure exits non-zero
    /// without printing it. Without the variable this path is never taken.
    private func runSmokeLaunch() {
        do {
            try FileManager.default.createDirectory(at: appConfiguration.supportURL, withIntermediateDirectories: true)
        } catch {
            failSmokeLaunch("cannot create \(appConfiguration.supportURL.path): \(error.localizedDescription)")
        }
        installMainMenu()
        createWindow()
        guard window != nil, webViewController != nil else {
            failSmokeLaunch("main window was not created")
        }
        let supportURL = appConfiguration.supportURL
        DispatchQueue.main.async {
            FileHandle.standardOutput.write(Data((AppConfiguration.smokeReadyMarker + "\n").utf8))
            try? FileManager.default.removeItem(at: supportURL)
            exit(0)
        }
    }

    private func failSmokeLaunch(_ message: String) -> Never {
        FileHandle.standardError.write(Data("smoke launch failed: \(message)\n".utf8))
        exit(1)
    }

    func applicationWillTerminate(_ notification: Notification) {
        serviceManager.stopHealthMonitor()
        try? FileManager.default.removeItem(at: appConfiguration.appPIDURL)
        serviceManager.closeLog()
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
        guard !serviceManager.isQuitting else { return .terminateNow }
        guard !terminationDecisionPending else { return .terminateLater }

        switch serviceManager.configuration.quitBehavior {
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
        let existingPID = (try? String(contentsOf: appConfiguration.appPIDURL, encoding: .utf8))
            .flatMap { ProcessInspector.parsePIDRecord($0) }
        if let existingPID, processInspector.isProcessAlive(existingPID) {
            return false
        }
        if FileManager.default.fileExists(atPath: appConfiguration.instanceLockURL.path) {
            try? FileManager.default.removeItem(at: appConfiguration.instanceLockURL)
        }
        FileManager.default.createFile(atPath: appConfiguration.instanceLockURL.path, contents: nil)
        do {
            instanceLockHandle = try FileHandle(forWritingTo: appConfiguration.instanceLockURL)
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
        webViewController = WebViewController(
            serviceURL: startURL,
            servicePort: serviceManager.configuration.port,
            windowProvider: { [weak self] in self?.window }
        )
        webViewController.onNavigationFailure = { [weak self] failure in
            guard let self, !self.serviceManager.isQuitting else { return }
            self.serviceManager.setState(.stopped)
            switch failure {
            case .loadFailed(let description):
                self.webViewController.showErrorPage(message: "页面加载失败：\(description)")
            case .connectionFailed(let description):
                self.webViewController.showErrorPage(message: "无法连接 Pi Web：\(description)")
            }
        }

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
        window.contentView = webViewController.webView
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

    // MARK: - Service manager callbacks

    private func installServiceManagerCallbacks() {
        serviceManager.onStateChange = { [weak self] state in
            self?.applyState(state)
        }
        serviceManager.onLoadPage = { [weak self] in
            guard let self else { return }
            self.webViewController.updateService(
                url: self.serviceManager.configuration.serviceURL,
                port: self.serviceManager.configuration.port
            )
            self.webViewController.loadServicePage()
        }
        serviceManager.onPageMessage = { [weak self] message in
            self?.webViewController.showLoadingPage(message: message)
        }
        serviceManager.onStartupFailure = { [weak self] message in
            self?.presentStartupError(message)
        }
    }

    private func applyState(_ state: ServiceState) {
        currentState = state
        // The status menu keeps the pre-split base text; the ownership suffix is
        // reserved for the diagnostics copy.
        statusMenuItem?.title = "状态：\(state.displayText)"
    }

    /// Alert shown when the managed service could not start. ServiceManager owns
    /// the state change and the "启动失败" page; the buttons are UI wiring here.
    private func presentStartupError(_ message: String) {
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
            case .alertFirstButtonReturn: self.serviceManager.ensureServerIsRunning()
            case .alertSecondButtonReturn: self.openLog(nil)
            default: self.quitApp(nil)
            }
        }
    }

    @objc private func showPreferences(_ sender: Any?) {
        let controller = PreferencesWindowController(configuration: serviceManager.configuration)
        controller.onSave = { [weak self] newConfiguration in
            guard let self else { return }
            self.appConfiguration.save(newConfiguration)
            let changed = self.serviceManager.configuration.runtimeSignature != newConfiguration.runtimeSignature
            let managed = changed && self.serviceManager.managedServicePID() != nil

            if managed {
                // 先停止旧参数启动的服务，再切换配置，避免旧端口和新端口同时留下实例。
                self.serviceManager.stopService { [weak self] in
                    guard let self else { return }
                    self.serviceManager.updateConfiguration(newConfiguration)
                    self.serviceManager.reloadAfterConfigurationChange()
                }
            } else {
                self.serviceManager.updateConfiguration(newConfiguration)
                if changed {
                    self.serviceManager.reloadAfterConfigurationChange()
                } else {
                    // Re-emit the current state so the status menu title refreshes.
                    self.serviceManager.setState(self.serviceManager.currentState)
                }
            }
        }
        preferencesWindowController = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        if !NSApp.isActive {
            NSApp.activate(ignoringOtherApps: true)
        }
    }


    // MARK: - Actions

    @objc private func startServiceAction(_ sender: Any?) {
        serviceManager.startService()
    }

    @objc private func restartServiceAction(_ sender: Any?) {
        if serviceManager.managedServicePID() != nil {
            serviceManager.restartManagedService()
        } else {
            // 外部服务只读：确认后的“重启”只会在端口空闲时启动一个可验证的托管进程；
            // 如果外部服务仍在响应，应用只是继续使用它，不会向它发送信号。
            presentExternalServiceWarning(action: "重启") { [weak self] in
                self?.serviceManager.ensureServerIsRunning()
            }
        }
    }

    @objc private func stopServiceAction(_ sender: Any?) {
        if serviceManager.managedServicePID() != nil {
            serviceManager.stopService()
        } else {
            // 外部服务只读：保留原有警告文案，但确认后 stopService() 找不到可验证的
            // 所有权记录，只会更新状态，不会向任何进程发送 TERM/KILL。
            presentExternalServiceWarning(action: "停止") { [weak self] in
                self?.serviceManager.stopService()
            }
        }
    }

    /// Warning shown before a stop/restart action that involves a service the
    /// app cannot prove it started. The copy is intentionally unchanged, but
    /// `proceed` may only update state or start a managed process: an external
    /// service never receives a signal.
    private func presentExternalServiceWarning(action: String, proceed: @escaping () -> Void) {
        serviceManager.checkServer { [weak self] ready in
            DispatchQueue.main.async {
                guard let self else { return }
                if !ready {
                    if action == "重启" { self.serviceManager.startManagedService() }
                    else { self.serviceManager.setState(.stopped) }
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

    @objc private func openInBrowser(_ sender: Any?) { NSWorkspace.shared.open(startURL) }
    @objc private func copyLocalAddress(_ sender: Any?) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(startURL.absoluteString, forType: .string) }
    @objc private func openLog(_ sender: Any?) {
        let logURL = appConfiguration.logURL
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
        let piWebPath = serviceManager.resolvePiWebPath() ?? "未找到"
        let piWebVersion = shell([piWebPath, "--version"])?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "未知"
        let nodeVersion = shell(["/usr/bin/env", "node", "--version"])?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "未知"
        let diagnostics = DiagnosticsCollector.text(for: DiagnosticsInput(
            appVersion: appVersionDescription,
            piWebVersion: piWebVersion,
            nodeVersion: nodeVersion,
            serviceAddress: startURL.absoluteString,
            status: statusDescription(),
            listenerPID: processInspector.listenerPIDDescription(port: serviceManager.configuration.port),
            listenerProcess: processInspector.listenerProcessDescription(port: serviceManager.configuration.port),
            managedPID: serviceManager.managedServicePID().map(String.init) ?? "无（外部服务或未运行）",
            piWebPath: piWebPath,
            configurationDirectory: "~/.pi/agent",
            logPath: appConfiguration.logURL.path
        ))
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(diagnostics, forType: .string)
    }

    private func statusDescription() -> String {
        ServiceState.statusText(for: currentState, managedPID: serviceManager.managedServicePID())
    }

    @objc private func reloadPage(_ sender: Any?) { webViewController.reload() }
    @objc private func hardReloadPage(_ sender: Any?) { webViewController.reloadFromOrigin() }
    @objc private func zoomIn(_ sender: Any?) { webViewController.zoomIn() }
    @objc private func zoomOut(_ sender: Any?) { webViewController.zoomOut() }
    @objc private func resetZoom(_ sender: Any?) { webViewController.resetZoom() }

    @objc private func showFindBar(_ sender: Any?) { webViewController.showFindBar(in: window) }

    @objc private func quitKeepingService(_ sender: Any?) {
        guard !serviceManager.isQuitting else { return }
        serviceManager.keepRunningOnQuit()
        // 不调用 stopService，也不删除 service-owner.json，让 pi-web 继续独立运行。
        NSApp.terminate(nil)
    }

    @objc private func quitApp(_ sender: Any?) {
        quitAndStop(sender)
    }

    @objc private func quitAndStop(_ sender: Any?) {
        guard !serviceManager.isQuitting else { return }
        serviceManager.stopAllServices {
            NSApp.terminate(nil)
        }
    }

    // MARK: - Error and utility

    @discardableResult private func shell(_ arguments: [String]) -> String? {
        commandRunner.run(arguments)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(startServiceAction(_:)): return serviceManager.managedServicePID() == nil
        case #selector(stopServiceAction(_:)), #selector(restartServiceAction(_:)): return true
        case #selector(toggleFullScreen(_:)):
            menuItem.title = window.styleMask.contains(.fullScreen) ? "退出全屏幕" : "进入全屏幕"
            return true
        default: return true
        }
    }
}
