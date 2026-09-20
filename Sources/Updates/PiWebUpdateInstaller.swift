/// Restricted npm install execution and run outcomes for Pi Web.

import Darwin
import Foundation

/// 生产安装器：`posix_spawn` + 参数数组，没有 shell、没有 `sudo`。
///
/// - 可执行文件、参数数组、环境都来自 `PiWebUpdateInstallPlan`；
/// - 子进程是一个**新的独立进程组**（组 id = 子进程 pid），npm 自己派生的子进程
///   因此也在这个组里；
/// - stdin 为 `/dev/null`，stdout/stderr 合并进一个管道并只保留有界末尾片段；
/// - 超时/取消只对**本次启动的**子进程组发送一次终止信号（尽力而为），随后按
///   失败结束，并写一条「已放弃」记录（结束时间未知、派生进程是否结束未确认）；
/// - 无法建立独立进程组时降级为“只放弃等待 + 记录未确认”，不发送任何信号；
/// - 任何失败都只返回结果，不抛出、不崩溃。
final class ProcessPiWebUpdateInstaller: PiWebUpdateInstalling {
    /// 保留的子进程输出上限（字符）。
    static let outputTailLimit = 2000
    /// 进程退出后等待输出管道 EOF 的有界宽限；防止退出通知抢在最后一块输出前收尾。
    static let defaultPipeDrainGrace: TimeInterval = 0.5

    private let stateQueue = DispatchQueue(label: "io.github.su-luoya.pi-web-desktop.pi-web-update-installer")
    private let waitQueue = DispatchQueue.global(qos: .utility)
    private let clock: () -> Date
    private let spawner: PiWebUpdateChildSpawning
    private let redact: (String) -> String
    private let recordAbandonedAttempt: (UpdateAbandonedAttempt) -> Void
    private let pipeDrainGrace: TimeInterval

    /// 结果投递队列：`completion` 不在 `stateQueue` 上执行，回调里的长耗时工作
    /// （例如重新检测版本）就不会把 `cancel()` 排在后面（W2A A-5）。
    private let deliveryQueue = DispatchQueue.global(qos: .userInitiated)

    /// 当前正在执行的安装；nil 表示空闲。每次 install 新建一份，后来者不能
    /// 覆盖它（W2A A-1/A-2）。只在 stateQueue 上访问。
    private var attempt: Attempt?
    /// 已放弃等待、但仍在排空管道的读端：保持打开直到子进程退出，子进程后续
    /// 写 stdout/stderr 不会收到 SIGPIPE / EPIPE（W2A A-3）。只在 stateQueue
    /// 上访问。
    private var drainingHandles: [ObjectIdentifier: FileHandle] = [:]

    /// 已放弃等待、但还不能确认已经退出的子进程数量：放弃等待时只对**自己的**
    /// 进程组尽力终止一次，降级路径不发送任何信号；只要它大于 0 就不允许开始
    /// 新的安装（上一次的 npm 可能还在跑，W2A A-2）。只在 stateQueue 上访问。
    private var abandonedChildrenInFlight = 0

    /// 一次 install 调用的全部可变状态。每次调用独立一份：重叠调用不会再覆盖
    /// 上一次的 handle / 回调 / 定时器（W2A A-1/A-2）。
    private final class Attempt {
        let plan: PiWebUpdateInstallPlan
        let timeout: TimeInterval
        let completion: (PiWebUpdateInstallResult) -> Void
        let startedAt: Date
        var handle: PiWebChildProcessHandle?
        var outputHandle: FileHandle?
        var timer: DispatchSourceTimer?
        var drainTimer: DispatchSourceTimer?
        var timedOut = false
        var cancelled = false
        var outputTail = ""
        var outputDecoder = IncrementalUTF8Decoder()
        /// 取消请求落在了收尾窗口内（F5，GitHub #121）：不发信号、不改判定，只留下事实。
        var cancelRequestedDuringFinish = false
        /// 没有输出管道时视为已经排空；建立管道后改为 false，读到 EOF 再置回 true。
        var outputDrained = true
        /// 已确认退出、但仍在等待输出管道 EOF 时暂存真实退出码。
        var pendingFinish: (exitCode: Int32?, launchFailed: Bool)?
        /// 本次子进程是否已经发送过终止信号（至多一次）。
        var didSignalOwnProcessGroup = false
        var childProcessAction: UpdateAbandonedAttempt.ChildProcessAction?
        /// 已经放弃等待、但退出尚未确认（计入 `abandonedChildrenInFlight`）。
        var abandonedUnconfirmed = false

