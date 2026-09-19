import Foundation

// MARK: - 受限自动更新模型（GitHub #20）
//
// 本文件是唯一一处“应用自己执行安装命令”的实现。边界：
// - 只有“设置位打开 + #16 检测结果 source == .npmGlobal 且 confidence == .verified +
//   有已验证的目标版本 + 检查结果来源是本次网络响应 + 当前没有以本应用名义运行的
//   服务”五条同时成立才允许自动安装；
// - 缓存回退（`UpdateCheckOrigin.cachedFallback`）与没有结果一律不自动安装：
//   缓存文件不是可信输入（同一用户可改写），只用于提示（GitHub #59 / 安全审查 A-1）；
// - 其它来源只产出可展示的命令文本，绝不自动安装；
// - 命令只以参数数组传给子进程（`Process` + `arguments`），没有 shell 字符串，
//   也不调用 `sudo`；
// - 环境变量白名单化：不把无关凭据、`NODE_OPTIONS`、`npm_config_*` 透传给 npm；
// - 安装有超时；超时按失败处理，不阻塞应用启动无上限；
// - 安装后重新检测版本并复用既有健康检查；验证失败或健康检查失败时保留旧版本
//   语义并记录失败原因，不静默继续、也不声称回滚成功（完整回滚框架属于 #23）。

// MARK: - 拒绝 / 授权原因

/// 不自动安装的原因，或自动安装被拒绝的原因。全部是固定文案：不含路径、包名
/// 之外的动态内容或诊断细节。
enum PiWebUpdateRefusal: Equatable {
    /// 设置位关闭。
    case settingDisabled
    /// 没有可用的 Pi Web 安装信息（缺少 #16 识别结果）。
    case missingInstallation
    /// 来源不是“已验证的 npm 全局安装”。
    case sourceNotVerifiedNPMGlobal(source: InstallSource, confidence: DetectionConfidence)
    /// 没有可用的目标版本（检查结果不是“可更新”或没有版本号）。
    case noTargetVersion
    /// 目标版本未经上游响应验证（confidence != verified）。
    case targetNotVerified
    /// 判定所用的检查结果不是本次运行从白名单主机取得的网络结果（缓存回退或
    /// 没有结果）。缓存文件不是可信输入，因此这条前置条件不允许被绕过。
    case targetNotFromNetwork(origin: UpdateCheckOrigin, cacheWrittenAt: Date?)
    /// 目标版本不是可比较的语义化版本。
    case invalidTargetVersion
    /// 本机版本不低于目标版本。
    case noNewerTargetVersion
    /// 当前有以本应用名义运行的服务：自动更新只安排到下次启动。
    case serviceRunning
    /// 无法解析出可执行位确认的 npm。
    case npmExecutableUnresolved
    /// 包名不是预期的 Pi Web 包名（或不符合 npm 包名规范）。
    case invalidPackageName
    /// 构造出的命令未通过参数安全校验（含 shell 元字符或 `sudo`/shell 包装）。
    case unsafeCommand

    var text: String {
        switch self {
        case .settingDisabled:
            return "启动前自动更新设置已关闭"
        case .missingInstallation:
            return "没有可用的 Pi Web 安装信息"
        case .sourceNotVerifiedNPMGlobal(let source, let confidence):
            return "Pi Web 来源是 \(source.displayName)（可信度 \(confidence.displayName)）；只有来源为已验证的 npm 全局安装才允许自动更新"
        case .noTargetVersion:
            return "没有可用的目标版本"
        case .targetNotVerified:
            return "目标版本未经上游响应验证"
        case .targetNotFromNetwork(let origin, let cacheWrittenAt):
            return origin.autoInstallRefusalText(cacheWrittenAt: cacheWrittenAt)
        case .invalidTargetVersion:
            return "目标版本无法解析为语义化版本"
        case .noNewerTargetVersion:
            return "本机版本不低于目标版本"
        case .serviceRunning:
            return "有本应用启动的 Pi Web 服务正在运行；自动更新只安排到下次启动"
        case .npmExecutableUnresolved:
            return "无法确认可用于安装的 npm 可执行文件"
        case .invalidPackageName:
            return "包名不是预期的 Pi Web 包名"
        case .unsafeCommand:
            return "构造出的安装命令未通过参数安全校验"
        }
    }
}

// MARK: - 参数与环境策略（纯函数）

/// 安装命令的参数与安全校验。
///
/// 只接受“字面量参数”形态：ASCII 字母、数字与 `@ / . _ - + ~ = :`。因此参数
/// 里不可能出现空白、引号、`;`、`|`、`&`、`$`、反引号、`(`、`)`、`>`、`<`、
/// `*`、`?`、`!`、换行等 shell 元字符。`sudo` 与 shell 解释器名也被显式拒绝，
/// 即使未来有人把参数来源换成别的输入。
enum PiWebUpdateArgumentPolicy {
    /// 允许的参数字符集（包名与语义化版本都落在其中）。
    static let allowedCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789@/._-+~=:")

    /// 显式禁止的整词参数（命令名与 shell 包装）。
    static let forbiddenTokens: Set<String> = ["sudo", "sh", "bash", "zsh", "eval", "exec", "env", "-c"]

    static func isSafe(argument: String) -> Bool {
        guard !argument.isEmpty else { return false }
        guard !forbiddenTokens.contains(argument) else { return false }
        return argument.unicodeScalars.allSatisfy { allowedCharacters.contains($0) }
    }

    static func isSafe(_ arguments: [String]) -> Bool {
        !arguments.isEmpty && arguments.allSatisfy(isSafe(argument:))
    }

    /// 展示用的 argv 文本。参数已通过安全校验，因此用空格连接不会有歧义。
    static func displayText(for arguments: [String]) -> String {
        arguments.map { "\"\($0)\"" }.joined(separator: ", ")
    }
}

/// 子进程环境变量白名单。
///
/// npm 正常运行需要 `HOME`（npmrc/缓存）与 `PATH`（`node` 通过 shebang 解析），
/// 所以只保留以下键；`NODE_OPTIONS`、`NODE_PATH`、`npm_config_*`、代理与任何
/// 凭据（token/password/secret/key）都不进入子进程。日志与诊断只记录键名，
/// 从不记录值。
enum PiWebUpdateEnvironment {
    static let allowedKeys: Set<String> = ["PATH", "HOME", "TMPDIR", "LANG", "LC_ALL", "LC_CTYPE"]

