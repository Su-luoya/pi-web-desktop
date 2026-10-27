/// 监听地址在本机不存在时的回环回落（issue：Tailscale 地址掉线后 pi-web 秒退）。
///
/// 生产实证：设置里保存的是覆盖网络地址（Tailscale 的 CGNAT 段），Tailscale 没运行
/// 或地址变了时本机根本没有这个地址；pi-web 直接 `bind` 失败（`EADDRNOTAVAIL`）秒退，
/// 应用只能看到一条通用的“进程已退出”，用户无从判断原因。本文件只做纯判定，不写
/// UserDefaults、不改配置：
///
/// - 只有通过既有地址校验的值才检测；空值、带空白、非法字符、通配地址返回 `.unknown`，
///   由 `RemoteAccessPolicy` 继续给出可读诊断，绝不因为“看起来可用”而放行。
/// - IPv4/IPv6 字面量按字符串与本机接口地址比较（含 loopback），不走 DNS；
///   主机名走 `getaddrinfo` 并要求结果与接口地址重合。
/// - 判定为不存在时，调用方用回环地址启动并明确告知；配置保持原样，下一次启动
///   若地址恢复就仍然用原地址。

import Darwin
import Foundation

/// 配置的监听地址在本机的存在性判定结果。
enum ListeningAddressPresence: Equatable {
    /// 本机确实有该地址（或该主机名解析到本机）。
    case present
    /// 本机没有该地址：用它启动只会得到 `EADDRNOTAVAIL`。
    case missing
    /// 无法判定（非法值）。调用方沿用既有校验路径。
    case unknown
}

/// 一次回环回落的事实记录：只描述“配置了什么、实际用了什么”。
struct ListeningAddressFallback: Equatable {
    /// 配置里要求监听的地址；没有回落时为 nil。
    var requested: String?
    /// 实际生效的监听地址。
    var effective: String

    /// 没有回落：生效地址仍是配置地址。
    static func none(_ hostname: String) -> ListeningAddressFallback {
        ListeningAddressFallback(requested: nil, effective: hostname)
    }

    var isActive: Bool { requested != nil }

    /// 可读提示：说明为什么改用了回环地址，以及配置本身没有被改动。
    var notice: String? {
        guard let requested else { return nil }
        return "监听地址 \(requested) 当前不在本机（例如 Tailscale 未运行或地址已变化），"
            + "已临时改用 \(effective) 启动。设置里的监听地址没有改动，下次启动会重新检测。"
    }
}

enum ListeningAddressFallbackPolicy {
    /// 回落目标：与默认配置同一个回环地址。
    static let fallbackHostname = ServiceConfiguration.defaultHostname

    /// 配置地址的可用性结论 + 本次启动应使用的监听地址。
    ///
    /// 两个依赖都可注入，测试因此不访问真实接口表与 DNS。
    static func resolve(
        hostname: String,
        localAddresses: @escaping () -> LocalAddresses = LocalAddresses.current,
        resolvesToLocalHost: ((String) -> Bool)? = nil
    ) -> (presence: ListeningAddressPresence, fallback: ListeningAddressFallback) {
        let resolver = resolvesToLocalHost
            ?? { HostnameResolver.resolvesToLocalHost($0, localAddresses: localAddresses) }
        let presence = self.presence(
            of: hostname,
            localAddresses: localAddresses,
            resolvesToLocalHost: resolver
        )
        guard presence == .missing else { return (presence, .none(hostname)) }
        return (.missing, ListeningAddressFallback(requested: hostname, effective: fallbackHostname))
    }

