import XCTest

/// 退出状态机的 unhosted 测试（GitHub #72）。
///
/// `Sources/QuitCoordinator.swift`、`Sources/QuitPolicy.swift` 与
/// `Sources/ServiceConfiguration.swift` 直接编译进本目标：三条路径、取消、重复
/// 触发、超时兜底、服务未运行与外部服务都在这里断言，不启动应用、不弹框、不碰
/// 真实进程与用户目录。
final class QuitCoordinatorTests: XCTestCase {
    private let baseDate = Date(timeIntervalSince1970: 1_700_000_000)

    private func later(_ seconds: TimeInterval) -> Date {
        baseDate.addingTimeInterval(seconds)
    }

    // MARK: - 三条路径

    /// 设置 =「每次退出时询问」：只弹确认框，不退出、不停止任何服务。
    func testConfiguredAskPresentsAlertWithoutTerminatingOrStopping() {
        var coordinator = QuitCoordinator()

        let transition = coordinator.handle(.configuredQuitRequested(
            behavior: .ask,
            service: .managedRunning,
            now: baseDate
        ))

        XCTAssertEqual(transition.effects, [.presentDecisionAlert])
        XCTAssertNil(transition.outcome)
        XCTAssertNil(transition.terminationReply, "用户发起的退出不在 AppKit 终止序列里，不需要回复")
        XCTAssertEqual(
            coordinator.phase,
            .waitingForUserDecision(deadline: later(QuitCoordinator.defaultDecisionTimeout), service: .managedRunning)
        )
        XCTAssertTrue(coordinator.isWaitingForUserDecision)
        XCTAssertFalse(coordinator.isTerminating)
    }

    /// 设置 =「退出但保持服务运行」：直接退出，不产生停止副作用。
    func testConfiguredKeepRunningTerminatesWithoutStoppingTheService() {
        var coordinator = QuitCoordinator()

        let transition = coordinator.handle(.configuredQuitRequested(
            behavior: .keepRunning,
            service: .managedRunning,
            now: baseDate
        ))

        XCTAssertEqual(transition.effects, [.terminateApplication])
        XCTAssertEqual(transition.outcome, .keepServiceRunning)
        XCTAssertTrue(coordinator.isTerminating)
        XCTAssertFalse(transition.effects.contains(.stopManagedService))
    }

    /// 设置 =「退出并停止服务」且托管服务在运行：先停服务，停止完成后才退出。
    func testConfiguredStopServiceStopsTheManagedServiceBeforeTerminating() {
        var coordinator = QuitCoordinator()

        let first = coordinator.handle(.configuredQuitRequested(
            behavior: .stopService,
            service: .managedRunning,
            now: baseDate
        ))
        XCTAssertEqual(first.effects, [.stopManagedService])
        XCTAssertTrue(coordinator.isStoppingManagedService)
        XCTAssertFalse(coordinator.isTerminating, "停止还没完成时不得退出")

        let second = coordinator.handle(.managedServiceStopFinished)
        XCTAssertEqual(second.effects, [.terminateApplication])
        XCTAssertEqual(second.outcome, .stopManagedService)
        XCTAssertTrue(coordinator.isTerminating)
    }

    /// 两个显式菜单项不受设置影响。
    func testExplicitMenuItemsBypassTheConfiguredBehaviour() {
        var keep = QuitCoordinator()
        let keepTransition = keep.handle(.keepServiceRunningQuitRequested(service: .managedRunning, now: baseDate))
        XCTAssertEqual(keepTransition.effects, [.terminateApplication])
        XCTAssertEqual(keepTransition.outcome, .keepServiceRunning)
        XCTAssertTrue(keep.isTerminating)

        var stop = QuitCoordinator()
        let stopTransition = stop.handle(.stopServiceQuitRequested(service: .managedRunning, now: baseDate))
        XCTAssertEqual(stopTransition.effects, [.stopManagedService])
        XCTAssertTrue(stop.isStoppingManagedService)
    }

    /// 用户选择「保持服务运行」：退出，不停止服务。
    func testChoosingKeepServiceRunningTerminatesWithoutStopping() {
        var coordinator = QuitCoordinator()
        _ = coordinator.handle(.configuredQuitRequested(behavior: .ask, service: .managedRunning, now: baseDate))

        let transition = coordinator.handle(.userChose(.keepServiceRunning))

        XCTAssertEqual(transition.effects, [.terminateApplication])
        XCTAssertEqual(transition.outcome, .keepServiceRunning)
        XCTAssertTrue(coordinator.isTerminating)
    }

