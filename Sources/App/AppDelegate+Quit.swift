/// Application termination: pending work confirmation, service teardown and exit.

import Cocoa

extension AppDelegate {
    // MARK: - 退出（GitHub #72）

    /// AppKit 终止序列入口：Dock 退出、注销/关机，或其他进程调用 `terminate:`。
    ///
    /// 只返回两种立即回复：`.terminateNow`（决策已完成、服务处置已落地）或
    /// `.terminateCancel`（需要询问用户或先停止托管服务，异步流程完成后重新发起
    /// `NSApp.terminate(nil)`）。**从不**返回 `.terminateLater`，因此不存在
    /// “漏掉 `reply(toApplicationShouldTerminate:)`”而让终止序列永久悬空的路径；
    /// 等待期间主队列也不再停在 AppKit 的终止等待循环里。
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let transition = quitCoordinator.handle(.appKitTerminationRequested(
            behavior: serviceManager.configuration.quitBehavior,
            service: currentQuitServiceState(),
            now: Date()
        ))
        logQuitOutcome(transition.outcome)
        applyQuitEffects(transition.effects)
        switch transition.terminationReply {
        case .terminateNow:
            return .terminateNow
        case .cancelPendingDecision, .none:
            return .terminateCancel
        }
    }

    /// 当前服务状态（退出状态机输入）。所有权记录是本应用唯一的管理凭据：只有能
    /// 通过 `ServiceOwnershipVerifier` 校验的记录才算托管服务，其余一律按外部服务
    /// 处理，退出流程不会向它发信号。
    func currentQuitServiceState() -> QuitServiceState {
        if serviceManager.managedServicePID() != nil { return .managedRunning }
        switch currentState {
        case .running, .starting: return .externalRunning
        case .checking, .stopped, .failed: return .notRunning
        }
    }

    /// 处理一个退出事件：状态机给出副作用，这里只负责执行与记录。
    func handleQuitEvent(_ event: QuitEvent) {
        let transition = quitCoordinator.handle(event)
        logQuitOutcome(transition.outcome)
        applyQuitEffects(transition.effects)
    }

    private func applyQuitEffects(_ effects: [QuitEffect]) {
        for effect in effects {
            switch effect {
            case .presentDecisionAlert:
                presentQuitDecisionAlert()
            case .stopManagedService:
                // 异步等待停止完成（不嵌套 RunLoop、不在等待期间停住主队列）；
                // 完成回调只回报事件，由状态机决定下一步。
                serviceManager.stopManagedServiceOnQuit { [weak self] in
                    self?.handleQuitEvent(.managedServiceStopFinished)
                }
            case .terminateApplication:
                finishQuit()
            }
        }
    }

    /// 决策完成后的最后一步：进入“正在退出”状态，并**异步**重新发起终止序列。
    ///
    /// 异步是 AppKit 契约要求：这一步可能来自确认框的 sheet 回调或
    /// `stopManagedServiceOnQuit` 的同步完成回调，同步调用 `NSApp.terminate(nil)`
    /// 会在 AppKit 回调栈里重入终止序列（W4 M4）。
    private func finishQuit() {
        // 停止服务的路径已经由 `stopManagedServiceOnQuit` → `beginQuitting()` 进入
        // 退出状态；保持运行的路径在这里进入退出状态并关闭日志句柄，子进程与
        // service-owner.json 都保留。
        if !serviceManager.isQuitting { serviceManager.keepRunningOnQuit() }
        DispatchQueue.main.async { NSApp.terminate(nil) }
    }

    /// “退出时是否保持服务运行”确认框。等待用户选择的上限由状态机注入，超时后
    /// 按最安全行为处理（保持服务运行并退出）。
    private func presentQuitDecisionAlert() {
        quitDecisionTimer?.invalidate()
        let timer = Timer(timeInterval: quitCoordinator.decisionTimeout, repeats: false) { [weak self] _ in
            self?.handleQuitEvent(.deadlineReached(now: Date()))
        }
        // 加进 common modes：sheet 期间主运行循环跑在 modal panel 模式，只挂在默认
        // 模式上的计时器在那段时间不会触发。
        RunLoop.main.add(timer, forMode: .common)
        quitDecisionTimer = timer

        let alert = NSAlert()
        alert.messageText = "退出 Pi Web"
        alert.informativeText = "是否在退出应用后继续保持 Pi Web 服务运行？"
        alert.addButton(withTitle: "保持服务运行")
        alert.addButton(withTitle: "退出并停止服务")
        alert.addButton(withTitle: "取消")
        let decide: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard let self else { return }
            self.quitDecisionTimer?.invalidate()
            self.quitDecisionTimer = nil
            let confirmation: QuitConfirmation
            switch response {
            case .alertFirstButtonReturn: confirmation = .keepServiceRunning
            case .alertSecondButtonReturn: confirmation = .stopService
            default: confirmation = .cancel
            }
            self.handleQuitEvent(.userChose(confirmation))
        }
        // W4 L5：⌘W 只是 `orderOut` 隐藏窗口；在不可见窗口上挂 sheet 会让 AppKit
        // 把这个窗口重新显示出来（“刚隐藏的窗口自己回来了”，与用户状态不一致）。
        // 因此窗口不可见时改用应用级模态（`runModal`），窗口保持隐藏。
        if window.isVisible {
            alert.beginSheetModal(for: window, completionHandler: decide)
        } else {
            NSApp.activate(ignoringOtherApps: true)
            decide(alert.runModal())
        }
    }

    private func logQuitOutcome(_ outcome: QuitDecisionOutcome?) {
        guard let outcome else { return }
        switch outcome {
        case .keepServiceRunning:
            logQuitDecision("退出：保持服务运行（不发信号，保留 service-owner.json）")
        case .stopManagedService:
            logQuitDecision("退出：停止通过所有权校验的托管服务")
        case .cancelled:
            logQuitDecision("退出已取消：应用继续运行")
        case .decisionTimedOutKeepingServiceRunning:
            logQuitDecision("退出确认等待超过 \(Int(quitCoordinator.decisionTimeout)) 秒：按最安全行为保持服务运行并退出")
        }
    }

    private func logQuitDecision(_ message: String) {
        _ = logWriter.append(logRedactor.redact(message))
    }

    func acquireSingleInstanceLock() -> Bool {
        let existingPID = (try? String(contentsOf: appConfiguration.appPIDURL, encoding: .utf8))
            .flatMap { ProcessInspector.parsePIDRecord($0) }
        if let existingPID, processInspector.isProcessAlive(existingPID) {
            return false
        }
        if FileManager.default.fileExists(atPath: appConfiguration.instanceLockURL.path) {
            try? FileManager.default.removeItem(at: appConfiguration.instanceLockURL)
        }
        FileManager.default.createFile(atPath: appConfiguration.instanceLockURL.path, contents: nil)
        do {
            instanceLockHandle = try FileHandle(forWritingTo: appConfiguration.instanceLockURL)
            hasInstanceLock = true
            return true
        } catch {
            return false
        }
    }

    func installQuitShortcuts() {
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard modifiers.contains(.command) else { return event }

            switch event.charactersIgnoringModifiers?.lowercased() {
            case ",":
                self?.showPreferences(nil)
                return nil
            case "r" where modifiers.contains(.shift):
                self?.hardReloadPage(nil)
                return nil
            case "r":
                self?.reloadPage(nil)
                return nil
            case "f" where modifiers.contains(.control):
                self?.toggleFullScreen(nil)
                return nil
            default:
                return event
            }
        }
    }

    func installScreenChangeObserver() {
        screenParametersObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // 屏幕旋转/分辨率变化时，windowDidChangeScreen 不一定会发送；
            // 等 AppKit 更新 NSScreen.visibleFrame 后再重新布局。
            self?.scheduleWindowFit()
        }
    }

    func scheduleWindowFit() {
        screenFitWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.screenFitWorkItem = nil
            self.fitWindowToCurrentScreen()
        }
        screenFitWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: workItem)
    }
}
