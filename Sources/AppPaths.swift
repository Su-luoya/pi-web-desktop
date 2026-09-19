import Foundation

/// 应用读写的全部文件系统位置（GitHub #9）。
///
/// 设置分层只有三处：
/// - 普通设置：UserDefaults（不经过这里；键与默认值约定见 `ServiceConfiguration`）；
/// - 运行状态：`~/Library/Application Support/Pi Web Desktop/`（PID、实例锁、
///   所有权记录、默认工作目录）；
/// - 日志：`~/Library/Logs/Pi Web Desktop/`。
///
/// 每个路径都从 `supportDirectory` / `logsDirectory` 派生，两个根目录都可以
/// 注入：单元测试与 smoke 启动传入临时目录，永远不会触碰真实 Home。
struct AppPaths: Equatable {
    /// 运行状态根目录：`~/Library/Application Support/Pi Web Desktop`。
    var supportDirectory: URL
    /// 日志目录：`~/Library/Logs/Pi Web Desktop`。
    var logsDirectory: URL

    static let supportDirectoryName = "Pi Web Desktop"
    static let logsDirectoryName = "Pi Web Desktop"
    /// 默认工作目录名（相对 `supportDirectory`）。
    static let workspaceDirectoryName = "Workspace"
    /// 日志文件名（相对 `logsDirectory`）。
    static let logFileName = "Pi Web Desktop.log"

    var logFileURL: URL { logsDirectory.appendingPathComponent(Self.logFileName) }

    /// 默认工作目录；首次使用时由应用创建。用户可以在偏好窗口选择其他目录。
    var workspaceDirectory: URL {
        supportDirectory.appendingPathComponent(Self.workspaceDirectoryName, isDirectory: true)
    }

    /// 所有权记录；只有它通过逐项校验时应用才可以停止对应进程组。
    var serviceOwnerRecordURL: URL { supportDirectory.appendingPathComponent("service-owner.json") }
    /// 旧版单 PID 记录；只在启动时删除，永不作为所有权证据。
    var legacyServicePIDURL: URL { supportDirectory.appendingPathComponent("service.pid") }
    var appPIDURL: URL { supportDirectory.appendingPathComponent("app.pid") }
    var instanceLockURL: URL { supportDirectory.appendingPathComponent("instance.lock") }

    /// 更新检查缓存（GitHub #17）：support 目录下的独立 JSON 文件。
    ///
    /// 只含检查结果、时间戳与 etag/条件请求字段；不含凭据、cookies、会话、
    /// URL、响应体或诊断内容。删除该文件只会让下一次检查重新发起普通 GET。
    var updateCheckCacheURL: URL { supportDirectory.appendingPathComponent("update-check-cache.json") }

    /// 真实用户目录：`~/Library/Application Support/Pi Web Desktop` 与
    /// `~/Library/Logs/Pi Web Desktop`。
    static func standard(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> AppPaths {
        AppPaths(
            supportDirectory: homeDirectory.appendingPathComponent(
                "Library/Application Support/\(supportDirectoryName)",
                isDirectory: true
            ),
            logsDirectory: homeDirectory.appendingPathComponent(
                "Library/Logs/\(logsDirectoryName)",
                isDirectory: true
            )
        )
    }

    /// `$TMPDIR/pi-web-desktop-smoke-<pid>`：smoke 启动使用临时 support 目录
    /// （日志放在它下面的 `Logs/`），因此不会写入真实 support 目录或日志目录。
    static func smoke(
        temporaryDirectory: URL = FileManager.default.temporaryDirectory,
        processIdentifier: Int32 = ProcessInfo.processInfo.processIdentifier
    ) -> AppPaths {
        let root = temporaryDirectory.appendingPathComponent(
            "pi-web-desktop-smoke-\(processIdentifier)",
            isDirectory: true
        )
        return AppPaths(supportDirectory: root, logsDirectory: root.appendingPathComponent("Logs", isDirectory: true))
    }
}
