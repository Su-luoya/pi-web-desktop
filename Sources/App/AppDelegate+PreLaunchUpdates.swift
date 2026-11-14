/// Restricted update checks that run before the workspace WebView is allowed to load.

import Cocoa

extension AppDelegate {
    // MARK: - 启动前受限自动更新（GitHub #20）

    /// 主窗口路由的启动尾部：启动服务（更新检查不再挡在启动路径上）。
    ///
    /// 默认**不等**网络：检查在服务起来之后跑完，结果只用于提示，并在发现可用
    /// 更新时记下「下次启动安装」。只有上一次运行留下那个标记时，这一次启动才按
    /// 原路径等一次检查并安装 Pi Web（`piWebUpdateDeferredPending`）。
    ///
    /// 任何更新失败路径都不会让应用无法启动：WebView 停在带持久告警的诊断状态
    /// 页、诊断窗口保留、服务不启动；也不会静默继续或声称回滚成功。
    func beginMainWindowLaunch(
        report: DependencyReport,
        launchIntent: ServiceLaunchIntent,
        firstLaunchSetupIncomplete: Bool,
        presentDiagnostics: Bool
    ) {
        serviceManager.setState(.checking)
        webViewController.showLoadingPage(message: "正在检查 Pi Web 服务…")
        let proceed = { [weak self] in
            guard let self else { return }
            if let warning = self.piWebUpdateWarning {
                self.presentPiWebUpdateWarningBanner(warning)
            }
            self.webViewController.showLoadingPage(message: "正在检查 Pi Web 服务…")
            self.serviceManager.startAtLaunch(forceStart: launchIntent.forcesStart)
            if presentDiagnostics {
                self.showDiagnostics(
                    report: report,
                    firstLaunchSetupIncomplete: firstLaunchSetupIncomplete,
                    canContinueToService: report.canStartService && self.workspaceValidation.isUsable
                )
            }
        }
        // 服务正在运行（例如用户重新检测）：不弹确认、不安装，只记录决策行。
        if serviceManager.managedServicePID() != nil {
            logPiWebUpdateDecision(PiWebUpdatePlanner.decide(piWebUpdatePlanningInput(report: report)))
            proceed()
            return
        }
        guard let updateChecker else {
            proceed()
            return
        }
        let installation = report.components.first { $0.kind == .piWeb }
        let eligible = PiWebUpdatePlanner.needsTargetVersionBeforeLaunch(
            preferences: updateChecker.preferences,
            installation: installation
        )
        guard eligible,
              !preLaunchUpdateAttemptedInThisRun,
              appConfiguration.piWebUpdateDeferredPending() else {
            // 这一次启动不等网络：先启动服务，检查在后台跑完（应用自己的启动检查和
            // 依赖检测完成后的复查已经覆盖 Pi Web，结果只用于提示与记录「下次启动
            // 安装」）。设置关闭或来源变了就顺手清掉可能过期的标记，免得之后某次启动
            // 白等一轮。
            if !eligible {
                appConfiguration.setPiWebUpdateDeferredPending(false)
            }
            logPiWebUpdateDecision(PiWebUpdatePlanner.decide(piWebUpdatePlanningInput(report: report)))
            proceed()
            return
        }
        // 上一次运行发现了可用更新：这一次启动按原路径等一次覆盖 Pi Web 的检查结果
        // 再决定是否安装（唯一会等网络的启动）；检查失败也只会跳过自动更新，不影响
        // 服务启动。
        preLaunchUpdateInProgress = true
        updateChecker.checkNow(
            triggeredBy: .launch,
            inventory: UpdateCheckInventory(components: report.components)
        ) { [weak self] in
            guard let self else { return }
            self.attemptPreLaunchPiWebUpdate(report: report, proceed: proceed)
        }
    }

