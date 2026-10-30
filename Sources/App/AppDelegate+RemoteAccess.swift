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
        case .off:
            menu.addItem(remoteAccessItem(title: "启用远程访问…", action: #selector(enableRemoteAccess(_:))))
        case .on:
            menu.addItem(remoteAccessItem(title: "显示地址与二维码…", action: #selector(showRemoteAccessCode(_:))))
            menu.addItem(remoteAccessItem(title: "复制远程地址", action: #selector(copyRemoteAccessAddress(_:))))
            menu.addItem(remoteAccessItem(title: "在浏览器中打开远程地址", action: #selector(openRemoteAccessAddress(_:))))
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

    /// 关闭：CLI 失败也清掉本机记录，但要如实告诉用户「那条入口可能还在」。
    @objc func disableRemoteAccess(_ sender: Any?) {
        remoteAccessController.disable { [weak self] succeeded in
            guard let self, !succeeded else { return }
            self.presentRemoteAccessFailure(
                "远程访问可能没有完全关闭",
                message: "Tailscale 拒绝或没能执行撤销命令，那条入口可能仍然存在。可以再试一次，或在终端里手动关闭该端口。"
            )
        }
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
