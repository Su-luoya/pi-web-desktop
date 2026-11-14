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
            reportSingleInstanceRefusalIfEnvironmental()
            quitCoordinator.handle(.directQuitRequested)
            NSApp.terminate(nil)
            return
        }
        if (try? "\(ProcessInfo.processInfo.processIdentifier)\n".write(to: appConfiguration.appPIDURL, atomically: true, encoding: .utf8)) != nil {
            // 记录归本进程所有：退出时才允许删除（见 `ownsPIDRecord`）。
            ownsPIDRecord = true
        }
        NSApp.mainMenu = nil
        installQuitShortcuts()
        installScreenChangeObserver()
        installMainMenu()
        createWindow()
        installServiceManagerCallbacks()
        // 远程访问对账：上次异常退出留下的记录在这里收尾（serve 里那条已经不在
        // 就丢弃记录，否则恢复成「已开启」）。不阻塞启动，结果只影响菜单文案。
        remoteAccessController.refresh(configuration: serviceManager.configuration)
        serviceManager.setState(.checking)
        webViewController.showLoadingPage(message: "正在检查运行环境…")
        refreshWorkspaceState()
        // 更新检查立即开始：先把应用自身版本发出去；依赖检测完成后补齐
        // Pi / Pi Web / 扩展包版本（见 `startUpdateChecking`）。
        startUpdateChecking(with: UpdateCheckInventory(desktopAppVersion: ApplicationInstallationProbe.current.version))
        // 环境门控（GitHub #169）：有可信缓存就立刻放行并跳过这屏等待，完整检查
        // 转入后台复查；没有缓存（或缓存不可信）时走原来的完整检查。
        runStartupDependencyCheck()
    }

    // MARK: - Pi 扩展包更新（GitHub #22）

    /// 当前扩展包策略。策略只允许 关闭 / 检查并通知 / 询问后更新。
    private func piPackagePolicy() -> UpdateCheckPolicy {
        (updateChecker?.preferences ?? appConfiguration.updateCheckPreferences()).policy(for: .piPackages)
    }

    /// 规划输入：全部来自 #16 的检测结果、#17 的检查结果、策略与最近的进程检查。
    /// 不在这里发起任何检查：检查由 #17/#18 的策略调度负责（关闭时根本不调度）。
    func piPackagePlanningInput() -> PiPackageUpdatePlanningInput {
        PiPackageUpdatePlanningInput(
            policy: piPackagePolicy(),
            packages: PiPackageCandidate.list(from: dependencyReport?.components ?? []),
            checks: PiPackageCheckOutcome.list(from: updateChecker?.summary.results ?? []),
            piExecutablePath: dependencyReport?.components.first { $0.kind == .piCLI }?.executablePath,
            abandonedAttempts: appConfiguration.abandonedAttempts().filter { $0.componentKind == .piPackage }
        )
    }

    /// 统一更新流程里的扩展包一步：参数数组执行一次，记录退出码与耗时，并重新检测版本。
    func performPiPackageUpdates(
        _ plans: [PiPackageUpdatePlan],
        completion: @escaping (String, Bool) -> Void
    ) {
        guard let coordinator = piPackageUpdateCoordinator, !piPackageUpdateInProgress else {
            completion("Pi 扩展包未执行：更新正在进行或更新器尚未就绪", false)
            return
        }
        piPackageUpdateInProgress = true
        updateProgressCenter.beginBatch(components: plans.map { .piPackage($0.packageName) })
        updateProgressWindowController?.onCopyCommands = nil
        refreshUpdateMenuState()
        logPiPackageUpdate("Pi 扩展包更新：用户已确认 \(plans.count) 个计划，命令为 \(plans.map { $0.arguments.joined(separator: " ") }.joined(separator: "、"))。")
        coordinator.runConfirmed(plans) { [weak self] batch in
            guard let self else { return }
            self.piPackageUpdateInProgress = false
            self.handlePiPackageUpdateOutcome(batch)
            let line = UpdateFlowRun.piPackageLine(batch)
            completion(line.0, line.1)
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
            for detail in details { logPiPackageUpdate(detail) }
        } else {
            recordPiPackageUpdateWarning(batch.latestWarning)
            let details = batch.outcomes.map { $0.logLine(redactingWith: logRedactor) }
            logPiPackageUpdate((details + [batch.latestWarning?.text ?? "", latestUpdateDegradationText() ?? ""])
                .filter { !$0.isEmpty }.joined(separator: "\n"))
        }
        updateProgressCenter.finish(batch: batch)
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
    private func presentPiPackageInfo(_ title: String, detail: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.addButton(withTitle: "好")
        presentAlert(alert)
    }

    private func logPiPackageUpdate(_ message: String) {
        let redacted = logRedactor.redact(message)
        _ = logWriter.append(redacted)
        updateProgressCenter.appendLog(redacted)
    }

    /// 诊断页/设置页的扩展包更新状态块（已脱敏）。smoke 启动返回空串：不为诊断
    /// fixture 枚举真实进程。`compact` 为真时进程状态只报数量（设置页用）。
    func piPackageStatusBlockText(compact: Bool = false) -> String {
        guard !appConfiguration.isSmokeLaunch else { return "" }
        return PiPackageUpdateStatusPresenter.lines(
            policy: piPackagePolicy(),
            planSet: piPackageUpdatePlanSet,
            inspection: piProcessInspection,
            warning: piPackageUpdateWarning,
            compact: compact
        ).joined(separator: "\n")
    }
}
