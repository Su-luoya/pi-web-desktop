/// Clock, timer and scheduler abstractions behind the recurring checks.

import Foundation

// MARK: - 时钟与调度（可注入）

/// 时间来源。默认系统时钟；测试注入由假时钟驱动的闭包，推进时间即可，不需要
/// 真实 sleep。
///
/// 只持有一个 `@Sendable` 纯函数，值类型因此自动成立 `Sendable`，不需要
/// `@unchecked` 担保。
struct UpdateClock: Sendable {
    var now: @Sendable () -> Date

    /// 不可变值类型（见类型声明），跨队列读取无竞争。
    static let system = UpdateClock { Date() }
}

/// 周期计时器的取消句柄。
protocol UpdateTimerToken: AnyObject {
    func cancel()
}

/// 更新检查用到的调度原语。
///
/// - `perform`：执行一次检查主体（生产：后台串行队列；测试：立即执行）；
/// - `perform(after:)`：延迟执行（只用于限流后的一次重试；默认忽略延迟，
///   因此测试不 sleep 也能断言重试结果）；
/// - `deliver`：把结果回到主线程（生产：主队列；测试：立即执行）；
/// - `startRepeating`：按间隔重复触发（生产：主 run loop Timer；测试：记录间隔
///   并由测试手动触发）。
///
/// 测试用替身让整个检查同步完成，因此断言是确定性的，且从不 sleep、从不联网。
protocol UpdateCheckScheduling: AnyObject {
    func perform(_ work: @escaping () -> Void)
    func perform(after delay: TimeInterval, _ work: @escaping () -> Void)
    func deliver(_ work: @escaping () -> Void)
    func startRepeating(interval: TimeInterval, _ work: @escaping () -> Void) -> UpdateTimerToken
}

extension UpdateCheckScheduling {
    /// 默认实现：忽略延迟立即执行。测试替身因此不必实现它，也不会 sleep。
    func perform(after delay: TimeInterval, _ work: @escaping () -> Void) {
        perform(work)
    }
}

/// 生产实现：后台串行队列 + 主队列回调 + 主 run loop 重复计时器。
final class DispatchUpdateCheckScheduler: UpdateCheckScheduling {
    private let queue = DispatchQueue(label: "io.github.su-luoya.pi-web-desktop.update-check", qos: .utility)

    // 投递一律包成 `DispatchWorkItem`：`DispatchQueue.async` 与 `Timer` 的 block 参数都要
    // 求 `@Sendable`，而 `work` 是调用方给的普通闭包。work item 本身是 Sendable 容器，
    // 执行一次、执行线程不变，语义完全一致。
    func perform(_ work: @escaping () -> Void) {
        queue.async(execute: DispatchWorkItem(block: work))
    }

    func perform(after delay: TimeInterval, _ work: @escaping () -> Void) {
        queue.asyncAfter(deadline: .now() + delay, execute: DispatchWorkItem(block: work))
    }

    func deliver(_ work: @escaping () -> Void) {
        DispatchQueue.main.async(execute: DispatchWorkItem(block: work))
    }

    /// 计时器必须挂在 `.common` 模式上，不能只用 `Timer.scheduledTimer`。
    ///
    /// `scheduledTimer` 只把计时器加入默认 `RunLoop.Mode.default`；而菜单跟
    /// 踪、拖动滑杆、sheet 与 `runModal()` 期间主运行循环跑在
    /// `eventTracking` / `modalPanel` 等模式，默认模式上的计时器在那段时间
    /// 完全不触发。对每日/每周复查来说，表现为「用户在菜单里按住一会儿，
    /// 当天的到期检查就不发生」——静默漏掉一次检查，且没有任何日志。
    /// `AppDelegate+Quit.swift` 的退出超时计时器有同样的注释与同样的处理。
    func startRepeating(interval: TimeInterval, _ work: @escaping () -> Void) -> UpdateTimerToken {
        // `Timer` 的 block 同样是 `@Sendable`，包成 work item 再 `perform()`。
        nonisolated(unsafe) let item = DispatchWorkItem(block: work)
        let timer = Timer(timeInterval: interval, repeats: true) { _ in item.perform() }
        RunLoop.main.add(timer, forMode: .common)
        return TimerUpdateToken(timer: timer)
    }
}

private final class TimerUpdateToken: UpdateTimerToken {
    private let timer: Timer

    init(timer: Timer) {
        self.timer = timer
    }

    func cancel() {
        timer.invalidate()
    }
}
