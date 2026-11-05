import Cocoa
import CoreImage

/// 「服务 → 远程访问」子菜单：把本机服务通过 Tailscale serve 挂到 tailnet 上。
///
/// 刻意不做访问密码：唯一的边界是 tailnet 身份，因此**只做 serve、不做 funnel**
/// （funnel 会把它暴露到公网）。菜单项按控制器缓存的状态重建，不在菜单打开时
/// 跑 CLI——打开菜单不能卡住主线程。
extension AppDelegate {
    /// 建子菜单：只挂 delegate，内容在打开时重建。
    func makeRemoteAccessMenu() -> NSMenu {
        let menu = NSMenu(title: "远程访问")
        menu.delegate = self
        remoteAccessMenus.append(menu)
        return menu
    }

    /// 按当前状态重建菜单项。三种状态各自只给能做的事。
    func rebuildRemoteAccessMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        switch remoteAccessController.state {
        case let .unavailable(reason):
            let item = NSMenuItem(title: reason, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
            if remoteAccessController.activePort != nil {
                menu.addItem(remoteAccessItem(title: "重试关闭远程访问", action: #selector(disableRemoteAccess(_:))))
            }
        case .off:
            menu.addItem(remoteAccessItem(title: "启用远程访问…", action: #selector(enableRemoteAccess(_:))))
        case .on:
            menu.addItem(remoteAccessItem(title: "显示地址与二维码…", action: #selector(showRemoteAccessCode(_:))))
            menu.addItem(remoteAccessItem(title: "复制远程地址", action: #selector(copyRemoteAccessAddress(_:))))
            menu.addItem(remoteAccessItem(title: "在浏览器中打开远程地址", action: #selector(openRemoteAccessAddress(_:))))
            menu.addItem(.separator())
            menu.addItem(remoteAccessItem(title: "测试访问延迟…", action: #selector(measureRemoteAccessLatency(_:))))
            menu.addItem(.separator())
            menu.addItem(remoteAccessItem(title: "关闭远程访问", action: #selector(disableRemoteAccess(_:))))
        }
    }

    private func remoteAccessItem(title: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    // MARK: - 动作

    /// 启用：先确认（可能重启服务），成功后直接给二维码——否则用户还得自己去
    /// 拼手机上的地址。
    @objc func enableRemoteAccess(_ sender: Any?) {
        let configuration = serviceManager.configuration
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "通过 Tailscale 提供远程访问？"
        alert.informativeText = """
        本机服务会被挂到 https://<你的机器名> 这一条入口上，只有你自己的 tailnet 能访问，不会暴露到公网。

        这一功能不设访问密码：能进入你 tailnet 的设备就能完全控制 pi-web。如果主机名还没在「允许的主机名」里，保存它需要重启服务，当前会话会中断。
        """
        alert.addButton(withTitle: "启用")
        alert.addButton(withTitle: "取消")
        presentRemoteAccessAlert(alert) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            self.remoteAccessController.enable(
                configuration: configuration,
                applyConfiguration: { [weak self] updated, completion in
                    self?.applyPreferencesConfiguration(updated, completion: completion)
                },
                completion: { [weak self] result in
                    guard let self else { return }
                    switch result {
                    case let .success(url):
                        self.presentRemoteAccessCode(url)
                    case let .failure(failure):
                        self.presentRemoteAccessFailure("无法启用远程访问", message: failure.message)
                    }
                }
            )
        }
    }

    @objc func showRemoteAccessCode(_ sender: Any?) {
        guard let url = remoteAccessController.state.url else { return }
        presentRemoteAccessCode(url)
    }

    @objc func copyRemoteAccessAddress(_ sender: Any?) {
        guard let url = remoteAccessController.state.url else { return }
        copyRemoteAccessURL(url)
    }

    @objc func openRemoteAccessAddress(_ sender: Any?) {
        guard let url = remoteAccessController.state.url else { return }
        NSWorkspace.shared.open(url)
    }

    /// 关闭失败保留本机记录与重试入口，并如实告诉用户「那条入口可能还在」。
    @objc func disableRemoteAccess(_ sender: Any?) {
        remoteAccessController.disable { [weak self] succeeded in
            guard let self, !succeeded else { return }
            self.presentRemoteAccessFailure(
                "远程访问可能没有完全关闭",
                message: "Tailscale 拒绝或没能执行撤销命令，那条入口可能仍然存在。可以再试一次，或在终端里手动关闭该端口。"
            )
        }
    }

    // MARK: - 延迟测量

    /// 先拿设备列表再问“测哪台”：两者都经后台队列，菜单打开时不跑 CLI。
    @objc func measureRemoteAccessLatency(_ sender: Any?) {
        remoteAccessController.peers { [weak self] peers in
            guard let self else { return }
            guard let peers, !peers.isEmpty else {
                self.presentRemoteAccessFailure(
                    "没有可测试的设备",
                    message: "Tailscale 里没有其他设备，或者状态读不出来（未登录、后端未运行）。"
                )
                return
            }
            self.presentPeerPicker(peers)
        }
    }

    /// 下拉选一台。设备数不限，且仍然是一张常规模态框，不需要自建面板。
    private func presentPeerPicker(_ peers: [TailscalePeer]) {
        let popUp = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 420, height: 25), pullsDown: false)
        popUp.addItems(withTitles: peers.map(\.pickerTitle))
        // 列表已按“在线在前”排序，第一项就是最可能的目标。
        popUp.selectItem(at: 0)
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "测试哪台设备的访问延迟？"
        alert.informativeText = "会向选中的设备发 3 个 Tailscale 层探测包，顺便测本机到各中转节点的延迟，约 5 秒。"
        alert.accessoryView = popUp
        alert.addButton(withTitle: "开始测试")
        alert.addButton(withTitle: "取消")
        presentRemoteAccessAlert(alert) { [weak self] response in
            let index = popUp.indexOfSelectedItem
            guard response == .alertFirstButtonReturn, peers.indices.contains(index) else { return }
            self?.startLatencyMeasurement(peer: peers[index])
        }
    }

    private func startLatencyMeasurement(peer: TailscalePeer) {
        remoteAccessController.sample(peer: peer) { [weak self] report in
            self?.presentLatencyReport(report)
        }
    }

    /// 结果窗口：只读文本 + 复制。内容多（采样逐条 + DERP 延迟表），所以不用弹框。
    private func presentLatencyReport(_ report: TailscaleLatencyReport) {
        let contentSize = NSSize(width: 480, height: 380)
        let content = NSView(frame: NSRect(origin: .zero, size: contentSize))

        let scroll = NSScrollView(frame: NSRect(x: 0, y: 44, width: contentSize.width, height: contentSize.height - 44))
        scroll.autoresizingMask = [.width, .height]
        scroll.hasVerticalScroller = true
        let textView = NSTextView(frame: scroll.bounds)
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        // 不换行就会被窗口右边缘切掉：DERP 延迟表一行能到 700+ pt。
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: scroll.contentSize.width, height: .greatestFiniteMagnitude)
        textView.string = report.text
        scroll.documentView = textView
        content.addSubview(scroll)

        let copyButton = NSButton(title: "复制结果", target: self, action: #selector(copyLatencyReport(_:)))
        copyButton.frame = NSRect(x: contentSize.width - 200, y: 8, width: 96, height: 28)
        copyButton.autoresizingMask = [.minXMargin]
        content.addSubview(copyButton)
        let closeButton = NSButton(title: "关闭", target: nil, action: #selector(NSWindow.performClose(_:)))
        closeButton.frame = NSRect(x: contentSize.width - 100, y: 8, width: 92, height: 28)
        closeButton.autoresizingMask = [.minXMargin]
        content.addSubview(closeButton)

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "访问延迟：\(report.peer.hostName)"
        window.contentView = content
        window.isReleasedWhenClosed = false
        window.center()

        // 上一次的窗口若已关闭就丢掉引用；同时防止同一窗口被释放。
        latencyReportWindowControllers.removeAll { $0.window?.isVisible != true }
        let controller = NSWindowController(window: window)
        latencyReportWindowControllers.append(controller)
        controller.showWindow(nil)
    }

    /// 复制按钮从所在窗口里取文本：不在 extension 里为一个按钮另存状态。
    @objc func copyLatencyReport(_ sender: Any?) {
        guard let window = (sender as? NSView)?.window,
              let scroll = window.contentView?.subviews.compactMap({ $0 as? NSScrollView }).first,
              let textView = scroll.documentView as? NSTextView
        else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(textView.string, forType: .string)
    }

    // MARK: - 呈现

    /// 地址 + 二维码：手机扫一下就能打开，不用在手机上敲一长串域名。
    private func presentRemoteAccessCode(_ url: URL) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "在手机上打开"
        alert.informativeText = """
        \(url.absoluteString)

        直接用手机相机扫码即可。只有接入了你 tailnet 的设备能打开；这个地址没有访问密码。
        """
        if let image = Self.qrImage(for: url) {
            let imageView = NSImageView(frame: NSRect(x: 0, y: 0, width: 180, height: 180))
            imageView.image = image
            imageView.imageScaling = .scaleProportionallyUpOrDown
            alert.accessoryView = imageView
        }
        alert.addButton(withTitle: "复制地址")
        alert.addButton(withTitle: "好")
        presentRemoteAccessAlert(alert) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.copyRemoteAccessURL(url)
        }
    }

    private func copyRemoteAccessURL(_ url: URL) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
    }

    private func presentRemoteAccessFailure(_ messageText: String, message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = messageText
        alert.informativeText = message
        alert.addButton(withTitle: "好")
        presentRemoteAccessAlert(alert) { _ in }
    }

    private func presentRemoteAccessAlert(_ alert: NSAlert, completion: @escaping (NSApplication.ModalResponse) -> Void) {
        if let window, window.isVisible {
            alert.beginSheetModal(for: window, completionHandler: completion)
        } else {
            completion(alert.runModal())
        }
    }

    /// 二维码渲染（CoreImage），按目标边长放大后再变成 `NSImage`。
    static func qrImage(for url: URL, side: CGFloat = 180) -> NSImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(url.absoluteString.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage, output.extent.width > 0 else { return nil }
        let scale = side / max(output.extent.width, output.extent.height)
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let rep = NSCIImageRep(ciImage: scaled)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
}