    /// 兜底的 PATH 目录（与 `ServiceLaunchSpecification` 的固定 PATH 一致）。
    static let fallbackPathDirectories = [
        "/opt/homebrew/bin",
        "/opt/homebrew/sbin",
        "/usr/local/bin",
        "/usr/bin",
        "/bin",
        "/usr/sbin",
        "/sbin"
    ]

    /// 只保留白名单键，空值也丢弃。
    static func sanitized(_ base: [String: String]) -> [String: String] {
        var result: [String: String] = [:]
        for key in allowedKeys {
            guard let value = base[key], !value.isEmpty else { continue }
            result[key] = value
        }
        return result
    }

    /// 白名单化后把 npm 所在目录放到 PATH 最前：npm 是带 `#!/usr/bin/env node`
    /// shebang 的脚本，GUI 应用的默认 PATH 里通常没有 Node.js 的目录。
    static func environment(base: [String: String], npmExecutablePath: String) -> [String: String] {
        var result = sanitized(base)
        var directories: [String] = []
        let npmDirectory = (npmExecutablePath as NSString).deletingLastPathComponent
        if !npmDirectory.isEmpty, npmDirectory != "/" {
            directories.append(npmDirectory)
        }
        for directory in (result["PATH"] ?? "").split(separator: ":") {
            let text = String(directory)
            guard !text.isEmpty, !directories.contains(text) else { continue }
            directories.append(text)
        }
        for directory in fallbackPathDirectories where !directories.contains(directory) {
            directories.append(directory)
        }
        result["PATH"] = directories.joined(separator: ":")
        return result
    }

    /// 只用于展示/日志：按键排序的键名，不含值。
    static func keyDescription(_ environment: [String: String]) -> String {
        environment.keys.sorted().joined(separator: ", ")
    }
}

// MARK: - npm 生命周期脚本策略（GitHub #60，对应 alpha.3 安全审查 A-2）

/// 自动安装是否传 `--ignore-scripts` 的结论与理由。
///
/// **结论：刻意不传。** 这是一次**静态评估**——只读地检查了本机已安装包的文件，
/// 没有真的执行过安装，所以下面是脚本声明与作用的证据，不是实跑结果。
///
/// 只读证据（来自本机 npm 全局安装目录，路径由 `npm prefix -g` 推出的
/// `<前缀>/lib/node_modules/<静态包名>` 决定，不是硬编码的个人路径）：
/// - 上游 `package.json` 声明了 `postinstall`（命令是 `node bin/prepare-terminal.js`），
///   且 `files` 白名单含 `bin` 与 `.next`，即构建产物随包发布、安装期不依赖构建；
/// - `bin/prepare-terminal.js` 在 macOS 上只做一件事：给依赖 `node-pty` 的
///   `spawn-helper` 二进制补上可执行位（该脚本自己的注释写明上游包可能不保留该位）；
/// - 同一安装树里的依赖 `node-pty` 自己声明了 `install` 与 `postinstall`
///   （选择预编译原生模块，必要时 `node-gyp rebuild`）。
///
/// npm 的 `--ignore-scripts` 会跳过**所有**生命周期脚本，包括依赖的 `install`，
/// 因此跳过脚本可能留下缺少可执行位的终端辅助二进制或未就绪的原生模块——也就是
/// 破坏上游包自己的安装。是否允许脚本执行由用户的 npm 配置与上游包的声明决定，
/// 应用不替用户决定：argv 保持不带该开关，环境白名单也不注入
/// `npm_config_ignore_scripts`（`npm_config_*` 一律不传递）。
enum PiWebUpdateLifecycleScriptPolicy {
    /// 自动安装是否传 `--ignore-scripts`。恒为 `false`，见类型文档里的证据与取舍。
    static let passesIgnoreScripts = false

    /// 展示/日志用的固定说明（不含路径，也不含包名之外的动态内容）。
    static let rationale = "不传 --ignore-scripts（按上游包声明的安装期脚本执行；用你本机的 npm 与 npm 配置）"
}

// MARK: - 安装计划

/// 一次受限自动安装的完整计划：可执行文件、参数数组、白名单环境与展示字段。
///
/// `arguments` 精确等于将要传给子进程的 argv（不含可执行文件本身），因此测试
/// 可以逐项断言。展示文本里的可执行文件路径在展示前才用 `LogRedactor` 脱敏。
struct PiWebUpdateInstallPlan: Equatable {
    var npmExecutablePath: String
    var arguments: [String]
    var environment: [String: String]
    var packageName: String
    var installedVersion: String
    var targetVersion: String
    var source: InstallSource
    var confidence: DetectionConfidence

    /// 构造计划。包名、目标版本与参数必须全部通过校验；返回 nil 表示不允许执行。
    static func make(
        packageName: String,
        installedVersion: String,
        targetVersion: String,
        npmExecutablePath: String,
        baseEnvironment: [String: String],
        source: InstallSource,
        confidence: DetectionConfidence
    ) -> PiWebUpdateInstallPlan? {
        guard ComponentInstallationDetector.isPackageName(packageName),
              packageName == InstallCommandManifest.piWebPackageName else { return nil }
        guard let target = SemanticVersion(targetVersion), target.description == targetVersion else { return nil }
        guard !npmExecutablePath.isEmpty else { return nil }
        // 刻意不传 `--ignore-scripts`：上游包声明了安装期脚本，而 npm 的该开关会连依赖的
        // `install` 脚本一起跳过，可能留下不可用的原生模块。静态评估与只读证据见
        // `PiWebUpdateLifecycleScriptPolicy`。
        let arguments = ["install", "-g", "\(packageName)@\(targetVersion)"]
        guard PiWebUpdateArgumentPolicy.isSafe(arguments) else { return nil }
        return PiWebUpdateInstallPlan(
            npmExecutablePath: npmExecutablePath,
            arguments: arguments,
            environment: PiWebUpdateEnvironment.environment(base: baseEnvironment, npmExecutablePath: npmExecutablePath),
            packageName: packageName,
            installedVersion: installedVersion,
            targetVersion: targetVersion,
            source: source,
            confidence: confidence
        )
    }

