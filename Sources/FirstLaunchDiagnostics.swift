import Foundation

// MARK: - 依赖门控

/// 依赖前置的门控状态（GitHub #7）。
///
/// `AppDelegate` 用它决定菜单控件与 WebView 的可用性：
/// - `.checking`：诊断尚未返回，启动/停止/重启全部不可用；
/// - `.ready`：硬性前置满足，启动/停止/重启可用；
/// - `.blocked`：硬性前置缺失，启动/停止/重启全部不可用。
///
/// 端口占用与 Pi 配置目录缺失只做提示，不改变门控。
enum DiagnosticsGate: Equatable {
    case checking
    case ready
    case blocked
}

/// 服务控件的可用性映射（纯值类型，可单元测试）。
///
/// 只有一个规则：门控为 `.ready` 时 start/stop/restart 才可用；`.checking`
/// 与 `.blocked` 时三者全部不可用。`AppDelegate` 的 `validateMenuItem` 与显式
/// `isEnabled` 更新都读取这个映射，菜单和代码路径不会出现两套规则。
struct ServiceControlState: Equatable {
    var canStart: Bool
    var canStop: Bool
    var canRestart: Bool

    init(canStart: Bool, canStop: Bool, canRestart: Bool) {
        self.canStart = canStart
        self.canStop = canStop
        self.canRestart = canRestart
    }

    init(gate: DiagnosticsGate) {
        let ready = gate == .ready
        self.init(canStart: ready, canStop: ready, canRestart: ready)
    }

    /// 依赖门控 + 工作目录可用性（GitHub #9）。两者都就绪时启动/停止/重启才
    /// 可用：工作目录不可用时启动会被拒绝，控件必须同步置灰。
    init(gate: DiagnosticsGate, workspaceIsReady: Bool) {
        let ready = gate == .ready && workspaceIsReady
        self.init(canStart: ready, canStop: ready, canRestart: ready)
    }
}

// MARK: - 首次启动路由

/// 首次启动路由决策（GitHub #7）。
///
/// 纯函数：不读盘、不执行命令、不启动进程，因此可以在 unhosted 测试里直接断言。
/// 只有以下情况进入诊断状态页：
/// 1. 硬性前置未通过（Node.js / Pi CLI / Pi Web 缺失、过旧或版本无法解析）；
/// 2. 硬性前置已通过，但首次设置尚未完成（首次启动需要先走一次环境复核）；
/// 3. 工作目录不存在或不可写（GitHub #9）。
///
/// 判定看的是 `DependencyReport.canStartService`（必需项齐备且状态均为 `ok`），
/// 不是“`blockingFindings` 为空”：`DependencyReport(findings: [])` 这类缺少必需
/// 条目的报告没有 blocking 项，但必须停留在诊断页。
/// 除这两种情况外都进入正常主窗口。路由结果里没有“退出应用”这一项：缺少
/// pi/pi-web 时应用保留窗口并停留在诊断状态页，由用户修复后重新检测。
enum DiagnosticsRouting {
    /// 停留在诊断状态页的原因。
    enum Reason: Equatable {
        /// 硬性前置未通过；关联值是需要用户处理的诊断项（缺项与状态非 `ok`
        /// 的项），顺序与 `DependencyReport.prerequisiteKinds` 一致。
        case unmetPrerequisites([DependencyFinding.Kind])
        /// 首次设置尚未完成（环境复核从未通过）。
        case firstLaunchSetupIncomplete
        /// 工作目录不存在或不可写（GitHub #9）：同样阻止启动服务，
        /// 呈现可读修复提示。
        case unusableWorkspace(WorkspaceDirectoryProblem)
    }

    enum Route: Equatable {
        case mainWindow
        case diagnostics([Reason])
    }

    /// 路由输入：只包含已算好的诊断报告、首次设置状态和工作目录校验结果。
    struct Context: Equatable {
        var report: DependencyReport
        var hasCompletedFirstLaunchSetup: Bool
        /// 工作目录不可用的原因（GitHub #9）；nil 表示目录可用或尚未校验。
        var workspaceProblem: WorkspaceDirectoryProblem?