    /// 根据已完成的检查结果执行或跳过启动前自动更新。
    private func attemptPreLaunchPiWebUpdate(report: DependencyReport, proceed: @escaping () -> Void) {
        // 这次启动就是来兑现标记的：先清掉，失败时由持久告警接替（不会每次启动重试）。
        appConfiguration.setPiWebUpdateDeferredPending(false)
        let input = piWebUpdatePlanningInput(report: report)
        let decision = PiWebUpdatePlanner.decide(input)
        logPiWebUpdateDecision(decision)
        guard case .automatic(let plan) = decision, let coordinator = piWebUpdateCoordinator else {
            preLaunchUpdateInProgress = false
            proceed()
            // 检查结果已经到达，只是不安装 Pi Web：把统一流程的自动更新判定补上。
            attemptAutomaticUpdatesAfterPreLaunch()
            return
        }
        piWebUpdateRedetectionPath = serviceManager.configuration.piWebPath
        preLaunchUpdateAttemptedInThisRun = true
        showPiWebUpdateProgressPage(plan: plan)
        coordinator.run(input) { [weak self] outcome in
            guard let self else { return }
            self.preLaunchUpdateInProgress = false
            switch outcome {
            case .succeeded(_, let oldVersion, let newVersion):
                self.clearPiWebUpdateWarning()
                self.logPiWebUpdate(
                    "启动前自动更新完成：\(oldVersion) → \(newVersion)。"
                )
                proceed()
            case .skipped(let reason, _):
                // `.skipped` 的 warning 为 nil，不能交给失败路径：那里会直接
                // return，把应用永久留在“正在更新”执行页（此时既没有成功、
                // 也没有任何提示），服务永不启动。跳过不是失败：记一行日志、
                // 给出可见说明，然后照常启动服务。
                self.logPiWebUpdate("启动前自动更新未执行：\(reason.text)")
                self.presentPreLaunchUpdateSkipped(reason: reason)
                proceed()
            default:
                self.presentPiWebUpdateFailure(outcome)
            }
            // Pi Web 的启动前流程结束了：现在补上因它而推迟的自动更新判定
            // （没有开启自动更新的组件不会执行任何命令）。
            self.attemptAutomaticUpdatesAfterPreLaunch()
        }
    }

    /// 决策输入：全部来自 #16 识别结果、#17/#18 检查结果与当前服务状态。
    /// npm 路径只由检测到的前缀与 PATH 解析，且必须通过可执行位确认。
    func piWebUpdatePlanningInput(
        report: DependencyReport?,
        serviceIsRunning: Bool? = nil
    ) -> PiWebUpdatePlanningInput {
        let installation = (report ?? dependencyReport)?.components.first { $0.kind == .piWeb }
        let piWebTarget = UpdateCheckTarget(category: .piWeb, packageName: nil)
        let result = updateChecker?.summary.result(for: piWebTarget.id)
        // 同一份工具 PATH（GitHub #89）：npm 解析与安装子进程都靠它找到 node。
        let environment = toolPathProvider.probeEnvironment()
        let npmPath = PiWebUpdateNPMResolver(environment: environment).resolve(installation: installation)
        return PiWebUpdatePlanningInput(
            preferences: updateChecker?.preferences ?? appConfiguration.updateCheckPreferences(),
            installation: installation,
            targetVersion: result?.latestVersion,
            targetStatus: result?.status ?? .unknown,
            targetConfidence: result?.confidence ?? .unknown,
            targetOrigin: result?.origin ?? .unavailable,
            targetCacheWrittenAt: result?.cacheWrittenAt,
            serviceIsRunning: serviceIsRunning ?? (serviceManager.managedServicePID() != nil),
            npmExecutablePath: npmPath,
            baseEnvironment: environment,
            abandonedAttempt: abandonedAttempt(for: .piWeb)
        )
    }

    /// 指定组件的未清除「已放弃」记录（GitHub #62）。三个组件互相独立：同组件
    /// 的记录只阻断同组件的自动路径。
    func abandonedAttempt(for component: UpdateTransactionComponent) -> UpdateAbandonedAttempt? {
        UpdateAbandonedAttemptGate.blockingAttempt(for: component, in: appConfiguration.abandonedAttempts())
    }

    /// 该组件成功完成一次更新后清除它的「已放弃」记录（GitHub #62）。
    func clearAbandonedAttempt(_ component: UpdateTransactionComponent) {
        guard appConfiguration.abandonedAttempts().contains(where: { $0.component == component }) else { return }
        appConfiguration.clearAbandonedAttempt(for: component)
        logUpdateAbandoned("已清除「已放弃」记录：\(component.displayName) 成功完成了一次更新。")
        refreshUpdateMenuState()
        diagnosticsWindowController?.refreshUpdateStatus()
        syncUpdateSettingsWindow()
    }
    private func logUpdateAbandoned(_ message: String) {
        _ = logWriter.append(logRedactor.redact(message))
    }

    /// 菜单“更新 → 更新记录…”（GitHub #62）：展示记录（组件、开始时间、超时
    /// 上限、结束时间未知、本次实际动作）并提供显式清除。清除只删除记录，不改动
    /// 任何已安装文件、也不结束任何进程。
    private func logPiWebUpdateDecision(_ decision: PiWebUpdateDecision) {
        logPiWebUpdate(decision.logLine(redactingWith: logRedactor))
    }

    private func logPiWebUpdate(_ message: String) {
        _ = logWriter.append(logRedactor.redact(message))
    }

