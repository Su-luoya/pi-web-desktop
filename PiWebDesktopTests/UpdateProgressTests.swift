import Cocoa
import XCTest

/// GitHub #219：更新进度窗口的模型与窗口渲染测试。
///
/// 全部副作用都是内存状态：不联网、不执行命令、不读写用户目录、不发信号。
final class UpdateProgressTests: XCTestCase {
    private let referenceDate = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - 夹具

    private func phase(
        _ phase: UpdateTransactionPhase,
        _ status: UpdateTransactionPhaseStatus,
        reason: String = "已记录"
    ) -> UpdateTransactionPhaseResult {
        UpdateTransactionPhaseResult(
            phase: phase,
            status: status,
            reason: reason,
            recordedAt: referenceDate
        )
    }

    private func history(
        component: UpdateTransactionComponent = .piWeb,
        toVersion: String? = "1.2.3",
        completed: UpdateTransactionPhase? = .commit,
        termination: UpdateTransactionPhase? = nil,
        failureReason: String? = nil,
        phases: [UpdateTransactionPhaseResult] = []
    ) -> UpdateHistoryEntry {
        UpdateHistoryEntry(
            recordedAt: referenceDate,
            component: component,
            source: .npmGlobal,
            fromVersion: "1.2.2",
            toVersion: toVersion,
            completedPhase: completed,
            terminationPhase: termination,
            phases: phases,
            degradationKind: nil,
            failureReason: failureReason,
            manualCommandText: nil,
            manualGuidanceText: nil,
            rollbackDescription: nil,
            evidenceLevel: nil,
            evidenceNote: nil
        )
    }

    // MARK: - 阶段映射

    /// 事务阶段 → 界面状态：`notAttempted` 是“跳过”而不是失败，只有 `applied`
    /// 才算成功（降级的另外两种结果是“没做成”）。
    func testPhaseStatusMapsToStepState() {
        XCTAssertEqual(UpdateProgressPlan.state(for: .succeeded), .succeeded)
        XCTAssertEqual(UpdateProgressPlan.state(for: .applied), .succeeded)
        XCTAssertEqual(UpdateProgressPlan.state(for: .failed), .failed)
        XCTAssertEqual(UpdateProgressPlan.state(for: .notPossible), .failed)
        XCTAssertEqual(UpdateProgressPlan.state(for: .skipped), .skipped)
        XCTAssertEqual(UpdateProgressPlan.state(for: .recordedOnly), .skipped)
        XCTAssertEqual(UpdateProgressPlan.state(for: .notAttempted), .skipped)
    }

    /// 第一次阶段记录才开始会话：准备阶段进行中，其余等待。
    func testFirstPhaseStartsSessionWithPreflightRunning() {
        let center = UpdateProgressCenter()
        center.apply(phase: phase(.preflight, .succeeded, reason: "已记录指纹"), component: .piWeb)

        let session = center.session
        XCTAssertEqual(session?.title, "Pi Web 更新")
        XCTAssertEqual(session?.steps.map(\.title), ["准备", "执行安装", "验证", "启用/提交"])
        XCTAssertEqual(session?.steps.map(\.state), [.succeeded, .running, .pending, .pending])
        XCTAssertEqual(session?.steps.first?.detail, "已记录指纹")
    }

    /// 成功的阶段会把下一阶段标成进行中，用户始终看到“做完的 + 正在做的”。
    func testSuccessAdvancesNextStepToRunning() {
        let center = UpdateProgressCenter()
        center.apply(phase: phase(.preflight, .succeeded), component: .piCLI)
        center.apply(phase: phase(.install, .succeeded), component: .piCLI)

        XCTAssertEqual(center.session?.steps.map(\.state), [.succeeded, .succeeded, .running, .pending])
        XCTAssertEqual(center.session?.runningStepTitle, "验证")
    }

    /// 失败阶段只改自己那一行，不推进下一行。
    func testFailedPhaseDoesNotAdvance() {
        let center = UpdateProgressCenter()
        center.apply(phase: phase(.preflight, .succeeded), component: .piWeb)
        center.apply(phase: phase(.install, .failed, reason: "npm 安装失败"), component: .piWeb)

        XCTAssertEqual(center.session?.steps.map(\.state), [.succeeded, .failed, .pending, .pending])
        XCTAssertEqual(center.session?.steps[1].detail, "npm 安装失败")
    }

