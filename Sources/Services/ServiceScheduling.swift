import Foundation

/// Service lifecycle state, shown in the status menu and in diagnostics.

/// Service state, scheduling/probing protocols and their dispatch implementations.

enum ServiceState: Equatable {
    case checking
    case starting
    case running
    case stopped
    case failed(String)

    /// Base text used by the status menu, matching the pre-split behaviour:
    /// `.running` is shown without an ownership suffix.
    var displayText: String {
        switch self {
        case .checking: return "正在检查"
        case .starting: return "正在启动"
        case .running: return "正在运行"
        case .stopped: return "已停止"
        case .failed(let message): return "失败：\(message)"
        }
    }

    /// Diagnostics copy only: a running service is labelled by ownership, as the
    /// pre-split `statusDescription()` did for "复制诊断信息". The status menu must
    /// use `displayText` instead.
    static func statusText(for state: ServiceState, managedPID: pid_t?) -> String {
        guard case .running = state else { return state.displayText }
        return managedPID == nil ? "正在运行（外部服务）" : "正在运行（本应用管理）"
    }
}

/// Scheduling and clock primitives used by `ServiceManager`.
///
/// Injected so the state machine can be exercised without timers, delays or
/// background threads: the production implementation below maps one-to-one onto
/// the timers and dispatch queues the app used before the split.
protocol ServiceScheduling: AnyObject {
    /// Runs work on the main queue.
    func onMain(_ work: @escaping () -> Void)
    /// Runs work off the main thread (blocking process waits).
    func onBackground(_ work: @escaping () -> Void)
    /// Runs work on the main queue after `delay` seconds.
    func after(_ delay: TimeInterval, _ work: @escaping () -> Void)
    /// Starts a repeating timer on the main run loop and returns its token.
    func repeating(interval: TimeInterval, _ work: @escaping () -> Void) -> RepeatingTimerToken
    /// Blocking sleep, only called from background work.
    func sleep(seconds: TimeInterval)
}

protocol RepeatingTimerToken: AnyObject {
    func invalidate()
}

/// `Sendable`：实例没有任何存储状态（每个方法只是把闭包交给一条队列或计时器），
/// 因此可以自由地在并发上下文之间传递。测试需要把它捕获进 `DispatchQueue.async`
/// 的 `@Sendable` 闭包里，这个一致性把它从“假设”变成“编译器确认”。
final class DispatchServiceScheduler: ServiceScheduling, Sendable {
    // 投递一律包成 `DispatchWorkItem`：`DispatchQueue.async` / `asyncAfter` / `Timer` 的
    // block 参数都要求 `@Sendable`，而这些 `work` 是调用方给的普通闭包。work item 本身是
    // Sendable 容器，执行一次、执行线程不变，语义完全一致。
    func onMain(_ work: @escaping () -> Void) {
        DispatchQueue.main.async(execute: DispatchWorkItem(block: work))
    }

    func onBackground(_ work: @escaping () -> Void) {
        DispatchQueue.global().async(execute: DispatchWorkItem(block: work))
    }

    func after(_ delay: TimeInterval, _ work: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: DispatchWorkItem(block: work))
    }

    /// 重复计时器必须挂在 `.common` 模式上，不能只用 `Timer.scheduledTimer`。
    ///
    /// 服务健康监控用的就是这条计时器（`ServiceManager` 的 4 秒健康检查）。
    /// `scheduledTimer` 只把计时器加入 `RunLoop.Mode.default`；菜单跟踪、拖动
    /// 窗口、sheet 与 `runModal()` 期间主运行循环跑在 `eventTracking` /
    /// `modalPanel` 等模式，默认模式上的计时器在那段时间完全不触发。表现为
    /// “服务已经挂掉，菜单一打开就一直显示正在运行”，要等到关掉菜单才补一次
    /// 检查（健康检查连着失败 3 次才重启，实际间隔会变得更长）。
    /// `DispatchUpdateCheckScheduler.startRepeating` 与退出超时计时器有同样的
    /// 处理。
    func repeating(interval: TimeInterval, _ work: @escaping () -> Void) -> RepeatingTimerToken {
        // `Timer` 的 block 同样是 `@Sendable`，包成 work item 再 `perform()`
        // （`perform()` 在调用线程上同步执行，与直接写 `work()` 等价）。
        nonisolated(unsafe) let item = DispatchWorkItem(block: work)
        let timer = Timer(timeInterval: interval, repeats: true) { _ in item.perform() }
        RunLoop.main.add(timer, forMode: .common)
        return TimerRepeatingToken(timer: timer)
    }

    func sleep(seconds: TimeInterval) {
        usleep(useconds_t(seconds * 1_000_000))
    }
}

private final class TimerRepeatingToken: RepeatingTimerToken {
    private let timer: Timer

    init(timer: Timer) {
        self.timer = timer
    }

    func invalidate() {
        timer.invalidate()
    }
}

/// Probes the service HTTP endpoint. Injected so tests never touch the network.
protocol ServiceProbing: AnyObject {
    func probe(url: URL, timeout: TimeInterval, completion: @escaping (Bool) -> Void)
}

final class URLSessionServiceProbe: ServiceProbing {
    /// 复用会话。在 `init` 里一次性建好：`probe` 可能从任何队列调用，`lazy var`
    /// 在多线程下并不安全。
    private let session: URLSession

    init() {
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        // GitHub #157：探针只测本机/局域网/Tailscale 上的服务本身，必须直连。
        // 默认的 ephemeral 会话会走系统代理，而代理的应答（502/407/缓存页）
        // 不代表服务状态：用户把监听地址切到 Tailscale 地址（CGNAT 段 100.x.y.z）后，
        // 系统代理未排除该网段就会返回 502，探针据此误报「服务已断开」。
        // 显式空代理字典强制直连。
        sessionConfiguration.connectionProxyDictionary = [:]
        // 单次请求的超时由 `URLRequest.timeoutInterval` 逐个指定；会话级的
        // 请求/资源超时保持默认，避免把“调用方传了更长超时”截短。
        self.session = URLSession(configuration: sessionConfiguration)
    }

    func probe(url: URL, timeout: TimeInterval, completion: @escaping (Bool) -> Void) {
        // `completion` 只在这里被转交给 URLSession 的完成回调执行一次，属于所有权转移。
        nonisolated(unsafe) let deliver = completion
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.cachePolicy = .reloadIgnoringLocalCacheData
        session.dataTask(with: request) { _, response, _ in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            deliver((200..<500).contains(status))
        }.resume()
    }
}