    /// 更新前展示的完整信息（写入日志与诊断/确认界面）。路径用 `redactor`
    /// 脱敏；环境变量只列键名，不列值。
    func displayLines(redactingWith redactor: LogRedactor) -> [String] {
        [
            "可执行文件：\(redactor.redact(npmExecutablePath))",
            "参数数组：\(PiWebUpdateArgumentPolicy.displayText(for: arguments))",
            "生命周期脚本：\(PiWebUpdateLifecycleScriptPolicy.rationale)",
            "当前版本：\(installedVersion)",
            "目标版本：\(targetVersion)",
            "来源：\(source.displayName)；可信度：\(confidence.displayName)",
            "环境变量键（不记录值）：\(PiWebUpdateEnvironment.keyDescription(environment))",
            "不使用 shell 字符串、不调用 sudo。"
        ]
    }

    /// 手动更新的确认文案：与日志/诊断同一组事实。
    func confirmationText(redactingWith redactor: LogRedactor) -> String {
        displayLines(redactingWith: redactor).joined(separator: "\n")
    }
}

// MARK: - 决策

/// 自动更新决策。只有 `.automatic` 会真正执行安装；其余情况只展示命令文本
/// （可能为 nil，表示按来源文档更新）。
enum PiWebUpdateDecision: Equatable {
    case automatic(PiWebUpdateInstallPlan)
    case manualOnly(commandText: String?, reason: PiWebUpdateRefusal)
    case unavailable(reason: PiWebUpdateRefusal)

    var reason: PiWebUpdateRefusal {
        switch self {
        case .automatic: return .settingDisabled
        case .manualOnly(_, let reason): return reason
        case .unavailable(let reason): return reason
        }
    }

    var isAutomatic: Bool {
        if case .automatic = self { return true }
        return false
    }

    var commandText: String? {
        switch self {
        case .automatic(let plan):
            return ([plan.npmExecutablePath] + plan.arguments).joined(separator: " ")
        case .manualOnly(let commandText, _):
            return commandText
        case .unavailable:
            return nil
        }
    }

    /// 日志与诊断行（已脱敏）。参数数组只在 `.automatic` 时给出。
    func logLine(redactingWith redactor: LogRedactor) -> String {
        switch self {
        case .automatic(let plan):
            var lines = ["Pi Web 启动前自动更新：允许执行（设置打开、来源为已验证的 npm 全局、目标版本 \(plan.targetVersion)）"]
            lines.append(contentsOf: plan.displayLines(redactingWith: redactor))
            return lines.joined(separator: "\n")
        case .manualOnly(let commandText, let reason):
            var line = "Pi Web 启动前自动更新：不执行（\(reason.text)）"
            if let commandText {
                line += "；只展示命令：\(redactor.redact(commandText))"
            } else {
                line += "；没有适用于该来源的静态命令，请按来源文档更新"
            }
            return line
        case .unavailable(let reason):
            return "Pi Web 启动前自动更新：不执行（\(reason.text)）"
        }
    }
}

// MARK: - 决策输入与规划器

/// 决策所需的全部输入（纯值类型，测试可直接构造）。
struct PiWebUpdatePlanningInput: Equatable {
    var preferences: UpdateCheckPreferences
    /// #16 的 Pi Web 组件识别结果。
    var installation: ComponentInstallation?
    /// #17/#18 检查器给出的上游版本。
    var targetVersion: String?
    /// 检查结论；只有 `.updateAvailable` 才算有可用目标版本。
    var targetStatus: UpdateCheckStatus = .unknown
    /// 检查结论的可信度；只有 `.verified` 才允许自动安装。
    var targetConfidence: DetectionConfidence = .unknown
    /// 检查结论的来源；只有 `.network`（本次运行刚从白名单主机取得）才允许
    /// 自动安装。默认值是最安全的一档，漏传时不会退化成“允许自动安装”。
    var targetOrigin: UpdateCheckOrigin = .unavailable
    /// 来源为缓存回退时的缓存写入时间（仅用于展示与拒绝原因）。
    var targetCacheWrittenAt: Date? = nil
    /// 当前是否有以本应用名义运行的服务。
    var serviceIsRunning: Bool = false
    /// 已由 `PiWebUpdateNPMResolver` 解析并通过可执行位确认的 npm 路径。
    var npmExecutablePath: String?
    /// 进程环境；规划器只把白名单键交给子进程。
    var baseEnvironment: [String: String] = [:]
}

/// 前置条件与命令构造的纯逻辑（GitHub #20 第 1 项）。
enum PiWebUpdatePlanner {
    /// 是否需要为了自动更新等一次覆盖 Pi Web 的检查结果：设置打开且检测结果是
    /// 已验证的 npm 全局安装。
    static func needsTargetVersionBeforeLaunch(
        preferences: UpdateCheckPreferences,
        installation: ComponentInstallation?
    ) -> Bool {
        guard preferences.autoUpdatePiWebBeforeLaunch, let installation else { return false }
        return installation.kind == .piWeb
            && installation.source == .npmGlobal
            && installation.confidence == .verified
    }

    /// 包名必须是 #16 静态清单里的 Pi Web 包名：检测结果里的包名只用于交叉验证，
    /// 不会直接拼进命令。
    static func safePackageName(_ text: String?) -> String? {
        guard let text,
              ComponentInstallationDetector.isPackageName(text),
              text == InstallCommandManifest.piWebPackageName else { return nil }
        return text
    }