    /// 降级行只在真的记录降级时才追加，并且固定在末尾。
    func testDegradationStepIsAppendedOnlyWhenRecorded() {
        let center = UpdateProgressCenter()
        center.apply(phase: phase(.preflight, .succeeded), component: .piWeb)
        XCTAssertEqual(center.session?.steps.count, 4)

        center.apply(phase: phase(.degrade, .applied, reason: "已回到更新前的可执行文件"), component: .piWeb)
        XCTAssertEqual(center.session?.steps.count, 5)
        XCTAssertEqual(center.session?.steps.last?.state, .succeeded)
        XCTAssertEqual(center.session?.steps.last?.detail, "已回到更新前的可执行文件")
    }

    /// 越界或没有会话的阶段更新必须被忽略（晚到的回调不能让窗口崩）。
    func testStepUpdatesAreIgnoredWithoutSession() {
        let center = UpdateProgressCenter()
        center.setStep(3, state: .failed, detail: "晚到")
        XCTAssertNil(center.session)

        center.apply(phase: phase(.preflight, .succeeded), component: .piWeb)
        center.setStep(99, state: .failed)
        XCTAssertEqual(center.session?.steps.count, 4)
        XCTAssertEqual(center.session?.steps.map(\.state), [.succeeded, .running, .pending, .pending])
    }

    // MARK: - 日志

    func testLogLinesSkipBlankAndKeepOrder() {
        let center = UpdateProgressCenter()
        center.begin(title: "更新", steps: [])
        center.appendLog("第一行")
        center.appendLog("   \n ")
        center.appendLog("  第二行  ")

        XCTAssertEqual(center.session?.logLines, ["第一行", "第二行"])
    }

    func testLogLinesAreCappedAtLimit() {
        let center = UpdateProgressCenter()
        center.begin(title: "更新", steps: [])
        for index in 0..<(UpdateProgressSession.maximumLogLines + 5) {
            center.appendLog("行 \(index)")
        }
        XCTAssertEqual(center.session?.logLines.count, UpdateProgressSession.maximumLogLines)
        XCTAssertEqual(center.session?.logLines.first, "行 5")
    }

    // MARK: - 结束

    /// 成功收尾：结论行带版本号，仍在进行中的阶段改成“跳过”，不留假进行中。
    func testFinishSuccessMarksRunningStepSkipped() {
        let center = UpdateProgressCenter()
        center.apply(phase: phase(.preflight, .succeeded), component: .piWeb)
        center.finish(history: history(), now: referenceDate)

        XCTAssertEqual(center.session?.outcome, .succeeded(version: "1.2.3"))
        XCTAssertEqual(center.session?.steps.map(\.state), [.succeeded, .skipped, .pending, .pending])
        XCTAssertTrue(center.session?.isFinished == true)
    }

    /// 失败收尾用历史里记录的第一句原因，保证窗口和诊断页是同一句话。
    func testFinishFailureUsesHistoryReason() {
        let center = UpdateProgressCenter()
        center.apply(phase: phase(.preflight, .succeeded), component: .piWeb)
        center.finish(
            history: history(
                completed: nil,
                termination: .install,
                failureReason: "npm 安装失败",
                phases: [phase(.preflight, .succeeded), phase(.install, .failed, reason: "npm 安装失败")]
            )
        )
        XCTAssertEqual(center.session?.outcome, .failed(reason: "npm 安装失败"))
        XCTAssertEqual(
            center.session?.outcome?.headline,
            "更新失败：npm 安装失败"
        )
    }

    /// 没有失败原因但有终止阶段时，说明停在哪一步，而不是笼统的“没有完成”。
    func testFinishFailureWithoutReasonNamesTerminationPhase() {
        let center = UpdateProgressCenter()
        center.apply(phase: phase(.preflight, .succeeded), component: .piWeb)
        center.finish(history: history(completed: nil, termination: .verify))
        XCTAssertEqual(center.session?.outcome, .failed(reason: "流程停在「验证」，没有完成提交"))
    }

    /// 重复结束只保留第一次结论：晚到的失败不得覆盖已发布的结果。
    func testSecondFinishIsIgnored() {
        let center = UpdateProgressCenter()
        center.apply(phase: phase(.preflight, .succeeded), component: .piWeb)
        center.finish(.succeeded(version: "1.2.3"), now: referenceDate)
        center.finish(.failed(reason: "晚到的失败"), now: referenceDate.addingTimeInterval(10))
        XCTAssertEqual(center.session?.outcome, .succeeded(version: "1.2.3"))
    }

