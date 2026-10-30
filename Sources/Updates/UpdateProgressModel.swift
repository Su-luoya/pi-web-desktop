/// Update progress window model (GitHub #219).
///
/// 纯 Foundation，不依赖 AppKit：窗口只渲染这里算好的快照，`AppDelegate` 负责把
/// 更新路径的事件推进来。这里只做状态汇总与固定文案拼装：
///
///   * 不联网、不执行命令、不读写配置，也不碰文件系统；
///   * 文本只由固定文案 + 已校验的版本号/包名组成；日志行由调用方先经
///     `LogRedactor` 脱敏再传进来；
///   * 不向任何进程发信号（更新路径本身也没有取消动作，见 `docs/architecture.md`）。

import Foundation

// MARK: - 阶段状态

/// 进度窗口里单个阶段的状态。与 `UpdateTransactionPhaseStatus` 不同：这里描述的是
/// “界面上怎么显示”，不是事务判定。
enum UpdateProgressStepState: Equatable {
    case pending
    case running
    case succeeded
    case failed
    case skipped

    /// 单字符标记（等宽字体下对齐）。不用 emoji：它在不同系统字体下宽度不一致。
    var symbol: String {
        switch self {
        case .pending: return "○"
        case .running: return "●"
        case .succeeded: return "✓"
        case .failed: return "✗"
        case .skipped: return "–"
        }
    }

    var displayName: String {
        switch self {
        case .pending: return "等待中"
        case .running: return "进行中"
        case .succeeded: return "成功"
        case .failed: return "失败"
        case .skipped: return "跳过"
        }
    }
}

/// 一个阶段：标题、说明与状态。`detail` 是固定文案原因，可为空（等待中的阶段）。
struct UpdateProgressStep: Equatable {
    var title: String
    var detail: String
    var state: UpdateProgressStepState

    init(title: String, detail: String = "", state: UpdateProgressStepState = .pending) {
        self.title = title
        self.detail = detail
        self.state = state
    }
}

// MARK: - 结论

enum UpdateProgressOutcome: Equatable {
    /// `version` 是重新检测到的到版本；手动路径或未确认时可以是 nil。
    case succeeded(version: String?)
    case failed(reason: String)
    case skipped(reason: String)

    var isSuccess: Bool {
        if case .succeeded = self { return true }
        return false
    }

    /// 结束时窗口顶部的结论行。只使用固定措辞，不承诺未验证的结果。
    var headline: String {
        switch self {
        case .succeeded(let version):
            return version.map { "更新完成（到 \($0)）" } ?? "更新完成"
        case .failed(let reason):
            return "更新失败：\(reason)"
        case .skipped(let reason):
            return "更新已跳过：\(reason)"
        }
    }
}

// MARK: - 会话快照

/// 一次更新的进度快照。窗口按它整块重绘，不做增量 diff。
struct UpdateProgressSession: Equatable {
    var title: String
    var startedAt: Date
    var steps: [UpdateProgressStep]
    /// 已脱敏的日志行，按到达顺序；超过上限时丢最旧的。
    var logLines: [String] = []
    var finishedAt: Date?
    var outcome: UpdateProgressOutcome?

    /// 日志行上限：足够看清一次更新，又不会让窗口无限增长。
    static let maximumLogLines = 400

    var isFinished: Bool { finishedAt != nil }

    /// 已用时长：结束后固定为结束时间，进行中按当前时间增长。
    func elapsed(at now: Date) -> TimeInterval {
        max(0, (finishedAt ?? now).timeIntervalSince(startedAt))
    }

    /// 底部状态行的固定格式：`已用 00:32`，结束后追加结论。
    func statusLine(at now: Date) -> String {
        var text = "已用 \(UpdateProgressSession.durationText(elapsed(at: now)))"
        if let outcome {
            text += " · \(outcome.headline)"
        }
        return text
    }

    /// 当前正在进行的阶段（没有则 nil）。窗口用它决定要不要继续走计时器。
    var runningStepTitle: String? {
        steps.first { $0.state == .running }?.title
    }

    static func durationText(_ interval: TimeInterval) -> String {
        let total = Int(interval.rounded(.down))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }
}

// MARK: - 进度中心

/// 进度中心：把更新路径的事件汇总成一份快照，并在变化时通知窗口。
///
/// 主线程独占（与 `desktopAppUpdateRound` 同一约定）：调用方负责在主线程调用，
/// 后台线程上的日志行必须先 `DispatchQueue.main.async` 再进来。这里不加锁，
/// 因为加锁会掩盖调用方的线程错误，而进度显示不值得为它引入锁语义。
final class UpdateProgressCenter {
    private(set) var session: UpdateProgressSession?
    /// 快照变化（开始、阶段变化、新日志、结束、清空）时在主线程回调。
    var onChange: ((UpdateProgressSession?) -> Void)?

    /// 开始一次新会话。已有会话时直接替换：同一时刻只显示一次更新，
    /// 四类更新本来就有各自的互斥门控。
    func begin(title: String, steps: [UpdateProgressStep], now: Date = Date()) {
        session = UpdateProgressSession(title: title, startedAt: now, steps: steps)
        publish()
    }

    /// 更新单个阶段。越界或没有会话时忽略（晚到的回调不该让窗口崩）。
    func setStep(_ index: Int, state: UpdateProgressStepState, detail: String? = nil) {
        guard var session, session.steps.indices.contains(index) else { return }
        session.steps[index].state = state
        if let detail {
            session.steps[index].detail = detail
        }
        self.session = session
        publish()
    }

