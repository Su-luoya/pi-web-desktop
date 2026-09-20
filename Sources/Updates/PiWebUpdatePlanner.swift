/// Pi Web update planning and npm version resolution.

import Darwin
import Foundation

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
            if PiWebUpdateNPMResolver.hasRelativePATHEntry(in: input.baseEnvironment["PATH"]) {
                return .unavailable(reason: .unsafeExecutablePath)
            }
            return .unavailable(reason: .npmExecutableUnresolved)
        }
        guard PiCLIUpdatePlan.isSafeExecutablePath(npmExecutablePath) else {
            return .unavailable(reason: .unsafeExecutablePath)
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
///
/// 信任模型（F3，GitHub #121）与 `PiCLIUpdatePlan.isSafeExecutablePath` 一致：
/// `PATH` 目录即信任边界，解析结果不固定位置、不校验签名；这里只保证用的是绝对路径、
/// 没有 `.`/`..` 与 shell 元字符，且确实带可执行位。
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

    /// 候选路径（按优先级）。只保留通过绝对路径安全校验的候选，不判存在性。
    func candidates(installation: ComponentInstallation?) -> [String] {
        var result: [String] = []
        func append(_ path: String) {
            guard PiCLIUpdatePlan.isSafeExecutablePath(path), !result.contains(path) else { return }
            result.append(path)
        }
        if let installation {
            for path in [installation.resolvedPath, installation.executablePath].compactMap({ $0 }) {
                for candidate in Self.prefixDerivedNPMPaths(from: path) {
                    append(candidate)
                }
            }
        }
        for directory in (environment["PATH"] ?? "").split(
            separator: ":",
            omittingEmptySubsequences: false
        ) {
            guard directory.hasPrefix("/") else { continue }
            append((String(directory) as NSString).appendingPathComponent("npm"))
        }
        return result
    }

    /// PATH 的空项与非 `/` 开头项都依赖当前工作目录，更新执行器明确拒绝。
    static func hasRelativePATHEntry(in path: String?) -> Bool {
        guard let path else { return false }
        return path.split(separator: ":", omittingEmptySubsequences: false).contains {
            !$0.hasPrefix("/")
        }
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
