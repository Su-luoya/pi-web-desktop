/// Clock, timer and scheduler abstractions behind the recurring checks.

import Foundation

// MARK: - 时钟与调度（可注入）

/// 时间来源。默认系统时钟；测试注入由假时钟驱动的闭包，推进时间即可，不需要
/// 真实 sleep。
struct UpdateClock {
    var now: () -> Date

    static let system = UpdateClock { Date() }
}

/// 周期计时器的取消句柄。
protocol UpdateTimerToken: AnyObject {
    func cancel()
}

/// 更新检查用到的调度原语。
///
/// - `perform`：执行一次检查主体（生产：后台串行队列；测试：立即执行）；
/// - `deliver`：把结果回到主线程（生产：主队列；测试：立即执行）；
/// - `startRepeating`：按间隔重复触发（生产：主 run loop Timer；测试：记录间隔
///   并由测试手动触发）。
///
/// 测试用替身让整个检查同步完成，因此断言是确定性的，且从不 sleep、从不联网。
protocol UpdateCheckScheduling: AnyObject {
    func perform(_ work: @escaping () -> Void)
    func deliver(_ work: @escaping () -> Void)
    func startRepeating(interval: TimeInterval, _ work: @escaping () -> Void) -> UpdateTimerToken
}

/// 生产实现：后台串行队列 + 主队列回调 + 主 run loop 重复计时器。
final class DispatchUpdateCheckScheduler: UpdateCheckScheduling {
    private let queue = DispatchQueue(label: "io.github.su-luoya.pi-web-desktop.update-check", qos: .utility)

    func perform(_ work: @escaping () -> Void) {
        queue.async(execute: work)
    }

    func deliver(_ work: @escaping () -> Void) {
        DispatchQueue.main.async(execute: work)
    }

    func startRepeating(interval: TimeInterval, _ work: @escaping () -> Void) -> UpdateTimerToken {
        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in work() }
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
