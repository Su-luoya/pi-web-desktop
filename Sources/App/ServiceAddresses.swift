/// 手机可访问的地址模型与探测（GitHub #150）。
///
/// 「复制手机访问链接」需要把服务从 loopback 切到手机能连到的地址：Tailscale
/// 的 CGNAT 地址（`100.x.y.z`）或局域网私网地址。分类是纯函数，枚举接口
/// 的探测走可注入的 provider，因此这段逻辑可以在不访问真实网络的测试里覆盖。
///
/// 探测结果只用于菜单候选与剪贴板，不写入日志、诊断导出或错误文案。

import Darwin
import Foundation

/// 手机可以访问的地址种类。
enum ServiceAddressKind: Equatable {
    /// CGNAT 网段（`100.x.y.z`）：Tailscale 等覆盖网络的地址。
    case tailnet
    /// 局域网私网地址：`10/8`、`172.16/12`、`192.168/16`。
    case localNetwork

    /// 菜单里显示的种类名。
    var title: String {
        switch self {
        case .tailnet: return "Tailscale"
        case .localNetwork: return "局域网"
        }
    }
}

/// 一个可用于手机访问的 IPv4 地址。
struct ServiceAddress: Equatable {
    let kind: ServiceAddressKind
    let ipv4: String

    /// 子菜单候选项标题：`Tailscale · 100.x.y.z`、`局域网 · 192.168.x.y`。
    var title: String { "\(kind.title) · \(ipv4)" }
}

/// IPv4 文本到地址种类的纯分类。
///
/// 只接受点分四段十进制（每段 0–255）；loopback `127/8`、link-local
/// `169.254/16` 与其余地址都返回 nil —— 手机连不上它们，不是候选项。
enum ServiceAddressClassifier {
    static func kind(forIPv4 address: String) -> ServiceAddressKind? {
        guard let octets = ipv4Octets(address) else { return nil }
        let (first, second, _, _) = octets
        // 100.x.y.z：CGNAT 段，Tailscale 默认从这里选地址。
        if first == 100, (64...127).contains(second) { return .tailnet }
        if first == 10 { return .localNetwork }
        // 172.16.0.0/12。
        if first == 172, (16...31).contains(second) { return .localNetwork }
        if first == 192, second == 168 { return .localNetwork }
        return nil
    }

    /// 严格的点分四段解析；任何非数字段、越界段或段数不对都返回 nil。
    private static func ipv4Octets(_ address: String) -> (UInt8, UInt8, UInt8, UInt8)? {
        let parts = address.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var octets: [UInt8] = []
        for part in parts {
            guard part.allSatisfy({ $0.isASCII && $0.isNumber }), let value = UInt8(part) else { return nil }
            octets.append(value)
        }
        return (octets[0], octets[1], octets[2], octets[3])
    }
}

/// 地址列表的纯过滤、去重与稳定排序：探测实现与测试共用同一段逻辑。
enum ServiceAddressList {
    /// 丢弃非候选地址（loopback、link-local、非法文本）、按地址文本去重，再按
    /// 「Tailscale 在前，组内按地址字符串升序」输出稳定顺序。
    static func classifyAndSort(_ rawIPv4Addresses: [String]) -> [ServiceAddress] {
        var seen = Set<String>()
        var addresses: [ServiceAddress] = []
        for raw in rawIPv4Addresses {
            let ipv4 = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard seen.insert(ipv4).inserted else { continue }
            guard let kind = ServiceAddressClassifier.kind(forIPv4: ipv4) else { continue }
            addresses.append(ServiceAddress(kind: kind, ipv4: ipv4))
        }
        return addresses.sorted { lhs, rhs in
            if lhs.kind != rhs.kind { return lhs.kind == .tailnet }
            return lhs.ipv4 < rhs.ipv4
        }
    }
}

/// 本机 IPv4 地址探测；默认实现只读枚举接口，测试注入替身。
protocol NetworkAddressProviding {
    func ipv4Addresses() -> [ServiceAddress]
}

