/// Pi CLI update planning plus environment and re-detection helpers.

import Foundation

/// 前置条件与命令构造的纯逻辑（GitHub #21 第 3 项）。
enum PiCLIUpdatePlanner {
    /// 手动入口展示的命令文本：`<pi 路径> update --self`。路径必须通过安全校验；
    /// 否则返回 nil（界面显示“没有可用的手动命令”）。
    static func manualCommandText(executablePath: String?) -> String? {
        guard let plan = PiCLIUpdatePlan.make(
            executablePath: executablePath,
            installedVersion: "0.0.0",
            targetVersion: nil,
            source: .unknown,
            confidence: .unknown
        ) else { return nil }
        return plan.commandText
    }

    /// 手动更新的计划：只要求 #16 已经解析出可执行文件并通过命令安全校验。
    /// 不要求来源可信度，也不看进程状态：确认框会把进程信息与风险一起展示给
    /// 用户，由用户显式确认。目标版本可以缺失。
    static func manualPlan(
        installation: ComponentInstallation?,
        targetVersion: String?
    ) -> PiCLIUpdatePlan? {
        guard let installation, installation.kind == .piCLI else { return nil }
        guard let installedVersion = installation.version else { return nil }
        return PiCLIUpdatePlan.make(
            executablePath: installation.executablePath,
            installedVersion: installedVersion,
            targetVersion: targetVersion.flatMap { SemanticVersion($0)?.description },
            source: installation.source,
            confidence: installation.confidence
        )
    }

    /// 决策。前置条件的顺序是“设置 → 安装信息 → 来源 → 目标版本 → 命令安全”，
    /// 最后才是进程保护：进程保护只会让已经就绪的更新**推迟**，不会掩盖上面
    /// 任何一条不满足的事实。
    static func decide(_ input: PiCLIUpdatePlanningInput) -> PiCLIUpdateDecision {
        let commandText = manualCommandText(executablePath: input.installation?.executablePath)
        guard input.preferences.autoUpdatePiBeforeLaunch else {
            return .manualOnly(commandText: commandText, reason: .settingDisabled)
        }
        guard let installation = input.installation, installation.kind == .piCLI else {
            return .unavailable(reason: .missingInstallation)
        }
        guard let executablePath = installation.executablePath, !executablePath.isEmpty else {
            return .unavailable(reason: .executableUnresolved)
        }
        guard installation.source.isPackageManagerManaged, installation.confidence == .verified else {
            return .manualOnly(
                commandText: commandText,
                reason: .sourceNotVerifiedPackageManager(
                    source: installation.source,
                    confidence: installation.confidence
                )
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
        guard let plan = PiCLIUpdatePlan.make(
            executablePath: executablePath,
            installedVersion: installedVersion,
            targetVersion: targetVersion,
            source: installation.source,
            confidence: installation.confidence
        ) else {
            return .unavailable(reason: .unsafeCommand)
        }
        // 「已放弃」记录硬前置（GitHub #62 / alpha.3 安全审查 A-6、A-7）：同一组件
        // 存在未清除的记录时不允许自动执行，推迟到下次启动。进程保护只在这一条
        // 满足之后才参与判定；手动入口单独经 `manualPlan` 走。
        if let attempt = input.abandonedAttempt {
            return .deferred(plan: plan, reason: .abandonedAttemptPending(attempt))
        }
        // 进程保护：唯一允许自动执行的情况是“确认没有任何 Pi 进程”。
        switch input.processes {
        case .noProcesses:
            return .automatic(plan)
        case .runningProcesses(let records):
            return .deferred(plan: plan, reason: .piRunning(records))
        case .unknown(let reason):
            return .deferred(plan: plan, reason: .processStateUnknown(reason))
        }
    }

    /// 重新检测的版本是否确认更新成功。
    ///
    /// 有目标版本时要求“达到或超过目标版本”；没有目标版本（手动路径）时只要
    /// 版本发生变化就算成功；版本不可解析一律算失败。
    static func updateVerified(detected: String?, old: String, target: String?) -> Bool {
        UpdateVerifier.versionReached(detected: detected, old: old, target: target)
    }

    /// 兼容旧调用名：重新检测的版本是否达到目标版本。
    static func versionReached(detected: String?, target: String) -> Bool {
        updateVerified(detected: detected, old: target, target: target)
    }
}

/// 子进程环境变量白名单：与 #20 的 npm 路径使用同一组允许键与兜底 PATH。
enum PiCLIUpdateEnvironment {
    static func environment(base: [String: String], executablePath: String) -> [String: String] {
        var result = PiWebUpdateEnvironment.sanitized(base)
        // PATH 合并复用 `ToolPathBuilder`（GitHub #89）：pi 自己所在目录排在最前，
        // 其余目录（登录 shell PATH、已知目录、node 目录、npm prefix/bin）由构建器
        // 给出；白名单与“只增路径、不增变量”的语义保持不变。
        let builder = ToolPathBuilder(
            appEnvironment: result,
            homeDirectory: result["HOME"] ?? ""
        )
        result["PATH"] = builder.path(prioritizing: [
            (executablePath as NSString).deletingLastPathComponent
        ])
        return result
    }

    /// 只用于展示/日志：按键排序的键名，不含值。
    static func keyDescription(_ environment: [String: String]) -> String {
        PiWebUpdateEnvironment.keyDescription(environment)
    }
}

// MARK: - 重新检测辅助

/// 执行后的聚焦版本重检测：复用 #16 识别器，只识别 Pi CLI 一个组件。
enum PiCLIUpdateRedetection {
    static func request(piPath: String?) -> ComponentInstallationDetector.ComponentDetectionRequest {
        var candidates: [String] = []
        if let piPath, !piPath.isEmpty {
            candidates.append(piPath)
        }
        candidates.append(contentsOf: [
            "/opt/homebrew/bin/pi",
            "/usr/local/bin/pi"
        ])
        return ComponentInstallationDetector.ComponentDetectionRequest(
            kind: .piCLI,
            packageName: InstallCommandManifest.piCLIPackageName,
            executableNames: ["pi"],
            candidates: candidates,
            knownVersion: nil,
            runsVersionCommand: true,
            isApplicationBundle: false,
            probesShellPath: true
        )
    }

    static func detect(
        piPath: String?,
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
        return detector.detect(request(piPath: piPath))
    }
}
