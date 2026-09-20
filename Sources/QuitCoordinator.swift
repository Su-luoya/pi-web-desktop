import Foundation

/// 一次退出请求看到的服务状态（GitHub #72，纯逻辑）。
///
/// 只区分“本应用启动、并通过 `ServiceOwnershipVerifier` 校验的托管服务”和
/// “其他来源的外部服务”。退出状态机只可能请求停止前者：外部服务（用户手动启动、
/// 上一次运行留下、任何校验失败的进程）在任何退出行为下都不发信号。
enum QuitServiceState: Equatable {
    case notRunning
    case managedRunning
    case externalRunning

    /// 只有可验证的托管服务能被退出流程停止。
    var isManagedServiceRunning: Bool { self == .managedRunning }
}

/// 退出状态机请求执行的副作用；由 `AppDelegate` 实现，状态机本身不碰 AppKit。
enum QuitEffect: Equatable {
    /// 弹出“退出时是否保持服务运行”确认框，等待用户选择或超时。
    case presentDecisionAlert
    /// 停止通过所有权校验的托管服务；完成后回报
    /// `QuitEvent.managedServiceStopFinished`。
    case stopManagedService
    /// 决策已完成、服务处置已落地：重新进入 AppKit 终止序列退出应用。
    case terminateApplication
}

/// 状态机对 AppKit 终止序列的同步回复（GitHub #72）。
///
/// 只有两种取值，而且都是立即回复：状态机从不要求 `.terminateLater`，因此不存在
/// “等待回复期间主队列不排水 / 从未调用 `reply(toApplicationShouldTerminate:)`”
/// 这条让应用无法退出的路径。
enum QuitTerminationReply: Equatable {
    /// 决策已完成且服务处置已落地：让 AppKit 继续终止序列。
    case terminateNow
    /// 取消本次终止序列。等待用户决策或等待托管服务停止；流程完成后由状态机产生
    /// `.terminateApplication` 重新发起退出，用户取消则不再发起。
    case cancelPendingDecision
}

/// 一次转换的语义结果，用于日志与测试。
enum QuitDecisionOutcome: Equatable {
    case keepServiceRunning
    case stopManagedService
    case cancelled
    /// 等待用户决策超时：按最安全行为处理——保持服务运行并退出。
    case decisionTimedOutKeepingServiceRunning
}

/// 退出状态机的输入事件（GitHub #72）。
enum QuitEvent: Equatable {
    /// ⌘Q 与菜单“退出 Pi Web Desktop”：按设置里的退出行为。
    case configuredQuitRequested(behavior: ServiceConfiguration.QuitBehavior, service: QuitServiceState, now: Date)
    /// 显式菜单项“退出 Pi Web Desktop（保持服务运行）”：不受设置影响。
    case keepServiceRunningQuitRequested(service: QuitServiceState, now: Date)
    /// 显式菜单项“退出 Pi Web Desktop（停止服务）”：不受设置影响。
    case stopServiceQuitRequested(service: QuitServiceState, now: Date)
    /// AppKit 终止序列入口：Dock 退出、注销/关机，或其他进程调用 `terminate:`。
    case appKitTerminationRequested(behavior: ServiceConfiguration.QuitBehavior, service: QuitServiceState, now: Date)
    /// 已经决定直接退出（例如启动时拿不到单实例锁）：不再询问，也不停止服务。
    case directQuitRequested
    /// 用户在确认框里的选择。
    case userChose(QuitConfirmation)
    /// 等待用户决策达到上限。
    case deadlineReached(now: Date)
    /// 托管服务已停止（`ServiceManager.stopManagedServiceOnQuit` 的完成回调）。
    case managedServiceStopFinished
}

