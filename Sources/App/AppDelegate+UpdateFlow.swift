/// 统一更新流程：检查 → 一个确认框 → 按顺序真的执行 → 一条结果。
///
/// 过去的四套入口各自为政，其中「检查更新…」只弹一句“发现 N 项可用更新”。这里把
/// 四类组件的既有计划排成一个队列，一次问完、顺序执行、汇总结果。各组件的安全
/// 前置（可执行文件位置、包名、版本比较、参数数组）仍然由各自的 Planner 负责，
/// 这一层只做编排，不重复判定。

import Cocoa

/// 一次正在执行的统一更新（主线程独占）。
final class UpdateFlowRun {
    let plan: UpdateFlowPlan
    var index = 0
    var results: [String] = []
    var failures = 0

    init(plan: UpdateFlowPlan) {
        self.plan = plan
    }
}

extension AppDelegate {
    // MARK: - 计划

    /// 汇总四类组件的可执行更新。
    ///
    /// 全部使用各 Planner 的“手动”构造：手动路径不看自动更新开关、不看检查结果
    /// 是否来自本次网络结果——那些是自动路径的闸。用户点了「检查更新」并确认
    /// 「更新全部」，这就是明确授权；安全前置（绝对路径、包名白名单、参数数组、
    /// 版本严格更高）一条都没放松。
    func updateFlowPlan() -> UpdateFlowPlan {
        var entries: [UpdateFlowEntry] = []
        var skipped: [String] = []
        guard dependencyGate == .ready, dependencyReport != nil else {
            return UpdateFlowPlanner.plan(entries: [], skipped: ["环境检查尚未完成，请稍后再试"])
        }

        if let entry = piCLIUpdateFlowEntry() {
            entries.append(entry)
        } else if piCLICheckReportsUpdate() {
            skipped.append("Pi CLI：没有可用的目标版本或安装来源无法验证")
        }
        if let entry = piPackageUpdateFlowEntry() {
            entries.append(entry)
        }
        if let entry = piWebUpdateFlowEntry() {
            entries.append(entry)
        } else if piWebCheckReportsUpdate() {
            skipped.append("Pi Web：\(piWebFlowSkipReason())")
        }
        if let entry = desktopAppUpdateFlowEntry() {
            entries.append(entry)
        } else if desktopAppCheckReportsUpdate() {
            skipped.append("桌面应用：这次检查的版本没能核实，暂时不下载")
        }
        // 刚装上的版本在下次网络检查前仍会被旧结果列成“可更新”：这一轮不再重复
        // 列它，否则用户会看到同一个版本反复要求安装。
        entries.removeAll { entry in
            guard let version = entry.step.targetVersion else { return false }
            return installedUpdateFlowVersions[entry.component.checkCategory] == version
        }
        return UpdateFlowPlanner.plan(entries: entries, skipped: skipped)
    }

    private func piCLICheckReportsUpdate() -> Bool {
        updateChecker?.summary
            .result(for: UpdateCheckTarget(category: .piCLI, packageName: nil).id)?
            .status == .updateAvailable
    }

    private func piWebCheckReportsUpdate() -> Bool {
        updateChecker?.summary
            .result(for: UpdateCheckTarget(category: .piWeb, packageName: nil).id)?
            .status == .updateAvailable
    }

    private func desktopAppCheckReportsUpdate() -> Bool {
        updateChecker?.summary.result(for: UpdateCheckCategory.desktopApp.rawValue)?.status == .updateAvailable
    }

    private func piCLIUpdateFlowEntry() -> UpdateFlowEntry? {
        // 检查说没有更新就不进队列：`pi update --self` 在这种情况下只会回一句
        // “already up to date”，跑一遍除了多一条日志什么也改变不了。
        guard piCLICheckReportsUpdate() else { return nil }
        let installation = dependencyReport?.components.first { $0.kind == .piCLI }
        guard let plan = PiCLIUpdatePlanner.manualPlan(
            installation: installation,
            targetVersion: piCLIManualTargetVersion()
        ) else { return nil }
        let target = plan.targetVersion ?? "最新版本"
        return UpdateFlowEntry(
            component: .piCLI,
            summary: "Pi CLI \(plan.installedVersion) → \(target)",
            note: nil,
            step: .piCLI(plan)
        )
    }