    /// 决策。所有拒绝原因都可用 `reason.text` 展示。
    static func decide(_ input: PiWebUpdatePlanningInput) -> PiWebUpdateDecision {
        let commandText = input.installation?.suggestedCommand
        guard input.preferences.autoUpdatePiWebBeforeLaunch else {
            return .manualOnly(commandText: commandText, reason: .settingDisabled)
        }
        guard let installation = input.installation, installation.kind == .piWeb else {
            return .unavailable(reason: .missingInstallation)
        }
        guard installation.source == .npmGlobal, installation.confidence == .verified else {
            return .manualOnly(
                commandText: commandText,
                reason: .sourceNotVerifiedNPMGlobal(source: installation.source, confidence: installation.confidence)
            )
        }
        guard input.targetStatus == .updateAvailable,
              let targetVersion = input.targetVersion,
              !targetVersion.isEmpty else {
            return .manualOnly(commandText: commandText, reason: .noTargetVersion)
        }
        guard input.targetConfidence == .verified else {
            return .manualOnly(commandText: commandText, reason: .targetNotVerified)
        }
        // 硬前置（GitHub #59 / alpha.3 安全审查 A-1）：判定所用的检查结果必须是
        // 本次运行刚从白名单主机取得的响应。缓存回退或没有结果一律不自动执行，
        // 只保留手动入口；缓存文件不是可信输入（同一用户可改写）。
        guard input.targetOrigin.isEligibleForAutomaticInstall else {
            return .manualOnly(
                commandText: commandText,
                reason: .targetNotFromNetwork(origin: input.targetOrigin, cacheWrittenAt: input.targetCacheWrittenAt)
            )
        }
        guard let target = SemanticVersion(targetVersion) else {
            return .manualOnly(commandText: commandText, reason: .invalidTargetVersion)
        }
        guard let installedVersion = installation.version,
              let installed = SemanticVersion(installedVersion),
              installed < target else {
            return .manualOnly(commandText: commandText, reason: .noNewerTargetVersion)
        }
        guard !input.serviceIsRunning else {
            return .manualOnly(commandText: commandText, reason: .serviceRunning)
        }
        guard let packageName = safePackageName(installation.packageName) else {
            return .unavailable(reason: .invalidPackageName)
        }
        guard let npmExecutablePath = input.npmExecutablePath, !npmExecutablePath.isEmpty else {
            return .unavailable(reason: .npmExecutableUnresolved)
        }
        guard let plan = PiWebUpdateInstallPlan.make(
            packageName: packageName,
            installedVersion: installedVersion,
            targetVersion: targetVersion,
            npmExecutablePath: npmExecutablePath,
            baseEnvironment: input.baseEnvironment,
            source: installation.source,
            confidence: installation.confidence
        ) else {
            return .unavailable(reason: .unsafeCommand)
        }
        return .automatic(plan)
    }
}

// MARK: - npm 可执行文件解析

/// 从 #16 的检测结果与进程环境里解析安装用的 npm。
///
/// 只使用两条证据：检测到的 npm 全局前缀（由 pi-web 的可执行文件 / 真实路径
/// 推导）与 `PATH` 解析结果；候选路径必须通过注入文件系统探针的可执行位确认。
/// 解析不出时返回 nil：绝不猜测路径，也绝不回退到 shell。
struct PiWebUpdateNPMResolver {
    var fileSystem: DependencyFileSystemProbing
    var environment: [String: String]

    init(
        fileSystem: DependencyFileSystemProbing = SystemDependencyFileSystemProbe(),
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.fileSystem = fileSystem
        self.environment = environment
    }

    /// 候选路径（按优先级）。只做推导，不判存在性。
    func candidates(installation: ComponentInstallation?) -> [String] {
        var result: [String] = []
        func append(_ path: String) {
            guard !path.isEmpty, !result.contains(path) else { return }
            result.append(path)
        }
        if let installation {
            for path in [installation.resolvedPath, installation.executablePath].compactMap({ $0 }) {
                for candidate in Self.prefixDerivedNPMPaths(from: path) {
                    append(candidate)
                }
            }
        }
        for directory in (environment["PATH"] ?? "").split(separator: ":") {
            guard !directory.isEmpty else { continue }
            append((String(directory) as NSString).appendingPathComponent("npm"))
        }
        return result
    }

    /// 解析并确认可执行位；没有可执行候选时返回 nil。
    func resolve(installation: ComponentInstallation?) -> String? {
        candidates(installation: installation).first { fileSystem.isExecutableFile(atPath: $0) }
    }

    /// 由 `<prefix>/bin/pi-web` 或 `<prefix>/lib/node_modules/<包>/…` 推导
    /// `<prefix>/bin/npm`。
    static func prefixDerivedNPMPaths(from path: String) -> [String] {
        guard !path.isEmpty else { return [] }
        var result: [String] = []
        if let range = path.range(of: "/lib/node_modules/") {
            let prefix = String(path[path.startIndex..<range.lowerBound])
            if !prefix.isEmpty {
                result.append(prefix + "/bin/npm")
            }
        }
        let directory = (path as NSString).deletingLastPathComponent
        if (directory as NSString).lastPathComponent == "bin", !directory.isEmpty {
            result.append((directory as NSString).appendingPathComponent("npm"))
        }
        return result
    }
}

// MARK: - 安装执行

/// 安装失败类别。固定枚举，不含子进程输出或路径。
enum PiWebUpdateInstallFailure: String, Equatable {
    case launchFailed
    case timedOut
    case cancelled
    case nonZeroExit

    var text: String {
        switch self {
        case .launchFailed: return "无法启动安装进程"
        case .timedOut: return "安装超时"
        case .cancelled: return "安装被取消"
        case .nonZeroExit: return "安装命令以非零退出码结束"
        }
    }
}

/// 一次安装执行的结果。`outputTail` 是子进程输出的有界末尾片段，只用于诊断；
/// 展示/记录前必须经过 `LogRedactor`。
struct PiWebUpdateInstallResult: Equatable {
    var exitCode: Int32?
    var timedOut: Bool
    var cancelled: Bool
    var launchFailed: Bool
    var startedAt: Date
    var finishedAt: Date
    var outputTail: String?

    init(
        exitCode: Int32?,
        timedOut: Bool = false,
        cancelled: Bool = false,
        launchFailed: Bool = false,
        startedAt: Date,
        finishedAt: Date,
        outputTail: String? = nil
    ) {
        self.exitCode = exitCode
        self.timedOut = timedOut
        self.cancelled = cancelled
        self.launchFailed = launchFailed
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.outputTail = outputTail
    }

    /// nil 表示执行成功（退出码 0 且未超时/取消）。超时与取消优先于退出码。
    var failure: PiWebUpdateInstallFailure? {
        if cancelled { return .cancelled }
        if timedOut { return .timedOut }
        if launchFailed { return .launchFailed }
        guard let exitCode else { return .launchFailed }
        return exitCode == 0 ? nil : .nonZeroExit
    }

    var duration: TimeInterval { finishedAt.timeIntervalSince(startedAt) }
}

/// 安装器抽象。生产实现是 `ProcessPiWebUpdateInstaller`；测试注入记录调用的
/// 替身，绝不执行真实 npm 或访问网络。
protocol PiWebUpdateInstalling: AnyObject {
    /// 以参数数组执行安装命令。超时按失败处理，并在结果里标记；`completion`
    /// 可能在任何队列上被调用。
    func install(
        _ plan: PiWebUpdateInstallPlan,
        timeout: TimeInterval,
        completion: @escaping (PiWebUpdateInstallResult) -> Void
    )
    /// 取消进行中的安装（若还有）。取消按失败处理。
    func cancel()
}

