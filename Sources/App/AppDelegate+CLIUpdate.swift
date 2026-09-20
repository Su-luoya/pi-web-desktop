/// Pi CLI update flow: banner, progress and resolution reporting.

import Cocoa

extension AppDelegate {
    // MARK: - Pi CLI 更新与运行进程保护（GitHub #21）

    /// 刷新 Pi 进程检查（只读枚举）。smoke 启动不枚举真实进程，返回缓存值。
    @discardableResult
    func refreshPiProcessInspection() -> PiProcessInspection {
        guard !appConfiguration.isSmokeLaunch else {
            return piProcessInspection ?? .unknown(.enumerationFailed)
        }
        let inspection = piProcessInspector.inspect()
        piProcessInspection = inspection
        _ = logWriter.append(logRedactor.redact("Pi 进程检查：\(inspection.statusText)"))
        return inspection
    }

    /// 决策输入：全部来自 #16 识别结果、#17/#18 检查结果与最近一次进程检查。
    private func piCLIPlanningInput() -> PiCLIUpdatePlanningInput {
        let installation = dependencyReport?.components.first { $0.kind == .piCLI }
        let result = updateChecker?.summary.result(for: UpdateCheckTarget(category: .piCLI, packageName: nil).id)
        return PiCLIUpdatePlanningInput(
            preferences: updateChecker?.preferences ?? appConfiguration.updateCheckPreferences(),
            installation: installation,
            targetVersion: result?.latestVersion,
            targetStatus: result?.status ?? .unknown,
            targetConfidence: result?.confidence ?? .unknown,
            targetOrigin: result?.origin ?? .unavailable,
            targetCacheWrittenAt: result?.cacheWrittenAt,
            processes: piProcessInspection ?? .unknown(.enumerationFailed),
            abandonedAttempt: abandonedAttempt(for: .piCLI)
        )
    }

    /// 手动更新可以用的目标版本：优先本次运行已验证的检查结果，其次缓存里的
    /// “可更新”状态；都没有时为 nil（`pi update --self` 自己决定版本）。
    private func piCLIManualTargetVersion() -> String? {
        let target = UpdateCheckTarget(category: .piCLI, packageName: nil)
        if let result = updateChecker?.summary.result(for: target.id), result.status == .updateAvailable {
            return result.latestVersion
        }
        guard let updateChecker else { return nil }
        let status = statusSnapshot(for: updateChecker).first { $0.category == .piCLI }
        return status?.status == .updateAvailable ? status?.latestVersion : nil
    }

    /// 启动/周期检查完成后尝试一次自动更新。只有决策为 `.automatic` 且本次运行
    /// 还没有执行过时才会执行；推迟只记录原因，下一次检查结果到达时再判定。
    func attemptPiCLIAutomaticUpdateIfNeeded() {
        guard let updateChecker,
              updateChecker.preferences.autoUpdatePiBeforeLaunch,
              !piCLIUpdateInProgress,
              !preLaunchUpdateInProgress else { return }
        // 判定前刷新一次进程检查：决策必须基于“刚刚”的事实，而不是上一次打开诊断页
        // 时的缓存（设置关闭时不会走到这里，也就不做任何进程枚举）。
        _ = refreshPiProcessInspection()
        let input = piCLIPlanningInput()
        let decision = PiCLIUpdatePlanner.decide(input)
        piCLIUpdateDecision = decision
        switch decision {
        case .automatic(let plan):
            guard !piCLIUpdateAttemptedInThisRun, let coordinator = piCLIUpdateCoordinator else { return }
            piCLIUpdateAttemptedInThisRun = true
            piCLIUpdateInProgress = true
            piCLIUpdateRedetectionPath = plan.executablePath
            logPiCLIUpdate(decision.logLine(redactingWith: logRedactor))
            coordinator.run(input) { [weak self] outcome in
                guard let self else { return }
                self.piCLIUpdateInProgress = false
                self.handlePiCLIUpdateOutcome(outcome, manual: false)
            }
        case .deferred:
            logPiCLIUpdate(decision.logLine(redactingWith: logRedactor))
            refreshUpdateMenuState()
        case .manualOnly, .unavailable:
            // 不自动更新的原因（含 GitHub #59 的“来源不是本次网络结果”）写入日志；
            // 上一个分支已经刷新过菜单，这里只需要把拒绝原因持久化。
            logPiCLIUpdate(decision.logLine(redactingWith: logRedactor))
        }
    }