    /// 单个地址的存在性判定：只回答“本机有没有这个地址”，不涉及配置改动。
    static func presence(
        of hostname: String,
        localAddresses: @escaping () -> LocalAddresses = LocalAddresses.current,
        resolvesToLocalHost: ((String) -> Bool)? = nil
    ) -> ListeningAddressPresence {
        let resolver = resolvesToLocalHost
            ?? { HostnameResolver.resolvesToLocalHost($0, localAddresses: localAddresses) }
        // 先过既有校验：非法/通配地址不进入检测，诊断仍由 `RemoteAccessPolicy` 给出。
        guard RemoteAccessPolicy.addressVerdict(hostname: hostname).diagnosisMessage == nil else {
            return .unknown
        }
        let host = RemoteAccessPolicy.normalizedHostname(hostname)
        if RemoteAccessPolicy.isLoopbackHostname(host) { return .present }
        let local = localAddresses()
        if isIPv4Literal(host) {
            return local.ipv4.contains(host) ? .present : .missing
        }
        if RemoteAccessPolicy.isIPv6Literal(host) {
            return local.ipv6.contains(host.lowercased()) ? .present : .missing
        }
        return resolver(host) ? .present : .missing
    }

    /// 严格的点分四段 IPv4 判定。覆盖网络地址必须按字面量比较，不能交给 DNS：
    /// `getaddrinfo` 对不存在的数字地址可能给出别的主机结果。
    static func isIPv4Literal(_ hostname: String) -> Bool {
        var address = in_addr()
        return inet_pton(AF_INET, hostname, &address) == 1
    }
}

/// 本机接口地址快照（含 loopback）。只用于“配置的地址还在不在本机”这一判断，
/// 不写入日志、诊断导出或提示文案。
struct LocalAddresses: Equatable {
    var ipv4: Set<String>
    var ipv6: Set<String>

    static func current() -> LocalAddresses {
        var snapshot = LocalAddresses(ipv4: [], ipv6: [])
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return snapshot }
        defer { freeifaddrs(first) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let interface = cursor {
            cursor = interface.pointee.ifa_next
            guard interface.pointee.ifa_flags & UInt32(IFF_UP) != 0,
                  let socketAddress = interface.pointee.ifa_addr else { continue }
            switch Int32(socketAddress.pointee.sa_family) {
            case AF_INET:
                if let text = numericHost(socketAddress) { snapshot.ipv4.insert(text) }
            case AF_INET6:
                if let text = numericHost(socketAddress) { snapshot.ipv6.insert(text.lowercased()) }
            default:
                continue
            }
        }
        return snapshot
    }
}

enum HostnameResolver {
    /// 主机名是否解析到本机：解析成功且至少一个结果属于本机接口地址。
    ///
    /// 只看解析结果是否与接口地址重合，不发起连接，也不做反向解析；解析失败或
    /// 解析结果都不在本机时判为不可用——宁可回落到回环地址，也不要再重复一次
    /// `EADDRNOTAVAIL` 秒退。
    static func resolvesToLocalHost(
        _ hostname: String,
        localAddresses: () -> LocalAddresses = LocalAddresses.current
    ) -> Bool {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        hints.ai_flags = AI_ADDRCONFIG
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(hostname, nil, &hints, &result) == 0, let first = result else { return false }
        defer { freeaddrinfo(first) }
        let local = localAddresses()
        var cursor: UnsafeMutablePointer<addrinfo>? = first
        while let entry = cursor {
            cursor = entry.pointee.ai_next
            guard let address = entry.pointee.ai_addr,
                  let text = numericHost(address, length: entry.pointee.ai_addrlen) else { continue }
            switch Int32(address.pointee.sa_family) {
            case AF_INET: if local.ipv4.contains(text) { return true }
            case AF_INET6: if local.ipv6.contains(text.lowercased()) { return true }
            default: continue
            }
        }
        return false
    }
}

/// `sockaddr` 到数字形式地址文本；失败返回 nil。
private func numericHost(_ socketAddress: UnsafeMutablePointer<sockaddr>) -> String? {
    numericHost(socketAddress, length: socklen_t(socketAddress.pointee.sa_len))
}

private func numericHost(_ socketAddress: UnsafeMutablePointer<sockaddr>, length: socklen_t) -> String? {
    var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
    let status = getnameinfo(socketAddress, length, &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST)
    guard status == 0 else { return nil }
    return String(validatingUTF8: buffer)
}
