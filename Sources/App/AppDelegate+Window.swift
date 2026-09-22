/// Window and WebView creation, restoration and navigation policy.

import Cocoa

extension AppDelegate {
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

    /// 把**最近使用的窗口**（`mainWindow`，不一定等于启动主窗口 primary）适配到它
    /// 当前所在的屏幕（既有调用点语义不变，见 `AppDelegate+Quit.swift` 的
    /// `scheduleWindowFit`）。
    func fitWindowToCurrentScreen() {
        fitOnCurrentScreen(window)
    }

    /// 把指定窗口适配到它当前所在的屏幕。多窗口（GitHub #168）下每个窗口只改
    /// 自己的 frame：对某个窗口的适配不会覆盖用户刚挪到另一块屏幕上的新窗口。
    private func fitOnCurrentScreen(_ target: NSWindow?) {
        guard let target, let screen = target.screen ?? NSScreen.main else { return }
        // Native full-screen mode owns the window frame. Do not overwrite it
        // while AppKit is entering or already in a full-screen Space.
        guard !isFullScreenTransition, !target.styleMask.contains(.fullScreen) else { return }
        let visible = screen.visibleFrame
        guard visible.width > 0, visible.height > 0 else { return }

        // 竖屏时必须覆盖整个可用桌面区域。原实现只在窗口过宽时缩小，
        // 而且还额外留了 20pt 边距；如果窗口之前已经较小，就永远不会
        // 被放大回去，因此在旋转显示器或恢复自动保存 frame 后会偶发露出桌面。
        if visible.height > visible.width {
            if target.frame != visible {
                target.setFrame(visible, display: true, animate: false)
            }
            return
        }

        var frame = target.frame
        frame.size.width = min(max(frame.size.width, target.minSize.width), visible.width)
        frame.size.height = min(max(frame.size.height, target.minSize.height), visible.height)
        frame.origin.x = min(max(frame.origin.x, visible.minX), visible.maxX - frame.width)
        frame.origin.y = min(max(frame.origin.y, visible.minY), visible.maxY - frame.height)
        if frame != target.frame {
            target.setFrame(frame, display: true, animate: false)
        }
    }

    // MARK: - 窗口创建（GitHub #168 多窗口）

    /// 创建**启动主窗口（primary）**：登记进 `windowRegistry` 并标记为 primary
    /// （primary 与最近使用顺序相互独立，见 `AppWindowRegistry`），继续使用
    /// `PiWebMainWindow` 这个自动保存名（多窗口后只有这一个窗口使用它）。
    func createWindow() {
        let made = makeWindow(autosaveName: "PiWebMainWindow", offsetFromMostRecentlyUsed: false)
        windowRegistry.markPrimary(window: made.window)
        presentWindow(made.window)
    }

    /// 「新建窗口」/ ⌘N 的入口：新窗口 + **新的** `WebViewController` 实例，加载
    /// `serviceManager.configuration.serviceURL`（GitHub #149 的放行面由
    /// `WebViewController` 自身的 `serviceURL` 决定，不受窗口数量影响）。
    ///
    /// 窗口共享同一个 `ServiceManager`：开窗只创建展示层，不启动、不停止、不重启
    /// 服务；新窗口位置按最近使用窗口级联偏移，也不与主窗口抢同一个 autosave 名。
    @discardableResult
    func createNewWindow() -> NSWindow {
        let made = makeWindow(autosaveName: nil, offsetFromMostRecentlyUsed: true)
        presentWindow(made.window)
        loadInitialPage(in: made.controller)
        return made.window
    }

    /// ⌘N / 窗口菜单「新建窗口」动作。
    @objc func newWindow(_ sender: Any?) {
        createNewWindow()
    }

