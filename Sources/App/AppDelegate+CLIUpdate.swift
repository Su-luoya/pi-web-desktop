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
            abandonedAttempt: abandonedAttempt(for: .piCLI),
            // outD-4：把「已有一轮在跑」也纳入决策。只看自动路径自己的标记不够——
            // 手动入口、事务尾段、放弃等待未确认都不会置它。
            updateInProgress: piCLIUpdateInProgress || piCLIUpdateEntryState.isBlocked
        )
    }

    /// 手动更新可以用的目标版本：优先本次运行已验证的检查结果，其次缓存里的
    /// “可更新”状态；都没有时为 nil（`pi update --self` 自己决定版本）。
    func piCLIManualTargetVersion() -> String? {
        let target = UpdateCheckTarget(category: .piCLI, packageName: nil)
        if let result = updateChecker?.summary.result(for: target.id), result.status == .updateAvailable {
            return result.latestVersion
        }
        guard let updateChecker else { return nil }
        let status = statusSnapshot(for: updateChecker).first { $0.category == .piCLI }
        return status?.status == .updateAvailable ? status?.latestVersion : nil
    }

    func performPiCLIManualUpdate(
        plan: PiCLIUpdatePlan,
        completion: ((String, Bool) -> Void)? = nil
    ) {
        let cliEntry = piCLIUpdateEntryState
        guard !cliEntry.isBlocked, !piCLIUpdateInProgress else {
            logPiCLIUpdate(cliEntry.rejectionDetail)
            updateProgressCenter.finish(.skipped(reason: "更新正在进行，详见过程日志"))
            completion?("Pi CLI 未执行：\(cliEntry.rejectionDetail)", false)
            return
        }
        guard let coordinator = piCLIUpdateCoordinator else {
            updateProgressCenter.finish(.skipped(reason: "Pi CLI 更新器尚未就绪"))
            completion?("Pi CLI 未执行：更新器尚未就绪", false)
            return
        }
        // outD-4：手动路径也必须置位。否则手动更新执行期间到达的一次检查结果会把
        // 决策判成 `.automatic`，先烧掉「本次运行只自动更新一次」的额度，再被编排
        // 器拒绝——自动更新在本整次运行里静默失效。
        piCLIUpdateInProgress = true
        piCLIUpdateRedetectionPath = plan.executablePath
        updateProgressCenter.confirm()
        logPiCLIUpdate("手动更新 Pi CLI：用户已确认（参数数组 \(plan.arguments.joined(separator: " "))）。")
        refreshUpdateMenuState()
        coordinator.runManual(plan) { [weak self] outcome in
            guard let self else { return }
            self.piCLIUpdateInProgress = false
            self.refreshUpdateMenuState()
            self.handlePiCLIUpdateOutcome(outcome, manual: true)
            let line = UpdateFlowRun.piCLILine(outcome)
            completion?(line.0, line.1)
        }
    }

    private func handlePiCLIUpdateOutcome(_ outcome: PiCLIUpdateRunOutcome, manual: Bool) {
        switch outcome {
        case .succeeded(_, let oldVersion, let newVersion) where oldVersion == newVersion:
            clearPiCLIUpdateWarning()
            logPiCLIUpdate("Pi CLI 已是最高版本：\(newVersion)，本次没有安装任何东西。")
            updateProgressCenter.finish(.succeeded(version: newVersion))
        case .succeeded(_, let oldVersion, let newVersion):
            clearPiCLIUpdateWarning()
            logPiCLIUpdate("Pi CLI 更新完成：\(oldVersion) → \(newVersion)。")
            updateProgressCenter.finish(.succeeded(version: newVersion))
        case .versionUnchanged:
            recordPiCLIUpdateWarning(outcome.warning)
            logPiCLIUpdate([outcome.warning?.text, latestUpdateDegradationText()]
                .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n\n"))
            updateProgressCenter.finish(.failed(reason: "更新后版本验证未通过，详见过程日志"))
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
                updateProgressCenter.finish(.skipped(reason: "已放弃等待；下次启动重新检测"))
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
            logPiCLIUpdate(detail)
            updateProgressCenter.finish(.failed(reason: failure.text))
        case .deferred(let reason):
            logPiCLIUpdate("Pi CLI 自动更新已推迟：\(reason.text)")
            updateProgressCenter.finish(.skipped(reason: "Pi CLI 更新已推迟，详见过程日志"))
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
                logPiCLIUpdate(detail)
            }
            updateProgressCenter.finish(.skipped(reason: "Pi CLI 更新未执行，详见过程日志"))
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

    private func presentPiCLIUpdateInfo(_ title: String, detail: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.addButton(withTitle: "好")
        presentAlert(alert)
    }

    func logPiCLIUpdate(_ message: String) {
        let redacted = logRedactor.redact(message)
        _ = logWriter.append(redacted)
        updateProgressCenter.appendLog(redacted)
    }

    /// 诊断页/设置页的 Pi CLI 进程保护与更新状态块（已脱敏）。smoke 启动返回空串：
    /// 不为诊断 fixture 枚举真实进程。
    /// `compact` 为真时进程状态只报数量（设置页用，诊断页保持完整展开）。
    func piCLIStatusBlockText(compact: Bool = false) -> String {
        guard !appConfiguration.isSmokeLaunch else { return "" }
        let input = piCLIPlanningInput()
        return PiCLIUpdateStatusPresenter.lines(
            preferences: input.preferences,
            inspection: piProcessInspection,
            decision: PiCLIUpdatePlanner.decide(input),
            warning: piCLIUpdateWarning,
            compact: compact
        ).joined(separator: "\n")
    }
}