        init(
            plan: PiWebUpdateInstallPlan,
            timeout: TimeInterval,
            completion: @escaping (PiWebUpdateInstallResult) -> Void,
            startedAt: Date
        ) {
            self.plan = plan
            self.timeout = timeout
            self.completion = completion
            self.startedAt = startedAt
        }
    }

    /// 是否有安装正在进行（供 UI 门控）。已经放弃等待、但子进程退出还没确认时
    /// 也算「进行中」：这段时间里不会再启动第二次安装。
    var isRunning: Bool {
        stateQueue.sync { attempt != nil || abandonedChildrenInFlight > 0 }
    }

    /// 已经放弃等待、但子进程退出还没确认（W3B F3）：这种窗口下的拒绝必须给出
    /// 「重启应用即可恢复」的可见提示，而不是一句「正在运行」之后静默置灰。
    var abandonedChildrenUnconfirmed: Bool {
        stateQueue.sync { abandonedChildrenInFlight > 0 }
    }

    init(
        clock: @escaping () -> Date = { Date() },
        spawner: PiWebUpdateChildSpawning = POSIXPiWebUpdateChildSpawner(),
        redact: @escaping (String) -> String = { LogRedactor().redact($0) },
        recordAbandonedAttempt: @escaping (UpdateAbandonedAttempt) -> Void = { _ in },
        pipeDrainGrace: TimeInterval = ProcessPiWebUpdateInstaller.defaultPipeDrainGrace
    ) {
        self.clock = clock
        self.spawner = spawner
        self.redact = redact
        self.recordAbandonedAttempt = recordAbandonedAttempt
        self.pipeDrainGrace = pipeDrainGrace
    }

    func install(
        _ plan: PiWebUpdateInstallPlan,
        timeout: TimeInterval,
        completion: @escaping (PiWebUpdateInstallResult) -> Void
    ) {
        stateQueue.async { [weak self] in
            self?.startLocked(plan, timeout: timeout, completion: completion)
        }
    }

    func cancel() {
        stateQueue.async { [weak self] in
            guard let self, let attempt = self.attempt else { return }
            // F5（GitHub #121）：排水宽限窗口内子进程已经退出，没有信号可发。取消不会生效，
            // 但也不能静默：留下标记，结果与日志都能区分「取消被忽略」与「没来得及取消」。
            guard attempt.pendingFinish == nil else {
                attempt.cancelRequestedDuringFinish = true
                return
            }
            attempt.cancelled = true
            self.stopWaitingLocked(attempt, reason: .abandonedWaiting)
            self.finishLocked(attempt, exitCode: nil)
        }
    }

    // MARK: - 内部（全部在 stateQueue 上执行）

    private func startLocked(
        _ plan: PiWebUpdateInstallPlan,
        timeout: TimeInterval,
        completion: @escaping (PiWebUpdateInstallResult) -> Void
    ) {
        let startedAt = clock()
        // 重叠 install：整体拒绝这一次调用——不启动第二个子进程，也不覆盖正在跑
        // 的那份状态（W2A A-2）；拒绝同样要有终态回调，否则调用方永远等不到结果
        // （W2A A-1）。上一次安装彻底结束（子进程退出已确认）后可以再次安装。
        guard attempt == nil, abandonedChildrenInFlight == 0 else {
            deliver(
                PiWebUpdateInstallResult(
                    exitCode: nil,
                    alreadyRunning: true,
                    startedAt: startedAt,
                    finishedAt: startedAt
                ),
                to: completion
            )
            return
        }

        let attempt = Attempt(
            plan: plan,
            timeout: timeout,
            completion: completion,
            startedAt: startedAt
        )
        self.attempt = attempt

        let specification = PiWebChildProcessSpecification(
            executablePath: plan.npmExecutablePath,
            arguments: plan.arguments,
            environment: plan.environment
        )
        let handle: PiWebChildProcessHandle
        do {
            handle = try spawner.spawn(specification)
        } catch {
            finishLocked(attempt, exitCode: nil, launchFailed: true)
            return
        }
        attempt.handle = handle

        if handle.outputDescriptor > STDERR_FILENO {
            let outputHandle = FileHandle(fileDescriptor: handle.outputDescriptor, closeOnDealloc: true)
            attempt.outputDrained = false
            outputHandle.readabilityHandler = { [weak self, weak attempt] fileHandle in
                let data = fileHandle.availableData
                guard let attempt else { return }
                self?.receiveOutput(data, from: fileHandle, attempt: attempt)
            }
            attempt.outputHandle = outputHandle
        }

        waitQueue.async { [weak self] in
            let exitCode = self?.spawner.waitForExit(handle) ?? -1
            self?.stateQueue.async {
                self?.childExitedLocked(attempt, exitCode: exitCode)
            }
        }
        scheduleTimeoutLocked(attempt)
    }