    /// 创建一个窗口与它自己的 WebView 控制器，并登记两者。
    ///
    /// 控制器先建、窗口后建：`WebViewController` 需要在初始化时就拿到窗口供
    /// 查找栏/保存面板使用，而窗口的 `contentView` 又需要 `webView`。这里先给
    /// 控制器一个占位 provider，窗口建好后立刻改写成绑定该窗口的 provider。
    private func makeWindow(
        autosaveName: String?,
        offsetFromMostRecentlyUsed: Bool
    ) -> (window: NSWindow, controller: WebViewController) {
        let controller = WebViewController(
            serviceURL: startURL,
            servicePort: serviceManager.configuration.port,
            windowProvider: { nil }
        )
        controller.onNavigationFailure = { [weak self, weak controller] failure in
            guard let self, let controller, !self.serviceManager.isQuitting else { return }
            // 导航失败只写日志并渲染错误页：服务状态由启动流程与健康检查决定，
            // 不能因为一次页面级失败（例如被取消的外链导航）被改成「已停止」。
            // 多窗口下错误页只渲染到出错的那个窗口，其它窗口保持原样。
            let message: String
            switch failure {
            case .loadFailed(let description):
                message = "页面加载失败：\(description)"
            case .connectionFailed(let description):
                message = "无法连接 Pi Web：\(description)"
            }
            _ = self.logWriter.append(self.logRedactor.redact(message))
            controller.showErrorPage(message: message)
        }

        let newWindow = NSWindow(
            contentRect: preferredWindowFrame(for: NSScreen.main),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        newWindow.delegate = self
        newWindow.title = "Pi Web Desktop"
        newWindow.titlebarAppearsTransparent = false
        // Keep the native green button and the standard Control-Command-F
        // shortcut available on a regular foreground application.
        newWindow.collectionBehavior = [.fullScreenPrimary]
        newWindow.minSize = NSSize(width: 560, height: 560)
        // 使用原生标题栏作为稳定的拖拽区域；网页内容不会被透明拖拽层遮挡。
        newWindow.contentView = controller.webView
        // 启动主窗口（primary）只隐藏不关闭（`windowShouldClose`）；⌘N 打开的
        // 窗口可以真正关闭。
        // 让 ARC 持有/释放窗口，避免 AppKit 在 isReleasedWhenClosed 下重复释放。
        newWindow.isReleasedWhenClosed = false
        controller.windowProvider = { [weak newWindow] in newWindow }
        if offsetFromMostRecentlyUsed, let reference = windowRegistry.mainWindow {
            cascade(newWindow, from: reference)
        } else {
            newWindow.center()
        }
        if let autosaveName {
            newWindow.setFrameAutosaveName(autosaveName)
        }
        windowRegistry.register(window: newWindow, controller: controller)
        return (newWindow, controller)
    }

    /// 新窗口位置：从最近使用窗口向右下偏移；偏移后超出屏幕可用区域时回落到
    /// 该屏幕上的默认 frame（竖屏同样是整块可用区域）。
    private func cascade(_ target: NSWindow, from reference: NSWindow) {
        let screen = reference.screen ?? NSScreen.main
        var frame = reference.frame
        frame.origin.x += 24
        frame.origin.y -= 24
        if let visible = screen?.visibleFrame, !visible.contains(frame) {
            frame = preferredWindowFrame(for: screen)
        }
        target.setFrame(frame, display: false)
    }

    /// 把窗口显示到最前并适配当前屏幕；主窗口启动路径与 ⌘N 共用。
    private func presentWindow(_ target: NSWindow) {
        target.makeKeyAndOrderFront(nil)
        fitOnCurrentScreen(target)
        if !NSApp.isActive {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    /// 新窗口的首页：依赖门控就绪时加载同一个服务地址；门控未就绪时渲染与主窗口
    /// 同一来源（`DiagnosticsRouting` 的输入）的诊断状态页，而不是留下空白窗口。
    /// 两种路径都不触碰服务生命周期。
    private func loadInitialPage(in controller: WebViewController) {
        guard dependencyGate == .ready, workspaceValidation.isUsable else {
            let dependencyText = dependencyReport.map {
                DependencyReportPresenter.statusPageText(
                    for: $0,
                    setupIncomplete: !appConfiguration.hasCompletedFirstLaunchSetup
                )
            }
            let message = [workspaceProblemMessage, dependencyText]
                .compactMap { $0 }
                .filter { !$0.isEmpty }
                .joined(separator: "\n\n")
            controller.showDependencyPage(
                title: appConfiguration.hasCompletedFirstLaunchSetup
                    ? "无法启动 Pi Web 服务"
                    : "首次启动环境检查",
                message: message.isEmpty ? "依赖检查尚未完成，请稍后重新检测。" : message
            )
            return
        }
        controller.updateService(
            url: serviceManager.configuration.serviceURL,
            port: serviceManager.configuration.port
        )
        controller.loadServicePage()
    }

    // MARK: - 打开工作目录

    /// Finder 拖放 / `open -a` 的入口（GitHub #135 F3）。
    ///
    /// 只接受 file URL：非 file URL（http/https、自定义 scheme）的 `path` 不是
    /// 目录路径，拿去校验只会得到误导性的“目录不存在”，因此显式忽略。一次打开
    /// 多个 file URL 时只处理第一个，其余记一条脱敏日志（只记数量，不记路径）：
    /// 既不静默丢弃，也不为多个 URL 弹多个窗口或连续切换。
    func application(_ application: NSApplication, open urls: [URL]) {
        let fileURLs = urls.filter(\.isFileURL)
        guard let directory = fileURLs.first else {
            if !urls.isEmpty {
                _ = logWriter.append(logRedactor.redact("打开请求含 \(urls.count) 个非文件 URL，已忽略"))
            }
            return
        }
        if fileURLs.count > 1 {
            _ = logWriter.append(logRedactor.redact("打开请求含 \(fileURLs.count) 个文件 URL，只处理第一个"))
        }
        requestWorkspaceSwitch(to: directory)
    }

    /// 关闭窗口：**只有启动主窗口（primary）**沿用 GitHub #158 的语义（只 `orderOut`
    /// 隐藏，窗口对象、WebView 与页面会话都保留，服务不因关窗而停止）；**其它所有
    /// 窗口**（包括 ⌘N 新建后成为最近使用的窗口）返回 true 真正关闭，登记表在
    /// `windowWillClose` 里移除它，其它窗口完全不受影响。
    ///
    /// 判据是「是不是 primary」而不是「是不是最近使用」：否则 ⌘N 之后新窗口成为
    /// 最近使用，就永远关不掉，而用户真正想关的（最近使用）窗口反而关不掉。
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if windowRegistry.isPrimaryWindow(sender) {
            sender.orderOut(nil)
            return false
        }
        return true
    }

    /// 窗口真正关闭（红色关闭按钮、⌘W 或以后新增的“关闭窗口”动作）后从登记表
    /// 移除，避免对已释放窗口继续下发页面动作。移除 primary 时 `primaryWindow`
    /// 回到 nil（正常路径不会发生，因为 `windowShouldClose` 对 primary 只隐藏），
    /// 下次 `showMainWindow()` 会补建窗口并登记新的 primary；移除最近使用的窗口
    /// 时 `mainWindow` 由下一个最近使用窗口接任。登记表清空只意味着下次会补建窗口，
    /// **不代表**服务被停止（服务生命周期只由 `ServiceManager` 决定）。
    func windowWillClose(_ notification: Notification) {
        guard let closed = notification.object as? NSWindow else { return }
        windowRegistry.remove(window: closed)
    }

    /// 窗口成为 key 窗口即记为最近使用（只影响菜单/页面动作的回落目标，**不改变**
    /// 启动主窗口 primary）。
    func windowDidBecomeKey(_ notification: Notification) {
        guard let key = notification.object as? NSWindow else { return }
        windowRegistry.noteUsage(of: key)
    }

    /// 「显示 Pi Web」菜单项：与 Dock 点击同一条路径（恢复启动主窗口 primary）。
    @objc func showWindow(_ sender: Any?) {
        showMainWindow()
    }

    func windowDidChangeScreen(_ notification: Notification) {
        // 最近使用的窗口沿用防抖适配（`scheduleWindowFit`，见 `AppDelegate+Quit.swift`）；
        // 其它窗口直接适配自己，避免把某个窗口的屏幕变化应用到最近使用窗口。
        if let changed = notification.object as? NSWindow, !windowRegistry.isMainWindow(changed) {
            fitOnCurrentScreen(changed)
            return
        }
        scheduleWindowFit()
    }

    /// 全屏幕（菜单 ⌃⌘F 与绿色按钮）：作用于当前 key 窗口（仅限已登记窗口），
    /// 没有可用的 key 窗口时回落到最近使用的窗口（`mainWindow`）。
    @objc func toggleFullScreen(_ sender: Any?) {
        activeWindow?.toggleFullScreen(sender)
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

    // MARK: - Dock 恢复（GitHub #158）

    /// 点 Dock 图标（或应用被重新打开）时把**启动主窗口（primary）**带回来。返回
    /// true 表示事件已处理，AppKit 不再走自带的“新建窗口”路径。
    ///
    /// AppKit 只在 `hasVisibleWindows == false` 时调这个方法，恰好覆盖三种情形：
    /// 1. 红色关闭按钮之后（`windowShouldClose` 只做 `orderOut(nil)`）；
    /// 2. 窗口被最小化到 Dock（`isVisible` 仍为 true，但屏幕上没有窗口）；
    /// 3. 窗口还没创建（启动早期点击 Dock 图标）。
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        showMainWindow()
        return true
    }

    /// 把**启动主窗口（primary）**显示到当前屏幕并置前；登记表为空或 primary 缺失
    /// 时补建一个窗口，并在 `createWindow()` 里把它登记为新的 primary。
    ///
    /// 关闭按钮只隐藏 primary（见 `windowShouldClose`），窗口对象、WebView 和页面
    /// 会话都还在，所以这里**必须复用**同一个窗口：重建会丢掉页面状态并留下第二个
    /// 窗口。恢复的不是「最近使用」窗口（⌘N 打开的新窗口可能正是最近使用，但它不是
    /// 主窗口）；只有在 primary 不存在时才补建，见 `AppWindowRegistry`。
    func showMainWindow() {
        if let primary = windowRegistry.primaryWindow {
            // 最小化的窗口必须先还原：`makeKeyAndOrderFront` 不会把它拉出最小化状态。
            if primary.isMiniaturized {
                primary.deminiaturize(nil)
            }
            // 隐藏期间显示器可能已经变过（分辨率/旋转/插拔外接屏），重新显示前按当前
            // 屏幕适配一次；重建大小不会动自动保存的 frame 名。
            fitOnCurrentScreen(primary)
            primary.makeKeyAndOrderFront(nil)
            if !NSApp.isActive {
                NSApp.activate(ignoringOtherApps: true)
            }
            return
        }
        // 没有 primary：登记表为空，或主窗口已被真正关闭（正常路径不会发生，因为
        // `windowShouldClose` 对 primary 只隐藏）。只有主菜单已安装（即启动流程已经
        // 走到 `applicationDidFinishLaunching`/smoke 路径）时才补建，避免和
        // `AppDelegate+PackageUpdates.swift` 里的正常启动路径各建一个窗口。
        if NSApp.mainMenu != nil {
            createWindow()
        }
    }
}