/// 生产安装器：`Process` + `arguments`，没有 shell、没有 `sudo`。
///
/// - 可执行文件、参数数组、环境都来自 `PiWebUpdateInstallPlan`；
/// - stdin 为 `/dev/null`，stdout/stderr 合并进一个管道并只保留有界末尾片段；
/// - 超时先用 `SIGTERM`，宽限期后 `SIGKILL`，并把结果标记为超时失败；
/// - 任何失败都只返回结果，不抛出、不崩溃。
final class ProcessPiWebUpdateInstaller: PiWebUpdateInstalling {
    /// 保留的子进程输出上限（字符）。
    static let outputTailLimit = 2000
    /// 默认终止宽限期（秒）。
    static let defaultTerminationGrace: TimeInterval = 2

    private let stateQueue = DispatchQueue(label: "io.github.su-luoya.pi-web-desktop.pi-web-update-installer")
    private let clock: () -> Date
    private let terminationGrace: TimeInterval

    private var process: Process?
    private var timer: DispatchSourceTimer?
    private var completion: ((PiWebUpdateInstallResult) -> Void)?
    private var finished = false
    private var timedOut = false
    private var cancelled = false
    private var startedAt: Date?
    private var outputTail = ""

    init(
        clock: @escaping () -> Date = { Date() },
        terminationGrace: TimeInterval = ProcessPiWebUpdateInstaller.defaultTerminationGrace
    ) {
        self.clock = clock
        self.terminationGrace = terminationGrace
    }

    func install(
        _ plan: PiWebUpdateInstallPlan,
        timeout: TimeInterval,
        completion: @escaping (PiWebUpdateInstallResult) -> Void
    ) {
        stateQueue.async { [weak self] in
            self?.startLocked(plan, timeout: timeout, completion: completion)
        }
    }

    func cancel() {
        stateQueue.async { [weak self] in
            guard let self, !self.finished else { return }
            self.cancelled = true
            self.terminateLocked()
            self.finishLocked(exitCode: nil)
        }
    }

    // MARK: - 内部（全部在 stateQueue 上执行）

    private func startLocked(
        _ plan: PiWebUpdateInstallPlan,
        timeout: TimeInterval,
        completion: @escaping (PiWebUpdateInstallResult) -> Void
    ) {
        guard !finished else { return }
        self.completion = completion
        self.startedAt = clock()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: plan.npmExecutablePath)
        process.arguments = plan.arguments
        process.environment = plan.environment
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            self?.appendOutput(data)
        }
        process.terminationHandler = { [weak self] finishedProcess in
            self?.stateQueue.async {
                self?.finishLocked(exitCode: finishedProcess.terminationStatus)
            }
        }
        self.process = process
        do {
            try process.run()
        } catch {
            finishLocked(exitCode: nil, launchFailed: true)
            return
        }
        scheduleTimeoutLocked(timeout)
    }

    private func scheduleTimeoutLocked(_ timeout: TimeInterval) {
        let timer = DispatchSource.makeTimerSource(queue: stateQueue)
        timer.schedule(deadline: .now() + max(0.05, timeout))
        timer.setEventHandler { [weak self] in
            guard let self, !self.finished else { return }
            self.timedOut = true
            self.terminateLocked()
            self.finishLocked(exitCode: nil)
        }
        timer.resume()
        self.timer = timer
    }

    /// 先 `SIGTERM`，宽限期后 `SIGKILL`。只针对本次启动的子进程。
    private func terminateLocked() {
        guard let process, process.isRunning else { return }
        let pid = process.processIdentifier
        process.terminate()
        guard pid > 1 else { return }
        stateQueue.asyncAfter(deadline: .now() + terminationGrace) {
            guard process.isRunning else { return }
            kill(pid, SIGKILL)
        }
    }

    private func appendOutput(_ data: Data) {
        guard let text = String(data: data, encoding: .utf8), !text.isEmpty else { return }
        stateQueue.async { [weak self] in
            guard let self, !self.finished else { return }
            self.outputTail += text
            if self.outputTail.count > Self.outputTailLimit {
                self.outputTail = String(self.outputTail.suffix(Self.outputTailLimit))
            }
        }
    }

    private func finishLocked(exitCode: Int32?, launchFailed: Bool = false) {
        guard !finished else { return }
        finished = true
        timer?.cancel()
        timer = nil
        if let handle = (process?.standardOutput as? Pipe)?.fileHandleForReading {
            handle.readabilityHandler = nil
        }
        let finishedAt = clock()
        let result = PiWebUpdateInstallResult(
            exitCode: exitCode,
            timedOut: timedOut,
            cancelled: cancelled,
            launchFailed: launchFailed,
            startedAt: startedAt ?? finishedAt,
            finishedAt: finishedAt,
            outputTail: outputTail.isEmpty ? nil : outputTail
        )
        let completion = self.completion
        self.completion = nil
        self.process = nil
        completion?(result)
    }
}

// MARK: - 编排

/// 一次运行的结果。`plan` 携带版本前后值与参数数组，供日志与诊断使用。
enum PiWebUpdateRunOutcome: Equatable {
    /// 未尝试自动安装（设置关闭 / 来源不符 / 无目标版本 / 服务在运行）。
    case skipped(reason: PiWebUpdateRefusal, commandText: String?)
    /// 安装器失败（非零退出 / 超时 / 取消 / 启动失败）：旧版本保持原样。
    case installFailed(plan: PiWebUpdateInstallPlan, failure: PiWebUpdateInstallFailure, oldVersion: String, targetVersion: String, outputTail: String?)
    /// 安装器成功但重新检测的版本仍未达到目标版本。
    case versionUnchanged(plan: PiWebUpdateInstallPlan, detectedVersion: String?, oldVersion: String, targetVersion: String)
    /// 版本已更新，但服务启动或健康检查失败。
    case healthCheckFailed(plan: PiWebUpdateInstallPlan, oldVersion: String, newVersion: String)
    /// 版本已更新且服务健康检查通过。
    case succeeded(plan: PiWebUpdateInstallPlan, oldVersion: String, newVersion: String)

    var isSucceeded: Bool {
        if case .succeeded = self { return true }
        return false
    }