    private func piPackageUpdateFlowEntry() -> UpdateFlowEntry? {
        let planSet = PiPackageUpdatePlanner.decide(piPackagePlanningInput())
        piPackageUpdatePlanSet = planSet
        let plans = planSet.confirmationPlans
        guard !plans.isEmpty else { return nil }
        let summaries = plans.map { "\($0.packageName) \($0.installedVersion) → \($0.targetVersion ?? "最新版本")" }
        return UpdateFlowEntry(
            component: .piPackages,
            summary: "Pi 扩展包 \(plans.count) 个：\(summaries.joined(separator: "、"))",
            note: "已运行的 Pi 会话需要重启后才使用新版本",
            step: .piPackages(plans)
        )
    }

    private func piWebUpdateFlowEntry() -> UpdateFlowEntry? {
        // 以检查结论为准：检查说已是最新时不再凭记录里的旧版本号排一条“更新”。
        guard piWebCheckReportsUpdate() else { return nil }
        guard let report = dependencyReport,
              let installation = report.components.first(where: { $0.kind == .piWeb }) else { return nil }
        let input = piWebUpdatePlanningInput(report: report, serviceIsRunning: false)
        let target = updateChecker?.summary
            .result(for: UpdateCheckTarget(category: .piWeb, packageName: nil).id)?
            .latestVersion
        guard let plan = PiWebUpdatePlanner.manualPlan(
            installation: installation,
            targetVersion: target,
            npmExecutablePath: input.npmExecutablePath,
            baseEnvironment: input.baseEnvironment
        ) else { return nil }
        return UpdateFlowEntry(
            component: .piWeb,
            summary: "Pi Web \(plan.installedVersion) → \(plan.targetVersion)",
            note: "需要短暂停止 Pi Web 服务",
            step: .piWeb(plan)
        )
    }

    private func desktopAppUpdateFlowEntry() -> UpdateFlowEntry? {
        guard let target = DesktopAppUpdateInstallPolicy.installTarget(
            for: updateChecker?.summary.result(for: UpdateCheckCategory.desktopApp.rawValue),
            runningVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        ) else { return nil }
        let running = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "当前版本"
        return UpdateFlowEntry(
            component: .desktopApp,
            summary: "桌面应用 \(running) → \(target.version)",
            note: "应用会退出并重新启动",
            step: .desktopApp(target)
        )
    }

    /// Pi Web 不能进计划的唯一原因：只保留一句人能看懂的话。
    private func piWebFlowSkipReason() -> String {
        let installation = dependencyReport?.components.first { $0.kind == .piWeb }
        guard let installation else { return "没有检测到 Pi Web 安装" }
        guard installation.source == .npmGlobal, installation.confidence == .verified else {
            return "安装来源不是已验证的 npm 全局安装（\(installation.source.displayName)）"
        }
        guard let version = installation.version, SemanticVersion(version) != nil else {
            return "没有可用的已安装版本"
        }
        guard piWebUpdatePlanningInput(report: dependencyReport).npmExecutablePath != nil else {
            return "找不到可用于安装的 npm"
        }
        return "没有可用的目标版本（检查结果里没有更新版本）"
    }

    // MARK: - 呈现

    /// 检查结果落地后的入口：手动检查一律给出可执行的对话框，自动检查只执行
    /// 用户已经明确开启自动更新的组件，不再弹“发现更新”的空提醒。
    func presentUpdateFlow(manual: Bool) {
        let plan = updateFlowPlan()
        if manual {
            presentManualUpdateFlow(plan)
        } else {
            presentAutomaticUpdateFlow(plan)
        }
    }

    private func presentManualUpdateFlow(_ plan: UpdateFlowPlan) {
        guard !plan.isEmpty else {
            presentUpdateFlowInfo(
                title: "没有可执行的更新",
                detail: UpdateFlowText.nothingToDoBody(skipped: plan.skipped)
            )
            return
        }
        presentUpdateReview(
            title: UpdateFlowText.title(for: plan),
            detail: UpdateFlowText.body(for: plan),
            confirm: { [weak self] in self?.executeUpdateFlow(plan) },
            cancel: { [weak self] in
                self?.logUpdateFlow("用户取消了这一轮更新，未执行任何命令。")
            }
        )
    }