        init(
            report: DependencyReport,
            hasCompletedFirstLaunchSetup: Bool,
            workspaceProblem: WorkspaceDirectoryProblem? = nil
        ) {
            self.report = report
            self.hasCompletedFirstLaunchSetup = hasCompletedFirstLaunchSetup
            self.workspaceProblem = workspaceProblem
        }
    }

    /// 需要用户处理的必需项：报告里没有该条目，或状态不是 `.ok`。
    /// 报告缺项（包括空报告）也算未通过，所以路由不能只看 `blockingFindings`。
    static func unmetPrerequisiteKinds(in report: DependencyReport) -> [DependencyFinding.Kind] {
        report.unsatisfiedPrerequisiteKinds
    }

    /// 硬性前置未通过时优先报告需要用户处理的项；前置就绪但首次设置未完成时
    /// 报告首次设置。工作目录不可用是独立原因，追加在两者之后（两者都成立时
    /// 页面上会同时看到硬性前置与工作目录两个问题）。
    static func route(_ context: Context) -> Route {
        var reasons: [Reason] = []
        if !context.report.canStartService {
            reasons.append(.unmetPrerequisites(unmetPrerequisiteKinds(in: context.report)))
        } else if !context.hasCompletedFirstLaunchSetup {
            reasons.append(.firstLaunchSetupIncomplete)
        }
        if let problem = context.workspaceProblem {
            reasons.append(.unusableWorkspace(problem))
        }
        return reasons.isEmpty ? .mainWindow : .diagnostics(reasons)
    }

    /// 首次设置完成的唯一条件：硬性前置已通过诊断（`canStartService`）。
    /// 用户重新检测（或在诊断页选择 pi-web 路径）得到就绪报告时才记录完成。
    static func completesFirstLaunchSetup(report: DependencyReport) -> Bool {
        report.canStartService
    }
}

// MARK: - 首次启动完成后的启动语义

/// 进入主窗口时服务应如何启动（GitHub #7 复审）。
///
/// 首次设置刚由用户完成时不能沿用 `autoStart`：用户刚刚修好了前置，如果关掉
/// 自动启动，`startAtLaunch()` 只会探测外部服务然后显示“未运行”，看起来像
/// 设置没有任何效果。正常启动（包括已配置的每次重启）仍然尊重 `autoStart`。
enum ServiceLaunchIntent: Equatable {
    /// 正常启动：用配置里的 `autoStart` 决定是否拉起服务。
    case respectAutoStart
    /// 首次设置刚完成：忽略 `autoStart`，显式启动服务。
    case startExplicitly

    /// 可测试的判定点：只有“本次调用刚刚完成首次设置”才显式启动。
    static func intent(firstLaunchSetupJustCompleted: Bool) -> ServiceLaunchIntent {
        firstLaunchSetupJustCompleted ? .startExplicitly : .respectAutoStart
    }

    /// 传给 `ServiceManager.startAtLaunch(forceStart:)` 的开关。
    var forcesStart: Bool { self == .startExplicitly }
}

// MARK: - pi-web 路径选择

/// 选择一个 pi-web 可执行文件时收集到的只读身份证据。
///
/// 可执行位不是身份：`/bin/echo` 也可执行，所以选择路径时必须再看版本或包名。
struct PiWebIdentityEvidence: Equatable {
    /// 目标是否存在且可执行。
    var isExecutable: Bool
    /// `--version` 解析出的版本；无法解析为 nil。
    var version: String?
    /// 沿真实路径向上找到的 package.json 名称；没有为 nil。
    var packageName: String?

    /// 至少有一项可核对的身份证据：能解析出版本，或包名就是 `@agegr/pi-web`。
    var confirmsPiWebIdentity: Bool {
        version != nil || packageName == DependencyChecker.piWebPackageName
    }
}