    /// 失败路径的持久警告记录；成功与跳过返回 nil。
    var warning: PiWebUpdateWarning? {
        switch self {
        case .skipped, .succeeded:
            return nil
        case .installFailed(let plan, let failure, let oldVersion, let targetVersion, _):
            return PiWebUpdateWarning(
                kind: .installFailed,
                oldVersion: oldVersion,
                newVersion: plan.installedVersion,
                targetVersion: targetVersion,
                reason: "更新失败，仍在使用旧版本：\(failure.text)"
            )
        case .versionUnchanged(_, let detectedVersion, let oldVersion, let targetVersion):
            return PiWebUpdateWarning(
                kind: .versionUnchanged,
                oldVersion: oldVersion,
                newVersion: detectedVersion,
                targetVersion: targetVersion,
                reason: "更新后验证失败，仍在使用更新前的版本：安装命令已结束，但重新检测到的版本是 \(detectedVersion ?? "未知")，未达到目标版本"
            )
        case .healthCheckFailed(let plan, let oldVersion, let newVersion):
            return PiWebUpdateWarning(
                kind: .healthCheckFailed,
                oldVersion: oldVersion,
                newVersion: newVersion,
                targetVersion: plan.targetVersion,
                reason: "更新后验证失败：版本已更新，但服务启动或健康检查失败"
            )
        }
    }
}

/// 启动前更新与手动更新的顺序编排：决策 → 安装 → 重新检测版本 → 启动 + 健康检查。
///
/// 全部副作用都注入（安装器、版本重检测、启动/健康检查、日志、投递队列、时钟），
/// 因此 unhosted 测试可以用同步替身断言每一步，不执行真实 npm、不访问网络、
/// 不启动真实服务。
final class PiWebUpdateCoordinator {
    struct Environment {
        /// 安装器（生产：`ProcessPiWebUpdateInstaller`；测试：记录替身）。
        var installer: PiWebUpdateInstalling
        /// 重新检测 Pi Web 版本（复用 #16 识别器）。
        var detectInstallation: () -> ComponentInstallation?
        /// 启动服务并做健康检查（复用既有启动/健康检查路径）。回调 true 表示
        /// 服务可用。
        var startServiceAndCheckHealth: (@escaping (Bool) -> Void) -> Void
        /// 统一脱敏器（与日志/诊断共用同一个实例）。
        var redactor: LogRedactor
        /// 日志入口；每条消息写入前都必须经过 `redactor`。
        var log: (String) -> Void
        /// 结果投递队列（生产：主队列；测试：立即执行）。
        var deliver: (@escaping () -> Void) -> Void
        /// 安装超时（秒）。超时按失败处理。
        var timeout: TimeInterval
        /// 共享更新事务（GitHub #23）：文件系统探针、统一历史与降级应用。
        /// 默认不注入探针、不记历史、不应用降级，也不改变已有行为。
        var transaction: UpdateTransactionEnvironment

        init(
            installer: PiWebUpdateInstalling,
            detectInstallation: @escaping () -> ComponentInstallation?,
            startServiceAndCheckHealth: @escaping (@escaping (Bool) -> Void) -> Void,
            redactor: LogRedactor,
            log: @escaping (String) -> Void,
            deliver: @escaping (@escaping () -> Void) -> Void,
            timeout: TimeInterval = PiWebUpdateCoordinator.defaultTimeout,
            transaction: UpdateTransactionEnvironment = .disabled
        ) {
            self.installer = installer
            self.detectInstallation = detectInstallation
            self.startServiceAndCheckHealth = startServiceAndCheckHealth
            self.redactor = redactor
            self.log = log
            self.deliver = deliver
            self.timeout = timeout
            self.transaction = transaction
        }
    }

    /// 默认安装超时：5 分钟。有界，应用启动不会因为安装无上限地卡住。
    static let defaultTimeout: TimeInterval = 300

    private let environment: Environment

    init(environment: Environment) {
        self.environment = environment
    }

    /// 执行一次受限自动更新。`input.serviceIsRunning` 为 true 时只会得到
    /// `.skipped(.serviceRunning)`，不会调用安装器。
    func run(_ input: PiWebUpdatePlanningInput, completion: @escaping (PiWebUpdateRunOutcome) -> Void) {
        let decision = PiWebUpdatePlanner.decide(input)
        environment.log(decision.logLine(redactingWith: environment.redactor))
        switch decision {
        case .manualOnly(let commandText, let reason):
            environment.deliver { completion(.skipped(reason: reason, commandText: commandText)) }
        case .unavailable(let reason):
            environment.deliver { completion(.skipped(reason: reason, commandText: nil)) }
        case .automatic(let plan):
            runInstall(plan: plan, installation: input.installation, completion: completion)
        }
    }