    /// 自动检查：只执行「自动更新」开关打开（扩展包为“询问后更新”除外）的组件；
    /// 其余组件只更新状态行与设置窗口里的版本，不弹框。
    private func presentAutomaticUpdateFlow(_ plan: UpdateFlowPlan) {
        // 启动前 Pi Web 更新还在跑：两条安装同时进行会互相踩。它在结束时再补判定
        // （见 `attemptAutomaticUpdatesAfterPreLaunch`）。
        guard !preLaunchUpdateInProgress else { return }
        let preferences = updateChecker?.preferences ?? .factoryDefaults
        let automatic = plan.entries.filter { entry in
            switch entry.component {
            case .piCLI: return preferences.autoUpdatePiBeforeLaunch
            case .piWeb: return preferences.autoUpdatePiWebBeforeLaunch
            case .piPackages, .desktopApp: return false
            }
        }
        guard !automatic.isEmpty else { return }
        let autoPlan = UpdateFlowPlanner.plan(entries: automatic, skipped: plan.skipped)
        executeUpdateFlow(autoPlan)
    }

    /// 启动前 Pi Web 更新结束后补一次自动更新判定。
    func attemptAutomaticUpdatesAfterPreLaunch() {
        guard !preLaunchUpdateInProgress else { return }
        presentUpdateFlow(manual: false)
    }

    private func presentUpdateFlowInfo(title: String, detail: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.addButton(withTitle: "好")
        presentAlert(alert)
    }

    // MARK: - 执行

    func executeUpdateFlow(_ plan: UpdateFlowPlan) {
        guard !plan.isEmpty else { return }
        guard updateFlowRun == nil else {
            presentUpdateFlowInfo(title: "更新正在进行", detail: "请等这一轮更新结束后再试。")
            return
        }
        let run = UpdateFlowRun(plan: plan)
        updateFlowRun = run
        logUpdateFlow("开始统一更新：\(plan.entries.map(\.summary).joined(separator: "；"))。")
        refreshUpdateMenuState()
        advanceUpdateFlow()
    }

    private func advanceUpdateFlow() {
        guard let run = updateFlowRun else { return }
        guard run.index < run.plan.entries.count else {
            finishUpdateFlow(run)
            return
        }
        let entry = run.plan.entries[run.index]
        run.index += 1
        let installedVersion = entry.step.targetVersion
        let completion: (String, Bool) -> Void = { [weak self] line, succeeded in
            guard let self, self.updateFlowRun === run else { return }
            if succeeded, let installedVersion {
                self.installedUpdateFlowVersions[entry.component.checkCategory] = installedVersion
            }
            run.results.append(line)
            if !succeeded { run.failures += 1 }
            self.logUpdateFlow(line)
            self.advanceUpdateFlow()
        }
        switch entry.step {
        case .piCLI(let plan):
            performPiCLIManualUpdate(plan: plan, completion: completion)
        case .piPackages(let plans):
            performPiPackageUpdates(plans, completion: completion)
        case .piWeb(let plan):
            performManualPiWebUpdate(plan: plan, completion: completion)
        case .desktopApp(let target):
            // 安装成功会退出并重启应用：这一步不给 completion，失败会由
            // `failDesktopAppUpdateRound` 收尾并中止整轮流程。
            startDesktopAppUpdate(target: target)
        }
    }

    /// 某一步在启动前就被拒绝（例如同一组件已有一轮在跑）：记一行失败并收尾。
    /// 调用方自己已经弹过失败框时传 `presentAlert: false`，避免同一件事弹两次。
    func abortUpdateFlow(_ line: String, presentAlert: Bool = true) {
        guard let run = updateFlowRun else { return }
        run.results.append(line)
        run.failures += 1
        logUpdateFlow(line)
        finishUpdateFlow(run, presentAlert: presentAlert)
    }

    private func finishUpdateFlow(_ run: UpdateFlowRun, presentAlert: Bool = true) {
        updateFlowRun = nil
        refreshUpdateMenuState()
        syncUpdateSettingsWindow()
        diagnosticsWindowController?.refreshUpdateStatus()
        let succeeded = run.results.count - run.failures
        var lines = run.results
        if !run.plan.skipped.isEmpty {
            lines.append("")
            lines.append(contentsOf: run.plan.skipped.map { "· \($0)" })
        }
        if presentAlert {
            presentUpdateFlowInfo(
                title: UpdateFlowText.resultTitle(succeeded: succeeded, failed: run.failures),
                detail: UpdateFlowText.resultBody(lines)
            )
        }
        logUpdateFlow("统一更新结束：成功 \(succeeded) 项，失败 \(run.failures) 项。")
    }