    /// 用户选择「退出并停止服务」：先停托管服务，停止完成后退出。
    func testChoosingStopServiceStopsTheManagedServiceThenTerminates() {
        var coordinator = QuitCoordinator()
        _ = coordinator.handle(.configuredQuitRequested(behavior: .ask, service: .managedRunning, now: baseDate))

        let stop = coordinator.handle(.userChose(.stopService))
        XCTAssertEqual(stop.effects, [.stopManagedService])
        XCTAssertTrue(coordinator.isStoppingManagedService)

        let finished = coordinator.handle(.managedServiceStopFinished)
        XCTAssertEqual(finished.effects, [.terminateApplication])
        XCTAssertEqual(finished.outcome, .stopManagedService)
        XCTAssertTrue(coordinator.isTerminating)
    }

    // MARK: - 取消与重复触发

    /// 「取消」不退出、不停止任何服务，并回到 idle；之后可以正常再次退出。
    func testCancelReturnsToIdleAndTheAppCanQuitAgainLater() {
        var coordinator = QuitCoordinator()
        _ = coordinator.handle(.configuredQuitRequested(behavior: .ask, service: .managedRunning, now: baseDate))

        let cancel = coordinator.handle(.userChose(.cancel))

        XCTAssertEqual(cancel.effects, [])
        XCTAssertEqual(cancel.outcome, .cancelled)
        XCTAssertTrue(coordinator.isIdle, "取消后不能残留 pending 状态")
        XCTAssertFalse(coordinator.isTerminating)
        XCTAssertFalse(coordinator.isWaitingForUserDecision)

        // 再次 ⌘Q：重新走一遍完整决策，不叠加、不残留。
        let request = coordinator.handle(.configuredQuitRequested(behavior: .ask, service: .managedRunning, now: baseDate))
        XCTAssertEqual(request.effects, [.presentDecisionAlert])
        let keep = coordinator.handle(.userChose(.keepServiceRunning))
        XCTAssertEqual(keep.effects, [.terminateApplication])
        XCTAssertTrue(coordinator.isTerminating)
    }

    /// 等待决策期间重复触发：不叠加第二个确认框，也不产生停止副作用。
    func testRepeatedRequestsWhileWaitingDoNotStackAlerts() {
        var coordinator = QuitCoordinator()
        _ = coordinator.handle(.configuredQuitRequested(behavior: .ask, service: .managedRunning, now: baseDate))

        let second = coordinator.handle(.configuredQuitRequested(behavior: .ask, service: .managedRunning, now: later(10)))
        XCTAssertEqual(second.effects, [])
        XCTAssertEqual(second.phase, coordinator.phase)

        let third = coordinator.handle(.keepServiceRunningQuitRequested(service: .managedRunning, now: later(10)))
        XCTAssertEqual(third.effects, [], "显式菜单项也不能在等待期间绕开已有决策")
    }

    /// 停止服务期间重复触发：不会重复停服务。
    func testRepeatedRequestsWhileStoppingDoNotStopTwice() {
        var coordinator = QuitCoordinator()
        _ = coordinator.handle(.configuredQuitRequested(behavior: .stopService, service: .managedRunning, now: baseDate))

        let second = coordinator.handle(.configuredQuitRequested(behavior: .stopService, service: .managedRunning, now: later(1)))
        XCTAssertEqual(second.effects, [])

        let finished = coordinator.handle(.managedServiceStopFinished)
        XCTAssertEqual(finished.effects, [.terminateApplication])
    }

    /// 取消之后迟到的按钮回调、重复的取消、迟到的停止回调都只被忽略。
    func testStaleCallbacksAreIgnored() {
        var coordinator = QuitCoordinator()
        _ = coordinator.handle(.configuredQuitRequested(behavior: .ask, service: .managedRunning, now: baseDate))
        _ = coordinator.handle(.userChose(.cancel))

        XCTAssertEqual(coordinator.handle(.userChose(.stopService)).effects, [])
        XCTAssertEqual(coordinator.handle(.userChose(.cancel)).effects, [])
        XCTAssertEqual(coordinator.handle(.managedServiceStopFinished).effects, [])
        XCTAssertEqual(coordinator.handle(.deadlineReached(now: later(10_000))).effects, [])
        XCTAssertTrue(coordinator.isIdle)
    }

