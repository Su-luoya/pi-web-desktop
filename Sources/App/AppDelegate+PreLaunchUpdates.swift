/// Restricted update checks that run before the workspace WebView is allowed to load.

import Cocoa

extension AppDelegate {
    // MARK: - 启动前受限自动更新（GitHub #20）

    /// 主窗口路由的启动尾部：先处理待更新，再启动服务。
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
        guard !preLaunchUpdateAttemptedInThisRun,
              PiWebUpdatePlanner.needsTargetVersionBeforeLaunch(
            preferences: updateChecker.preferences,
            installation: installation
        ) else {
            // 设置关闭或来源不满足：记录一次决策行（为何不走启动前自动更新），
            // 然后照常启动服务。
            logPiWebUpdateDecision(PiWebUpdatePlanner.decide(piWebUpdatePlanningInput(report: report)))
            proceed()
            return
        }
        // 先等一次覆盖 Pi Web 的检查结果（仍然尊重每一类的开关），再根据
        // “是否有已验证的可用版本”决定是否安装；检查失败也只会跳过自动更新，
        // 不影响服务启动。
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
        let input = piWebUpdatePlanningInput(report: report)
        let decision = PiWebUpdatePlanner.decide(input)
        logPiWebUpdateDecision(decision)
        guard case .automatic(let plan) = decision, let coordinator = piWebUpdateCoordinator else {
            preLaunchUpdateInProgress = false
            proceed()
            // 检查结果已经到达，只是不安装 Pi Web：顺便判定一次 Pi CLI（GitHub #21）。
            attemptPiCLIAutomaticUpdateIfNeeded()
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
            default:
                self.presentPiWebUpdateFailure(outcome)
            }
            // Pi Web 的启动前流程结束了：现在可以把因它而跳过的 Pi CLI 判定补上
            // （设置关闭时这个调用会立即返回）。
            self.attemptPiCLIAutomaticUpdateIfNeeded()
        }
    }

    /// 决策输入：全部来自 #16 识别结果、#17/#18 检查结果与当前服务状态。
    /// npm 路径只由检测到的前缀与 PATH 解析，且必须通过可执行位确认。
    private func piWebUpdatePlanningInput(
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

    /// 菜单“已放弃的更新记录…”（GitHub #62）：展示记录（组件、开始时间、超时
    /// 上限、结束时间未知、本次实际动作）并提供显式清除。清除只删除记录，不改动
    /// 任何已安装文件、也不结束任何进程。
    @objc func showAbandonedUpdateAttempts(_ sender: Any?) {
        let attempts = appConfiguration.abandonedAttempts()
        let alert = NSAlert()
        alert.messageText = attempts.isEmpty ? "没有已放弃的更新记录" : "已放弃的更新记录"
        if attempts.isEmpty {
            alert.informativeText = "没有「已放弃」记录：最近没有超时或放弃等待的更新命令。"
        } else {
            alert.informativeText = updateAbandonedStatusBlockText()
                + "\n\n清除只删除记录，不改动任何已安装文件，也不会结束任何进程：应用绝不对 Pi 进程发送信号。"
        }
        alert.addButton(withTitle: "好")
        if !attempts.isEmpty {
            alert.addButton(withTitle: "清除全部记录")
        }
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertSecondButtonReturn else { return }
            self?.clearAllAbandonedAttempts()
        }
    }

    /// 用户显式清除全部「已放弃」记录。
    private func clearAllAbandonedAttempts() {
        guard !appConfiguration.abandonedAttempts().isEmpty else { return }
        appConfiguration.clearAllAbandonedAttempts()
        logUpdateAbandoned("已清除全部「已放弃」记录（用户显式清除）。")
        refreshUpdateMenuState()
        diagnosticsWindowController?.refreshUpdateStatus()
        syncUpdateSettingsWindow()
    }

    private func logPiWebUpdateDecision(_ decision: PiWebUpdateDecision) {
        logPiWebUpdate(decision.logLine(redactingWith: logRedactor))
    }

    private func logPiWebUpdate(_ message: String) {
        _ = logWriter.append(logRedactor.redact(message))
    }

    /// 失败路径：记录持久告警、进入诊断状态、保留可用 UI；不启动服务、不声称回滚。
    private func presentPiWebUpdateFailure(_ outcome: PiWebUpdateRunOutcome) {
        guard let warning = outcome.warning else { return }
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
        alert.beginSheetModal(for: window)
    }

    private func presentPiWebUpdateWarningBanner(_ warning: PiWebUpdateWarning) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Pi Web 上次更新未完成"
        alert.informativeText = warning.text
        alert.addButton(withTitle: "好")
        alert.addButton(withTitle: "清除警告")
        alert.beginSheetModal(for: window) { [weak self] response in
            // 只清除这条持久警告；不会改变 Pi Web 的版本，也不会重试安装。
            guard response == .alertSecondButtonReturn else { return }
            self?.clearPiWebUpdateWarning()
        }
    }

    /// 菜单里的持久警告项：展开完整告警文本，并提供“清除警告”。
    @objc func showPiWebUpdateWarning(_ sender: Any?) {
        guard let warning = piWebUpdateWarning else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = warning.shortText
        alert.informativeText = warning.text
            + "\n\nPi Web 仍保持更新前的版本；可以手动更新，或修好环境后重试。"
        alert.addButton(withTitle: "好")
        alert.addButton(withTitle: "清除警告")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertSecondButtonReturn else { return }
            self?.clearPiWebUpdateWarning()
        }
    }

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
            DispatchQueue.main.async {
                guard let self else {
                    completion(ready)
                    return
                }
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

    /// 手动“立即更新 Pi Web…”：必须先确认（说明需要停服），确认后先停服务
    /// （走既有所有权验证的停止路径）再安装。运行期间发现的更新不会自动安装。
    @objc func updatePiWebNow(_ sender: Any?) {
        // 更新进行中闸控（W2A A-4 + W3B F2/F3）：这是 A-1/A-2 的真实用户可达入口，
        // 必须拒绝重叠更新并给出可见反馈；闸控覆盖整轮事务（含安装之后的版本
        // 重检测与服务启动/健康检查），不再只看安装子进程；只看 Pi Web 自己。
        let webEntry = piWebUpdateEntryState
        guard !webEntry.isBlocked else {
            presentPiWebUpdateInfo("更新正在进行", detail: webEntry.rejectionDetail)
            return
        }
        guard dependencyGate == .ready, let report = dependencyReport else {
            presentPiWebUpdateInfo("环境检查尚未完成", detail: "请等待依赖诊断完成后再试。")
            return
        }
        var input = piWebUpdatePlanningInput(report: report)
        // 「已放弃」记录只挡住**自动**路径（GitHub #62）：手动入口仍然可用，但确认框
        // 必须先展示这条记录。其余前置条件（设置位、来源、检查结果来源等）保持不变。
        let abandoned = input.abandonedAttempt
        input.abandonedAttempt = nil
        let decision = PiWebUpdatePlanner.decide(input)
        guard case .automatic(let plan) = decision else {
            presentPiWebUpdateInfo("当前不能立即更新 Pi Web", detail: manualUpdateUnavailableText(decision))
            return
        }
        var detail = plan.confirmationText(redactingWith: logRedactor)
        if let abandoned {
            detail += "\n\n" + UpdateAbandonedAttemptPresenter.confirmationBlock(for: abandoned)
        }
        detail += "\n\n更新前会先停止本应用启动的 Pi Web 服务（需要短暂停服）；外部启动的服务不会被停止，"
            + "如果服务仍在运行，更新会被取消。应用不会调用 sudo。"
        let alert = NSAlert()
        alert.messageText = "立即更新 Pi Web"
        alert.informativeText = detail
        alert.addButton(withTitle: "停止服务并更新")
        alert.addButton(withTitle: "取消")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.performManualPiWebUpdate(plan: plan)
        }
    }

    private func performManualPiWebUpdate(plan: PiWebUpdateInstallPlan) {
        // 确认框是异步的：用户确认时上一次更新可能已经在跑（例如启动前自动更新，
        // 或已经进入重检测/启动/健康检查的尾段），这里再检一次，避免重叠安装
        // （W2A A-4 + W3B F2）。
        let webEntry = piWebUpdateEntryState
        guard !webEntry.isBlocked else {
            presentPiWebUpdateInfo("更新正在进行", detail: webEntry.rejectionDetail)
            return
        }
        logPiWebUpdate("手动立即更新 Pi Web：先停止托管服务，再执行安装（只使用参数数组）。")
        serviceManager.stopService { [weak self] in
            guard let self else { return }
            self.serviceManager.checkServer { [weak self] ready in
                DispatchQueue.main.async {
                    guard let self else { return }
                    guard !ready else {
                        self.presentPiWebUpdateInfo(
                            "已取消更新",
                            detail: "Pi Web 服务仍在响应（可能是外部启动的服务）。"
                                + "为避免在服务运行期间替换文件，已取消本次更新；应用不会停止外部服务。"
                        )
                        return
                    }
                    self.runManualPiWebUpdate(plan: plan)
                }
            }
        }
    }

    private func runManualPiWebUpdate(plan: PiWebUpdateInstallPlan) {
        guard let coordinator = piWebUpdateCoordinator else { return }
        piWebUpdateRedetectionPath = serviceManager.configuration.piWebPath
        showPiWebUpdateProgressPage(plan: plan)
        // 手动路径不再重跑自动判定（否则「已放弃」记录会把已确认的执行挡回去）。
        coordinator.runManual(plan) { [weak self] outcome in
            guard let self else { return }
            switch outcome {
            case .succeeded(_, let oldVersion, let newVersion):
                self.clearPiWebUpdateWarning()
                self.logPiWebUpdate("手动更新完成：\(oldVersion) → \(newVersion)。")
                self.presentPiWebUpdateInfo(
                    "Pi Web 已更新",
                    detail: "已更新到 \(newVersion)，服务健康检查通过。"
                )
            case .skipped(let reason, _):
                // 手动路径的拒绝必须看得见（W2A A-4）：确认框到真正执行之间可能已经
                // 有一次更新在跑，编排层的这一层拒绝不能只是记日志。
                self.logPiWebUpdate("手动更新未执行：\(reason.text)")
                self.presentPiWebUpdateInfo("Pi Web 更新未执行", detail: "原因：\(reason.text)")
            default:
                self.presentPiWebUpdateFailure(outcome)
            }
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

    private func presentPiWebUpdateInfo(_ title: String, detail: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.addButton(withTitle: "好")
        alert.beginSheetModal(for: window)
    }

    private func manualUpdateUnavailableText(_ decision: PiWebUpdateDecision) -> String {
        var text = "原因：\(decision.reason.text)。"
        if let command = decision.commandText {
            text += "\n\n可以手动执行以下命令（应用不会代为执行）：\n\(logRedactor.redact(command))"
        } else {
            text += "\n\n该来源没有适用的静态命令，请按来源文档更新。"
        }
        text += "\n\n自动更新只对已验证的 npm 全局安装生效；应用不承诺所有来源都能回滚。"
        return text
    }
}
