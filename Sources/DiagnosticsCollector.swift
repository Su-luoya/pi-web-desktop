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

    /// 探测值 → 导出文本：nil（命令超时或失败）统一标注为
    /// `DiagnosticsProbeText.failure`，有值时原样返回。导出文本里“标注失败项”
    /// 只有这一处来源，不在调用点各自写文案。
    static func probeValue(_ value: String?) -> String {
        guard let value, !value.isEmpty else { return DiagnosticsProbeText.failure }
        return value
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

// MARK: - 诊断导出的后台采集（W4 M3）

/// 探测失败的统一文案。诊断导出里所有“这次没读到”的字段都渲染成它，
/// 与“没有监听者”“未运行”这类**成功读到的事实**区分开。
enum DiagnosticsProbeText {
    static let failure = "无法读取（命令超时或失败）"
}

/// 有界等待的命令执行器（W4 M3）：诊断导出专用。
///
/// 与 `SystemCommandRunner` 的差别：
/// - 每个子进程都有硬超时：先 `terminate()`（SIGTERM），宽限期内没退出再
///   `SIGKILL`；只对**本次启动的**子进程发信号（`Process.processIdentifier`），
///   不按名字杀进程、不向其它进程发信号；
/// - stdout 在后台线程读取，输出超过管道缓冲区时子进程不会和读取方互相等待；
/// - stdout 读尽与进程退出共用同一个截止时间，超时/失败一律返回 nil，调用方
///   据 `DiagnosticsProbeText.failure` 降级，而不是继续等待。
struct TimeoutCommandRunner: CommandRunning {
    static let defaultTimeout: TimeInterval = 3
    static let defaultTerminationGrace: TimeInterval = 1
    /// 轮询进程状态的步长；`Process` 没有带超时的 `waitUntilExit`，用有界轮询
    /// 替代（不阻塞在无限等待上）。
    private static let pollInterval: TimeInterval = 0.01

    let timeout: TimeInterval
    let terminationGrace: TimeInterval

    init(
        timeout: TimeInterval = TimeoutCommandRunner.defaultTimeout,
        terminationGrace: TimeInterval = TimeoutCommandRunner.defaultTerminationGrace
    ) {
        self.timeout = timeout
        self.terminationGrace = terminationGrace
    }

    func run(_ arguments: [String]) -> String? {
        guard let executable = arguments.first, !executable.isEmpty else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = Array(arguments.dropFirst())
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        // stdout 在后台读：既不与子进程互等，也不阻塞调用方线程。
        let output = PipeOutputBuffer()
        let reading = DispatchGroup()
        reading.enter()
        DispatchQueue(label: "app.pi-web-desktop.diagnostics-probe-read").async {
            output.store(pipe.fileHandleForReading.readDataToEndOfFile())
            reading.leave()
        }
        // 单一截止时间：读尽 stdout 与进程退出都必须在这个窗口内完成。
        let deadline = DispatchTime.now() + timeout
        let finishedReading = reading.wait(timeout: deadline) == .success
        var exited = !process.isRunning
        while !exited && DispatchTime.now() < deadline {
            Thread.sleep(forTimeInterval: TimeoutCommandRunner.pollInterval)
            exited = !process.isRunning
        }
        guard finishedReading, exited, process.terminationStatus == 0 else {
            Self.terminate(process, grace: terminationGrace)
            return nil
        }
        return String(data: output.data, encoding: .utf8)
    }

    /// 超时后的终止：先 SIGTERM，宽限期内没退出再 SIGKILL。
    private static func terminate(_ process: Process, grace: TimeInterval) {
        guard process.isRunning else { return }
        process.terminate()
        let deadline = DispatchTime.now() + grace
        while process.isRunning && DispatchTime.now() < deadline {
            Thread.sleep(forTimeInterval: pollInterval)
        }
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }
    }
}

/// 读线程写、调用线程读的 stdout 缓冲。
private final class PipeOutputBuffer {
    private let lock = NSLock()
    private var stored = Data()

    func store(_ data: Data) {
        lock.lock()
        stored = data
        lock.unlock()
    }

