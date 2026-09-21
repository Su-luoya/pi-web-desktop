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

    func fitWindowToCurrentScreen() {
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

    func createWindow() {
        webViewController = WebViewController(
            serviceURL: startURL,
            servicePort: serviceManager.configuration.port,
            windowProvider: { [weak self] in self?.window }
        )
        webViewController.onNavigationFailure = { [weak self] failure in
            guard let self, !self.serviceManager.isQuitting else { return }
            // 导航失败只写日志并渲染错误页：服务状态由启动流程与健康检查决定，
            // 不能因为一次页面级失败（例如被取消的外链导航）被改成「已停止」。
            let message: String
            switch failure {
            case .loadFailed(let description):
                message = "页面加载失败：\(description)"
            case .connectionFailed(let description):
                message = "无法连接 Pi Web：\(description)"
            }
            _ = self.logWriter.append(self.logRedactor.redact(message))
            self.webViewController.showErrorPage(message: message)
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

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }

    @objc func showWindow(_ sender: Any?) {
        window.makeKeyAndOrderFront(nil)
        if !NSApp.isActive {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func windowDidChangeScreen(_ notification: Notification) {
        scheduleWindowFit()
    }

    @objc func toggleFullScreen(_ sender: Any?) {
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

    // MARK: - Dock 恢复（GitHub #158）

    /// 点 Dock 图标（或应用被重新打开）时把主窗口带回来。返回 true 表示事件已处理，
    /// AppKit 不再走自带的“新建窗口”路径。
    ///
    /// AppKit 只在 `hasVisibleWindows == false` 时调这个方法，恰好覆盖三种情形：
    /// 1. 红色关闭按钮之后（`windowShouldClose` 只做 `orderOut(nil)`）；
    /// 2. 窗口被最小化到 Dock（`isVisible` 仍为 true，但屏幕上没有窗口）；
    /// 3. 窗口还没创建（启动早期点击 Dock 图标）。
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        showMainWindow()
        return true
    }

    /// 把已存在的主窗口显示到当前屏幕并置前；窗口对象还没创建时补建它。
    ///
    /// 关闭按钮只隐藏窗口（见 `windowShouldClose`），窗口对象、WebView 和页面会话都
    /// 还在，所以这里**必须复用**同一个窗口：重建会丢掉页面状态并留下第二个窗口。
    func showMainWindow() {
        guard let window else {
            // 还没有窗口：只有主菜单已安装（即启动流程已经走到
            // `applicationDidFinishLaunching`/smoke 路径）时才补建，避免和
            // `AppDelegate+PackageUpdates.swift` 里的正常启动路径各建一个窗口。
            if NSApp.mainMenu != nil {
                createWindow()
            }
            return
        }
        // 最小化的窗口必须先还原：`makeKeyAndOrderFront` 不会把它拉出最小化状态。
        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        // 隐藏期间显示器可能已经变过（分辨率/旋转/插拔外接屏），重新显示前按当前
        // 屏幕适配一次；重建大小不会动自动保存的 frame 名。
        fitWindowToCurrentScreen()
        window.makeKeyAndOrderFront(nil)
        if !NSApp.isActive {
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}
