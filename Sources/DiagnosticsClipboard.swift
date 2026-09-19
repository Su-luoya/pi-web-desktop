import Cocoa

/// “复制诊断”前的脱敏提醒（GitHub #10）。
///
/// 菜单项与诊断窗口共用这一条路径和这一份说明：导出的文本已经过 `LogRedactor`
/// 统一脱敏，但脱敏不替代用户自查——公开粘贴前仍要确认没有不希望公开的主机名、
/// 路径或业务信息。窗口为 nil 时退化为独立提示框（菜单动作也可能没有主窗口）。
enum DiagnosticsClipboard {
    static let reminderTitle = "诊断信息已按规则脱敏"
    static let reminderDetail = """
    已替换 Home 路径、URL 查询串、Authorization/Bearer、token/password/secret/api_key \
    等键值、代理凭据、JWT 与私钥。脱敏不能替代自查：公开粘贴前请再确认一次，\
    不要包含不希望公开的主机名、路径或业务信息。
    """

    /// 用户确认后才写入剪贴板；取消时不复制。
    static func copyAfterConfirmation(_ text: String, presentingIn window: NSWindow?) {
        guard !text.isEmpty else { return }
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = reminderTitle
        alert.informativeText = reminderDetail
        alert.addButton(withTitle: "复制")
        alert.addButton(withTitle: "取消")
        let complete: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .alertFirstButtonReturn else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
        if let window {
            alert.beginSheetModal(for: window, completionHandler: complete)
        } else {
            complete(alert.runModal())
        }
    }
}