    /// 没有会话时的结束调用什么也不做。
    func testFinishWithoutSessionDoesNothing() {
        let center = UpdateProgressCenter()
        center.finish(.failed(reason: "无会话"))
        XCTAssertNil(center.session)
    }

    // MARK: - 快照文案

    func testElapsedAndStatusLine() {
        let center = UpdateProgressCenter()
        center.begin(title: "更新", steps: [], now: referenceDate)
        let session = center.session
        XCTAssertEqual(session?.elapsed(at: referenceDate.addingTimeInterval(32)), 32)
        XCTAssertEqual(session?.statusLine(at: referenceDate.addingTimeInterval(32)), "已用 00:32")

        center.finish(.succeeded(version: "1.2.3"), now: referenceDate.addingTimeInterval(65))
        XCTAssertEqual(
            center.session?.statusLine(at: referenceDate.addingTimeInterval(999)),
            "已用 01:05 · 更新完成（到 1.2.3）"
        )
    }

    func testDurationTextHandlesHours() {
        XCTAssertEqual(UpdateProgressSession.durationText(0), "00:00")
        XCTAssertEqual(UpdateProgressSession.durationText(59.9), "00:59")
        XCTAssertEqual(UpdateProgressSession.durationText(3725), "01:02:05")
    }

    /// 每次变化都要通知窗口：开始、阶段、日志、结束、清空。
    func testCenterPublishesOnEveryChange() {
        let center = UpdateProgressCenter()
        var published: [Int] = []
        center.onChange = { published.append($0?.logLines.count ?? -1) }

        center.begin(title: "更新", steps: [], now: referenceDate)
        center.appendLog("一")
        center.finish(.skipped(reason: "无变更"), now: referenceDate)
        center.reset()

        XCTAssertEqual(published, [0, 1, 1, -1])
    }

    // MARK: - 事务环境

    /// 未接入进度窗口的调用点（含全部现有测试）不需要改：默认回调是空实现。
    func testDefaultReportPhaseIsNoOp() {
        let environment = UpdateTransactionEnvironment(
            probe: .disabled,
            recordHistory: { _ in },
            applyDegradation: { _ in }
        )
        _ = XCTAssertNoThrow(environment.reportPhase(.piWeb, phase(.preflight, .succeeded)))
    }

    // MARK: - 确认与连续更新

    func testConfirmationWaitsForExplicitActionAndKeepsReviewInSameSession() {
        let center = UpdateProgressCenter()
        center.begin(title: "立即更新 Pi CLI", steps: [], requiresConfirmation: true, now: referenceDate)
        center.appendLog("更新计划与进程详情")
        center.apply(phase: phase(.preflight, .succeeded), component: .piCLI)
        center.finish(history: history(component: .piCLI))
        XCTAssertTrue(center.session?.requiresConfirmation == true)
        XCTAssertTrue(center.session?.steps.isEmpty == true)
        XCTAssertFalse(center.session?.isFinished == true)

        let confirmedAt = referenceDate.addingTimeInterval(60)
        center.confirm(now: confirmedAt)
        XCTAssertFalse(center.session?.requiresConfirmation == true)
        XCTAssertEqual(center.session?.startedAt, confirmedAt)
        XCTAssertEqual(center.session?.logLines, ["更新计划与进程详情"])
        XCTAssertEqual(center.session?.steps.map(\.state), [.running, .pending, .pending, .pending])

        center.apply(phase: phase(.preflight, .succeeded), component: .piCLI)
        center.confirm(now: confirmedAt.addingTimeInterval(10))
        XCTAssertEqual(center.session?.startedAt, confirmedAt, "重复确认不能重置进度")
        XCTAssertEqual(center.session?.steps.first?.state, .succeeded)
    }

    func testNewTransactionReplacesFinishedSession() {
        let center = UpdateProgressCenter()
        center.apply(phase: phase(.preflight, .succeeded), component: .piWeb, now: referenceDate)
        center.appendLog("上一轮日志")
        center.finish(history: history(), now: referenceDate)
        center.apply(
            phase: phase(.preflight, .succeeded), component: .piCLI,
            now: referenceDate.addingTimeInterval(10)
        )
        XCTAssertEqual(center.session?.title, "Pi CLI 更新")
        XCTAssertFalse(center.session?.isFinished == true)
        XCTAssertEqual(center.session?.logLines, [])
        XCTAssertEqual(center.session?.steps.map(\.state), [.succeeded, .running, .pending, .pending])
    }