/// “选择 pi-web 路径”的纯校验与应用逻辑（GitHub #7）。
///
/// 只有校验通过才会返回改写后的配置；被拒绝时返回原配置和一个可读错误，
/// 调用方因此不可能在失败路径上写入 UserDefaults。可执行性与身份证据由调用方
/// 注入（生产环境用 `DependencyChecker.piWebIdentityEvidence(atPath:)`），
/// 测试不需要真实文件、进程或网络。
enum PiWebPathSelection {
    struct Result: Equatable {
        /// 接受时是写入 `piWebPath` 后的配置；拒绝时与输入完全相同。
        var configuration: ServiceConfiguration
        /// 可读错误信息；nil 表示已接受。
        var error: String?
    }

    static func apply(
        selectedPath: String,
        configuration: ServiceConfiguration,
        evidence: (String) -> PiWebIdentityEvidence
    ) -> Result {
        let trimmed = selectedPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return Result(configuration: configuration, error: "没有选择文件，pi-web 路径未修改。")
        }
        guard (trimmed as NSString).isAbsolutePath else {
            return Result(
                configuration: configuration,
                error: "请选择 pi-web 可执行文件的绝对路径，配置未修改：\(trimmed)"
            )
        }
        let proof = evidence(trimmed)
        guard proof.isExecutable else {
            return Result(
                configuration: configuration,
                error: "该文件不可执行，配置未修改：\(trimmed)。请选择已安装的 pi-web 可执行文件。"
            )
        }
        guard proof.confirmsPiWebIdentity else {
            return Result(
                configuration: configuration,
                error: "无法确认该文件是 pi-web，配置未修改：\(trimmed)。"
                    + "需要能解析出版本，或 package.json 名称为 \(DependencyChecker.piWebPackageName)。"
            )
        }
        var updated = configuration
        updated.piWebPath = trimmed
        return Result(configuration: updated, error: nil)
    }
}

// MARK: - 诊断 smoke 夹具

/// `PI_WEB_DESKTOP_SMOKE=diagnostics` 使用的确定性诊断报告（GitHub #7）。
///
/// 报告仍由真实的 `DependencyChecker.run()` 生成，但所有探针都是固定的：
/// 不执行任何命令、不读真实磁盘或 `~/.pi`、不绑定真实端口、不联网。因此 smoke
/// 输出与机器状态无关，也不会触碰真实配置。假 Home 是 `/smoke`，脱敏后诊断
/// 文本里只会出现 `~`。
enum DiagnosticsSmokeFixture {
    static func report() -> DependencyReport {
        DependencyChecker(
            commandRunner: SmokeCommandRunner(),
            fileSystem: SmokeFileSystem(),
            system: DependencySystemProbe(
                architecture: { "arm64" },
                // 复用最低系统版本常量，避免在源码里写第二份版本字面值。
                operatingSystemVersion: { DependencyChecker.minimumMacOSVersion }
            ),
            configuredPiWebPath: "",
            serviceHostname: ServiceConfiguration.defaultHostname,
            servicePort: ServiceConfiguration.defaultPort,
            portProbe: SmokePortProbe()
        ).run()
    }

    /// 从不出结果的假命令执行器：没有任何可执行文件会被真的运行。
    private struct SmokeCommandRunner: CommandRunning {
        func run(_ arguments: [String]) -> String? { nil }
    }

    /// 空文件系统：没有可执行文件、没有目录、没有文本文件。
    private struct SmokeFileSystem: DependencyFileSystemProbing {
        func isExecutableFile(atPath path: String) -> Bool { false }
        func symlinkDestination(atPath path: String) -> String? { nil }
        func resolvedPath(atPath path: String) -> String? { nil }
        func readText(atPath path: String) -> String? { nil }
        func homeDirectoryPath() -> String { "/smoke" }
        func directoryExists(atPath path: String) -> Bool? { false }
        func isReadableDirectory(atPath path: String) -> Bool? { false }
    }

    /// 端口探针固定报告“可用”：smoke 不绑定真实端口。
    private struct SmokePortProbe: DependencyPortProbing {
        func isPortAvailable(host: String, port: Int) -> Bool? { true }
    }
}
