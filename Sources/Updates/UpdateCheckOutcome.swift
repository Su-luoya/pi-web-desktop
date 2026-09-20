/// Outcome vocabulary: status, version verdict, failure and freshness.

import Foundation

// MARK: - 检查结果

/// 单个对象的检查结论。
enum UpdateCheckStatus: String, Equatable {
    case updateAvailable = "update-available"
    case upToDate = "up-to-date"
    case unknown
}

/// 结论只能由“本机版本 + 上游版本”现算，绝不沿用缓存里的旧结论（GitHub #74）。
///
/// 缓存回退、条件请求（304）与本次网络响应都走这里，因此同一种输入在三处
/// 得到同一个结论；缓存条目里记录的 `status` 只是当时那次计算的产物，不是
/// 可以拿去覆盖当前本机版本的事实。
enum UpdateVersionVerdict {
    /// 语义化比较：本机 < 上游 → 有新版本；本机 >= 上游 → 已是最新；
    /// 任一侧缺失或无法解析 → nil（不可判定，不猜）。
    static func status(installed: String?, upstream: String?) -> UpdateCheckStatus? {
        guard let installed,
              let upstream,
              let installedVersion = SemanticVersion(installed),
              let upstreamVersion = SemanticVersion(upstream) else {
            return nil
        }
        return installedVersion < upstreamVersion ? .updateAvailable : .upToDate
    }
}

/// 检查失败的原因；写入缓存的只有这个枚举的 rawValue，没有自由文本。
enum UpdateCheckFailure: String, Equatable {
    case timedOut
    case offline
    case cancelled
    case transport
    case rateLimited
    case serverError
    case httpError
    case unexpectedRedirect
    case unexpectedHost
    case invalidResponse
    case unparsableVersion
    case installedVersionUnknown
    case invalidPackageName

    /// 用户可见的原因文本，不含 HTTP 状态码（状态码由调用方按需追加）。
    var text: String {
        switch self {
        case .timedOut: return "请求超时"
        case .offline: return "网络不可用"
        case .cancelled: return "请求被取消"
        case .transport: return "网络错误"
        case .rateLimited: return "上游限流"
        case .serverError: return "上游服务错误"
        case .httpError: return "上游返回非预期状态码"
        case .unexpectedRedirect: return "上游尝试重定向到非预期地址"
        case .unexpectedHost: return "响应来自非预期主机"
        case .invalidResponse: return "响应无法解析"
        case .unparsableVersion: return "上游版本无法进行语义化比较"
        case .installedVersionUnknown: return "无法确定本机已安装版本，未发起请求"
        case .invalidPackageName: return "包名不符合 npm 规范，未发起请求"
        }
    }
}

/// 结果新鲜度：本次真实响应、沿用的缓存、或没有可用结果。
enum UpdateResultFreshness: String, Equatable {
    case fresh
    case cached
    case none
}

/// 检查结果的来源（GitHub #59 / alpha.3 安全审查 A-1）。
///
/// **只有 `.network` 允许作为自动安装（受限自动更新）的判定依据**：它表示本次
/// 运行刚从白名单主机取得的响应。`.cachedFallback` 的版本值来自本机缓存文件
/// （同一用户可改写，不是可信输入），只允许用于提示；`.unavailable` 表示没有
/// 可用结果（没有缓存或整份缓存被丢弃）。
///
/// 与 `freshness` 的分工：`freshness` 描述本次网络往返是否成功，`origin` 描述
/// 判定所用的**数据**从哪里来。条件请求命中 304 时网络往返是成功的
/// （`freshness` 仍为 `.fresh`），但版本值来自缓存文件，因此 `origin` 是
/// `.cachedFallback`：304 只确认“缓存里的那个版本仍然是上游最新”，不能让
/// 本地可改写的版本字符串变成自动安装的目标。
enum UpdateCheckOrigin: String, Equatable {
    case network
    case cachedFallback = "cached-fallback"
    case unavailable

    var displayName: String {
        switch self {
        case .network: return "本次网络检查"
        case .cachedFallback: return "本机缓存"
        case .unavailable: return "无可用结果"
        }
    }

    /// 是否允许作为自动安装的判定依据。只有本次网络结果可以。
    var isEligibleForAutomaticInstall: Bool { self == .network }

    /// 自动安装前的来源拒绝文案（Pi Web / Pi CLI / Pi 扩展包共用同一组固定
    /// 事实）。缓存回退分支包含“缓存”与缓存写入时间，且不出现“已验证”“官方”
    /// 之类会被读成“本次已由上游确认”的措辞。
    func autoInstallRefusalText(cacheWrittenAt: Date?) -> String {
        switch self {
        case .cachedFallback:
            let stamp = cacheWrittenAt.map { "（缓存写入时间 \(UpdateCheckTimestamp.text($0))）" } ?? ""
            return "判定所用的检查结果来自本机缓存\(stamp)，不是本次运行从白名单主机取得的网络结果；缓存不是可信输入，自动更新不做"
        case .network:
            return "判定所用的检查结果不是本次运行从白名单主机取得的网络结果"
        case .unavailable:
            return "本次运行没有可用的网络检查结果；缓存回退与缓存缺失都不触发自动更新"
        }
    }
}

/// 缓存时间戳的固定展示格式：UTC、秒级，不依赖机器时区与语言，日志、诊断与
/// 测试断言因此是确定性的。
enum UpdateCheckTimestamp {
    static func text(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        return formatter.string(from: date)
    }
}