    var data: Data {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}

/// 一次诊断导出的子进程探测结果。nil = 该次调用超时或失败（渲染成
/// `DiagnosticsProbeText.failure`）；`listenerPID == "无"` 是 lsof 成功执行且
/// 确认没有监听者的**事实**，与探测失败区分开。
struct DiagnosticsProbeResult: Equatable {
    var piWebVersion: String?
    var nodeVersion: String?
    var listenerPID: String?
    var listenerProcess: String?
}

/// 诊断导出的后台探测（W4 M3）。
///
/// `AppDelegate` 只在主线程调用 `collect` 并立即返回：`pi-web --version`、
/// `node --version`、`lsof`、`ps` 全部在一条专用**串行后台队列**上执行，每个调用
/// 都由注入的 `CommandRunning` 保证有界返回（生产里是 `TimeoutCommandRunner`）。
/// 外部监听进程的命令行复用更新路径的同一套遮罩（`PiProcessInspector.commandSummary`
/// = token 级凭据遮罩 + `LogRedactor` + 折叠空白 + 长度上限），导出里不另写一套。
final class DiagnosticsProbeCollector {
    private let queue: DispatchQueue
    private let runner: CommandRunning
    private let redactor: LogRedactor

    init(
        queue: DispatchQueue = DispatchQueue(label: "app.pi-web-desktop.diagnostics-probes", qos: .utility),
        runner: CommandRunning = TimeoutCommandRunner(),
        redactor: LogRedactor = LogRedactor()
    ) {
        self.queue = queue
        self.runner = runner
        self.redactor = redactor
    }

    /// 串行执行探测；`completion` 也在 `queue` 上回调，调用方自己回主线程。
    func collect(piWebPath: String?, port: Int, completion: @escaping (DiagnosticsProbeResult) -> Void) {
        queue.async { [self] in
            var result = DiagnosticsProbeResult()
            if let piWebPath, !piWebPath.isEmpty {
                result.piWebVersion = trimmed(runner.run([piWebPath, "--version"]))
            }
            result.nodeVersion = trimmed(runner.run(["/usr/bin/env", "node", "--version"]))
            if let lsofOutput = runner.run([
                ProcessInspector.listenerCommand, "-nP", "-t", "-iTCP:\(port)", "-sTCP:LISTEN"
            ]) {
                if let pid = ProcessInspector.parseListenerPID(lsofOutput) {
                    result.listenerPID = String(pid)
                    if let psOutput = runner.run([
                        ProcessInspector.processCommand, "-o", "command=", "-p", "\(pid)"
                    ]),
                       let description = ProcessInspector.parseProcessDescription(psOutput) {
                        result.listenerProcess = maskedProcessDescription(description)
                    }
                } else {
                    result.listenerPID = "无"
                }
            }
            completion(result)
        }
    }

    private func trimmed(_ output: String?) -> String? {
        let value = output?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? nil : value
    }

    /// 外部进程命令行按更新路径的同一套逻辑遮罩：`ps` 已经把 argv 拼成一个
    /// 字符串，这里按空白恢复 token 边界（带空格的参数边界不可恢复，但遮罩只是
    /// 多覆盖，不会少覆盖），再交给更新路径用的 `PiProcessInspector.commandSummary`
    /// （token 级凭据遮罩 + `LogRedactor` + 折叠空白 + 长度上限）。
    private func maskedProcessDescription(_ description: String) -> String {
        let tokens = description.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        return PiProcessInspector.commandSummary(arguments: tokens, redactor: redactor)
    }
}

// MARK: - 可复用的控制器存储（W4 M2）

/// 单例窗口控制器存储：同一时刻只保留一个可写实例。
///
/// 用途（W4 M2）：设置窗口重复打开时必须返回同一个控制器/窗口——旧实现每次
/// 新建控制器并覆盖引用，旧窗口（`isReleasedWhenClosed = false` 且不 close）
/// 会留在屏幕上，并持有打开时的配置快照，用户可能后写覆盖前写。
///
/// 放在本文件的原因：`PiWebDesktop.xcodeproj` 只把一份固定的源文件清单编进
/// unhosted 测试 target，本文件同时属于 app target 与测试 target，所以“两次
/// 请求同一个实例、旧实例被显式放弃后不再被保留”可以在没有 AppKit 应用实例的
/// 情况下被断言（见 `DiagnosticsCollectorTests`）。
final class ReusableControllerStore<Controller: AnyObject> {
    private(set) var stored: Controller?

    /// 复用已有实例；没有才用 `make` 创建并保存。
    func reuse(orMake make: () -> Controller) -> Controller {
        if let stored {
            return stored
        }
        let created = make()
        stored = created
        return created
    }

    /// 明确放弃当前实例：先执行 `close`（例如关闭窗口），再置 nil，
    /// 旧实例不再被本存储保留。返回值只用于断言“拿到的是被放弃的旧实例”。
    @discardableResult
    func discard(closing close: ((Controller) -> Void)? = nil) -> Controller? {
        guard let stored else { return nil }
        close?(stored)
        self.stored = nil
        return stored
    }
}