    private func scheduleTimeoutLocked(_ attempt: Attempt) {
        let timer = DispatchSource.makeTimerSource(queue: stateQueue)
        timer.schedule(deadline: .now() + max(0.05, attempt.timeout))
        timer.setEventHandler { [weak self, weak attempt] in
            // 只有这一次尝试仍是当前尝试时才收尾：已结束或已被后来调用替换的旧
            // 定时器不会再去动别人的子进程组（W2A A-2）。
            guard let self, let attempt, self.attempt === attempt,
                  attempt.pendingFinish == nil else { return }
            attempt.timedOut = true
            self.stopWaitingLocked(attempt, reason: .timedOut)
            self.finishLocked(attempt, exitCode: nil)
        }
        timer.resume()
        attempt.timer = timer
    }

    /// 停止等待：只对本次启动的子进程组发送**一次**终止信号（尽力而为），并记录
    /// “已终止子进程组 / 未确认派生进程是否结束”（降级时记录“没有发送任何信号”）。
    private func stopWaitingLocked(_ attempt: Attempt, reason: UpdateAbandonedAttempt.Reason) {
        // 放弃等待不等于子进程已经退出（信号是尽力而为、降级路径一个信号也不发）：
        // 在它的退出通知到达之前把这次尝试记为「不确定」，期间拒绝新的安装。
        if !attempt.abandonedUnconfirmed {
            attempt.abandonedUnconfirmed = true
            abandonedChildrenInFlight += 1
        }
        let action = terminateOwnProcessGroupLocked(attempt)
        attempt.childProcessAction = action
        recordAbandonedAttemptLocked(attempt, reason: reason, action: action)
    }

    private func terminateOwnProcessGroupLocked(_ attempt: Attempt) -> UpdateAbandonedAttempt.ChildProcessAction {
        guard let handle = attempt.handle else { return .processGroupUnavailable }
        // 只发送一次：取消之后又触发超时、或反过来，都不会出现第二次信号。
        guard !attempt.didSignalOwnProcessGroup else { return .terminatedOwnProcessGroup }
        guard handle.usesOwnProcessGroup,
              handle.processGroupIdentifier == handle.processIdentifier,
              handle.processIdentifier > 1 else {
            // 降级路径：子进程在共享进程组里，发信号会波及别人，因此不发送。
            return .processGroupUnavailable
        }
        attempt.didSignalOwnProcessGroup = true
        return spawner.terminateOwnProcessGroup(handle)
            ? .terminatedOwnProcessGroup
            : .processGroupUnavailable
    }

    /// 写一条「已放弃」记录：组件、脱敏命令摘要、开始时间、超时值、结束时间未知
    /// （`finishedAt == nil`）、来源与本次实际动作。
    private func recordAbandonedAttemptLocked(
        _ attempt: Attempt,
        reason: UpdateAbandonedAttempt.Reason,
        action: UpdateAbandonedAttempt.ChildProcessAction
    ) {
        let plan = attempt.plan
        let finishedAt = clock()
        let record = UpdateAbandonedAttempt(
            componentKind: .piWeb,
            packageName: nil,
            reason: reason,
            commandSummary: UpdateAbandonedAttempt.makeCommandSummary(
                executablePath: plan.npmExecutablePath,
                arguments: plan.arguments,
                redactingWith: redact
            ),
            startedAt: attempt.startedAt,
            timeout: attempt.timeout,
            finishedAt: nil,
            source: plan.source,
            recordedAt: finishedAt,
            childProcessAction: action,
            derivedProcessesConfirmedEnded: nil
        )
        recordAbandonedAttempt(record)
    }