    /// 手动“立即更新 Pi CLI…”：先展示计划、运行中的 Pi 进程与风险说明，用户
    /// 显式确认后才执行。执行内容只有 `pi update --self`，不操作任何进程。
    @objc func updatePiCLINow(_ sender: Any?) {
        // 与 Pi Web 同一道闸控（W2A A-4 + W3B F2/F3）：同一时间只允许一个更新在
        // 执行，闸控覆盖事务尾段与「退出未确认」窗口；只看 Pi CLI 自己的状态，
        // Pi Web 的子进程不在这里造成阻碍。
        let cliEntry = piCLIUpdateEntryState
        guard !cliEntry.isBlocked else {
            presentPiCLIUpdateInfo("更新正在进行", detail: cliEntry.rejectionDetail)
            return
        }
        guard dependencyGate == .ready, let report = dependencyReport else {
            presentPiCLIUpdateInfo("环境检查尚未完成", detail: "请等待依赖诊断完成后再试。")
            return
        }
        let installation = report.components.first { $0.kind == .piCLI }
        guard let plan = PiCLIUpdatePlanner.manualPlan(
            installation: installation,
            targetVersion: piCLIManualTargetVersion()
        ) else {
            presentPiCLIUpdateInfo(
                "当前不能立即更新 Pi CLI",
                detail: piCLIManualUnavailableText(installation: installation)
            )
            return
        }
        let inspection = refreshPiProcessInspection()
        let alert = NSAlert()
        alert.messageText = "立即更新 Pi CLI"
        alert.informativeText = PiCLIManualUpdateConfirmation.text(
            plan: plan,
            commandText: plan.commandText,
            inspection: inspection,
            abandonedAttempt: abandonedAttempt(for: .piCLI),
            redactingWith: logRedactor
        )
        alert.addButton(withTitle: "确认更新")
        alert.addButton(withTitle: "取消")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.performPiCLIManualUpdate(plan: plan)
        }
    }

    private func piCLIManualUnavailableText(installation: ComponentInstallation?) -> String {
        var text = "原因："
        if installation == nil {
            text += PiCLIUpdateRefusal.missingInstallation.text
        } else if installation?.executablePath == nil {
            text += PiCLIUpdateRefusal.executableUnresolved.text
        } else if installation?.version == nil {
            text += "没有可用的 Pi CLI 版本信息"
        } else {
            text += PiCLIUpdateRefusal.unsafeCommand.text
        }
        text += "。请先在诊断页确认 Pi CLI 的路径与版本，然后重新检测。"
        return text
    }

    private func performPiCLIManualUpdate(plan: PiCLIUpdatePlan) {
        let cliEntry = piCLIUpdateEntryState
        guard !cliEntry.isBlocked else {
            presentPiCLIUpdateInfo("更新正在进行", detail: cliEntry.rejectionDetail)
            return
        }
        guard let coordinator = piCLIUpdateCoordinator else { return }
        piCLIUpdateRedetectionPath = plan.executablePath
        logPiCLIUpdate("手动更新 Pi CLI：用户已确认（参数数组 \(plan.arguments.joined(separator: " "))）。")
        showPiCLIUpdateProgressPage(plan: plan)
        coordinator.runManual(plan) { [weak self] outcome in
            self?.handlePiCLIUpdateOutcome(outcome, manual: true)
        }
    }

    private func handlePiCLIUpdateOutcome(_ outcome: PiCLIUpdateRunOutcome, manual: Bool) {
        switch outcome {
        case .succeeded(_, let oldVersion, let newVersion):
            clearPiCLIUpdateWarning()
            logPiCLIUpdate("Pi CLI 更新完成：\(oldVersion) → \(newVersion)。")
            presentPiCLIUpdateInfo("Pi CLI 已更新", detail: "已从 \(oldVersion) 更新到 \(newVersion)。")
        case .versionUnchanged(_, let detectedVersion, let oldVersion, let targetVersion):
            recordPiCLIUpdateWarning(outcome.warning)
            logPiCLIUpdate(
                "Pi CLI 更新未通过版本验证：当前 \(oldVersion)，目标 \(targetVersion ?? "未知")，"
                    + "重新检测到 \(detectedVersion ?? "未知")。"
            )
            presentPiCLIUpdateInfo(
                "Pi CLI 更新未完成",
                detail: [outcome.warning?.text, latestUpdateDegradationText()]
                    .compactMap { $0 }
                    .filter { !$0.isEmpty }
                    .joined(separator: "\n\n")
            )
        case .commandFailed(_, let failure, let oldVersion, _, let outputTail):
            // 应用退出时的“放弃等待”不算更新失败：命令可能仍在后台自己完成，下次
            // 启动的检查会给出结论，因此只记日志，不写持久告警也不弹框。
            if failure == .abandoned {
                // L-5（GitHub #127）：这里不能断言「旧版本保持不变」——放弃等待时命令可能
                // 已经改完文件、也可能还在跑，日志只记「没有确认」这一事实。
                logPiCLIUpdate(
                    "Pi CLI 更新已放弃等待（应用退出）：命令可能仍在后台自己完成；"
                        + "没有确认更新前的版本 \(oldVersion) 是否仍在原位，下次启动重新检测。"
                )
                break
            }
            recordPiCLIUpdateWarning(outcome.warning)
            var detail = outcome.warning?.text ?? failure.text
            if let degradation = latestUpdateDegradationText() {
                detail += "\n\n" + degradation
            }
            if let outputTail {
                detail += "\n\n命令输出片段（已脱敏）：\(outputTail)"
            }
            presentPiCLIUpdateInfo("Pi CLI 更新未完成", detail: detail)
        case .deferred(let reason):
            logPiCLIUpdate("Pi CLI 自动更新已推迟：\(reason.text)")
            if manual {
                presentPiCLIUpdateInfo("已推迟 Pi CLI 更新", detail: reason.text)
            }
        case .notAttempted(let reason, let commandText):
            logPiCLIUpdate("Pi CLI 更新未执行：\(reason.text)")
            if manual {
                var detail = "原因：\(reason.text)"
                // L-3：CLI 的「更新进行中」拒绝文案本身不带恢复路径（Web 与扩展包都有）。
                // 只有「已放弃等待、退出未确认」这种窗口才提示重启；真正的更新事务还在跑
                // 时不能建议重启。
                if reason == .updateAlreadyInProgress, piCLIUpdateRunner.abandonedChildrenUnconfirmed {
                    detail += "\n\n上一次更新命令已放弃等待，但还不能确认它已经退出；"
                        + "如果长时间没有变化，重启应用即可恢复（重启后这个未确认窗口不会保留）。"
                }
                if let commandText {
                    detail += "\n\n可以手动执行：\(logRedactor.redact(commandText))"
                }
                presentPiCLIUpdateInfo("Pi CLI 更新未执行", detail: detail)
            }
        }
        refreshUpdateMenuState()
        diagnosticsWindowController?.refreshUpdateStatus()
        syncUpdateSettingsWindow()
    }

    private func recordPiCLIUpdateWarning(_ warning: PiCLIUpdateWarning?) {
        guard let warning else { return }
        piCLIUpdateWarning = warning
        appConfiguration.savePiCLIUpdateWarning(warning)
        logPiCLIUpdate(warning.text)
    }

    private func clearPiCLIUpdateWarning() {
        guard piCLIUpdateWarning != nil else { return }
        piCLIUpdateWarning = nil
        appConfiguration.savePiCLIUpdateWarning(nil)
        refreshUpdateMenuState()
        diagnosticsWindowController?.refreshUpdateStatus()
    }

    /// 菜单里的持久告警项：展开完整告警文本，并提供“清除警告”。
    @objc func showPiCLIUpdateWarning(_ sender: Any?) {
        guard let warning = piCLIUpdateWarning else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = warning.shortText
        alert.informativeText = warning.text
            + "\n\n应用不会自动回滚，也不会重试无上限；可以手动重试“立即更新 Pi CLI…”。"
        alert.addButton(withTitle: "好")
        alert.addButton(withTitle: "清除警告")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertSecondButtonReturn else { return }
            self?.clearPiCLIUpdateWarning()
        }
    }

    /// 手动更新的执行页：在真正执行前展示同一个计划与“不发送信号”的说明。
    private func showPiCLIUpdateProgressPage(plan: PiCLIUpdatePlan) {
        var lines = plan.displayLines(redactingWith: logRedactor)
        lines.append("")
        lines.append("正在执行 pi update --self；更新期间请不要退出应用。"
            + "命令有超时限制，超时只放弃等待，不会向任何进程发送信号，也不会结束 Pi 会话。")
        webViewController.showDependencyPage(title: "正在更新 Pi CLI", message: lines.joined(separator: "\n"))
    }

    private func presentPiCLIUpdateInfo(_ title: String, detail: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.addButton(withTitle: "好")
        alert.beginSheetModal(for: window)
    }

    func logPiCLIUpdate(_ message: String) {
        _ = logWriter.append(logRedactor.redact(message))
    }

    /// 诊断页/设置页的 Pi CLI 进程保护与更新状态块（已脱敏）。smoke 启动返回空串：
    /// 不为诊断 fixture 枚举真实进程。
    func piCLIStatusBlockText() -> String {
        guard !appConfiguration.isSmokeLaunch else { return "" }
        let input = piCLIPlanningInput()
        return PiCLIUpdateStatusPresenter.lines(
            preferences: input.preferences,
            inspection: piProcessInspection,
            decision: PiCLIUpdatePlanner.decide(input),
            warning: piCLIUpdateWarning
        ).joined(separator: "\n")
    }
}
