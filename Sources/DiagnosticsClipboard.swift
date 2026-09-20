import Cocoa

/// “复制诊断”前的脱敏提醒（GitHub #10）。
///
/// 菜单项与诊断窗口共用这一条路径和这一份说明：导出的文本已经过 `LogRedactor`
/// 统一脱敏，但脱敏不替代用户自查——公开粘贴前仍要确认没有不希望公开的主机名、
/// 路径或业务信息。
///
/// W4 M3 起提醒与复制拆成两步：诊断文本要等用户确认后才在后台队列上采集
/// （子进程有超时），所以调用方先 `confirmExport`，采集完成后再 `copy`。
enum DiagnosticsClipboard {
    static let reminderTitle = "诊断信息已按规则脱敏"
    static let reminderDetail = """
    已替换 Home 路径、URL 查询串、Authorization/Bearer、token/password/secret/api_key \
    等键值、代理凭据、JWT 与私钥。脱敏不能替代自查：公开粘贴前请再确认一次，\
    不要包含不希望公开的主机名、路径或业务信息。
    """

    /// 展示脱敏提醒，并回报用户是否确认导出。
    ///
    /// 窗口可见时挂 sheet；窗口被 ⌘W 隐藏（或本来没有窗口）时改用应用级模态：
    /// 在不可见窗口上 `beginSheetModal` 会让 AppKit 把这个窗口重新显示出来
    /// （W4 L5），与“窗口已经被隐藏”的用户状态不一致。
    static func confirmExport(presentingIn window: NSWindow?, completion: @escaping (Bool) -> Void) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = reminderTitle
        alert.informativeText = reminderDetail
        alert.addButton(withTitle: "复制")
        alert.addButton(withTitle: "取消")
        let complete: (NSApplication.ModalResponse) -> Void = { response in
            completion(response == .alertFirstButtonReturn)
        }
        if let window, window.isVisible {
            alert.beginSheetModal(for: window, completionHandler: complete)
        } else {
            // 不可见窗口上不挂 sheet；应用级模态不改变任何窗口的可见性。
            NSApp.activate(ignoringOtherApps: true)
            complete(alert.runModal())
        }
    }

    /// 把已经确认过的文本写入剪贴板；空文本不写入。
    static func copy(_ text: String) {
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