    /// 停止完成之后重复的完成回调不会再退出一次。
    func testRepeatedStopFinishedCallbacksAreIgnored() {
        var coordinator = QuitCoordinator()
        _ = coordinator.handle(.configuredQuitRequested(behavior: .stopService, service: .managedRunning, now: baseDate))

        let finished = coordinator.handle(.managedServiceStopFinished)
        XCTAssertEqual(finished.effects, [.terminateApplication])

        let repeated = coordinator.handle(.managedServiceStopFinished)
        XCTAssertEqual(repeated.effects, [])
        XCTAssertTrue(coordinator.isTerminating)
    }

    // MARK: - 超时兜底

    func testDefaultTimeoutIsFiveMinutes() {
        XCTAssertEqual(QuitCoordinator.defaultDecisionTimeout, 300)
    }

    func testInjectedTimeoutControlsTheDeadline() {
        var coordinator = QuitCoordinator(decisionTimeout: 30)

        _ = coordinator.handle(.configuredQuitRequested(behavior: .ask, service: .managedRunning, now: baseDate))

        XCTAssertEqual(
            coordinator.phase,
            .waitingForUserDecision(deadline: later(30), service: .managedRunning)
        )
    }

    func testDeadlineBeforeTheLimitKeepsWaiting() {
        var coordinator = QuitCoordinator(decisionTimeout: 30)
        _ = coordinator.handle(.configuredQuitRequested(behavior: .ask, service: .managedRunning, now: baseDate))

        let early = coordinator.handle(.deadlineReached(now: later(29)))
        XCTAssertEqual(early.effects, [])
        XCTAssertTrue(coordinator.isWaitingForUserDecision)
    }

    /// 超时按最安全行为处理：保持服务运行并退出，绝不停止托管服务。
    func testDeadlineKeepsTheServiceRunningAndTerminates() {
        var coordinator = QuitCoordinator(decisionTimeout: 30)
        _ = coordinator.handle(.configuredQuitRequested(behavior: .ask, service: .managedRunning, now: baseDate))

        let timeout = coordinator.handle(.deadlineReached(now: later(30)))

        XCTAssertEqual(timeout.effects, [.terminateApplication])
        XCTAssertEqual(timeout.outcome, .decisionTimedOutKeepingServiceRunning)
        XCTAssertFalse(timeout.effects.contains(.stopManagedService))
        XCTAssertTrue(coordinator.isTerminating)
    }

    /// 超时之后迟到的用户选择不再改变状态。
    func testUserChoiceAfterTimeoutIsIgnored() {
        var coordinator = QuitCoordinator(decisionTimeout: 30)
        _ = coordinator.handle(.configuredQuitRequested(behavior: .ask, service: .managedRunning, now: baseDate))
        _ = coordinator.handle(.deadlineReached(now: later(30)))

        XCTAssertEqual(coordinator.handle(.userChose(.cancel)).effects, [])
        XCTAssertEqual(coordinator.handle(.userChose(.stopService)).effects, [])
        XCTAssertTrue(coordinator.isTerminating)
    }

    // MARK: - 服务未运行 / 外部服务

    /// 没有服务在运行时，「停止服务」等同于保持运行：直接退出，不产生停止副作用。
    func testStopServiceBehaviorWithoutARunningServiceTerminatesImmediately() {
        var coordinator = QuitCoordinator()

        let transition = coordinator.handle(.configuredQuitRequested(
            behavior: .stopService,
            service: .notRunning,
            now: baseDate
        ))

        XCTAssertEqual(transition.effects, [.terminateApplication])
        XCTAssertEqual(transition.outcome, .stopManagedService)
        XCTAssertTrue(coordinator.isTerminating)
    }

