import Foundation

/// Already-collected values for the "复制诊断信息" text.
///
/// The collector receives them as plain strings: it never runs a command and
/// never reads the disk, so tests can assert the exact text with fake inputs and
/// no real user path or secret ever has to be involved.
struct DiagnosticsInput: Equatable {
    /// Bundle version description, e.g. "0.1.0 (1)" or the development fallback.
    var appVersion: String
    var piWebVersion: String
    var nodeVersion: String
    var serviceAddress: String
    var status: String
    /// Listener PID or "无".
    var listenerPID: String
    /// Listener command line or "无".
    var listenerProcess: String
    /// Managed PID or the "外部服务或未运行" description.
    var managedPID: String
    var piWebPath: String
    var configurationDirectory: String
    var logPath: String
    /// 远程访问密码的状态文案（例如 `RemoteAccessPassword.statusText(isSet:)`）。
    /// 只允许“已设置/未设置”这类描述：不得传入密码值、长度或 Keychain 原始数据。
    var remoteAccessPasswordStatus: String
}

enum DiagnosticsCollector {
    /// Field order and labels are unchanged from the previous inline template.
    static func text(for input: DiagnosticsInput) -> String {
        """
        Pi Web Desktop: \(input.appVersion)
        pi-web: \(input.piWebVersion)
        Node.js: \(input.nodeVersion)
        服务地址: \(input.serviceAddress)
        状态: \(input.status)
        监听 PID: \(input.listenerPID)
        监听进程: \(input.listenerProcess)
        托管 PID: \(input.managedPID)
        pi-web 路径: \(input.piWebPath)
        配置目录: \(input.configurationDirectory)
        日志: \(input.logPath)
        远程访问密码: \(input.remoteAccessPasswordStatus)
        """
    }
}
