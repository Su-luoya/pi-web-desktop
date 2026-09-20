import Darwin
import Foundation

/// 管道分块的增量 UTF-8 解码器。只暂存“合法多字节序列但字节尚未收齐”的尾部；
/// 真正非法的字节仍按 Swift 的 lossy 语义立即替换，EOF 时也会冲刷未完成尾部。

/// Incremental UTF-8 decoding plus the Pi Web install/plan value models.

struct IncrementalUTF8Decoder {
    private var pending = Data()

    mutating func decode(_ data: Data, final: Bool = false) -> String {
        var combined = pending
        combined.append(data)
        pending.removeAll(keepingCapacity: true)

        if !final {
            let count = Self.incompleteSuffixLength(in: combined)
            if count > 0 {
                pending = combined.suffix(count)
                combined.removeLast(count)
            }
        }
        return String(decoding: combined, as: UTF8.self)
    }

    private static func incompleteSuffixLength(in data: Data) -> Int {
        guard !data.isEmpty else { return 0 }
        let bytes = [UInt8](data)
        var continuationCount = 0
        var index = bytes.count - 1
        while continuationCount < 3, bytes[index] & 0xC0 == 0x80 {
            continuationCount += 1
            guard index > 0 else { return 0 }
            index -= 1
        }

        let expectedCount: Int
        switch bytes[index] {
        case 0xC2...0xDF: expectedCount = 2
        case 0xE0...0xEF: expectedCount = 3
        case 0xF0...0xF4: expectedCount = 4
        default: return 0
        }
        let availableCount = bytes.count - index
        return availableCount < expectedCount ? availableCount : 0
    }
}

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

// MARK: - 更新入口闸控状态（W3B F2/F3）

/// 一个组件更新入口（菜单项与手动更新动作）的闸控状态（W3B F2/F3）。每个组件
/// 一份，互不影响：Pi Web 的卡住的子进程不得禁用 Pi CLI 的入口，反之亦然；
/// 被挡住时带可见原因，不能静默置灰。
///
/// 定在这里而不是 `Sources/PiWebApp.swift` 的原因：本文件同时属于
/// PiWebDesktop 与 PiWebDesktopTests 两个 target；`PiWebApp.swift` 不在测试
/// target 的源文件清单里，放在那里会让测试 target 编译时报
/// “cannot find 'UpdateEntryState' in scope”。
struct UpdateEntryState: Equatable {
    /// 一次更新事务正在进行中：安装/命令执行、版本重检测、服务启动与健康检查
    /// 都算（不再只看安装子进程，W3B F2）。
    var transactionInProgress: Bool
    /// 上一次更新的子进程已经放弃等待，但退出尚未确认：保守起见先不启动第二次
    /// 更新（这种窗口只能靠重启应用可靠恢复，W3B F3）。
    var awaitingAbandonedChildExit: Bool

    static let free = UpdateEntryState(transactionInProgress: false, awaitingAbandonedChildExit: false)

    /// 由一个组件**自己**的三个状态合成入口闸控（W3B F3：构建时不会看到另一个
    /// 组件的状态，因此不可能跨组件误伤）。
    static func component(
        transactionInProgress: Bool,
        childInFlight: Bool,
        abandonedChildrenUnconfirmed: Bool
    ) -> UpdateEntryState {
        UpdateEntryState(
            transactionInProgress: transactionInProgress || (childInFlight && !abandonedChildrenUnconfirmed),
            awaitingAbandonedChildExit: abandonedChildrenUnconfirmed
        )
    }

    var isBlocked: Bool { transactionInProgress || awaitingAbandonedChildExit }

    /// 菜单标题后缀：被挡住时给出可见原因（W3B F3：不得静默置灰）。
    var menuTitleSuffix: String? {
        guard isBlocked else { return nil }
        return awaitingAbandonedChildExit
            ? "（上一次更新未确认退出，重启应用可恢复）"
            : "（正在更新）"
    }

    /// 入口被拒时的可见说明（含可恢复路径，W3B F3）。
    var rejectionDetail: String {
        if awaitingAbandonedChildExit {
            return "上一次更新命令已放弃等待，但还不能确认它已经退出，因此不会启动第二次更新。"
                + "如果长时间没有变化，重启应用即可恢复（重启后这个未确认窗口不会保留）。"
        }
        return "上一次更新尚未结束（可能正在重新检测版本、启动服务或做健康检查），请等它完成后再试。"
    }
}

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
    /// npm 可执行文件路径不是绝对安全路径；PATH 的相对项不会参与解析。
    case unsafeExecutablePath
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
        case .unsafeExecutablePath:
            return "npm 可执行文件路径不是绝对安全路径；PATH 中的相对项不会用于更新"
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
