/// Pi extension package update flow: candidate discovery, selection and apply.

import Cocoa

extension AppDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        switch appConfiguration.smokeLaunchMode {
        case .startup:
            runSmokeLaunch()
            return
        case .diagnostics:
            runDiagnosticsSmokeLaunch()
            return
        case .none:
            break
        }
        try? FileManager.default.createDirectory(at: appConfiguration.supportURL, withIntermediateDirectories: true)
        guard acquireSingleInstanceLock() else {
            // 已经决定直接退出：不再弹退出确认（此时窗口尚未创建），也不停止任何服务。
            quitCoordinator.handle(.directQuitRequested)
            NSApp.terminate(nil)
            return
        }
        try? "\(ProcessInfo.processInfo.processIdentifier)\n".write(to: appConfiguration.appPIDURL, atomically: true, encoding: .utf8)
        NSApp.mainMenu = nil
        installQuitShortcuts()
        installScreenChangeObserver()
        installMainMenu()
        createWindow()
        installServiceManagerCallbacks()
        serviceManager.setState(.checking)
        webViewController.showLoadingPage(message: "正在检查运行环境…")
        refreshWorkspaceState()
        recordCurrentWorkspace()
        rebuildRecentWorkspacesMenu()
        // 更新检查立即开始：先把应用自身版本发出去；依赖检测完成后补齐
        // Pi / Pi Web / 扩展包版本（见 `startUpdateChecking`）。
        startUpdateChecking(with: UpdateCheckInventory(desktopAppVersion: ApplicationInstallationProbe.current.version))
        runDependencyCheck()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let directory = urls.first else { return }
        requestWorkspaceSwitch(to: directory)
    }

    // MARK: - Pi 扩展包更新（GitHub #22）

    /// 当前扩展包策略。策略只允许 关闭 / 检查并通知 / 询问后更新。
    private func piPackagePolicy() -> UpdateCheckPolicy {
        (updateChecker?.preferences ?? appConfiguration.updateCheckPreferences()).policy(for: .piPackages)
    }

    /// 规划输入：全部来自 #16 的检测结果、#17 的检查结果、策略与最近的进程检查。
    /// 不在这里发起任何检查：检查由 #17/#18 的策略调度负责（关闭时根本不调度）。
    private func piPackagePlanningInput() -> PiPackageUpdatePlanningInput {
        PiPackageUpdatePlanningInput(
            policy: piPackagePolicy(),
            packages: PiPackageCandidate.list(from: dependencyReport?.components ?? []),
            checks: PiPackageCheckOutcome.list(from: updateChecker?.summary.results ?? []),
            processes: piProcessInspection ?? .unknown(.enumerationFailed),
            piExecutablePath: dependencyReport?.components.first { $0.kind == .piCLI }?.executablePath,
            abandonedAttempts: appConfiguration.abandonedAttempts().filter { $0.componentKind == .piPackage }
        )
    }

    /// 菜单“查看 Pi 扩展包更新…”：按三种策略分别处理。
    ///
    /// - 关闭：不检查、不通知、不执行（也不枚举进程）；
    /// - 检查并通知：只展示可用更新与可复制的官方命令，不提供一键执行；
    /// - 询问后更新：逐包评估，全部通过前置条件且没有运行中的 Pi 进程时，
    ///   展示整批确认框（取消是默认按钮）；未确认则不执行、不改状态。
    @objc func showPiPackageUpdates(_ sender: Any?) {
        guard dependencyGate == .ready, dependencyReport != nil else {
            presentPiPackageInfo("Pi 扩展包更新", detail: "请等待依赖诊断完成后再试。")
            return
        }
        let policy = piPackagePolicy()
        guard let mapped = PiPackageUpdatePolicy(policy) else {
            presentPiPackageInfo(
                "Pi 扩展包更新",
                detail: PiPackageUpdateRefusal.policyUnsupported.text
            )
            return
        }
        guard mapped != .off else {
            // 关闭策略：不检查、不通知、不执行，也不枚举本机进程。
            piPackageUpdatePlanSet = .disabledForPolicyOff
            logPiPackageUpdate(PiPackageUpdateRefusalRecord(packageName: nil, reason: .policyOff).logLine)
            presentPiPackageInfo(
                "Pi 扩展包更新已关闭",
                detail: "当前策略是“关闭”：不检查、不通知、不执行。可以在“更新检查偏好设置…”里改成“检查并通知”或“询问后更新”。"
            )
            return
        }
        // 展示前刷新一次进程检查：只有决策需要它（关闭策略已经在上面返回）。
        _ = refreshPiProcessInspection()
        let planSet = PiPackageUpdatePlanner.decide(piPackagePlanningInput())
        piPackageUpdatePlanSet = planSet
        for line in planSet.logLines(redactingWith: logRedactor) {
            logPiPackageUpdate(line)
        }
        switch mapped {
        case .checkAndNotify:
            presentPiPackageNotices(planSet)
        case .askBeforeUpdate:
            presentPiPackageConfirmation(planSet)
        case .off:
            break
        }
        refreshUpdateMenuState()
        diagnosticsWindowController?.refreshUpdateStatus()
        syncUpdateSettingsWindow()
    }

    /// 检查并通知：只展示版本与可复制命令，不提供执行按钮。
    private func presentPiPackageNotices(_ planSet: PiPackageUpdatePlanSet) {
        var lines: [String] = ["当前策略是“检查并通知”：只提示可用更新，不提供一键执行。"]
        if planSet.packageCount == 0 {
            lines.append("没有检测到可检查的 Pi 扩展包（`pi list` 没有给出包名与版本，或尚未完成检测）。")
        }
        for notice in planSet.notices {
            lines.append("")
            lines.append(contentsOf: notice.displayLines(
                reasonText: PiPackageUpdateRefusal.policyNotifiesOnly.text
            ))
            if let command = notice.manualCommandText {
                lines.append("命令（应用不会执行）：\(logRedactor.redact(command))")
            }
        }
        for record in planSet.refusalRecords {
            lines.append("拒绝记录：\(record.logLine)")
        }
        let alert = NSAlert()
        alert.messageText = "Pi 扩展包可用更新"
        alert.informativeText = lines.joined(separator: "\n")
        alert.addButton(withTitle: "好")
        let commands = planSet.notices.compactMap(\.manualCommandText)
        if !commands.isEmpty {
            alert.addButton(withTitle: "复制命令")
        }
        alert.beginSheetModal(for: window) { response in
            guard response == .alertSecondButtonReturn, !commands.isEmpty else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(commands.joined(separator: "\n"), forType: .string)
        }
    }

    /// 询问后更新：有可执行计划（或需要先看「已放弃」记录的计划）时展示整批
    /// 确认框（取消为默认按钮）。
    private func presentPiPackageConfirmation(_ planSet: PiPackageUpdatePlanSet) {
        let plans = planSet.confirmationPlans
        guard !plans.isEmpty else {
            var lines: [String] = ["当前没有可以执行的扩展包更新。"]
            if planSet.packageCount == 0 {
                lines.append("没有检测到可检查的 Pi 扩展包（`pi list` 没有给出包名与版本，或尚未完成检测）。")
            }
            for notice in planSet.notices {
                lines.append("")
                lines.append(contentsOf: notice.displayLines(reasonText: planSet.decisions
                    .first { $0.packageName == notice.packageName }?.refusalReason?.text))
            }
            for record in planSet.refusalRecords {
                lines.append("拒绝记录：\(record.logLine)")
            }
            let alert = NSAlert()
            alert.messageText = "Pi 扩展包更新"
            alert.informativeText = lines.joined(separator: "\n")
            alert.addButton(withTitle: "好")
            let commands = planSet.notices.compactMap(\.manualCommandText)
            if !commands.isEmpty {
                alert.addButton(withTitle: "复制命令")
            }
            alert.beginSheetModal(for: window) { response in
                guard response == .alertSecondButtonReturn, !commands.isEmpty else { return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(commands.joined(separator: "\n"), forType: .string)
            }
            return
        }
        let inspection = piProcessInspection ?? .unknown(.enumerationFailed)
        // 「已放弃」记录（GitHub #62）：同一包的记录必须在确认框里先展示，确认后
        // 才执行一次；一个包的记录不影响同批其它包。
        let abandoned = planSet.abandonedAttempts.filter { attempt in
            plans.contains { $0.packageName == attempt.packageName }
        }
        if !abandoned.isEmpty {
            logPiPackageUpdate(
                "Pi 扩展包更新：\(abandoned.count) 个包存在未清除的「已放弃」记录，"
                    + "确认框会先展示记录；确认后只执行一次。"
            )
        }
        let alert = NSAlert()
        alert.messageText = plans.count == 1
            ? "确认更新 Pi 扩展包 \(plans[0].packageName)"
            : "确认更新 \(plans.count) 个 Pi 扩展包"
        alert.informativeText = PiPackageUpdateConfirmation.text(
            plans: plans,
            inspection: inspection,
            abandonedAttempts: abandoned,
            redactingWith: logRedactor
        )
        // 取消是第一个按钮 = 默认按钮：回车即取消，不执行、不改状态。
        alert.addButton(withTitle: "取消")
        alert.addButton(withTitle: "确认更新")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            guard response == .alertSecondButtonReturn else {
                self.piPackageUpdateCoordinator?.recordCancellation(plans)
                self.piPackageUpdatePlanSet = planSet
                self.logPiPackageUpdate("Pi 扩展包更新：用户未确认（取消），未执行、未改动任何状态。")
                self.refreshUpdateMenuState()
                self.diagnosticsWindowController?.refreshUpdateStatus()
                return
            }
            self.performPiPackageUpdates(plans)
        }
    }

    /// 用户确认后才执行：参数数组执行一次，记录退出码与耗时，并重新检测版本。
    private func performPiPackageUpdates(_ plans: [PiPackageUpdatePlan]) {
        guard let coordinator = piPackageUpdateCoordinator, !piPackageUpdateInProgress else { return }
        piPackageUpdateInProgress = true
        logPiPackageUpdate("Pi 扩展包更新：用户已确认 \(plans.count) 个计划，命令为 \(plans.map { $0.arguments.joined(separator: " ") }.joined(separator: "、"))。")
        coordinator.runConfirmed(plans) { [weak self] batch in
            guard let self else { return }
            self.piPackageUpdateInProgress = false
            self.handlePiPackageUpdateOutcome(batch)
        }
    }

    private func handlePiPackageUpdateOutcome(_ batch: PiPackageUpdateBatchOutcome) {
        for line in batch.logLines(redactingWith: logRedactor) {
            logPiPackageUpdate(line)
        }
        if batch.isSucceeded {
            clearPiPackageUpdateWarning()
            let details = batch.outcomes.compactMap { outcome -> String? in
                guard case .succeeded(let plan, let newVersion, let record) = outcome else { return nil }
                return "\(plan.packageName)：\(plan.installedVersion) → \(newVersion)（退出码 "
                    + "\(record.exitCode.map(String.init) ?? "未知")，耗时 \(record.durationText)）"
            }
            presentPiPackageInfo("Pi 扩展包更新完成", detail: details.joined(separator: "\n"))
        } else {
            recordPiPackageUpdateWarning(batch.latestWarning)
            let details = batch.outcomes.map { $0.logLine(redactingWith: logRedactor) }
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Pi 扩展包更新未完成"
            alert.informativeText = (details + [batch.latestWarning?.text ?? "", latestUpdateDegradationText() ?? ""])
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
            alert.addButton(withTitle: "好")
            alert.beginSheetModal(for: window)
        }
        piPackageUpdatePlanSet = nil
        refreshUpdateMenuState()
        diagnosticsWindowController?.refreshUpdateStatus()
        syncUpdateSettingsWindow()
    }

    private func recordPiPackageUpdateWarning(_ warning: PiPackageUpdateWarning?) {
        guard let warning else { return }
        piPackageUpdateWarning = warning
        appConfiguration.savePiPackageUpdateWarning(warning)
        logPiPackageUpdate(warning.text)
    }

    private func clearPiPackageUpdateWarning() {
        guard piPackageUpdateWarning != nil else { return }
        piPackageUpdateWarning = nil
        appConfiguration.savePiPackageUpdateWarning(nil)
        refreshUpdateMenuState()
        diagnosticsWindowController?.refreshUpdateStatus()
    }

    /// 菜单里的持久告警项：展开完整告警文本，并提供“清除警告”。
    @objc func showPiPackageUpdateWarning(_ sender: Any?) {
        guard let warning = piPackageUpdateWarning else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = warning.shortText
        alert.informativeText = warning.text
            + "\n\n可以重新打开“查看 Pi 扩展包更新…”确认后重试；应用不会自动重试、也不会回滚。"
        alert.addButton(withTitle: "好")
        alert.addButton(withTitle: "清除警告")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertSecondButtonReturn else { return }
            self?.clearPiPackageUpdateWarning()
        }
    }

    private func presentPiPackageInfo(_ title: String, detail: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.addButton(withTitle: "好")
        alert.beginSheetModal(for: window)
    }

    private func logPiPackageUpdate(_ message: String) {
        _ = logWriter.append(logRedactor.redact(message))
    }

    /// 诊断页/设置页的扩展包更新状态块（已脱敏）。smoke 启动返回空串：不为诊断
    /// fixture 枚举真实进程。
    func piPackageStatusBlockText() -> String {
        guard !appConfiguration.isSmokeLaunch else { return "" }
        return PiPackageUpdateStatusPresenter.lines(
            policy: piPackagePolicy(),
            planSet: piPackageUpdatePlanSet,
            inspection: piProcessInspection,
            warning: piPackageUpdateWarning
        ).joined(separator: "\n")
    }
}