    /// 外部服务（不是本应用启动的）：任何行为、任何选择都不会产生停止副作用。
    func testExternalServiceIsNeverStopped() {
        for behavior in ServiceConfiguration.QuitBehavior.allCases {
            var coordinator = QuitCoordinator()
            let request = coordinator.handle(.configuredQuitRequested(
                behavior: behavior,
                service: .externalRunning,
                now: baseDate
            ))
            XCTAssertFalse(request.effects.contains(.stopManagedService), "\(behavior) 不应停止外部服务")

            if coordinator.isWaitingForUserDecision {
                let stopChoice = coordinator.handle(.userChose(.stopService))
                XCTAssertEqual(stopChoice.effects, [.terminateApplication])
                XCTAssertFalse(stopChoice.effects.contains(.stopManagedService))
                XCTAssertEqual(stopChoice.outcome, .stopManagedService)
            }
            XCTAssertTrue(coordinator.isTerminating)
        }
    }

    /// 只区分托管与外部：外部服务不会让 `isManagedServiceRunning` 为真。
    func testOnlyManagedServicesCountAsStoppable() {
        XCTAssertTrue(QuitServiceState.managedRunning.isManagedServiceRunning)
        XCTAssertFalse(QuitServiceState.externalRunning.isManagedServiceRunning)
        XCTAssertFalse(QuitServiceState.notRunning.isManagedServiceRunning)
    }

    /// 用户选择“退出并停止服务”但只有外部服务在跑：不发信号，直接退出。
    func testStopChoiceWithExternalServiceTerminatesWithoutStopping() {
        var coordinator = QuitCoordinator()
        _ = coordinator.handle(.configuredQuitRequested(behavior: .ask, service: .externalRunning, now: baseDate))

        let stop = coordinator.handle(.userChose(.stopService))

        XCTAssertEqual(stop.effects, [.terminateApplication])
        XCTAssertFalse(stop.effects.contains(.stopManagedService))
        XCTAssertEqual(stop.outcome, .stopManagedService)
        XCTAssertTrue(coordinator.isTerminating)
    }

    // MARK: - AppKit 终止序列

    /// Dock 退出 / 注销 / 关机，设置 =「保持服务运行」：立即 `terminateNow`，
    /// 且不再由状态机自己发起一次 terminate。
    func testAppKitTerminationWithKeepRunningRepliesTerminateNow() {
        var coordinator = QuitCoordinator()

        let transition = coordinator.handle(.appKitTerminationRequested(
            behavior: .keepRunning,
            service: .managedRunning,
            now: baseDate
        ))

        XCTAssertEqual(transition.terminationReply, .terminateNow)
        XCTAssertEqual(transition.effects, [], "AppKit 已经要退出了，不能再自己发起一次 terminate")
        XCTAssertTrue(coordinator.isTerminating)
    }

    /// 设置 =「每次询问」：取消这次终止序列并弹确认框；决策完成后重新发起退出。
    func testAppKitTerminationWithAskCancelsAndPresentsTheAlert() {
        var coordinator = QuitCoordinator()

        let transition = coordinator.handle(.appKitTerminationRequested(
            behavior: .ask,
            service: .managedRunning,
            now: baseDate
        ))

        XCTAssertEqual(transition.terminationReply, .cancelPendingDecision)
        XCTAssertEqual(transition.effects, [.presentDecisionAlert])

        let keep = coordinator.handle(.userChose(.keepServiceRunning))
        XCTAssertEqual(keep.effects, [.terminateApplication])

        let second = coordinator.handle(.appKitTerminationRequested(
            behavior: .ask,
            service: .managedRunning,
            now: later(1)
        ))
        XCTAssertEqual(second.terminationReply, .terminateNow)
        XCTAssertEqual(second.effects, [])
    }

    /// 设置 =「退出并停止服务」：先取消终止序列停服务，停止完成后重新发起退出。
    func testAppKitTerminationWithStopServiceCancelsUntilTheStopFinishes() {
        var coordinator = QuitCoordinator()

        let transition = coordinator.handle(.appKitTerminationRequested(
            behavior: .stopService,
            service: .managedRunning,
            now: baseDate
        ))
        XCTAssertEqual(transition.terminationReply, .cancelPendingDecision)
        XCTAssertEqual(transition.effects, [.stopManagedService])

        let finished = coordinator.handle(.managedServiceStopFinished)
        XCTAssertEqual(finished.effects, [.terminateApplication])

        let second = coordinator.handle(.appKitTerminationRequested(
            behavior: .stopService,
            service: .managedRunning,
            now: later(2)
        ))
        XCTAssertEqual(second.terminationReply, .terminateNow)
        XCTAssertEqual(second.effects, [])
    }

