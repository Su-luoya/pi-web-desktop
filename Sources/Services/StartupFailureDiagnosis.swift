/// 启动失败时的日志尾行归因（issue：pi-web 启动即退出时只报“请查看日志”）。
///
/// 生产实证：地址不在本机、端口被占用、npm 包损坏都会让 pi-web 一启动就退出，
/// 而应用此前只弹一条“pi-web 进程已退出。请查看日志：…”。用户拿到的是文件路径，
/// 不是原因；地址/端口回落能自动处理其中两类，剩下的（例如 `EACCES`、`ENOENT`）
/// 仍然需要把真实原因说出来。
///
/// 本文件只做纯文本判定，不读文件、不写日志：调用方把日志尾部交给 `summarize`，
/// 拿到的是一句可直接放进弹窗与日志的说明。认不出来的错误返回 nil，调用方沿用
/// 原文案（“请查看日志”），绝不猜。

import Foundation

enum StartupFailureDiagnosis {
    /// 已知的启动失败特征：命中即给出可执行的中文说明。
    ///
    /// 顺序有意义：同一次失败可能同时出现多条（例如 `EADDRINUSE` 之后跟着
    /// `Next.js exited unexpectedly`），先匹配最具体的那条。
    private static let signatures: [(needle: String, message: String)] = [
        (
            "EADDRINUSE",
            "端口已被其它程序占用。请在设置里换一个端口，或结束占用该端口的程序后重试。"
        ),
        (
            "EADDRNOTAVAIL",
            "配置的监听地址当前不在本机（例如 Tailscale 未运行）。请在设置里改用本机已有的地址，或重启应用重新检测。"
        ),
        (
            "EACCES",
            "没有权限监听该端口或读取相关文件。请检查端口是否低于 1024，或文件权限是否可读。"
        ),
        (
            "ENOENT",
            "启动所需的文件不存在，通常是 pi-web 未正确安装。请重新执行 npm install -g @agegr/pi-web@latest。"
        ),
        (
            "Cannot find module",
            "pi-web 依赖缺失或安装损坏。请重新执行 npm install -g @agegr/pi-web@latest。"
        ),
        (
            "command not found",
            "启动命令不存在，通常是 node 或 pi-web 未安装或不在 PATH 中。请在环境检查里修复后重试。"
        )
    ]

    /// 从日志尾部提取可读原因；没有可识别的特征时返回 nil。
    ///
    /// - Parameter logTail: 日志文件末尾若干 KB 的文本（不需要是完整文件）。
    static func summarize(logTail: String) -> String? {
        for signature in signatures where logTail.contains(signature.needle) {
            return signature.message
        }
        return nil
    }

    /// 启动失败的完整提示：有可读原因时把它放在前面，日志路径始终保留。
    ///
    /// - Parameters:
    ///   - logTail: 日志文件末尾文本；读取失败时传 nil。
    ///   - logPath: 弹窗里展示的日志路径。
    static func message(logTail: String?, logPath: String) -> String {
        let base = "pi-web 进程已退出。请查看日志：\(logPath)"
        guard let logTail, let reason = summarize(logTail: logTail) else { return base }
        return "\(reason)\n\n\(base)"
    }
}

extension StartupFailureDiagnosis {
    /// 读取日志末尾 `maxBytes` 字节并交给 `message(logTail:logPath:)`。
    ///
    /// 只在启动失败路径调用：读一个小文件不会阻塞界面到用户可感知的程度，而且
    /// 失败本身已经需要用户等待。
    static func message(logURL: URL, maxBytes: Int = 16 * 1024, fileManager: FileManager = .default) -> String {
        let tail = readTail(of: logURL, maxBytes: maxBytes, fileManager: fileManager)
        return message(logTail: tail, logPath: logURL.path)
    }

    /// 读取文件末尾若干字节；文件不存在或不可读时返回 nil。
    static func readTail(of url: URL, maxBytes: Int, fileManager: FileManager = .default) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        let offset = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
        guard (try? handle.seek(toOffset: offset)) != nil else { return nil }
        guard let data = try? handle.readToEnd(), let text = String(data: data, encoding: .utf8) else { return nil }
        return text
    }
}
