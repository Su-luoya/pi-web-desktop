import Foundation

// MARK: - 退出时间线（GitHub #158）

/// 退出序列的节点。`rawValue` 直接写进用户日志，是用户复现「Cmd+Q 卡顿」时读的
/// 那一列文字：请求 → 停止请求 → SIGTERM → 子进程退出（或 SIGKILL）→ 应用终止。
///
/// 停止路径也会被重启复用（重启内部同样调 `stopService`），因此非退出场景的
/// 日志里也可能出现 SIGTERM 两行；这不影响阅读，反而便于量化停止耗时。
enum QuitTimelineStage: String {
    case requested = "退出请求"
    case stopServiceRequested = "请求停止托管服务"
    case sigtermSent = "已发送 SIGTERM"
    case sigkillSent = "已发送 SIGKILL"
    case serviceExited = "子进程已退出"
    /// SIGKILL 之后复查仍未消失：停止并未真正生效（GitHub #158 复审）。
    case serviceStillAlive = "进程组在 SIGKILL 后仍存活"
    case applicationTerminating = "应用即将终止"
}

/// 退出时间线的格式化（纯函数，便于单测）。
///
/// 每行形如：`退出时间线 12:34:56.789 (+12345ms) 已发送 SIGTERM — SIGTERM 之后等待 8ms`。
/// `+Nms` 是相对进程启动的单调偏移（`ProcessInfo.systemUptime`），因此任意两行
/// 相减即得到该阶段的真实耗时，不受系统时钟调整影响；绝对时间只是给人定位现场用。
enum QuitTimeline {
    /// `HH:mm:ss.SSS`（本地时区）。`LogWriter.timestamp` 只精确到秒，而且它属于诊断
    /// 模块（本次改动不碰它），所以这里单独格式化。每次调用新建 formatter：
    /// `DateFormatter` 不是线程安全的，而退出路径横跨主线程与后台停止队列。
    static func clock(_ date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter.string(from: date)
    }

    /// 相对锚点的毫秒偏移，四舍五入且永不为负（时钟回拨也不产生负数）。
    static func elapsedMilliseconds(from origin: Date, to date: Date) -> Int {
        max(0, Int((date.timeIntervalSince(origin) * 1000).rounded()))
    }

    /// 相对进程启动的单调毫秒偏移。
    static func uptimeMilliseconds(_ uptime: TimeInterval) -> Int {
        max(0, Int((uptime * 1000).rounded()))
    }

    static func line(
        _ stage: QuitTimelineStage,
        detail: String? = nil,
        now: Date = Date(),
        uptime: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) -> String {
        var text = "退出时间线 \(clock(now)) (+\(uptimeMilliseconds(uptime))ms) \(stage.rawValue)"
        if let detail, !detail.isEmpty {
            text += " — \(detail)"
        }
        return text
    }
}