    /// 追加一行已脱敏的日志。
    func appendLog(_ line: String, now: Date = Date()) {
        guard var session else { return }
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        session.logLines.append(trimmed)
        if session.logLines.count > UpdateProgressSession.maximumLogLines {
            session.logLines.removeFirst(session.logLines.count - UpdateProgressSession.maximumLogLines)
        }
        self.session = session
        publish()
    }

    /// 结束当前会话。重复结束只保留第一次的结论（晚到的失败不得覆盖已发布的结果）。
    func finish(_ outcome: UpdateProgressOutcome, now: Date = Date()) {
        guard var session, !session.isFinished else { return }
        session.finishedAt = now
        session.outcome = outcome
        // 结束时不再有“进行中”的阶段：还在 running 的那个阶段停在原位，改记为跳过，
        // 免得窗口一直显示一个永远不会完成的“进行中”。
        for index in session.steps.indices where session.steps[index].state == .running {
            session.steps[index].state = .skipped
        }
        self.session = session
        publish()
    }

    /// 清空（窗口关闭且会话已结束）。
    func reset() {
        session = nil
        publish()
    }

    private func publish() {
        onChange?(session)
    }
}

// MARK: - 更新事务 → 进度窗口

/// 把 `UpdateTransactionJournal` 的五个阶段映射到窗口的阶段列表。
///
/// 顺序与 `UpdateTransactionPhase` 一致：准备 → 执行安装 → 验证 → 启用/提交，
/// 失败降级只在真的记录时出现（正常路径不会凭空多一行“失败降级：等待中”）。
enum UpdateProgressPlan {
    /// 进度阶段（不含降级）。
    static let progressPhases: [UpdateTransactionPhase] = [.preflight, .install, .verify, .commit]

    static func title(for component: UpdateTransactionComponent) -> String {
        "\(component.displayName) 更新"
    }

    /// 初始阶段列表：准备阶段直接进入“进行中”，其余等待。
    static func steps(includeDegradation: Bool = false) -> [UpdateProgressStep] {
        var steps = progressPhases.enumerated().map { index, phase in
            UpdateProgressStep(
                title: phase.title,
                detail: index == 0 ? "正在记录更新前指纹…" : "",
                state: index == 0 ? .running : .pending
            )
        }
        if includeDegradation {
            steps.append(UpdateProgressStep(title: UpdateTransactionPhase.degrade.title))
        }
        return steps
    }

    /// 阶段在窗口列表里的下标。降级固定追加在末尾。
    static func stepIndex(for phase: UpdateTransactionPhase) -> Int {
        if let index = progressPhases.firstIndex(of: phase) { return index }
        return progressPhases.count
    }

    /// 事务阶段结果 → 界面状态。
    ///
    /// `notAttempted` 显示成“跳过”：它的事实是“这一步没有执行”，不是失败；
    /// 降级的三种结果里只有真的执行了恢复动作（`applied`）才算成功。
    static func state(for status: UpdateTransactionPhaseStatus) -> UpdateProgressStepState {
        switch status {
        case .succeeded, .applied: return .succeeded
        case .failed, .notPossible: return .failed
        case .skipped, .recordedOnly, .notAttempted: return .skipped
        }
    }
}

extension UpdateProgressCenter {
    /// 记录一个事务阶段：第一次调用时按需开始会话，之后更新对应行。
    ///
    /// 记录成功后把下一个阶段标成“进行中”，这样用户看到的永远是“已经做完的”和
    /// “正在做的”两行，而不是一串等待中的空行。
    func apply(
        phase result: UpdateTransactionPhaseResult,
        component: UpdateTransactionComponent,
        now: Date = Date()
    ) {
        let index = UpdateProgressPlan.stepIndex(for: result.phase)
        if session == nil {
            begin(
                title: UpdateProgressPlan.title(for: component),
                steps: UpdateProgressPlan.steps(includeDegradation: result.phase == .degrade),
                now: now
            )
        }
        // 降级行是动态追加的：第一次真的记录降级时才加进来，位置固定在末尾。
        if result.phase == .degrade, let session, session.steps.count <= index {
            var steps = session.steps
            steps.append(UpdateProgressStep(title: UpdateTransactionPhase.degrade.title))
            begin(title: session.title, steps: steps, now: session.startedAt)
        }
        let state = UpdateProgressPlan.state(for: result.status)
        setStep(index, state: state, detail: result.reason)
        // 成功推进到下一阶段时，把它标成进行中（只对进度阶段，降级是终点）。
        guard state == .succeeded,
              let next = UpdateProgressPlan.progressPhases[safe: index + 1] else { return }
        setStep(UpdateProgressPlan.stepIndex(for: next), state: .running, detail: "等待\(next.title)…")
    }

    /// 写入统一历史时结束会话：成功与否由历史判定（`isSuccessful`），失败原因用
    /// 历史里记录的第一个失败阶段原因，保证窗口和诊断页看到的是同一句话。
    func finish(history entry: UpdateHistoryEntry, now: Date = Date()) {
        guard session != nil else { return }
        let outcome: UpdateProgressOutcome
        if entry.isSuccessful {
            outcome = .succeeded(version: entry.toVersion)
        } else if let reason = entry.failureReason {
            outcome = .failed(reason: reason)
        } else if let phase = entry.terminationPhase {
            outcome = .failed(reason: "流程停在「\(phase.title)」，没有完成提交")
        } else {
            outcome = .failed(reason: "更新没有完成")
        }
        finish(outcome, now: now)
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
