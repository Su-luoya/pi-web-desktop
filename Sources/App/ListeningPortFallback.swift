/// 监听端口被占用时的空闲端口回落（issue：端口冲突后 pi-web 启动即退出）。
///
/// 生产实证：`EADDRINUSE` 与「地址不在本机」是同一类问题的两个面——配置的端口被
/// 别的程序（或者上一次没退干净的实例）占着时，pi-web 一 `bind` 就失败退出，
/// 应用只能看到一条通用的「进程已退出」。本文件只做纯判定，不写 UserDefaults、
/// 不改配置：
///
/// - 只有配置端口**确实**不可用（`bind(2)` 返回 `EADDRINUSE`）才回落；
///   无法判定（主机名、权限错误等）一律不回落，交由既有路径报错，绝不因为
///   「看起来可能被占」就把用户的服务挪到别的端口。
/// - 回落从配置端口往后扫，取第一个可绑定的端口；扫完仍没有空闲端口时**不**回落，
///   调用方沿用配置端口，启动失败的原因仍然可见。
/// - 配置保持原样，下一次启动重新探测：端口腾出来就继续用原端口。

import Foundation

/// 一次端口回落的事实记录：只描述「配置了什么、实际用了什么」。
struct ListeningPortFallback: Equatable {
    /// 配置里要求的端口；没有回落时为 nil。
    var requested: Int?
    /// 实际生效的监听端口。
    var effective: Int

    /// 没有回落：生效端口仍是配置端口。
    static func none(_ port: Int) -> ListeningPortFallback {
        ListeningPortFallback(requested: nil, effective: port)
    }

    var isActive: Bool { requested != nil }

    /// 可读提示：说明为什么换了端口，以及配置本身没有被改动。
    var notice: String? {
        guard let requested else { return nil }
        return "端口 \(requested) 当前被其它程序占用，已临时改用 \(effective) 启动。"
            + "设置里的端口没有改动，下次启动会重新检测。"
    }
}

/// 端口可用性探测。与地址判定一样可注入，测试不碰真实 socket。
protocol PortAvailabilityProbing {
    /// `nil` 表示无法判定（例如主机名、权限不足）。
    func isPortAvailable(host: String, port: Int) -> Bool?
}

extension SystemDependencyPortProbe: PortAvailabilityProbing {}

enum ListeningPortFallbackPolicy {
    /// 从配置端口往后最多探测多少个端口。20 足够跨过常见的一两个冲突进程，
    /// 又不会在端口全被占用的机器上扫出一大片。
    static let scanLimit = 20

    /// 配置端口的可用性结论 + 本次启动应使用的端口。
    ///
    /// 只有「确定被占用」才回落；无法判定时返回配置端口，启动失败原因不变。
    static func resolve(
        hostname: String,
        port: Int,
        isAvailable: (String, Int) -> Bool? = { SystemDependencyPortProbe().isPortAvailable(host: $0, port: $1) }
    ) -> ListeningPortFallback {
        guard (1...65535).contains(port) else { return .none(port) }
        switch isAvailable(hostname, port) {
        case .some(false):
            break
        case .some(true), .none:
            return .none(port)
        }
        let upper = min(port + scanLimit, 65535)
        guard port + 1 <= upper else { return .none(port) }
        for candidate in (port + 1)...upper where isAvailable(hostname, candidate) == true {
            return ListeningPortFallback(requested: port, effective: candidate)
        }
        // 一段连续端口都被占用：不猜测，沿用配置端口，让失败原因保持可见。
        return .none(port)
    }
}
