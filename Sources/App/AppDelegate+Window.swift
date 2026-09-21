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
}