    /// 设置 =「退出并停止服务」但没有托管服务：立即 `terminateNow`。
    func testAppKitTerminationWithStopServiceAndNoManagedServiceRepliesTerminateNow() {
        var coordinator = QuitCoordinator()

        let transition = coordinator.handle(.appKitTerminationRequested(
            behavior: .stopService,
            service: .notRunning,
            now: baseDate
        ))

        XCTAssertEqual(transition.terminationReply, .terminateNow)
        XCTAssertEqual(transition.effects, [])
        XCTAssertTrue(coordinator.isTerminating)
    }

    /// 等待用户决策或等待停止完成期间，AppKit 再次请求终止：只取消，不叠加。
    func testAppKitTerminationWhileWaitingDoesNotStack() {
        var waiting = QuitCoordinator()
        _ = waiting.handle(.configuredQuitRequested(behavior: .ask, service: .managedRunning, now: baseDate))
        let duringWait = waiting.handle(.appKitTerminationRequested(
            behavior: .ask,
            service: .managedRunning,
            now: later(1)
        ))
        XCTAssertEqual(duringWait.terminationReply, .cancelPendingDecision)
        XCTAssertEqual(duringWait.effects, [], "不能叠加第二个确认框")

        var stopping = QuitCoordinator()
        _ = stopping.handle(.configuredQuitRequested(behavior: .stopService, service: .managedRunning, now: baseDate))
        let duringStop = stopping.handle(.appKitTerminationRequested(
            behavior: .stopService,
            service: .managedRunning,
            now: later(1)
        ))
        XCTAssertEqual(duringStop.terminationReply, .cancelPendingDecision)
        XCTAssertEqual(duringStop.effects, [], "不能重复停服务")
    }

    /// `.terminateNow` 时不带 `.terminateApplication` 副作用（AppKit 自己完成退出）；
    /// `.cancelPendingDecision` 时副作用只可能是弹框或停托管服务。
    func testReplyAndEffectsStayConsistent() {
        var coordinator = QuitCoordinator()
        let terminateNow = coordinator.handle(.appKitTerminationRequested(
            behavior: .keepRunning,
            service: .managedRunning,
            now: baseDate
        ))
        XCTAssertEqual(terminateNow.terminationReply, .terminateNow)
        XCTAssertFalse(terminateNow.effects.contains(.terminateApplication))

        var asking = QuitCoordinator()
        let cancel = asking.handle(.appKitTerminationRequested(
            behavior: .ask,
            service: .managedRunning,
            now: baseDate
        ))
        XCTAssertEqual(cancel.terminationReply, .cancelPendingDecision)
        XCTAssertTrue(cancel.effects.allSatisfy { $0 == .presentDecisionAlert || $0 == .stopManagedService })
    }

    /// 已经决定直接退出（单实例锁失败）：不再询问，直接退出。
    func testDirectQuitSkipsTheDecision() {
        var coordinator = QuitCoordinator()

        let direct = coordinator.handle(.directQuitRequested)
        XCTAssertEqual(direct.effects, [.terminateApplication])
        XCTAssertTrue(coordinator.isTerminating)

        let appKit = coordinator.handle(.appKitTerminationRequested(
            behavior: .ask,
            service: .managedRunning,
            now: baseDate
        ))
        XCTAssertEqual(appKit.terminationReply, .terminateNow)
        XCTAssertEqual(appKit.effects, [])
    }

    /// 决策完成后（保持运行）再收到 AppKit 终止请求：直接放行。
    func testAppKitTerminationAfterCancelIsAFreshDecision() {
        var coordinator = QuitCoordinator()
        _ = coordinator.handle(.appKitTerminationRequested(behavior: .ask, service: .managedRunning, now: baseDate))
        _ = coordinator.handle(.userChose(.cancel))
        XCTAssertTrue(coordinator.isIdle)

        let second = coordinator.handle(.appKitTerminationRequested(
            behavior: .ask,
            service: .managedRunning,
            now: later(5)
        ))
        XCTAssertEqual(second.terminationReply, .cancelPendingDecision)
        XCTAssertEqual(second.effects, [.presentDecisionAlert])
    }
}