    private func runInstall(
        plan: PiWebUpdateInstallPlan,
        installation: ComponentInstallation?,
        completion: @escaping (PiWebUpdateRunOutcome) -> Void
    ) {
        // 共享事务（GitHub #23）：准备阶段记录更新前指纹，安装/验证/提交/降级
        // 四个阶段的结果都进入同一份更新历史。
        let component = UpdateTransactionComponent.piWeb
        let advice = UpdateManualAdviceBuilder.advice(component: component, source: plan.source)
        var journal = UpdateTransactionJournal(
            configuration: UpdateTransactionJournal.Configuration(
                component: component,
                source: plan.source,
                previousVersion: plan.installedVersion,
                targetVersion: plan.targetVersion,
                fingerprint: UpdateArtifactFingerprint.capture(
                    installation: installation,
                    probe: environment.transaction.probe
                )
            ),
            now: environment.transaction.now
        )
        journal.recordPreflight()
        environment.installer.install(plan, timeout: environment.timeout) { [weak self] result in
            guard let self else { return }
            if let failure = result.failure {
                let degradation = UpdateDegradationPlanner.installFailure(
                    component: component,
                    source: plan.source,
                    fingerprint: journal.configuration.fingerprint,
                    targetVersion: plan.targetVersion,
                    failureReason: failure.text
                )
                journal.recordInstallFailed(failure.text)
                journal.recordCommitNotAttempted(reason: "安装阶段失败，未启用新版本")
                journal.recordDegradation(degradation)
                self.recordTransaction(
                    journal,
                    degradation: degradation,
                    advice: advice,
                    resultingVersion: nil
                )
                self.logOutcome(
                    "Pi Web 更新失败（\(failure.text)）：退出码 \(result.exitCode.map(String.init) ?? "无")，"
                    + "当前版本 \(plan.installedVersion)，目标版本 \(plan.targetVersion)。旧版本保持不变。"
                )
                if let tail = result.outputTail, !tail.isEmpty {
                    self.logOutputTail(tail)
                }
                let outcome = PiWebUpdateRunOutcome.installFailed(
                    plan: plan,
                    failure: failure,
                    oldVersion: plan.installedVersion,
                    targetVersion: plan.targetVersion,
                    outputTail: result.outputTail
                )
                self.environment.deliver { completion(outcome) }
                return
            }

            journal.recordInstallSucceeded()
            let detected = self.environment.detectInstallation()
            let detectedVersion = detected?.version
            let verificationInput = UpdateVerificationInput(
                component: .piWeb,
                packageName: component.expectedPackageName,
                previousVersion: plan.installedVersion,
                targetVersion: plan.targetVersion,
                detectedVersion: detectedVersion,
                detectedPackageName: detected?.packageName,
                detectedExecutablePath: detected?.executablePath,
                detectedResolvedPath: detected?.resolvedPath,
                detectedPackageJSONPath: detected?.packageJSONPath,
                fingerprint: journal.configuration.fingerprint
            )
            let report = UpdateVerifier.verify(
                verificationInput,
                probe: self.environment.transaction.probe
            )
            guard journal.recordVerification(report, detectedVersion: detectedVersion) else {
                let degradation = UpdateDegradationPlanner.verificationFailure(
                    component: component,
                    source: plan.source,
                    fingerprint: journal.configuration.fingerprint,
                    newVersion: detectedVersion,
                    newResolvedPath: detected?.resolvedPath ?? detected?.executablePath,
                    failureReason: report.failureReason ?? "验证未通过",
                    probe: self.environment.transaction.probe
                )
                journal.recordCommitNotAttempted(reason: "验证阶段失败，未启用新版本")
                journal.recordDegradation(degradation)
                self.environment.transaction.applyDegradation(degradation)
                self.recordTransaction(
                    journal,
                    degradation: degradation,
                    advice: advice,
                    resultingVersion: detectedVersion
                )
                self.logOutcome(
                    "Pi Web 更新未通过版本验证：安装命令退出码 0，但重新检测到的版本是 "
                    + "\(detectedVersion ?? "未知")，目标版本 \(plan.targetVersion)。"
                    + "旧版本语义保持不变；应用不会自动回滚，也不声称更新成功。"
                )
                let outcome = PiWebUpdateRunOutcome.versionUnchanged(
                    plan: plan,
                    detectedVersion: detectedVersion,
                    oldVersion: plan.installedVersion,
                    targetVersion: plan.targetVersion
                )
                self.environment.deliver { completion(outcome) }
                return
            }

            let newVersion = detectedVersion ?? plan.targetVersion
            self.environment.startServiceAndCheckHealth { [weak self] ready in
                guard let self else { return }
                let finalReport = UpdateVerifier.report(
                    report,
                    healthCheck: ready
                        ? .passed
                        : .failed(reason: "既有健康检查路径报告服务不可用")
                )
                if ready {
                    journal.recordDegradationNotNeeded()
                    journal.recordCommit(version: newVersion)
                    self.recordTransaction(
                        journal,
                        degradation: nil,
                        advice: advice,
                        resultingVersion: newVersion
                    )
                    self.logOutcome(
                        "Pi Web 更新完成：\(plan.installedVersion) → \(newVersion)，服务健康检查通过。"
                    )
                    let outcome = PiWebUpdateRunOutcome.succeeded(
                        plan: plan,
                        oldVersion: plan.installedVersion,
                        newVersion: newVersion
                    )
                    self.environment.deliver { completion(outcome) }
                } else {
                    // 健康检查失败也属于验证失败：用最终报告原地更新 verify 阶段。
                    journal.recordVerification(finalReport, detectedVersion: newVersion)
                    let degradation = UpdateDegradationPlanner.verificationFailure(
                        component: component,
                        source: plan.source,
                        fingerprint: journal.configuration.fingerprint,
                        newVersion: newVersion,
                        newResolvedPath: detected?.resolvedPath ?? detected?.executablePath,
                        failureReason: finalReport.failureReason ?? "服务健康检查失败",
                        probe: self.environment.transaction.probe
                    )
                    journal.recordDegradation(degradation)
                    self.environment.transaction.applyDegradation(degradation)
                    self.recordTransaction(
                        journal,
                        degradation: degradation,
                        advice: advice,
                        resultingVersion: newVersion
                    )
                    self.logOutcome(
                        "Pi Web 更新后健康检查失败：\(plan.installedVersion) → \(newVersion)。"
                        + "应用停在诊断状态，不会自动回滚，也不声称更新成功。"
                    )
                    let outcome = PiWebUpdateRunOutcome.healthCheckFailed(
                        plan: plan,
                        oldVersion: plan.installedVersion,
                        newVersion: newVersion
                    )
                    self.environment.deliver { completion(outcome) }
                }
            }
        }
    }

    /// 记录统一更新历史（GitHub #23）：阶段结果、从/到版本、降级结果与手动建议。
    /// 历史字段全部是固定枚举、已校验版本与静态清单文本，不含路径。
    private func recordTransaction(
        _ journal: UpdateTransactionJournal,
        degradation: UpdateDegradationPlan?,
        advice: UpdateManualAdvice,
        resultingVersion: String?
    ) {
        let entry = journal.historyEntry(
            degradation: degradation,
            advice: advice,
            resultingVersion: resultingVersion
        )
        environment.transaction.recordHistory(entry)
        logOutcome("更新历史：\(UpdateHistoryPresenter.lines(for: entry).joined(separator: " "))")
    }

    /// 重新检测的版本是否达到目标版本（相等或更高都算达到）。
    static func versionReached(detected: String?, target: String) -> Bool {
        UpdateVerifier.versionReached(detected: detected, old: target, target: target)
    }

    private func logOutcome(_ message: String) {
        environment.log(environment.redactor.redact(message))
    }

    private func logOutputTail(_ tail: String) {
        let redacted = environment.redactor.redact(tail)
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !redacted.isEmpty else { return }
        environment.log("Pi Web 安装输出片段（已脱敏）：\(redacted)")
    }
}