    func logUpdateFlow(_ message: String) {
        let redacted = logRedactor.redact(message)
        _ = logWriter.append(redacted)
        updateProgressCenter.appendLog(redacted)
    }

    // MARK: - 更新记录

    /// 「更新」→「更新记录…」：最近一次更新的阶段结果、被放弃的命令与告警。
    @objc func showUpdateHistory(_ sender: Any?) {
        var lines = UpdateHistoryPresenter.lines(for: appConfiguration.updateHistory().first)
        if let warning = piWebUpdateWarning {
            lines.append("")
            lines.append(warning.text)
        }
        if let warning = piCLIUpdateWarning {
            lines.append("")
            lines.append(warning.text)
        }
        if let warning = piPackageUpdateWarning {
            lines.append("")
            lines.append(warning.text)
        }
        let abandoned = updateAbandonedStatusBlockText()
        if !abandoned.isEmpty {
            lines.append("")
            lines.append(abandoned)
        }
        presentUpdateFlowInfo(title: "更新记录", detail: lines.joined(separator: "\n"))
    }
}

// MARK: - 各组件结果的单行摘要

extension UpdateFlowRun {
    /// 每个组件的执行器在结束时汇报一行；失败要带原因，成功要带新版版本。
    static func piCLILine(_ outcome: PiCLIUpdateRunOutcome) -> (String, Bool) {
        switch outcome {
        case .succeeded(_, let oldVersion, let newVersion) where oldVersion == newVersion:
            return ("Pi CLI 已是最高版本：\(newVersion)（无需变更）", true)
        case .succeeded(_, let oldVersion, let newVersion):
            return ("Pi CLI 已更新：\(oldVersion) → \(newVersion)", true)
        case .versionUnchanged(_, let detectedVersion, let oldVersion, _):
            return ("Pi CLI 更新后版本未变化：\(oldVersion) → \(detectedVersion ?? "未知")", false)
        case .commandFailed(_, let failure, _, _, _):
            return ("Pi CLI 更新失败：\(failure.text)", false)
        case .deferred(let reason):
            return ("Pi CLI 更新已推迟：\(reason.text)", false)
        case .notAttempted(let reason, _):
            return ("Pi CLI 未执行：\(reason.text)", false)
        }
    }

    static func piWebLine(_ outcome: PiWebUpdateRunOutcome) -> (String, Bool) {
        switch outcome {
        case .succeeded(_, let oldVersion, let newVersion):
            return ("Pi Web 已更新：\(oldVersion) → \(newVersion)，服务健康检查通过", true)
        case .healthCheckFailed(_, _, let newVersion):
            return ("Pi Web 已更新到 \(newVersion)，但服务健康检查失败", false)
        case .versionUnchanged(_, let detectedVersion, let oldVersion, _):
            return ("Pi Web 更新后版本未变化：\(oldVersion) → \(detectedVersion ?? "未知")", false)
        case .installFailed(_, let failure, _, _, _):
            return ("Pi Web 更新失败：\(failure.text)", false)
        case .skipped(let reason, _):
            return ("Pi Web 未执行：\(reason.text)", false)
        }
    }

    static func piPackageLine(_ batch: PiPackageUpdateBatchOutcome) -> (String, Bool) {
        if batch.isSucceeded {
            let changes = batch.outcomes.compactMap { outcome -> String? in
                guard case .succeeded(let plan, let newVersion, _) = outcome else { return nil }
                return "\(plan.packageName) \(plan.installedVersion) → \(newVersion)"
            }
            return ("Pi 扩展包已更新：" + changes.joined(separator: "、"), true)
        }
        var reasons: [String] = []
        for outcome in batch.outcomes {
            switch outcome {
            case .commandFailed(let plan, let failure, _, _):
                reasons.append("\(plan.packageName)：\(failure.text)")
            case .versionUnchanged(let plan, let detected, _):
                reasons.append("\(plan.packageName)：更新后版本仍是 \(detected ?? "未知")")
            case .refused(let plan, let reason):
                reasons.append("\(plan.packageName)：\(reason.text)")
            case .notAttempted(let name, let reason):
                reasons.append("\(name)：\(reason.text)")
            case .succeeded:
                break
            }
        }
        return ("Pi 扩展包没有全部更新：" + reasons.joined(separator: "；"), false)
    }
}