    func testBatchDoesNotFinishAtFirstPackageAndKeepsLogsBetweenPackages() throws {
        let center = UpdateProgressCenter()
        let first = UpdateTransactionComponent.piPackage("extension-one")
        let second = UpdateTransactionComponent.piPackage("extension-two")
        center.begin(title: "确认更新", steps: [], requiresConfirmation: true, now: referenceDate)
        center.appendLog("整批更新计划")
        var publishedLogs: [String] = []
        center.onChange = { publishedLogs = $0?.logLines ?? [] }
        center.beginBatch(components: [first, second], now: referenceDate.addingTimeInterval(10))
        XCTAssertEqual(publishedLogs, ["整批更新计划"], "发布的第一份批量快照就必须包含确认详情")
        XCTAssertFalse(center.session?.requiresConfirmation == true)

        center.apply(phase: phase(.preflight, .succeeded), component: first)
        center.apply(phase: phase(.commit, .succeeded), component: first)
        center.appendLog("第一个包完成")
        center.finish(history: history(component: first))
        XCTAssertFalse(center.session?.isFinished == true, "单包历史不能提前结束整批更新")

        center.apply(phase: phase(.preflight, .succeeded), component: second)
        XCTAssertEqual(center.session?.title, "Pi 扩展包 extension-two 更新（2/2）")
        XCTAssertEqual(center.session?.logLines, ["整批更新计划", "第一个包完成"])
        XCTAssertEqual(center.session?.steps.map(\.state), [.succeeded, .running, .pending, .pending])
        center.finish(history: history(component: second))
        XCTAssertFalse(center.session?.isFinished == true)

        let record = PiPackageUpdateCommandRecord(exitCode: 0, duration: 1, failure: nil)
        let plans = try ["extension-one", "extension-two"].map { name in
            try XCTUnwrap(PiPackageUpdatePlan.make(
                executablePath: "/opt/homebrew/bin/pi", packageName: name,
                installedVersion: "1.0.0", targetVersion: "2.0.0",
                source: .npmGlobal, confidence: .verified
            ))
        }
        center.finish(batch: PiPackageUpdateBatchOutcome(outcomes: plans.map {
            .succeeded(plan: $0, newVersion: "2.0.0", record: record)
        }))
        XCTAssertEqual(center.session?.outcome, .succeeded(version: nil))
    }

    func testRefusedBatchDoesNotRemainRunning() throws {
        let center = UpdateProgressCenter()
        let plan = try XCTUnwrap(PiPackageUpdatePlan.make(
            executablePath: "/opt/homebrew/bin/pi", packageName: "extension-one",
            installedVersion: "1.0.0", targetVersion: "2.0.0",
            source: .npmGlobal, confidence: .verified
        ))
        center.beginBatch(components: [.piPackage(plan.packageName)])
        center.finish(batch: PiPackageUpdateBatchOutcome(outcomes: [
            .refused(plan: plan, reason: .processStateUnknown(.enumerationFailed))
        ]))
        XCTAssertTrue(center.session?.isFinished == true)
        XCTAssertFalse(center.session?.steps.contains { $0.state == .running } == true)
        XCTAssertEqual(center.session?.outcome, .skipped(reason: "0/1 个扩展包更新完成；其余失败或未执行，详见过程日志"))
    }

    func testHistoryFromDifferentComponentCannotFinishCurrentUpdate() {
        let center = UpdateProgressCenter()
        center.apply(phase: phase(.preflight, .succeeded), component: .piCLI)
        center.finish(history: history(component: .piWeb))
        XCTAssertFalse(center.session?.isFinished == true)
        center.finish(history: history(component: .piCLI))
        XCTAssertTrue(center.session?.isFinished == true)
    }

    // MARK: - 窗口渲染