    /// 启动前自动更新被拒绝（`.skipped`）时的可见说明。
    ///
    /// 与失败路径的区别：没有任何安装动作发生、也没有持久告警要记，但用户必须
    /// 能看到“为什么这次没有自动更新”，而不是一个沉默的加载页。提示只在真正
    /// 走向启动前更新的路径上出现，且不阻断服务启动。
    private func presentPreLaunchUpdateSkipped(reason: PiWebUpdateRefusal) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "本次启动没有自动更新 Pi Web"
        alert.informativeText = "原因：\(reason.text)。\n\n服务会照常启动；需要更新时可以用菜单「更新 → 检查更新…」。"
        alert.addButton(withTitle: "好")
        presentAlert(alert)
    }

    /// 失败路径：记录持久告警、进入诊断状态、保留可用 UI；不启动服务、不声称回滚。
    private func presentPiWebUpdateFailure(_ outcome: PiWebUpdateRunOutcome) {
        guard let warning = outcome.warning else {
            // 其余结果（含将来新增的 case）必须仍然让启动继续走完，否则会
            // 重现“停在执行页、服务永不启动”的卡死。
            logPiWebUpdate("启动前自动更新未产生告警：\(outcome)；继续启动服务。")
            return
        }
        piWebUpdateWarning = warning
        appConfiguration.savePiWebUpdateWarning(warning)
        logPiWebUpdate(warning.text)
        refreshUpdateMenuState()
        diagnosticsWindowController?.refreshUpdateStatus()

        serviceManager.stopHealthMonitor()
        serviceManager.setState(.stopped)
        let report = dependencyReport
        let diagnosticsText = report.map {
            DependencyReportPresenter.statusPageText(
                for: $0,
                setupIncomplete: !appConfiguration.hasCompletedFirstLaunchSetup
            )
        }
        let message = [warning.text, latestUpdateDegradationText(), diagnosticsText]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
        webViewController.showDependencyPage(title: "Pi Web 更新未完成", message: message)
        if let report {
            showDiagnostics(
                report: report,
                firstLaunchSetupIncomplete: !appConfiguration.hasCompletedFirstLaunchSetup,
                canContinueToService: false
            )
        }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Pi Web 更新未完成"
        alert.informativeText = [warning.text, latestUpdateDegradationText()]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
        alert.addButton(withTitle: "好")
        presentAlert(alert)
    }

    private func presentPiWebUpdateWarningBanner(_ warning: PiWebUpdateWarning) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Pi Web 上次更新未完成"
        alert.informativeText = warning.text
        alert.addButton(withTitle: "好")
        alert.addButton(withTitle: "清除警告")
        presentAlert(alert) { [weak self] response in
            // 只清除这条持久警告；不会改变 Pi Web 的版本，也不会重试安装。
            guard response == .alertSecondButtonReturn else { return }
            self?.clearPiWebUpdateWarning()
        }
    }

    /// 菜单里的持久警告项：展开完整告警文本，并提供“清除警告”。
    private func clearPiWebUpdateWarning() {
        guard piWebUpdateWarning != nil else { return }
        piWebUpdateWarning = nil
        appConfiguration.savePiWebUpdateWarning(nil)
        refreshUpdateMenuState()
        diagnosticsWindowController?.refreshUpdateStatus()
    }

    /// 启动服务并做健康检查（复用既有启动与探测路径）。回调 true 表示服务可用。
    func startServiceAndCheckHealthForUpdate(completion: @escaping (Bool) -> Void) {
        DispatchQueue.main.async { [weak self] in
            guard let self else {
                completion(false)
                return
            }
            guard self.dependencyGate == .ready else {
                completion(false)
                return
            }
            self.serviceManager.ensureServerIsRunning()
            self.pollServiceHealth(attemptsRemaining: 25, completion: completion)
        }
    }

    /// 有界的健康检查轮询（25 × 0.5 秒）。超时按“健康检查失败”处理，不无限等待。
    private func pollServiceHealth(attemptsRemaining: Int, completion: @escaping (Bool) -> Void) {
        serviceManager.checkServer { [weak self] ready in
            // 先固化强引用；拿不到时仍然要在主线程上把结果交回去。
            guard let self else {
                DispatchQueue.main.async { completion(ready) }
                return
            }
            DispatchQueue.main.async { [self] in
                if ready {
                    completion(true)
                    return
                }
                guard attemptsRemaining > 0 else {
                    completion(false)
                    return
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                    self?.pollServiceHealth(attemptsRemaining: attemptsRemaining - 1, completion: completion)
                }
            }
        }
    }

    /// 共享更新事务（GitHub #23）的展示辅助：最近一次更新的降级结果。
    /// 只读历史，不重新执行任何动作。
    func latestUpdateDegradationText() -> String? {
        guard let entry = appConfiguration.updateHistory().first,
              let kind = entry.degradationKind else { return nil }
        let detail = entry.rollbackDescription ?? ""
        return "降级结果：\(kind.displayName)。\(detail)"
    }

    /// 应用 Pi Web 的有限降级：只把服务与重检测指向更新前仍然可用的可执行文件，
    /// 不移动、不复制、不卸载任何文件，也不发送信号。
    func applyPiWebUpdateDegradation(_ plan: UpdateDegradationPlan) {
        guard plan.performedAutomaticDegradation, let restored = plan.restoredExecutablePath else { return }
        piWebUpdateRedetectionPath = restored
        var configuration = appConfiguration.serviceConfiguration
        configuration.piWebPath = restored
        appConfiguration.save(configuration)
        serviceManager.updateConfiguration(configuration)
        logPiWebUpdate("更新降级（GitHub #23/#63）：已把 Pi Web 服务指向更新前记录的路径（"
            + (plan.evidence?.summaryText ?? "证据等级未知")
            + "）；不移动、不复制、不卸载任何文件。")
    }

    /// 应用 Pi CLI 的有限降级：只把后续版本重检测指向更新前的可执行文件。
    func applyPiCLIUpdateDegradation(_ plan: UpdateDegradationPlan) {
        guard plan.performedAutomaticDegradation, let restored = plan.restoredExecutablePath else { return }
        piCLIUpdateRedetectionPath = restored
        logPiCLIUpdate("更新降级（GitHub #23/#63）：已把 Pi CLI 重检测指向更新前记录的路径（"
            + (plan.evidence?.summaryText ?? "证据等级未知")
            + "）；不移动、不复制、不卸载任何文件。")
    }

    /// 统一更新流程里的 Pi Web 一步：先停托管服务（走既有所有权验证的停止路径），
    /// 再安装。外部启动的服务不会被停止；如果服务仍在响应就取消这一步。
    func performManualPiWebUpdate(
        plan: PiWebUpdateInstallPlan,
        completion: @escaping (String, Bool) -> Void
    ) {
        // 确认框是异步的：用户确认时上一次更新可能已经在跑（启动前自动更新，或
        // 已经进入重检测/启动/健康检查的尾段），这里再检一次，避免重叠安装。
        let webEntry = piWebUpdateEntryState
        guard !webEntry.isBlocked else {
            completion("Pi Web 未执行：\(webEntry.rejectionDetail)", false)
            return
        }
        logPiWebUpdate("统一更新：先停止托管服务，再执行安装（只使用参数数组）。")
        serviceManager.stopService { [weak self] in
            guard let self else { return }
            // 外层已经在 `stopService` 闭包里固化了强引用，内层不再重新 `weak`:
            // 在并发闭包里读 weak 捕获变量属于 #SendableClosureCaptures。
            self.serviceManager.checkServer { ready in
                DispatchQueue.main.async {
                    guard !ready else {
                        completion(
                            "Pi Web 未执行：服务仍在响应（可能是外部启动的服务）",
                            false
                        )
                        return
                    }
                    self.runPiWebUpdate(plan: plan, completion: completion)
                }
            }
        }
    }

    private func runPiWebUpdate(
        plan: PiWebUpdateInstallPlan,
        completion: @escaping (String, Bool) -> Void
    ) {
        guard let coordinator = piWebUpdateCoordinator else {
            completion("Pi Web 未执行：更新器尚未就绪", false)
            return
        }
        piWebUpdateRedetectionPath = serviceManager.configuration.piWebPath
        showPiWebUpdateProgressPage(plan: plan)
        // 手动路径不再重跑自动判定（否则「已放弃」记录会把已确认的执行挡回去）。
        coordinator.runManual(plan) { [weak self] outcome in
            guard let self else { return }
            if case .succeeded(_, let oldVersion, let newVersion) = outcome {
                self.clearPiWebUpdateWarning()
                self.logPiWebUpdate("手动更新完成：\(oldVersion) → \(newVersion)。")
            } else {
                self.logPiWebUpdate("Pi Web 更新结果：\(UpdateFlowRun.piWebLine(outcome).0)")
            }
            let line = UpdateFlowRun.piWebLine(outcome)
            completion(line.0, line.1)
        }
    }

    /// 更新执行页：在真正执行前展示同一个计划（可执行文件路径已把 Home 段换成
    /// `~`、参数数组逐项、当前/目标版本、来源与可信度、环境变量键名），保证用户
    /// 在安装开始前能看到将要执行什么。
    private func showPiWebUpdateProgressPage(plan: PiWebUpdateInstallPlan) {
        var lines = plan.displayLines(redactingWith: logRedactor)
        lines.append("")
        lines.append("正在执行安装；更新期间请不要退出应用（安装有超时限制）。")
        webViewController.showDependencyPage(
            title: "正在更新 Pi Web",
            message: lines.joined(separator: "\n")
        )
    }

}
