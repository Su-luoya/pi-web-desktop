import Darwin
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
    /// 同一时间只允许一次安装：已经有一次安装在进行（W2A A-2）。
    case updateAlreadyInProgress
    /// 同一组件存在未清除的「已放弃」记录（GitHub #62）：不允许自动执行，推迟到
    /// 下次启动；手动入口不受影响，但必须先看到这条记录。
    case abandonedAttemptPending(UpdateAbandonedAttempt)

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
        case .updateAlreadyInProgress:
            return "已有更新正在进行"
        case .abandonedAttemptPending(let attempt):
            return UpdateAbandonedAttemptPresenter.automaticRefusalText(attempt)
        }
    }
}

// MARK: - 参数与环境策略（纯函数）

/// 安装命令的参数形状校验。**它不是 flag 注入防线**：`-g`、`--registry=…`、
/// `--prefix=…` 这类以 `-` 开头的 token 全部满足下面的字符集，会被放行（W2A A-7）。
///
/// 真正拦住 flag 注入的是 `PiWebUpdateInstallPlan.make`：它不采纳任何外部参数，
/// 只把固定的三元素 argv（`install`、`-g`、`包名@版本`）交给 `Process.arguments`，
/// 全程没有 shell 字符串。这里的校验只保证“参数是字面量形态”——ASCII 字母、
/// 数字与 `@ / . _ - + ~ = :`，因此不可能出现空白、引号、`;`、`|`、`&`、`$`、
/// 反引号、`(`、`)`、`>`、`<`、`*`、`?`、`!`、换行等 shell 元字符；`sudo` 与
/// shell 解释器名也被显式拒绝。名字保留 `Policy`，但语义就是“形状白名单”。
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
    ///
    /// PATH 合并本身复用 `ToolPathBuilder`（GitHub #89）：`base` 里的 PATH 通常
    /// 已经来自应用级工具 PATH 构建器（登录 shell PATH、已知目录、node 目录），
    /// 这里只保证“npm 自己所在目录优先”与已知目录兜底——只增路径，不增变量。
    static func environment(base: [String: String], npmExecutablePath: String) -> [String: String] {
        var result = sanitized(base)
        let builder = ToolPathBuilder(
            appEnvironment: result,
            homeDirectory: result["HOME"] ?? ""
        )
        result["PATH"] = builder.path(prioritizing: [
            (npmExecutablePath as NSString).deletingLastPathComponent
        ])
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
        // npm 必须是绝对路径（与 CLI 更新计划同一套校验）：相对路径会依赖子进程的
        // 工作目录，既不可复现也无法在日志里定位（W2A A-7）。
        guard PiCLIUpdatePlan.isSafeExecutablePath(npmExecutablePath) else { return nil }
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
    /// 同一组件未清除的「已放弃」记录（GitHub #62）。有值时**不允许自动执行**
    /// （推迟到下次启动），手动入口仍然可用但必须在确认框里先看到这条记录。
    /// 默认 nil，旧调用点保持不变。
    var abandonedAttempt: UpdateAbandonedAttempt? = nil
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
        // 硬前置（GitHub #62 / alpha.3 安全审查 A-6、A-7）：同一组件存在未清除的
        // 「已放弃」记录时一律不自动执行，推迟到下次启动。这条判定不受其它前置
        // 条件影响，也不允许被绕过；手动入口单独经 `manualPlan` 走。
        if let attempt = input.abandonedAttempt {
            return .manualOnly(commandText: commandText, reason: .abandonedAttemptPending(attempt))
        }
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

    /// 手动入口的安装计划：只要求“已验证的 npm 全局安装 + 合法包名 + 可执行位确认
    /// 过的 npm + 可解析且更新的目标版本”。**不看**「已放弃」记录、不看设置位、
    /// 不看检查结果来源：确认框会把记录与计划一起展示给用户，由用户显式确认。
    ///
    /// 这里不构造命令文本之外的任何东西：argv 仍然是静态的 `install -g <包名>@<版本>`。
    static func manualPlan(
        installation: ComponentInstallation?,
        targetVersion: String?,
        npmExecutablePath: String?,
        baseEnvironment: [String: String]
    ) -> PiWebUpdateInstallPlan? {
        guard let installation, installation.kind == .piWeb else { return nil }
        guard installation.source == .npmGlobal, installation.confidence == .verified else { return nil }
        guard let installedVersion = installation.version,
              let installed = SemanticVersion(installedVersion) else { return nil }
        guard let packageName = safePackageName(installation.packageName) else { return nil }
        guard let npmExecutablePath, !npmExecutablePath.isEmpty else { return nil }
        // 目标版本必须是可解析、严格更高的语义化版本：手动入口不做“无目标版本”
        // 的宽泛重装（否则会把包钉在某个版本上）。
        guard let targetVersion,
              let target = SemanticVersion(targetVersion),
              target.description == targetVersion,
              installed < target else { return nil }
        return PiWebUpdateInstallPlan.make(
            packageName: packageName,
            installedVersion: installedVersion,
            targetVersion: targetVersion,
            npmExecutablePath: npmExecutablePath,
            baseEnvironment: baseEnvironment,
            source: installation.source,
            confidence: installation.confidence
        )
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
    /// 本次调用被整体拒绝：已经有一次安装正在进行，未启动第二个子进程（W2A A-2）。
    case alreadyRunning

    var text: String {
        switch self {
        case .launchFailed: return "无法启动安装进程"
        case .timedOut: return "安装超时"
        case .cancelled: return "安装被取消"
        case .nonZeroExit: return "安装命令以非零退出码结束"
        case .alreadyRunning: return "已有安装正在进行"
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
    /// 本次调用因为已有安装正在进行而被拒绝：没有启动任何子进程（W2A A-2）。
    var alreadyRunning: Bool
    var startedAt: Date
    var finishedAt: Date
    var outputTail: String?
    /// 停止等待时对本次子进程实际做了什么（超时/取消才非 nil）：用于记录「已放弃」
    /// 状态与日志，让人知道“超时”不等于“进程已经结束”。
    var childProcessAction: UpdateAbandonedAttempt.ChildProcessAction?

    init(
        exitCode: Int32?,
        timedOut: Bool = false,
        cancelled: Bool = false,
        launchFailed: Bool = false,
        alreadyRunning: Bool = false,
        startedAt: Date,
        finishedAt: Date,
        outputTail: String? = nil,
        childProcessAction: UpdateAbandonedAttempt.ChildProcessAction? = nil
    ) {
        self.exitCode = exitCode
        self.timedOut = timedOut
        self.cancelled = cancelled
        self.launchFailed = launchFailed
        self.alreadyRunning = alreadyRunning
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.outputTail = outputTail
        self.childProcessAction = childProcessAction
    }

    /// nil 表示执行成功（退出码 0 且未超时/取消）。超时与取消优先于退出码。
    var failure: PiWebUpdateInstallFailure? {
        if alreadyRunning { return .alreadyRunning }
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
    /// 取消进行中的安装（若还有）。取消按失败处理：只终止**本次启动的**子进程组
    /// （至多一次，尽力而为），绝不触碰任何 Pi 进程。
    func cancel()
    /// 是否有安装正在进行（供 UI 门控）。同一实现同一时间最多执行一次安装；
    /// 重叠调用会被拒绝并回调 `PiWebUpdateInstallFailure.alreadyRunning`。
    var isRunning: Bool { get }
}

// MARK: - 子进程启动（独立进程组）

/// 一次 Pi Web 安装子进程的启动规格。只有可执行文件、argv 与（已白名单化的）
/// 环境；没有 shell 字符串、没有工作目录、没有额外继承的 fd。
struct PiWebChildProcessSpecification: Equatable {
    var executablePath: String
    var arguments: [String]
    var environment: [String: String]
}

/// 启动后的子进程句柄。
///
/// `processGroupIdentifier` 只有在 `usesOwnProcessGroup == true` 时才可信：那时
/// 子进程是**它自己的新进程组**的组长（组 id = 子进程 pid）。降级启动
/// （无法设置进程组属性）时子进程留在应用自己的进程组里，句柄标记 false，超时
/// **不得**发送任何信号（否则会波及应用自己与其它进程）。
struct PiWebChildProcessHandle: Equatable {
    var processIdentifier: pid_t
    var processGroupIdentifier: pid_t
    var usesOwnProcessGroup: Bool
    /// 子进程 stdout + stderr 的读端描述符；-1 表示没有可读输出（测试替身）。
    var outputDescriptor: Int32
}

/// 启动/等待/读取/终止子进程的注入点。
///
/// 生产实现是 `POSIXPiWebUpdateChildSpawner`。测试注入替身来断言：
/// 1. `spawn` 的规格（argv 与环境）；
/// 2. 启动属性确实要求“新建独立进程组”（见 `PiWebUpdateSpawnPolicy`）；
/// 3. 超时/取消时**只出现一次** `terminateOwnProcessGroup` 调用，且参数是本次
///    子进程 pid / 进程组，绝不会是任何 Pi 进程或其它 pid。
protocol PiWebUpdateChildSpawning: AnyObject {
    func spawn(_ specification: PiWebChildProcessSpecification) throws -> PiWebChildProcessHandle
    /// 阻塞等待子进程结束并回收；返回退出码（-1 表示无法确定）。
    func waitForExit(_ handle: PiWebChildProcessHandle) -> Int32
    /// 只对本次启动、且已确认在它自己新进程组里的子进程组发送一次终止信号
    /// （`SIGTERM`，尽力而为）。返回是否真的发出了信号；降级句柄一律返回 false，
    /// 不调用任何信号 API。
    func terminateOwnProcessGroup(_ handle: PiWebChildProcessHandle) -> Bool
}

/// `posix_spawn` 启动属性的唯一来源：让本次子进程成为**新的独立进程组**的组长。
///
/// 语义：`POSIX_SPAWN_SETPGROUP` + `pgroup = 0` ⇒ 子进程的进程组 id 等于它自己的
/// pid，因此后续信号只可能落在这一个组上。顺序是先 `setpgroup` 再 `setflags`：
/// 任一步失败都保证 `SETPGROUP` 标志不存在，子进程不会进入一个组 id 未定义的
/// 进程组（降级为普通启动，句柄标记 `usesOwnProcessGroup == false`）。
enum PiWebUpdateSpawnPolicy {
    /// 传给 `posix_spawnattr_setpgroup` 的值：0 = 新建进程组，组 id = 子进程 pid。
    static let newProcessGroup: pid_t = 0
    /// 完整属性：独立进程组 + 其余 fd 默认 close-on-exec（只保留文件动作显式
    /// 重定向的 0/1/2）。
    static var flags: Int16 {
        Int16(POSIX_SPAWN_SETPGROUP) | Int16(POSIX_SPAWN_CLOEXEC_DEFAULT)
    }
    /// 降级属性：没有独立进程组，但 fd 卫生保持不变。
    static var degradedFlags: Int16 {
        Int16(POSIX_SPAWN_CLOEXEC_DEFAULT)
    }

    /// 把“新独立进程组”写进属性；成功返回 true。失败时属性保持未设置状态。
    @discardableResult
    static func apply(to attributes: inout posix_spawnattr_t?) -> Bool {
        guard posix_spawnattr_setpgroup(&attributes, newProcessGroup) == 0 else { return false }
        return posix_spawnattr_setflags(&attributes, flags) == 0
    }
}

/// 启动路径的失败原因。错误描述里只有 errno 与系统文案，不含路径或凭据。
enum PiWebUpdateSpawnError: LocalizedError, Equatable {
    case fileActionsUnavailable(Int32)
    case attributesUnavailable(Int32)
    case standardDescriptorsUnavailable(Int32)
    case spawnFailed(Int32)

    var errorDescription: String? {
        let reason: String
        let code: Int32
        switch self {
        case .fileActionsUnavailable(let value):
            reason = "无法准备文件重定向"
            code = value
        case .attributesUnavailable(let value):
            reason = "无法设置启动属性"
            code = value
        case .standardDescriptorsUnavailable(let value):
            reason = "无法重定向标准输入输出"
            code = value
        case .spawnFailed(let value):
            reason = "启动安装进程失败"
            code = value
        }
        return "\(reason)（errno \(code)：\(String(cString: strerror(code)))）"
    }
}

/// 生产启动器：`posix_spawn` + 参数数组 + 白名单环境 + 新独立进程组。
///
/// 只做四件事：启动一个子进程、回收它、返回它的输出读端、以及（仅在超时/取消时）
/// 对它**自己的**进程组发送一次 `SIGTERM`。没有 shell、没有 `sudo`、没有 `Process`
/// 对象，也没有对任何其它 pid / 进程组的信号调用。
final class POSIXPiWebUpdateChildSpawner: PiWebUpdateChildSpawning {
    func spawn(_ specification: PiWebChildProcessSpecification) throws -> PiWebChildProcessHandle {
        var fileActions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        var status = posix_spawn_file_actions_init(&fileActions)
        guard status == 0 else { throw PiWebUpdateSpawnError.fileActionsUnavailable(status) }
        defer { posix_spawn_file_actions_destroy(&fileActions) }
        status = posix_spawnattr_init(&attributes)
        guard status == 0 else { throw PiWebUpdateSpawnError.attributesUnavailable(status) }
        defer { posix_spawnattr_destroy(&attributes) }

        // 独立进程组（尽力而为）。失败时按现状降级：照常启动，但句柄标记 false，
        // 超时只放弃等待、绝不发送信号。
        let usesOwnProcessGroup = PiWebUpdateSpawnPolicy.apply(to: &attributes)
        if !usesOwnProcessGroup {
            status = posix_spawnattr_setflags(&attributes, PiWebUpdateSpawnPolicy.degradedFlags)
            guard status == 0 else { throw PiWebUpdateSpawnError.attributesUnavailable(status) }
        }

        // stdin 为 /dev/null；stdout/stderr 合并进一个管道，父进程读有界尾部。
        // 所有临时 fd 都由本函数显式管理：`ownedDescriptor` 把 0-2 的 fd 复制到
        // stderr 之上并关掉原件，因此“谁负责关闭”在每个分支上都唯一。
        let rawNullDevice = open("/dev/null", O_RDONLY)
        guard rawNullDevice >= 0 else {
            throw PiWebUpdateSpawnError.standardDescriptorsUnavailable(errno)
        }
        guard let nullDevice = Self.ownedDescriptor(rawNullDevice) else {
            throw PiWebUpdateSpawnError.standardDescriptorsUnavailable(errno)
        }
        defer { close(nullDevice) }

        var rawPipe: [Int32] = [-1, -1]
        guard pipe(&rawPipe) == 0 else {
            throw PiWebUpdateSpawnError.standardDescriptorsUnavailable(errno)
        }
        guard let readDescriptor = Self.ownedDescriptor(rawPipe[0]) else {
            close(rawPipe[1])
            throw PiWebUpdateSpawnError.standardDescriptorsUnavailable(errno)
        }
        guard let writeDescriptor = Self.ownedDescriptor(rawPipe[1]) else {
            close(readDescriptor)
            throw PiWebUpdateSpawnError.standardDescriptorsUnavailable(errno)
        }

        status = posix_spawn_file_actions_adddup2(&fileActions, nullDevice, STDIN_FILENO)
        guard status == 0 else {
            close(readDescriptor)
            close(writeDescriptor)
            throw PiWebUpdateSpawnError.standardDescriptorsUnavailable(status)
        }
        status = posix_spawn_file_actions_adddup2(&fileActions, writeDescriptor, STDOUT_FILENO)
        guard status == 0 else {
            close(readDescriptor)
            close(writeDescriptor)
            throw PiWebUpdateSpawnError.standardDescriptorsUnavailable(status)
        }
        status = posix_spawn_file_actions_adddup2(&fileActions, writeDescriptor, STDERR_FILENO)
        guard status == 0 else {
            close(readDescriptor)
            close(writeDescriptor)
            throw PiWebUpdateSpawnError.standardDescriptorsUnavailable(status)
        }
        // 管道写端与 /dev/null 只在子进程里以 0/1/2 的形式存在：把临时 fd 显式
        // 关掉，子进程不会多继承任何描述符（外层的 close 只关父进程这一侧）。
        status = posix_spawn_file_actions_addclose(&fileActions, writeDescriptor)
        guard status == 0 else {
            close(readDescriptor)
            close(writeDescriptor)
            throw PiWebUpdateSpawnError.standardDescriptorsUnavailable(status)
        }
        if nullDevice != STDIN_FILENO {
            status = posix_spawn_file_actions_addclose(&fileActions, nullDevice)
            guard status == 0 else {
                close(readDescriptor)
                close(writeDescriptor)
                throw PiWebUpdateSpawnError.standardDescriptorsUnavailable(status)
            }
        }

        var arguments = try Self.duplicateCStrings([specification.executablePath] + specification.arguments)
        defer { Self.freeCStrings(arguments) }
        var environment = try Self.duplicateCStrings(
            specification.environment.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
        )
        defer { Self.freeCStrings(environment) }

        var pid: pid_t = 0
        status = posix_spawn(&pid, specification.executablePath, &fileActions, &attributes, &arguments, &environment)
        guard status == 0, pid > 1 else {
            close(readDescriptor)
            close(writeDescriptor)
            throw PiWebUpdateSpawnError.spawnFailed(status == 0 ? ECHILD : status)
        }
        // 父进程这一侧立刻关掉写端：只有子进程还持有时，读到 EOF 才表示它结束了。
        close(writeDescriptor)
        return PiWebChildProcessHandle(
            processIdentifier: pid,
            // 降级时组 id 不可信：写 0，任何发送信号的路径都会先拒绝它。
            processGroupIdentifier: usesOwnProcessGroup ? pid : 0,
            usesOwnProcessGroup: usesOwnProcessGroup,
            outputDescriptor: readDescriptor
        )
    }

    func waitForExit(_ handle: PiWebChildProcessHandle) -> Int32 {
        guard handle.processIdentifier > 1 else { return -1 }
        var status: Int32 = 0
        while waitpid(handle.processIdentifier, &status, 0) == -1 {
            guard errno == EINTR else { return -1 }
        }
        return Self.exitCode(fromWaitStatus: status)
    }

    func terminateOwnProcessGroup(_ handle: PiWebChildProcessHandle) -> Bool {
        // 硬边界：只有“本次启动、已确认处在它自己的新进程组里、组 id 等于子进程
        // pid”的句柄才会被送信号。降级句柄（共享应用进程组）一律不发信号，
        // 因此不可能波及应用自己、其它进程组或任何 Pi 进程。
        guard handle.usesOwnProcessGroup,
              handle.processGroupIdentifier == handle.processIdentifier,
              handle.processIdentifier > 1 else { return false }
        return killpg(handle.processGroupIdentifier, SIGTERM) == 0
    }

    /// `waitpid` 原始状态 → 退出码：正常退出取高 8 位，被信号终止取信号号
    /// （与 Foundation `Process.terminationStatus` 的取值一致）。
    static func exitCode(fromWaitStatus status: Int32) -> Int32 {
        if status & 0x7F == 0 { return (status >> 8) & 0xFF }
        return status & 0x7F
    }

    /// 保证返回的 fd 高于 stderr 且由调用方拥有；0-2 的输入先复制再关原件。
    private static func ownedDescriptor(_ descriptor: Int32) -> Int32? {
        guard descriptor >= 0 else { return nil }
        guard descriptor <= STDERR_FILENO else { return descriptor }
        let copy = fcntl(descriptor, F_DUPFD_CLOEXEC, STDERR_FILENO + 1)
        close(descriptor)
        return copy > STDERR_FILENO ? copy : nil
    }

    /// NULL 结尾的 C 字符串数组；分配失败抛错而不是静默截断。
    private static func duplicateCStrings(_ strings: [String]) throws -> [UnsafeMutablePointer<CChar>?] {
        var result: [UnsafeMutablePointer<CChar>?] = []
        result.reserveCapacity(strings.count + 1)
        for string in strings {
            guard let duplicated = strdup(string) else {
                freeCStrings(result)
                throw PiWebUpdateSpawnError.spawnFailed(ENOMEM)
            }
            result.append(duplicated)
        }
        result.append(nil)
        return result
    }

    private static func freeCStrings(_ strings: [UnsafeMutablePointer<CChar>?]) {
        for pointer in strings { free(pointer) }
    }
}

/// 生产安装器：`posix_spawn` + 参数数组，没有 shell、没有 `sudo`。
///
/// - 可执行文件、参数数组、环境都来自 `PiWebUpdateInstallPlan`；
/// - 子进程是一个**新的独立进程组**（组 id = 子进程 pid），npm 自己派生的子进程
///   因此也在这个组里；
/// - stdin 为 `/dev/null`，stdout/stderr 合并进一个管道并只保留有界末尾片段；
/// - 超时/取消只对**本次启动的**子进程组发送一次终止信号（尽力而为），随后按
///   失败结束，并写一条「已放弃」记录（结束时间未知、派生进程是否结束未确认）；
/// - 无法建立独立进程组时降级为“只放弃等待 + 记录未确认”，不发送任何信号；
/// - 任何失败都只返回结果，不抛出、不崩溃。
final class ProcessPiWebUpdateInstaller: PiWebUpdateInstalling {
    /// 保留的子进程输出上限（字符）。
    static let outputTailLimit = 2000

    private let stateQueue = DispatchQueue(label: "io.github.su-luoya.pi-web-desktop.pi-web-update-installer")
    private let waitQueue = DispatchQueue.global(qos: .utility)
    private let clock: () -> Date
    private let spawner: PiWebUpdateChildSpawning
    private let redact: (String) -> String
    private let recordAbandonedAttempt: (UpdateAbandonedAttempt) -> Void

    /// 结果投递队列：`completion` 不在 `stateQueue` 上执行，回调里的长耗时工作
    /// （例如重新检测版本）就不会把 `cancel()` 排在后面（W2A A-5）。
    private let deliveryQueue = DispatchQueue.global(qos: .userInitiated)

    /// 当前正在执行的安装；nil 表示空闲。每次 install 新建一份，后来者不能
    /// 覆盖它（W2A A-1/A-2）。只在 stateQueue 上访问。
    private var attempt: Attempt?
    /// 已放弃等待、但仍在排空管道的读端：保持打开直到子进程退出，子进程后续
    /// 写 stdout/stderr 不会收到 SIGPIPE / EPIPE（W2A A-3）。只在 stateQueue
    /// 上访问。
    private var drainingHandles: [ObjectIdentifier: FileHandle] = [:]

    /// 已放弃等待、但还不能确认已经退出的子进程数量：放弃等待时只对**自己的**
    /// 进程组尽力终止一次，降级路径不发送任何信号；只要它大于 0 就不允许开始
    /// 新的安装（上一次的 npm 可能还在跑，W2A A-2）。只在 stateQueue 上访问。
    private var abandonedChildrenInFlight = 0

    /// 一次 install 调用的全部可变状态。每次调用独立一份：重叠调用不会再覆盖
    /// 上一次的 handle / 回调 / 定时器（W2A A-1/A-2）。
    private final class Attempt {
        let plan: PiWebUpdateInstallPlan
        let timeout: TimeInterval
        let completion: (PiWebUpdateInstallResult) -> Void
        let startedAt: Date
        var handle: PiWebChildProcessHandle?
        var outputHandle: FileHandle?
        var timer: DispatchSourceTimer?
        var timedOut = false
        var cancelled = false
        var outputTail = ""
        /// 本次子进程是否已经发送过终止信号（至多一次）。
        var didSignalOwnProcessGroup = false
        var childProcessAction: UpdateAbandonedAttempt.ChildProcessAction?
        /// 已经放弃等待、但退出尚未确认（计入 `abandonedChildrenInFlight`）。
        var abandonedUnconfirmed = false

        init(
            plan: PiWebUpdateInstallPlan,
            timeout: TimeInterval,
            completion: @escaping (PiWebUpdateInstallResult) -> Void,
            startedAt: Date
        ) {
            self.plan = plan
            self.timeout = timeout
            self.completion = completion
            self.startedAt = startedAt
        }
    }

    /// 是否有安装正在进行（供 UI 门控）。已经放弃等待、但子进程退出还没确认时
    /// 也算「进行中」：这段时间里不会再启动第二次安装。
    var isRunning: Bool {
        stateQueue.sync { attempt != nil || abandonedChildrenInFlight > 0 }
    }

    init(
        clock: @escaping () -> Date = { Date() },
        spawner: PiWebUpdateChildSpawning = POSIXPiWebUpdateChildSpawner(),
        redact: @escaping (String) -> String = { LogRedactor().redact($0) },
        recordAbandonedAttempt: @escaping (UpdateAbandonedAttempt) -> Void = { _ in }
    ) {
        self.clock = clock
        self.spawner = spawner
        self.redact = redact
        self.recordAbandonedAttempt = recordAbandonedAttempt
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
            guard let self, let attempt = self.attempt else { return }
            attempt.cancelled = true
            self.stopWaitingLocked(attempt, reason: .abandonedWaiting)
            self.finishLocked(attempt, exitCode: nil)
        }
    }

    // MARK: - 内部（全部在 stateQueue 上执行）

    private func startLocked(
        _ plan: PiWebUpdateInstallPlan,
        timeout: TimeInterval,
        completion: @escaping (PiWebUpdateInstallResult) -> Void
    ) {
        let startedAt = clock()
        // 重叠 install：整体拒绝这一次调用——不启动第二个子进程，也不覆盖正在跑
        // 的那份状态（W2A A-2）；拒绝同样要有终态回调，否则调用方永远等不到结果
        // （W2A A-1）。上一次安装彻底结束（子进程退出已确认）后可以再次安装。
        guard attempt == nil, abandonedChildrenInFlight == 0 else {
            deliver(
                PiWebUpdateInstallResult(
                    exitCode: nil,
                    alreadyRunning: true,
                    startedAt: startedAt,
                    finishedAt: startedAt
                ),
                to: completion
            )
            return
        }

        let attempt = Attempt(
            plan: plan,
            timeout: timeout,
            completion: completion,
            startedAt: startedAt
        )
        self.attempt = attempt

        let specification = PiWebChildProcessSpecification(
            executablePath: plan.npmExecutablePath,
            arguments: plan.arguments,
            environment: plan.environment
        )
        let handle: PiWebChildProcessHandle
        do {
            handle = try spawner.spawn(specification)
        } catch {
            finishLocked(attempt, exitCode: nil, launchFailed: true)
            return
        }
        attempt.handle = handle

        if handle.outputDescriptor > STDERR_FILENO {
            let outputHandle = FileHandle(fileDescriptor: handle.outputDescriptor, closeOnDealloc: true)
            outputHandle.readabilityHandler = { [weak self, weak attempt] fileHandle in
                let data = fileHandle.availableData
                if data.isEmpty {
                    fileHandle.readabilityHandler = nil
                    return
                }
                guard let attempt else { return }
                self?.appendOutput(data, to: attempt)
            }
            attempt.outputHandle = outputHandle
        }

        waitQueue.async { [weak self] in
            let exitCode = self?.spawner.waitForExit(handle) ?? -1
            self?.stateQueue.async {
                self?.childExitedLocked(attempt, exitCode: exitCode)
            }
        }
        scheduleTimeoutLocked(attempt)
    }

    private func scheduleTimeoutLocked(_ attempt: Attempt) {
        let timer = DispatchSource.makeTimerSource(queue: stateQueue)
        timer.schedule(deadline: .now() + max(0.05, attempt.timeout))
        timer.setEventHandler { [weak self, weak attempt] in
            // 只有这一次尝试仍是当前尝试时才收尾：已结束或已被后来调用替换的旧
            // 定时器不会再去动别人的子进程组（W2A A-2）。
            guard let self, let attempt, self.attempt === attempt else { return }
            attempt.timedOut = true
            self.stopWaitingLocked(attempt, reason: .timedOut)
            self.finishLocked(attempt, exitCode: nil)
        }
        timer.resume()
        attempt.timer = timer
    }

    /// 停止等待：只对本次启动的子进程组发送**一次**终止信号（尽力而为），并记录
    /// “已终止子进程组 / 未确认派生进程是否结束”（降级时记录“没有发送任何信号”）。
    private func stopWaitingLocked(_ attempt: Attempt, reason: UpdateAbandonedAttempt.Reason) {
        // 放弃等待不等于子进程已经退出（信号是尽力而为、降级路径一个信号也不发）：
        // 在它的退出通知到达之前把这次尝试记为「不确定」，期间拒绝新的安装。
        if !attempt.abandonedUnconfirmed {
            attempt.abandonedUnconfirmed = true
            abandonedChildrenInFlight += 1
        }
        let action = terminateOwnProcessGroupLocked(attempt)
        attempt.childProcessAction = action
        recordAbandonedAttemptLocked(attempt, reason: reason, action: action)
    }

    private func terminateOwnProcessGroupLocked(_ attempt: Attempt) -> UpdateAbandonedAttempt.ChildProcessAction {
        guard let handle = attempt.handle else { return .processGroupUnavailable }
        // 只发送一次：取消之后又触发超时、或反过来，都不会出现第二次信号。
        guard !attempt.didSignalOwnProcessGroup else { return .terminatedOwnProcessGroup }
        guard handle.usesOwnProcessGroup,
              handle.processGroupIdentifier == handle.processIdentifier,
              handle.processIdentifier > 1 else {
            // 降级路径：子进程在共享进程组里，发信号会波及别人，因此不发送。
            return .processGroupUnavailable
        }
        attempt.didSignalOwnProcessGroup = true
        return spawner.terminateOwnProcessGroup(handle)
            ? .terminatedOwnProcessGroup
            : .processGroupUnavailable
    }

    /// 写一条「已放弃」记录：组件、脱敏命令摘要、开始时间、超时值、结束时间未知
    /// （`finishedAt == nil`）、来源与本次实际动作。
    private func recordAbandonedAttemptLocked(
        _ attempt: Attempt,
        reason: UpdateAbandonedAttempt.Reason,
        action: UpdateAbandonedAttempt.ChildProcessAction
    ) {
        let plan = attempt.plan
        let finishedAt = clock()
        let record = UpdateAbandonedAttempt(
            componentKind: .piWeb,
            packageName: nil,
            reason: reason,
            commandSummary: UpdateAbandonedAttempt.makeCommandSummary(
                executablePath: plan.npmExecutablePath,
                arguments: plan.arguments,
                redactingWith: redact
            ),
            startedAt: attempt.startedAt,
            timeout: attempt.timeout,
            finishedAt: nil,
            source: plan.source,
            recordedAt: finishedAt,
            childProcessAction: action,
            derivedProcessesConfirmedEnded: nil
        )
        recordAbandonedAttempt(record)
    }

    private func childExitedLocked(_ attempt: Attempt, exitCode: Int32) {
        // 退出确认要结清「不确定」计数：晚到的退出通知同样要清账。
        settleAbandonedChildLocked(attempt)
        guard self.attempt === attempt else { return }
        finishLocked(attempt, exitCode: exitCode)
    }

    /// 子进程退出已确认：从「不确定」集合里摘掉（若它曾被放弃等待）。
    private func settleAbandonedChildLocked(_ attempt: Attempt) {
        guard attempt.abandonedUnconfirmed else { return }
        attempt.abandonedUnconfirmed = false
        abandonedChildrenInFlight = max(0, abandonedChildrenInFlight - 1)
    }

    private func appendOutput(_ data: Data, to attempt: Attempt) {
        // lossy 解码：不再因为一个分块不是完整 UTF-8 就整块丢弃（W2A A-6）。
        let text = String(decoding: data, as: UTF8.self)
        guard !text.isEmpty else { return }
        stateQueue.async { [weak self, weak attempt] in
            guard let self, let attempt, self.attempt === attempt else { return }
            attempt.outputTail += text
            if attempt.outputTail.count > Self.outputTailLimit {
                attempt.outputTail = String(attempt.outputTail.suffix(Self.outputTailLimit))
            }
        }
    }

    private func finishLocked(_ attempt: Attempt, exitCode: Int32?, launchFailed: Bool = false) {
        // 只有当前这次尝试能收尾：已经被拒绝、已经被后来调用替换的尝试不会写结果。
        guard self.attempt === attempt else { return }
        attempt.timer?.cancel()
        attempt.timer = nil
        self.attempt = nil
        // 放弃等待不关闭读端：把管道交给排空逻辑读到 EOF，子进程继续跑时写
        // stdout/stderr 不会收到 SIGPIPE / EPIPE（W2A A-3）。
        if let outputHandle = attempt.outputHandle {
            attempt.outputHandle = nil
            drainOutput(outputHandle)
        }
        let finishedAt = clock()
        let result = PiWebUpdateInstallResult(
            exitCode: exitCode,
            timedOut: attempt.timedOut,
            cancelled: attempt.cancelled,
            launchFailed: launchFailed,
            startedAt: attempt.startedAt,
            finishedAt: finishedAt,
            outputTail: attempt.outputTail.isEmpty ? nil : attempt.outputTail,
            childProcessAction: attempt.childProcessAction
        )
        deliver(result, to: attempt.completion)
    }

    /// 在 stateQueue 之外投递结果：回调里的长耗时工作（例如重新检测版本）不能
    /// 占住 installer 的串行队列，否则应用退出时的 `cancel()` 会被排在它后面
    /// （W2A A-5）。
    private func deliver(
        _ result: PiWebUpdateInstallResult,
        to completion: @escaping (PiWebUpdateInstallResult) -> Void
    ) {
        deliveryQueue.async { completion(result) }
    }

    /// 摘掉业务回调后**保持读端打开**，把剩余输出一路读到 EOF 再释放。这样被放弃
    /// 等待的子进程在下一次写 stdout/stderr 时不会因为读端已关而死亡（W2A A-3）。
    private func drainOutput(_ outputHandle: FileHandle) {
        let key = ObjectIdentifier(outputHandle)
        drainingHandles[key] = outputHandle
        outputHandle.readabilityHandler = { [weak self] fileHandle in
            guard fileHandle.availableData.isEmpty else { return }
            fileHandle.readabilityHandler = nil
            self?.stateQueue.async { [weak self] in
                self?.drainingHandles[key] = nil
            }
        }
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
        /// 该组件成功完成一次更新后清除它的「已放弃」记录（GitHub #62）。
        /// 默认什么都不做（旧调用点保持不变）。
        var clearAbandonedAttempt: (UpdateTransactionComponent) -> Void

        init(
            installer: PiWebUpdateInstalling,
            detectInstallation: @escaping () -> ComponentInstallation?,
            startServiceAndCheckHealth: @escaping (@escaping (Bool) -> Void) -> Void,
            redactor: LogRedactor,
            log: @escaping (String) -> Void,
            deliver: @escaping (@escaping () -> Void) -> Void,
            timeout: TimeInterval = PiWebUpdateCoordinator.defaultTimeout,
            transaction: UpdateTransactionEnvironment = .disabled,
            clearAbandonedAttempt: @escaping (UpdateTransactionComponent) -> Void = { _ in }
        ) {
            self.installer = installer
            self.detectInstallation = detectInstallation
            self.startServiceAndCheckHealth = startServiceAndCheckHealth
            self.redactor = redactor
            self.log = log
            self.deliver = deliver
            self.timeout = timeout
            self.transaction = transaction
            self.clearAbandonedAttempt = clearAbandonedAttempt
        }
    }

    /// 默认安装超时：5 分钟。有界，应用启动不会因为安装无上限地卡住。
    static let defaultTimeout: TimeInterval = 300

    /// 是否有一次安装正在进行（供 UI 门控：手动入口与菜单项）。
    var isUpdateInProgress: Bool { environment.installer.isRunning }

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

    /// 手动路径：用户已经在确认框里看到计划、「已放弃」记录（如果有）与风险说明
    /// 并显式确认，因此这里不再做自动判定，直接执行安装；执行结果同样重新检测
    /// 版本并进入同一份更新历史。
    func runManual(
        _ plan: PiWebUpdateInstallPlan,
        completion: @escaping (PiWebUpdateRunOutcome) -> Void
    ) {
        environment.log(environment.redactor.redact(
            "Pi Web 手动更新：已确认执行\n"
                + plan.displayLines(redactingWith: environment.redactor).joined(separator: "\n")
        ))
        runInstall(plan: plan, installation: nil, completion: completion)
    }

    private func runInstall(
        plan: PiWebUpdateInstallPlan,
        installation: ComponentInstallation?,
        completion: @escaping (PiWebUpdateRunOutcome) -> Void
    ) {
        // 同一时间只允许一次安装（W2A A-2/A-4）：已经有一次在跑时直接按「跳过」
        // 返回，给出可见文案，而不是排队等第二次回调。
        guard !environment.installer.isRunning else {
            environment.log("Pi Web 更新跳过：\(PiWebUpdateRefusal.updateAlreadyInProgress.text)")
            environment.deliver {
                completion(.skipped(reason: .updateAlreadyInProgress, commandText: nil))
            }
            return
        }
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
            // 与安装器的门控竞争失败：这一次没有启动子进程，不写失败历史。
            if result.failure == .alreadyRunning {
                self.logOutcome("Pi Web 更新跳过（\(PiWebUpdateRefusal.updateAlreadyInProgress.text)）。")
                self.environment.deliver {
                    completion(.skipped(reason: .updateAlreadyInProgress, commandText: nil))
                }
                return
            }
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
                    + (result.childProcessAction.map { "本次实际动作：\($0.text)。" } ?? "")
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
                    // 该组件成功完成了一次更新：清除它的「已放弃」记录（GitHub #62）。
                    self.environment.clearAbandonedAttempt(component)
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