    func testLongConfirmationStaysInScrollableWindowWithVisibleActions() throws {
        let center = UpdateProgressCenter()
        center.begin(title: "立即更新 Pi CLI", steps: [], requiresConfirmation: true, now: referenceDate)
        let detail = (1...19).map { index in
            "进程 PID：\(4000 + index)\n父进程 PID：4000\n启动时间：夹具时间\n判定依据：JS 运行时的 argv[0]（进程标题）是 pi\n真实镜像路径：~/.local/bin/node\n命令摘要：pi\n"
        }.joined(separator: "\n")
        center.appendLog(detail)
        let controller = UpdateProgressWindowController()
        let window = try XCTUnwrap(controller.window)
        let initialSize = window.frame.size
        controller.render(center.session)
        let content = try XCTUnwrap(window.contentView)
        content.layoutSubtreeIfNeeded()
        XCTAssertEqual(window.frame.size, initialSize, "长进程列表不得把窗口撑出屏幕")
        XCTAssertEqual(controller.logText, detail.trimmingCharacters(in: .whitespacesAndNewlines))
        XCTAssertTrue(controller.isAwaitingConfirmation)
        XCTAssertEqual(controller.closeButtonTitle, "取消")
        XCTAssertTrue(controller.statusLabelText.contains("等待确认"))
        XCTAssertEqual(controller.elapsedLabelText, "尚未执行更新")
        let scroll = try XCTUnwrap(content.subviews.compactMap { $0 as? NSScrollView }.first)
        XCTAssertTrue(scroll.hasVerticalScroller)
        XCTAssertLessThan(scroll.frame.height, window.frame.height)
        let document = try XCTUnwrap(scroll.documentView as? NSTextView)
        document.layoutManager?.ensureLayout(for: try XCTUnwrap(document.textContainer))
        XCTAssertGreaterThan(document.frame.height, scroll.contentSize.height)
        XCTAssertEqual(scroll.contentView.bounds.minY, 0, "确认详情从头显示，不自动滚到底部")

        let footer = try XCTUnwrap(content.subviews.compactMap { $0 as? NSStackView }.first {
            $0.arrangedSubviews.contains { ($0 as? NSButton)?.title == "确认更新" }
        })
        let confirm = try XCTUnwrap(footer.arrangedSubviews.compactMap { $0 as? NSButton }.first { $0.title == "确认更新" })
        let cancel = try XCTUnwrap(footer.arrangedSubviews.compactMap { $0 as? NSButton }.first { $0.title == "取消" })
        for button in [confirm, cancel] {
            XCTAssertFalse(button.isHidden)
            XCTAssertTrue(content.bounds.contains(button.convert(button.bounds, to: content)))
        }
        XCTAssertEqual(cancel.keyEquivalent, "\r")
        XCTAssertNotEqual(confirm.keyEquivalent, "\r", "回车不得误触发更新")
    }

    func testConfirmRunsOnceAndContinuesInSameWindowWithoutCancellation() throws {
        let center = UpdateProgressCenter()
        center.begin(title: "立即更新 Pi CLI", steps: [], requiresConfirmation: true, now: referenceDate)
        let controller = UpdateProgressWindowController()
        controller.render(center.session)
        let window = try XCTUnwrap(controller.window)
        var confirmed = 0
        var cancelled = 0
        controller.onConfirm = {
            confirmed += 1
            center.confirm(now: self.referenceDate.addingTimeInterval(1))
            controller.render(center.session)
        }
        controller.onCancel = { cancelled += 1 }
        controller.confirmUpdate(nil)
        controller.confirmUpdate(nil)
        XCTAssertEqual(confirmed, 1)
        XCTAssertFalse(controller.isAwaitingConfirmation)
        XCTAssertEqual(controller.closeButtonTitle, "关闭")
        XCTAssertEqual(controller.stepRowCount, 4)
        XCTAssertTrue(controller.window === window)
        controller.windowWillClose(Notification(name: NSWindow.willCloseNotification, object: window))
        XCTAssertEqual(cancelled, 0, "执行中关闭窗口只隐藏进度，不撤销更新")
    }

    func testClosingPendingReviewCancelsOnceWithoutConfirming() throws {
        let center = UpdateProgressCenter()
        center.begin(title: "确认更新", steps: [], requiresConfirmation: true)
        let controller = UpdateProgressWindowController()
        controller.render(center.session)
        var confirmed = 0
        var cancelled = 0
        controller.onConfirm = { confirmed += 1 }
        controller.onCancel = { cancelled += 1; center.reset() }
        let notification = Notification(name: NSWindow.willCloseNotification, object: controller.window)
        controller.windowWillClose(notification)
        controller.windowWillClose(notification)
        controller.confirmUpdate(nil)
        XCTAssertEqual(confirmed, 0)
        XCTAssertEqual(cancelled, 1)
        XCTAssertNil(center.session)
    }