/// 退出状态机（GitHub #72）：纯逻辑、可注入超时，不依赖 AppKit、时钟或真实进程。
///
/// 设计取舍：把“退出决策”移出 AppKit 终止序列。菜单/⌘Q 先按设置弹普通 alert，
/// 决策完成后才调用 `NSApp.terminate(nil)`；`applicationShouldTerminate` 只回答
/// `.terminateNow`（已决策）或 `.terminateCancel`（未决策，异步流程随后重新发起
/// 退出）。这样：
///
/// - 从不返回 `.terminateLater`，不需要 `reply(toApplicationShouldTerminate:)`，
///   也就不存在“漏掉回复导致终止序列永久悬空”的路径；
/// - 不在确认框回调或停止回调里重入 `NSApp.terminate(nil)`（W4 M4）；
/// - 等待用户决策、等待托管服务停止期间主队列照常排水（不在终止序列的等待循环
///   里，也不做嵌套 RunLoop 等待）；
/// - 等待用户决策有上限（默认 5 分钟），超时按最安全行为处理：保持服务运行并退出，
///   避免注销/关机被无限挂起；
/// - 取消后回到 `.idle` 且计时器失效，应用可以继续使用并在之后正常再次退出。
struct QuitCoordinator: Equatable {
    enum Phase: Equatable {
        /// 没有进行中的退出流程；应用可继续使用。
        case idle
        /// 已弹确认框，等待用户选择或超时。
        case waitingForUserDecision(deadline: Date, service: QuitServiceState)
        /// 正在停止托管服务；停止完成后退出。
        case stoppingManagedService
        /// 决策已完成：服务按处置落地（停止已完成 / 保持运行），下一次终止请求
        /// 直接得到 `.terminateNow`。
        case terminating
    }

    /// 等待用户决策的上限；超过后按最安全行为处理（保持服务运行并退出）。生产
    /// 为 5 分钟，测试注入短值，避免注销/关机时无限挂起。
    static let defaultDecisionTimeout: TimeInterval = 5 * 60

    struct Transition: Equatable {
        var phase: Phase
        var effects: [QuitEffect] = []
        /// 仅 AppKit 终止序列入口有值：需要立刻回复的终止结论。
        var terminationReply: QuitTerminationReply?
        var outcome: QuitDecisionOutcome?
    }

    private(set) var phase: Phase = .idle

    /// 等待用户决策的上限（秒）。
    let decisionTimeout: TimeInterval

    init(decisionTimeout: TimeInterval = QuitCoordinator.defaultDecisionTimeout) {
        self.decisionTimeout = decisionTimeout
    }

    var isIdle: Bool { phase == .idle }
    var isWaitingForUserDecision: Bool {
        if case .waitingForUserDecision = phase { return true }
        return false
    }
    var isStoppingManagedService: Bool { phase == .stoppingManagedService }
    /// 决策已完成：退出已获批准（服务处置也已落地）。
    var isTerminating: Bool { phase == .terminating }

    // MARK: - 事件入口

    /// 处理一个退出事件，返回需要执行的副作用与（AppKit 入口的）同步回复。
    @discardableResult
    mutating func handle(_ event: QuitEvent) -> Transition {
        switch event {
        case let .configuredQuitRequested(behavior, service, now):
            if let ongoing = userRequestTransition() { return ongoing }
            let plan = QuitPlan.plan(for: behavior)
            if plan.requiresUserConfirmation {
                return beginWaitingForUserDecision(service: service, now: now)
            }
            return settle(disposition: plan.serviceDisposition, service: service, includeTerminateEffect: true)

        case let .keepServiceRunningQuitRequested(service, _):
            if let ongoing = userRequestTransition() { return ongoing }
            return settle(disposition: .keepRunning, service: service, includeTerminateEffect: true)

        case let .stopServiceQuitRequested(service, _):
            if let ongoing = userRequestTransition() { return ongoing }
            return settle(disposition: .stopManagedService, service: service, includeTerminateEffect: true)

        case let .appKitTerminationRequested(behavior, service, now):
            return appKitTermination(behavior: behavior, service: service, now: now)

        case .directQuitRequested:
            phase = .terminating
            return Transition(phase: phase, effects: [.terminateApplication])

        case let .userChose(confirmation):
            return userChose(confirmation)

        case let .deadlineReached(now):
            return deadlineReached(now: now)

        case .managedServiceStopFinished:
            return managedServiceStopFinished()
        }
    }

    // MARK: - 转换

    /// 菜单/⌘Q 这类用户入口的重复触发防护：一次只跑一个退出流程。
    ///
    /// - `.terminating`：已决策，再给一次 `.terminateApplication`（幂等，避免之前
    ///   派发的退出被丢掉）；
    /// - `.waitingForUserDecision` / `.stoppingManagedService`：什么都不做，不叠加
    ///   第二个确认框、不重复停服务。
    private func userRequestTransition() -> Transition? {
        switch phase {
        case .idle:
            return nil
        case .terminating:
            return Transition(phase: phase, effects: [.terminateApplication])
        case .waitingForUserDecision, .stoppingManagedService:
            return Transition(phase: phase, effects: [])
        }
    }

