/// Sanitized process records and tri-state process inspection results.

import Darwin
import Foundation

// MARK: - 命中证据与进程记录

/// 一个进程被判定为 Pi CLI 的证据来源。四种都是“可执行名恰好等于 `pi`”，
/// 区别只在证据从哪来。
enum PiProcessMatchSource: String, Equatable {
    /// 真实镜像路径（`proc_pidpath`）的文件名是 `pi`。
    case imagePath
    /// 内核进程名（`pbi_comm`/`pbi_name`）是 `pi`。
    case executableName
    /// JS 运行时（`node`/`bun`/`deno` 等）报告的脚本路径是 `pi`。
    case interpreterScript
    /// JS 运行时的 `argv[0]` 被设为 `pi`（Pi CLI 会改写进程标题）。
    case processTitle

    var text: String {
        switch self {
        case .imagePath: return "真实镜像路径的可执行文件名是 pi"
        case .executableName: return "内核进程名是 pi"
        case .interpreterScript: return "JS 运行时报告的脚本路径文件名是 pi"
        case .processTitle: return "JS 运行时的 argv[0]（进程标题）是 pi"
        }
    }
}

/// 一个运行中的 Pi 进程的**已脱敏**记录。
///
/// 原始 argv 从不进入记录：命令摘要在构造时就经过 `LogRedactor` 并丢掉
/// `KEY=VALUE` 环境片段。路径字段同样是脱敏后的文本（Home 前缀 → `~`），
/// 因此记录可以安全地写进日志、诊断导出与确认框。
struct PiProcessRecord: Equatable {
    /// 命令摘要的长度上限（字符）。
    static let commandSummaryLimit = 200

    var pid: pid_t
    var parentPID: pid_t?
    /// 已按注入的格式器渲染的启动时间；未读到时为 nil。
    var startedAtText: String?
    /// 真实镜像路径（`proc_pidpath`，已脱敏）；不可得时为 nil。
    var executablePath: String?
    /// JS 运行时代理执行的脚本路径（已脱敏）；只有证据来自脚本路径时非 nil。
    var scriptPath: String?
    /// 判定为 Pi 的依据。
    var matchSource: PiProcessMatchSource
    /// 已脱敏、有界的命令摘要。
    var commandSummary: String

    /// 单行摘要（已脱敏）：`PID 1234（父进程 1200，真实镜像 .…）`。
    var shortText: String {
        var parts = ["PID \(pid)"]
        if let parentPID { parts.append("父进程 \(parentPID)") }
        if let startedAtText { parts.append("启动于 \(startedAtText)") }
        return parts.joined(separator: "，")
    }

    /// 手动更新确认框与诊断文本共用的多行描述。
    var displayLines: [String] {
        var lines = ["进程 PID：\(pid)"]
        lines.append("父进程 PID：\(parentPID.map(String.init) ?? "未知")")
        lines.append("启动时间：\(startedAtText ?? "未知")")
        lines.append("判定依据：\(matchSource.text)")
        lines.append("真实镜像路径：\(executablePath ?? "不可读")")
        if let scriptPath {
            lines.append("脚本路径：\(scriptPath)")
        }
        lines.append("命令摘要：\(commandSummary)")
        return lines
    }
}

// MARK: - 检查结果（三态）

/// 不确定的原因。全部是固定文案 + PID：不携带原始 argv、环境变量或未脱敏路径
/// （`scriptPathUnconfirmed` 里的路径在构造前已经过 `LogRedactor`）。
enum PiProcessInspectionUnknown: Equatable {
    /// `proc_listpids` 失败：连有哪些进程都不知道。
    case enumerationFailed
    /// 镜像路径与进程名都不可读（权限不足、受保护进程，或进程正在退出）。
    case identityUnavailable(pid: pid_t, failure: PiProcessReadFailure?)
    /// 进程确实由 JS 运行时承载，但 argv 不可读，因此无法排除它是 Pi。
    case argumentsUnavailable(pid: pid_t, interpreter: String)
    /// argv 里出现了名为 `pi` 的脚本路径，但无法确认它是可执行文件（可能是普通
    /// 文件、相对路径，或符号链接断裂无法解析）。
    case scriptPathUnconfirmed(pid: pid_t, path: String)

    var text: String {
        switch self {
        case .enumerationFailed:
            return "无法枚举本机进程（proc_listpids 失败）"
        case .identityUnavailable(let pid, let failure):
            let reason = failure.map { "：\($0.text)" } ?? ""
            return "PID \(pid) 的镜像路径与进程名都不可读\(reason)"
        case .argumentsUnavailable(let pid, let interpreter):
            return "PID \(pid) 由 \(interpreter) 承载，但无法读取它的参数，不能排除它是 Pi"
        case .scriptPathUnconfirmed(let pid, let path):
            return "PID \(pid) 的参数里出现了名为 pi 的脚本路径 \(path)，但无法确认它是可执行文件（普通文件、相对路径或无法解析的符号链接）"
        }
    }
}

/// Pi 进程检查的三态结果。
///
/// `unknown` 与 `runningProcesses` 在更新决策里同样按“不安全”处理：只有
/// `noProcesses` 才允许自动执行 `pi update --self`。
enum PiProcessInspection: Equatable {
    case noProcesses
    case runningProcesses([PiProcessRecord])
    case unknown(PiProcessInspectionUnknown)

    /// 只有确认“没有 Pi 进程”时才是安全的。
    var allowsAutomaticUpdate: Bool {
        if case .noProcesses = self { return true }
        return false
    }

    var records: [PiProcessRecord] {
        if case .runningProcesses(let records) = self { return records }
        return []
    }

    var unknownReason: PiProcessInspectionUnknown? {
        if case .unknown(let reason) = self { return reason }
        return nil
    }

    /// 单行状态（诊断页/设置页用）。
    var statusText: String {
        switch self {
        case .noProcesses:
            return "没有检测到运行中的 Pi 进程"
        case .runningProcesses(let records):
            let summary = records.map(\.shortText).joined(separator: "；")
            return "检测到 \(records.count) 个运行中的 Pi 进程：\(summary)"
        case .unknown(let reason):
            return "无法确认 Pi 进程状态：\(reason.text)"
        }
    }

    /// 更新决策使用的推迟原因文案。
    var deferralText: String {
        switch self {
        case .noProcesses:
            return "没有运行中的 Pi 进程"
        case .runningProcesses(let records):
            return "有 \(records.count) 个运行中的 Pi 进程；更新会让正在进行的会话读到被替换的文件，因此本次不自动更新"
        case .unknown(let reason):
            return "无法确定 Pi 进程状态（\(reason.text)）；按不安全处理，不自动更新"
        }
    }
}

/// 单个进程的分类结果。
enum PiProcessClassification: Equatable {
    case pi(PiProcessRecord)
    case notPi
    case unknown(PiProcessInspectionUnknown)
}