    private func childExitedLocked(_ attempt: Attempt, exitCode: Int32) {
        // 退出确认要结清「不确定」计数：晚到的退出通知同样要清账。
        settleAbandonedChildLocked(attempt)
        guard self.attempt === attempt else { return }
        attempt.timer?.cancel()
        attempt.timer = nil
        if !attempt.outputDrained {
            attempt.pendingFinish = (exitCode, false)
            scheduleDrainDeadlineLocked(attempt)
            return
        }
        finishLocked(attempt, exitCode: exitCode)
    }

    /// 子进程退出已确认：从「不确定」集合里摘掉（若它曾被放弃等待）。
    private func settleAbandonedChildLocked(_ attempt: Attempt) {
        guard attempt.abandonedUnconfirmed else { return }
        attempt.abandonedUnconfirmed = false
        abandonedChildrenInFlight = max(0, abandonedChildrenInFlight - 1)
    }

    private func receiveOutput(_ data: Data, from handle: FileHandle, attempt: Attempt) {
        stateQueue.async { [weak self] in
            guard let self, self.attempt === attempt else { return }
            if data.isEmpty {
                handle.readabilityHandler = nil
                attempt.outputDrained = true
                self.appendDecodedOutput(attempt.outputDecoder.decode(Data(), final: true), to: attempt)
                self.completePendingLocked(attempt)
                return
            }
            self.appendDecodedOutput(attempt.outputDecoder.decode(data), to: attempt)
        }
    }

    private func appendDecodedOutput(_ text: String, to attempt: Attempt) {
        guard !text.isEmpty else { return }
        attempt.outputTail += text
        if attempt.outputTail.count > Self.outputTailLimit {
            attempt.outputTail = String(attempt.outputTail.suffix(Self.outputTailLimit))
        }
    }

    private func completePendingLocked(_ attempt: Attempt) {
        guard let pending = attempt.pendingFinish, attempt.outputDrained else { return }
        attempt.pendingFinish = nil
        finishLocked(attempt, exitCode: pending.exitCode, launchFailed: pending.launchFailed)
    }

    private func scheduleDrainDeadlineLocked(_ attempt: Attempt) {
        guard attempt.drainTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: stateQueue)
        timer.schedule(deadline: .now() + pipeDrainGrace)
        timer.setEventHandler { [weak self] in
            guard let self, let pending = attempt.pendingFinish,
                  self.attempt === attempt else { return }
            attempt.pendingFinish = nil
            self.finishLocked(attempt, exitCode: pending.exitCode, launchFailed: pending.launchFailed)
        }
        timer.resume()
        attempt.drainTimer = timer
    }

    private func finishLocked(_ attempt: Attempt, exitCode: Int32?, launchFailed: Bool = false) {
        // 只有当前这次尝试能收尾：已经被拒绝、已经被后来调用替换的尝试不会写结果。
        guard self.attempt === attempt else { return }
        attempt.timer?.cancel()
        attempt.timer = nil
        attempt.drainTimer?.cancel()
        attempt.drainTimer = nil
        appendDecodedOutput(attempt.outputDecoder.decode(Data(), final: true), to: attempt)
        self.attempt = nil
        // 放弃等待不关闭读端：把管道交给排空逻辑读到 EOF，子进程继续跑时写
        // stdout/stderr 不会收到 SIGPIPE / EPIPE（W2A A-3）。
        if let outputHandle = attempt.outputHandle {
            attempt.outputHandle = nil
            drainOutput(outputHandle)
        }
        let finishedAt = clock()
        let result = PiWebUpdateInstallResult(
            exitCode: exitCode,
            timedOut: attempt.timedOut,
            cancelled: attempt.cancelled,
            launchFailed: launchFailed,
            startedAt: attempt.startedAt,
            finishedAt: finishedAt,
            outputTail: attempt.outputTail.isEmpty ? nil : attempt.outputTail,
            childProcessAction: attempt.childProcessAction,
            cancelRequestedDuringFinish: attempt.cancelRequestedDuringFinish
        )
        deliver(result, to: attempt.completion)
    }

    /// 在 stateQueue 之外投递结果：回调里的长耗时工作（例如重新检测版本）不能
    /// 占住 installer 的串行队列，否则应用退出时的 `cancel()` 会被排在它后面
    /// （W2A A-5）。
    private func deliver(
        _ result: PiWebUpdateInstallResult,
        to completion: @escaping (PiWebUpdateInstallResult) -> Void
    ) {
        deliveryQueue.async { completion(result) }
    }

    /// 摘掉业务回调后**保持读端打开**，把剩余输出一路读到 EOF 再释放。这样被放弃
    /// 等待的子进程在下一次写 stdout/stderr 时不会因为读端已关而死亡（W2A A-3）。
    private func drainOutput(_ outputHandle: FileHandle) {
        let key = ObjectIdentifier(outputHandle)
        drainingHandles[key] = outputHandle
        outputHandle.readabilityHandler = { [weak self] fileHandle in
            guard fileHandle.availableData.isEmpty else { return }
            fileHandle.readabilityHandler = nil
            self?.stateQueue.async { [weak self] in
                self?.drainingHandles[key] = nil
            }
        }
    }
}