    /// AppKit 终止序列入口。回复只有 `.terminateNow` / `.cancelPendingDecision`，
    /// 且都不需要 `reply(toApplicationShouldTerminate:)`。
    private mutating func appKitTermination(behavior: ServiceConfiguration.QuitBehavior,
                                            service: QuitServiceState,
                                            now: Date) -> Transition {
        switch phase {
        case .terminating:
            return Transition(phase: phase, effects: [], terminationReply: .terminateNow)
        case .waitingForUserDecision, .stoppingManagedService:
            // 已有一次退出流程在跑：不叠加确认框、不重复停服务；取消这次终止序列，
            // 流程完成时会重新发起 terminate。
            return Transition(phase: phase, effects: [], terminationReply: .cancelPendingDecision)
        case .idle:
            break
        }

        let plan = QuitPlan.plan(for: behavior)
        if plan.requiresUserConfirmation {
            phase = .waitingForUserDecision(deadline: now.addingTimeInterval(decisionTimeout), service: service)
            return Transition(phase: phase,
                              effects: [.presentDecisionAlert],
                              terminationReply: .cancelPendingDecision)
        }

        let transition = settle(disposition: plan.serviceDisposition, service: service, includeTerminateEffect: false)
        if phase == .terminating {
            // 决策立刻完成：由 AppKit 完成退出，不再自己发起一次 terminate。
            return Transition(phase: phase, effects: [], terminationReply: .terminateNow, outcome: transition.outcome)
        }
        return Transition(phase: phase,
                          effects: transition.effects,
                          terminationReply: .cancelPendingDecision,
                          outcome: transition.outcome)
    }

    /// 开始等待用户决策。
    private mutating func beginWaitingForUserDecision(service: QuitServiceState, now: Date) -> Transition {
        phase = .waitingForUserDecision(deadline: now.addingTimeInterval(decisionTimeout), service: service)
        return Transition(phase: phase, effects: [.presentDecisionAlert])
    }

    /// 落地一个已定好的服务处置。
    private mutating func settle(disposition: QuitPlan.ServiceDisposition,
                                 service: QuitServiceState,
                                 includeTerminateEffect: Bool) -> Transition {
        if disposition == .stopManagedService && service.isManagedServiceRunning {
            phase = .stoppingManagedService
            return Transition(phase: phase, effects: [.stopManagedService])
        }
        // 没有可验证的托管服务（含外部服务）时，“停止服务”等同于保持运行：
        // 状态机从不产生停止外部服务的副作用。
        phase = .terminating
        return Transition(
            phase: phase,
            effects: includeTerminateEffect ? [.terminateApplication] : [],
            outcome: disposition == .stopManagedService ? .stopManagedService : .keepServiceRunning
        )
    }

    private mutating func userChose(_ confirmation: QuitConfirmation) -> Transition {
        guard case let .waitingForUserDecision(_, service) = phase else {
            // 过期回调（取消后迟到的按钮、超时已兜底后才点击）：忽略，不叠加状态。
            return Transition(phase: phase, effects: [])
        }
        let plan = QuitPlan.plan(for: confirmation)
        switch plan.nextStep {
        case .stayOpen:
            phase = .idle
            return Transition(phase: phase, effects: [], outcome: .cancelled)
        case .askUser:
            return Transition(phase: phase, effects: [])
        case .terminate:
            return settle(disposition: plan.serviceDisposition, service: service, includeTerminateEffect: true)
        }
    }

    private mutating func deadlineReached(now: Date) -> Transition {
        guard case let .waitingForUserDecision(deadline, service) = phase else {
            return Transition(phase: phase, effects: [])
        }
        guard now >= deadline else {
            // 计时器提前触发：继续等待。
            return Transition(phase: phase, effects: [])
        }
        // 超时兜底：保持服务运行并退出。最安全的行为是不发信号、不删所有权记录。
        let transition = settle(disposition: .keepRunning, service: service, includeTerminateEffect: true)
        return Transition(phase: transition.phase,
                          effects: transition.effects,
                          outcome: .decisionTimedOutKeepingServiceRunning)
    }

    private mutating func managedServiceStopFinished() -> Transition {
        guard phase == .stoppingManagedService else {
            // 重复或迟到的停止回调：不重复退出，也不残留状态。
            return Transition(phase: phase, effects: [])
        }
        phase = .terminating
        return Transition(phase: phase, effects: [.terminateApplication], outcome: .stopManagedService)
    }
}