/// `getifaddrs` 实现：枚举启用中的非 loopback 接口的 `AF_INET` 地址。
///
/// 不读取任何接口之外的系统信息，不发起网络请求；顺序不稳定由
/// `ServiceAddressList.classifyAndSort` 收敛。
struct SystemNetworkAddressProvider: NetworkAddressProviding {
    func ipv4Addresses() -> [ServiceAddress] {
        ServiceAddressList.classifyAndSort(rawIPv4Addresses())
    }

    /// 原始地址枚举：未启用、loopback 或无地址的接口直接跳过。
    private func rawIPv4Addresses() -> [String] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(first) }

        var addresses: [String] = []
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let interface = cursor {
            cursor = interface.pointee.ifa_next
            let flags = interface.pointee.ifa_flags
            guard flags & UInt32(IFF_UP) != 0, flags & UInt32(IFF_LOOPBACK) == 0 else { continue }
            guard let socketAddress = interface.pointee.ifa_addr,
                  socketAddress.pointee.sa_family == UInt8(AF_INET) else { continue }
            var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            let status = getnameinfo(
                socketAddress,
                socklen_t(socketAddress.pointee.sa_len),
                &buffer,
                socklen_t(buffer.count),
                nil,
                0,
                NI_NUMERICHOST
            )
            guard status == 0, let text = String(validatingUTF8: buffer) else { continue }
            addresses.append(text)
        }
        return addresses
    }
}

/// 子菜单候选项的纯描述；AppKit 层只负责把它映射成 `NSMenuItem`。
struct PhoneAccessMenuEntry: Equatable {
    let title: String
    /// 候选地址；无候选时的说明项为 nil。
    let address: ServiceAddress?
    /// 说明项禁用，候选可点。
    let isEnabled: Bool
}

/// 「复制手机访问链接」子菜单的内容构建。
enum PhoneAccessMenuBuilder {
    /// 没有任何可用地址时的说明项文案。
    static let emptyTitle = "未检测到可用的 Tailscale 或局域网地址"

    static func entries(for addresses: [ServiceAddress]) -> [PhoneAccessMenuEntry] {
        guard !addresses.isEmpty else {
            return [PhoneAccessMenuEntry(title: emptyTitle, address: nil, isEnabled: false)]
        }
        return addresses.map { PhoneAccessMenuEntry(title: $0.title, address: $0, isEnabled: true) }
    }
}

/// 选中一个候选地址后的下一步动作（纯判定，交互层只做呈现）。
enum ServiceAddressDecision: Equatable {
    /// 已经是当前监听地址：直接复制链接，不改配置、不重启。
    case copyOnly
    /// Keychain 里没有可用密码：提示先设置密码，不改配置、不启动远程监听。
    case needsPassword
    /// 需要切换监听地址并重启服务：先向用户确认。
    case needsConfirmation

    /// 判定规则：地址已经是当前监听地址就只复制；否则没有密码时先补密码，
    /// 有密码时才允许进入“切换并重启”的确认流程。
    static func decide(
        currentHostname: String,
        selected: ServiceAddress,
        hasPassword: Bool
    ) -> ServiceAddressDecision {
        if currentHostname == selected.ipv4 { return .copyOnly }
        return hasPassword ? .needsConfirmation : .needsPassword
    }
}

/// 手机访问链接：`http://<地址>:<端口>/`。只按选中地址构造，不改 `startURL`。
enum ServiceAddressLink {
    static func url(forIPv4 ipv4: String, port: Int) -> URL? {
        var components = URLComponents()
        components.scheme = "http"
        components.host = ipv4
        components.port = port
        components.path = "/"
        return components.url
    }
}

/// `NSMenuItem.representedObject` 只接受对象：用它把值类型地址带进菜单动作。
final class ServiceAddressBox: NSObject {
    let address: ServiceAddress

    init(_ address: ServiceAddress) {
        self.address = address
    }
}