// MARK: - 编排

/// 一次运行的结果。`plan` 携带版本前后值与参数数组，供日志与诊断使用。
enum PiWebUpdateRunOutcome: Equatable {
    /// 未尝试自动安装（设置关闭 / 来源不符 / 无目标版本 / 服务在运行）。
    case skipped(reason: PiWebUpdateRefusal, commandText: String?)
    /// 安装器失败（非零退出 / 超时 / 取消 / 启动失败）：旧版本保持原样。
    case installFailed(plan: PiWebUpdateInstallPlan, failure: PiWebUpdateInstallFailure, oldVersion: String, targetVersion: String, outputTail: String?)
    /// 安装器成功但重新检测的版本仍未达到目标版本。
    case versionUnchanged(plan: PiWebUpdateInstallPlan, detectedVersion: String?, oldVersion: String, targetVersion: String)
    /// 版本已更新，但服务启动或健康检查失败。
    case healthCheckFailed(plan: PiWebUpdateInstallPlan, oldVersion: String, newVersion: String)
    /// 版本已更新且服务健康检查通过。
    case succeeded(plan: PiWebUpdateInstallPlan, oldVersion: String, newVersion: String)

    var isSucceeded: Bool {
        if case .succeeded = self { return true }
        return false
    }

    /// 失败路径的持久警告记录；成功与跳过返回 nil。
    var warning: PiWebUpdateWarning? {
        switch self {
        case .skipped, .succeeded:
            return nil
        case .installFailed(let plan, let failure, let oldVersion, let targetVersion, _):
            return PiWebUpdateWarning(
                kind: .installFailed,
                oldVersion: oldVersion,
                newVersion: plan.installedVersion,
                targetVersion: targetVersion,
                // B-6：命令失败不证明旧文件没被改动，不写“仍在使用旧版本”这类没有探针支撑的断言。
                reason: "更新失败，没有执行任何回滚动作：\(failure.text)"
            )
        case .versionUnchanged(_, let detectedVersion, let oldVersion, let targetVersion):
            return PiWebUpdateWarning(
                kind: .versionUnchanged,
                oldVersion: oldVersion,
                newVersion: detectedVersion,
                targetVersion: targetVersion,
                // L-2：与 CLI / 扩展包同一处理：nil 时不作版本状态断言。
                reason: detectedVersion.map { detected in
                    "更新后验证失败，仍在使用更新前的版本：安装命令已结束，但重新检测到的版本是 \(detected)，未达到目标版本"
                } ?? "更新后验证失败：安装命令已结束，但重新检测没有给出可用的版本结果，因此无法判断是否达到目标版本"
            )
        case .healthCheckFailed(let plan, let oldVersion, let newVersion):
            return PiWebUpdateWarning(
                kind: .healthCheckFailed,
                oldVersion: oldVersion,
                newVersion: newVersion,
                targetVersion: plan.targetVersion,
                reason: "更新后验证失败：版本已更新，但服务启动或健康检查失败"
            )
        }
    }
}
