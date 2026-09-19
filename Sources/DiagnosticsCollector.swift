import Foundation

/// 服务的托管关系（GitHub #10 诊断导出的“托管关系”一行）。
///
/// 只有通过所有权校验（PID、进程组、启动时间、端口、命令行摘要全部匹配）的记录
/// 才算 `managed`；外部服务、未运行或记录校验失败一律是 `external`，应用不会对它
/// 发信号。
enum DiagnosticsManagement: Equatable {
    case managed(pid: String)
    case external

    var text: String {
        switch self {
        case .managed(let pid):
            return "managed（本应用托管，所有权校验通过；托管 PID \(pid)）"
        case .external:
            return "external（外部服务或未运行，无有效所有权记录）"
        }
    }
}

/// Already-collected values for the "复制诊断" text.
///
/// The collector receives them as plain strings: it never runs a command and
/// never reads the disk, so tests can assert the exact text with fake inputs and
/// no real user path or secret ever has to be involved. Every line goes through
/// the injected `LogRedactor` (GitHub #10): the same instance that writes logs,
/// error messages and environment/command-line displays.
struct DiagnosticsInput: Equatable {
    /// `CFBundleShortVersionString`，或开发构建的说明文案。
    var appVersion: String
    /// `CFBundleVersion`，或开发构建的说明文案。
    var appBuild: String
    var piWebVersion: String
    /// `verified` / `inferred` / `unknown`（见 `DiagnosticsCollector.confidenceText`）。
    var piWebVersionConfidence: String
    var piWebPath: String
    var piWebPathConfidence: String
    var piCLIVersion: String
    var piCLIVersionConfidence: String
    var nodeVersion: String
    var nodeVersionConfidence: String
    var serviceAddress: String
    var port: String
    var status: String
    var management: DiagnosticsManagement
    /// Listener PID or "无".
    var listenerPID: String
    /// Listener command line or "无".
    var listenerProcess: String
    /// Managed PID or "无（外部服务或未运行）".
    var managedPID: String
    /// 生效的工作目录（用户自选或应用默认）。
    var workspaceDirectory: String
    var configurationDirectory: String
    /// 应用会为子进程执行的命令行（已脱敏由本收集器统一完成）。
    var launchCommand: String
    /// 应用显式设置的子进程环境变量，一行一个 `KEY=value`。
    ///
    /// 导出时第一个条目跟在 `启动环境: ` 后面，后续条目各自占一行并使用带序号的
    /// 唯一标签（`启动环境[2]: `…），所以每一行都能按 `标签: 值` 解析，值本身不裁剪、
    /// 不转义。目前这是唯一可能多行的字段。
    var launchEnvironment: String
    var logPath: String
    /// `LogWriter.writeStatusDescription` 的结果。
    var logWriteStatus: String
    /// 远程访问密码的状态文案（例如 `RemoteAccessPassword.statusText(isSet:)`）。
    /// 只允许“已设置/未设置”这类描述：不得传入密码值、长度或 Keychain 原始数据。
    var remoteAccessPasswordStatus: String
    /// 组件安装识别结果（GitHub #16）：每项一行，包含路径、包名、版本、来源、
    /// 可信度与建议命令。由调用方传入**已经脱敏**的条目（Home 前缀为 `~`）；
    /// 收集器自身不执行命令、不读磁盘，只做文本组装。默认空数组，旧调用点不受影响。
    var componentInstallations: [ComponentInstallation] = []
}

enum DiagnosticsCollector {
    /// 可信度渲染：同时给出依赖诊断内部取值与中文标注，避免导出的英文词无处对照。
    static func confidenceText(_ rawValue: String) -> String {
        switch rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "verified": return "verified（已验证）"
        case "inferred": return "inferred（推断）"
        default: return "unknown（未知）"
        }
    }

    /// 字段顺序即导出顺序；最后统一交给 `LogRedactor` 逐行脱敏，不在各处零散处理。
    ///
    /// 每个字段至少占一行，形如 `标签: 值`；值里本来含换行时，后续行用带序号的
    /// 唯一标签续写（见 `fieldLines`）。因此“每行恰好一个唯一标签、值逐字输出”
    /// 这一可解析性不变量对所有输入都成立，复制出去的文本可以按行解析。
    static func text(for input: DiagnosticsInput, redactor: LogRedactor = LogRedactor()) -> String {
        let fields: [(label: String, value: String)] = [
            ("Pi Web Desktop 版本", input.appVersion),
            ("Pi Web Desktop 构建号", input.appBuild),
            ("pi-web 版本", "\(input.piWebVersion)（可信度 \(confidenceText(input.piWebVersionConfidence))）"),
            ("pi-web 路径", "\(input.piWebPath)（可信度 \(confidenceText(input.piWebPathConfidence))）"),
            ("Pi CLI 版本", "\(input.piCLIVersion)（可信度 \(confidenceText(input.piCLIVersionConfidence))）"),
            ("Node.js 版本", "\(input.nodeVersion)（可信度 \(confidenceText(input.nodeVersionConfidence))）"),
            ("服务地址", input.serviceAddress),
            ("端口", input.port),
            ("状态", input.status),
            ("托管关系", input.management.text),
            ("监听 PID", input.listenerPID),
            ("监听进程", input.listenerProcess),
            ("托管 PID", input.managedPID),
            ("有效工作目录", input.workspaceDirectory),
            ("配置目录", input.configurationDirectory),
            ("启动命令", input.launchCommand),
            ("启动环境", input.launchEnvironment),
            ("日志文件", input.logPath),
            ("日志写入", input.logWriteStatus),
            ("远程访问密码", input.remoteAccessPasswordStatus),
            // #16 的组件安装信息追加在末尾，保持既有字段顺序稳定；每项占一行
            // （多行值由 `fieldLines` 拆成 `组件安装[2]:` 这样的唯一标签行）。
            ("组件安装", input.componentInstallations.map(\.summaryLine).joined(separator: "\n"))
        ]
        let lines = fields.flatMap { fieldLines(label: $0.label, value: $0.value) }
        return redactor.redact(lines.joined(separator: "\n"))
    }

    /// 把一个字段渲染成一行或多行 `标签: 值`。值含换行时，第一个条目用原标签，
    /// 后续条目用 `标签[序号]: 值`（序号从 2 开始），保证标签逐行唯一、值不裁剪、
    /// 不转义；空行也保留成一条带标签的空值字段。
    private static func fieldLines(label: String, value: String) -> [String] {
        let parts = value.components(separatedBy: "\n")
        guard parts.count > 1 else { return ["\(label): \(value)"] }
        return parts.enumerated().map { index, part in
            index == 0 ? "\(label): \(part)" : "\(label)[\(index + 1)]: \(part)"
        }
    }
}