// MARK: - 持久警告

/// 一次失败的受限自动更新的持久记录。
///
/// 只保存类别、旧/新/目标版本、固定原因文案与时间：不含路径、环境变量值、
/// 凭据或子进程输出。警告在界面与诊断文本里持续显示，直到下一次成功更新。
struct PiWebUpdateWarning: Equatable {
    enum Kind: String, Equatable {
        case installFailed
        case versionUnchanged
        case healthCheckFailed
    }

    var kind: Kind
    var oldVersion: String?
    var newVersion: String?
    var targetVersion: String?
    var reason: String
    var recordedAt: Date

    init(
        kind: Kind,
        oldVersion: String? = nil,
        newVersion: String? = nil,
        targetVersion: String? = nil,
        reason: String,
        recordedAt: Date = Date()
    ) {
        self.kind = kind
        self.oldVersion = oldVersion
        self.newVersion = newVersion
        self.targetVersion = targetVersion
        self.reason = reason
        self.recordedAt = recordedAt
    }

    /// 用户可见的持久警告：明确说明旧版本语义保持不变、没有回滚成功这回事。
    var text: String {
        var parts: [String] = []
        parts.append("Pi Web 启动前自动更新未完成：\(reason)。")
        parts.append("当前版本：\(oldVersion ?? "未知")；目标版本：\(targetVersion ?? "未知")"
            + (newVersion.map { "；重新检测到的版本：\($0)" } ?? "") + "。")
        parts.append("旧版本语义保持不变：应用不会自动回滚已替换的文件，也不声称更新成功。"
            + "请查看日志与诊断结果后手动处理。")
        return parts.joined(separator: " ")
    }

    /// 菜单/状态行用的单行摘要。
    var shortText: String {
        "Pi Web 更新告警：\(reason)（当前 \(oldVersion ?? "未知") → 目标 \(targetVersion ?? "未知")）"
    }
}

/// 持久警告的 UserDefaults 存取（只经 `AppConfiguration` 调用）。
///
/// 键与其它更新检查设置分开：保存策略不会清掉警告，保存警告也不会改动策略。
/// 读到的值必须通过类型与版本校验，否则整条记录视为无效（返回 nil）。
enum PiWebUpdateWarningStore {
    static func load(from defaults: UserDefaults) -> PiWebUpdateWarning? {
        guard let kindText = defaults.string(forKey: UpdateSettingKeys.piWebUpdateWarningKind),
              let kind = PiWebUpdateWarning.Kind(rawValue: kindText) else { return nil }
        guard let reason = defaults.string(forKey: UpdateSettingKeys.piWebUpdateWarningReason),
              !reason.isEmpty else { return nil }
        let recordedAt = UpdateIgnoredVersions.timestamp(
            defaults.object(forKey: UpdateSettingKeys.piWebUpdateWarningRecordedAt)
        ) ?? Date(timeIntervalSince1970: 0)
        return PiWebUpdateWarning(
            kind: kind,
            oldVersion: version(defaults, UpdateSettingKeys.piWebUpdateWarningOldVersion),
            newVersion: version(defaults, UpdateSettingKeys.piWebUpdateWarningNewVersion),
            targetVersion: version(defaults, UpdateSettingKeys.piWebUpdateWarningTargetVersion),
            reason: reason,
            recordedAt: recordedAt
        )
    }

    static func save(_ warning: PiWebUpdateWarning?, to defaults: UserDefaults) {
        guard let warning else {
            for key in UpdateSettingKeys.allPiWebUpdateWarningKeys {
                defaults.removeObject(forKey: key)
            }
            return
        }
        defaults.set(warning.kind.rawValue, forKey: UpdateSettingKeys.piWebUpdateWarningKind)
        defaults.set(warning.reason, forKey: UpdateSettingKeys.piWebUpdateWarningReason)
        defaults.set(warning.recordedAt.timeIntervalSince1970, forKey: UpdateSettingKeys.piWebUpdateWarningRecordedAt)
        setVersion(warning.oldVersion, key: UpdateSettingKeys.piWebUpdateWarningOldVersion, defaults: defaults)
        setVersion(warning.newVersion, key: UpdateSettingKeys.piWebUpdateWarningNewVersion, defaults: defaults)
        setVersion(warning.targetVersion, key: UpdateSettingKeys.piWebUpdateWarningTargetVersion, defaults: defaults)
    }

    /// 只接受可解析为语义化版本的字符串；否则写入 nil（删除键）。
    static func setVersion(_ version: String?, key: String, defaults: UserDefaults) {
        guard let version, SemanticVersion(version) != nil else {
            defaults.removeObject(forKey: key)
            return
        }
        defaults.set(version, forKey: key)
    }

    static func version(_ defaults: UserDefaults, _ key: String) -> String? {
        guard let text = defaults.string(forKey: key), SemanticVersion(text) != nil else { return nil }
        return text
    }
}

// MARK: - 重检测辅助

/// 安装后与手动更新前的聚焦版本重检测：复用 #16 识别器，只识别 Pi Web 一个
/// 组件，不重新跑整个依赖诊断。
enum PiWebUpdateRedetection {
    static func request(piWebPath: String?) -> ComponentInstallationDetector.ComponentDetectionRequest {
        var candidates: [String] = []
        if let piWebPath, !piWebPath.isEmpty {
            candidates.append(piWebPath)
        }
        candidates.append(contentsOf: [
            "/opt/homebrew/bin/pi-web",
            "/usr/local/bin/pi-web"
        ])
        return ComponentInstallationDetector.ComponentDetectionRequest(
            kind: .piWeb,
            packageName: InstallCommandManifest.piWebPackageName,
            executableNames: ["pi-web"],
            candidates: candidates,
            knownVersion: nil,
            runsVersionCommand: true,
            isApplicationBundle: false,
            probesShellPath: true
        )
    }

    static func detect(
        piWebPath: String?,
        commandRunner: CommandRunning,
        fileSystem: DependencyFileSystemProbing = SystemDependencyFileSystemProbe(),
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: String? = nil
    ) -> ComponentInstallation {
        let detector = ComponentInstallationDetector(
            commandRunner: commandRunner,
            fileSystem: fileSystem,
            environment: environment,
            homeDirectory: homeDirectory
        )
        return detector.detect(request(piWebPath: piWebPath))
    }
}