    func testNewSessionClearsPreviousReviewActions() {
        let center = UpdateProgressCenter()
        center.begin(title: "确认更新", steps: [], requiresConfirmation: true, now: referenceDate)
        let controller = UpdateProgressWindowController()
        controller.render(center.session)
        controller.onConfirm = {}
        controller.onCancel = {}
        controller.onCopyCommands = {}
        center.begin(title: "Pi CLI 更新", steps: UpdateProgressPlan.steps(), now: referenceDate.addingTimeInterval(1))
        controller.render(center.session)
        XCTAssertNil(controller.onConfirm)
        XCTAssertNil(controller.onCancel)
        XCTAssertNil(controller.onCopyCommands)
        XCTAssertFalse(controller.isAwaitingConfirmation)
    }

    /// 窗口按快照整块重绘：标题、阶段行、日志与底部状态行都来自模型。
    func testWindowRendersSessionSnapshot() throws {
        let center = UpdateProgressCenter()
        center.begin(
            title: "Pi Web 更新到 1.2.3",
            steps: [
                UpdateProgressStep(title: "准备", detail: "已记录指纹", state: .succeeded),
                UpdateProgressStep(title: "执行安装", detail: "正在安装", state: .running)
            ],
            now: referenceDate
        )
        center.appendLog("开始更新")
        center.finish(.failed(reason: "npm 安装失败"), now: referenceDate.addingTimeInterval(10))

        let controller = UpdateProgressWindowController()
        controller.render(center.session)

        XCTAssertEqual(controller.titleLabelText, "Pi Web 更新到 1.2.3")
        XCTAssertEqual(controller.stepRowCount, 2)
        XCTAssertEqual(controller.stepTexts.first, "✓|准备|已记录指纹")
        XCTAssertEqual(controller.logText, "开始更新")
        XCTAssertEqual(controller.statusLabelText, "更新失败：npm 安装失败")
        XCTAssertEqual(controller.progressBarFraction, 0.5)
        XCTAssertTrue(controller.elapsedLabelText.hasPrefix("已用 00:10"))
        XCTAssertTrue(controller.elapsedLabelText.contains("更新失败：npm 安装失败"))
    }

    /// 没有会话时窗口显示占位文案，而不是空白或崩溃。
    func testWindowRendersPlaceholderWithoutSession() {
        let controller = UpdateProgressWindowController()
        controller.render(nil)
        XCTAssertEqual(controller.stepRowCount, 0)
        XCTAssertEqual(controller.logText, "")
        XCTAssertEqual(controller.titleLabelText, "更新进度")
        XCTAssertEqual(controller.statusLabelText, "当前没有进行中的更新。")
        XCTAssertEqual(controller.progressBarFraction, 0)
    }

    /// 进度条只按已完成的阶段取值；成功收尾补满，不给成功会话留一截缺口。
    func testProgressBarTracksCompletedSteps() {
        let center = UpdateProgressCenter()
        center.begin(
            title: "更新",
            steps: [
                UpdateProgressStep(title: "一", state: .succeeded),
                UpdateProgressStep(title: "二", state: .running),
                UpdateProgressStep(title: "三", state: .pending),
                UpdateProgressStep(title: "四", state: .pending)
            ],
            now: referenceDate
        )
        let controller = UpdateProgressWindowController()
        controller.render(center.session)
        XCTAssertEqual(controller.progressBarFraction, 0.25)

        center.finish(.succeeded(version: "1.2.3"), now: referenceDate)
        controller.render(center.session)
        XCTAssertEqual(controller.progressBarFraction, 1)
    }

    /// 说明文字保留完整原因（供悬停提示），不被阶段行裁掉。
    func testStepRowKeepsFullDetailText() {
        let center = UpdateProgressCenter()
        center.begin(
            title: "更新",
            steps: [UpdateProgressStep(title: "执行安装", detail: "npm 安装失败", state: .failed)],
            now: referenceDate
        )
        let controller = UpdateProgressWindowController()
        controller.render(center.session)
        XCTAssertEqual(controller.stepTexts, ["✗|执行安装|npm 安装失败"])
    }
}
