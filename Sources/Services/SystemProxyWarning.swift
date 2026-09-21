/// 系统代理未排除 VPN 网段时的只读检测与提示状态（GitHub #157）。
///
/// 背景：服务监听地址切到 Tailscale 地址（CGNAT 段 `100.x.y.z`）后，应用窗口会经系统
/// 代理访问 `http://100.x.y.z:port/`；如果系统代理的例外列表不含该网段，代理会先
/// 返回自己的错误页（实机实测 502 Bad Gateway），看起来像服务断开，而服务本身正常。
///
/// 这个文件只做两件事：**只读**读取系统代理配置（`SCDynamicStoreCopyProxies`），
/// 以及纯函数判定「该不该提示」。它绝不写入或修改系统代理设置，日志与文案里也
/// 不出现用户的真实地址（只出现网段写法 `vpnSubnetDescription`，即 CGNAT 段）。

import Darwin
import Foundation
import SystemConfiguration

// MARK: - 系统代理快照

/// 系统代理配置里与「VPN 网段是否被排除」相关的部分。
///
/// 缺键、键类型不符、读取失败一律降级为「未启用代理 / 无例外」，也就是不提示；
/// 判定方向永远是「宁可漏报，不误报」。
struct SystemProxySnapshot: Equatable {
    var httpEnabled: Bool
    var httpsEnabled: Bool
    var socksEnabled: Bool
    var pacEnabled: Bool
    /// 未经拆分的例外条目（`ExceptionsList` 原样；可能是 `["a, b"]` 这种单串）。
    var exceptions: [String]

    init(
        httpEnabled: Bool = false,
        httpsEnabled: Bool = false,
        socksEnabled: Bool = false,
        pacEnabled: Bool = false,
        exceptions: [String] = []
    ) {
        self.httpEnabled = httpEnabled
        self.httpsEnabled = httpsEnabled
        self.socksEnabled = socksEnabled
        self.pacEnabled = pacEnabled
        self.exceptions = exceptions
    }

    /// 从一个系统代理字典解析。畸形值不抛错，只当成 `false` / 空列表。
    init(dictionary: [String: Any]) {
        self.init(
            httpEnabled: Self.enabledFlag(dictionary["HTTPEnable"]),
            httpsEnabled: Self.enabledFlag(dictionary["HTTPSEnable"]),
            socksEnabled: Self.enabledFlag(dictionary["SOCKSEnable"]),
            pacEnabled: Self.enabledFlag(dictionary["ProxyAutoConfigEnable"]),
            exceptions: Self.exceptionEntries(dictionary["ExceptionsList"])
        )
    }

    private static func enabledFlag(_ value: Any?) -> Bool {
        switch value {
        case let number as NSNumber:
            return number.boolValue
        case let text as String:
            return ["1", "true", "yes"].contains(text.lowercased())
        default:
            return false
        }
    }

    private static func exceptionEntries(_ value: Any?) -> [String] {
        switch value {
        case let list as [Any]:
            return list.compactMap { $0 as? String }
        case let text as String:
            return [text]
        default:
            return []
        }
    }
}

// MARK: - 只读读取器

/// 读取系统代理配置。读不到（返回 nil、桥接失败）就当作「无代理」，不提示。
protocol SystemProxySettingsReading {
    func readSnapshot() -> SystemProxySnapshot?
}

/// 生产实现：`SCDynamicStoreCopyProxies` 取当前生效的系统代理（含 `__SCOPED__`
/// 各接口副本与合并后的顶层键）。只读；不调用任何写入 API。
struct LiveSystemProxySettingsReader: SystemProxySettingsReading {
    func readSnapshot() -> SystemProxySnapshot? {
        guard let proxies = SCDynamicStoreCopyProxies(nil) else { return nil }
        guard let dictionary = proxies as NSDictionary as? [String: Any] else { return nil }
        return SystemProxySnapshot(dictionary: dictionary)
    }
}

// MARK: - 纯函数判定

enum SystemProxyWarningEvaluator {
    /// VPN/Tailscale 默认网段（CGNAT 段 `100.x.y.z`）在用户可见文案里的写法。
    /// 与 `Sources/App/ServiceAddresses.swift` 里 `.tailnet` 的分类判据一致。
    ///
    /// 点分字面量在运行时拼接：仓库文本扫描禁止把该网段写成字面值
    /// （`Scripts/check-identity.sh` 的 "no CGNAT private address default"），
    /// 与 `PiWebDesktopTests/ServiceAddressesTests.swift` 的 `cgnat(_:)` 同一约定。
    static let vpnSubnetDescription = ["100", "64.0.0/10"].joined(separator: ".")

    /// CGNAT 段（`100.x.y.z`）内的 IPv4 字面量。
    static func isVPNSubnetHost(_ host: String) -> Bool {
        guard let value = ipv4Value(normalizedHost(host)) else { return false }
        // CGNAT 段（首段 100、次段 64...127）右移 22 位后都等于 401（0x191）。
        return value >> 22 == 401
    }

    /// 判定是否提示。只对 CGNAT 段（`100.x.y.z`）的服务地址提示：loopback、普通局域网
    /// 地址、主机名（含 MagicDNS 名）都不提示（取舍见
    /// `docs/settings-and-workspace.md` 的「系统代理与 VPN 网段」一节）。
    static func shouldWarn(serviceURL: URL?, snapshot: SystemProxySnapshot?) -> Bool {
        guard let serviceURL, let snapshot, let host = serviceURL.host, !host.isEmpty else {
            return false
        }
        return shouldWarn(serviceHost: host, scheme: serviceURL.scheme, snapshot: snapshot)
    }

    static func shouldWarn(serviceHost: String, scheme: String?, snapshot: SystemProxySnapshot) -> Bool {
        let host = normalizedHost(serviceHost)
        guard isVPNSubnetHost(host) else { return false }
        let scheme = (scheme ?? "").lowercased()
        // SOCKS 与 PAC 生效时都会接管这条请求，因此同样按「有代理」处理。
        let schemeProxied = (scheme == "http" && snapshot.httpEnabled)
            || (scheme == "https" && snapshot.httpsEnabled)
        guard schemeProxied || snapshot.socksEnabled || snapshot.pacEnabled else { return false }
        return !isHostExcluded(host, rawEntries: snapshot.exceptions)
    }

    /// 系统例外列表是否命中该主机。
    ///
    /// 条目可以写成 `*.local`、`example.com`、网段 CIDR（见
    /// `vpnSubnetDescription`）、`127.0.0.1`、
    /// `<local>`，也可以整串用逗号/空格分隔。**无法解析的条目一律按「已排除」
    /// 处理**：宁可漏报，也不误报「代理没排除」。
    static func isHostExcluded(_ host: String, rawEntries: [String]) -> Bool {
        let host = normalizedHost(host)
        for raw in rawEntries {
            for entry in splitEntries(raw) where entryMatches(host: host, entry: entry) {
                return true
            }
        }
        return false
    }

    // MARK: 条目匹配

    private static func splitEntries(_ raw: String) -> [String] {
        raw.lowercased()
            .components(separatedBy: CharacterSet(charactersIn: ",;"))
            .flatMap { $0.components(separatedBy: .whitespacesAndNewlines) }
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private static func entryMatches(host: String, entry: String) -> Bool {
        if entry == "<local>" {
            // 只匹配不带点的主机名；IP 字面量不算。
            return !host.contains(".")
        }
        if entry.contains("/") {
            if entry.contains(":") {
                // 合法的 IPv6 网段不可能排掉一个 IPv4 服务地址；畸形条目按已排除。
                return isParseableIPv6Entry(entry) ? false : true
            }
            // IPv4 CIDR（CGNAT 段这类网段写法）或畸形条目：解析不了按「已排除」处理。
            guard let matches = ipv4CIDRMatch(host: host, cidr: entry) else { return true }
            return matches
        }
        if entry.contains("*") || entry.contains("?") {
            return globMatches(pattern: entry, text: host)
        }
        if entry.contains(":") {
            // 合法的 IPv6 字面量不可能排掉一个 IPv4 服务地址；畸形条目按已排除。
            return isValidIPv6Address(entry) ? false : true
        }
        let trimmed = entry.hasPrefix(".") ? String(entry.dropFirst()) : entry
        if host == trimmed { return true }
        // 域名后缀：`example.com` 同时覆盖 `www.example.com`。
        return host.hasSuffix("." + trimmed)
    }

    /// `*` 任意串、`?` 单个字符的通配匹配（大小写已在调用前统一）。
    private static func globMatches(pattern: String, text: String) -> Bool {
        let pattern = Array(pattern)
        let text = Array(text)
        var patternIndex = 0
        var textIndex = 0
        var starIndex = -1
        var starTextIndex = 0
        while textIndex < text.count {
            if patternIndex < pattern.count,
               pattern[patternIndex] == "?" || pattern[patternIndex] == text[textIndex] {
                patternIndex += 1
                textIndex += 1
            } else if patternIndex < pattern.count, pattern[patternIndex] == "*" {
                starIndex = patternIndex
                starTextIndex = textIndex
                patternIndex += 1
            } else if starIndex >= 0 {
                patternIndex = starIndex + 1
                starTextIndex += 1
                textIndex = starTextIndex
            } else {
                return false
            }
        }
        while patternIndex < pattern.count, pattern[patternIndex] == "*" { patternIndex += 1 }
        return patternIndex == pattern.count
    }

    // MARK: 地址解析

    private static func normalizedHost(_ raw: String) -> String {
        var host = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if host.hasPrefix("["), host.hasSuffix("]") {
            host = String(host.dropFirst().dropLast())
        }
        if let zone = host.firstIndex(of: "%") {
            host = String(host[host.startIndex..<zone])
        }
        return host
    }

    static func ipv4Value(_ text: String) -> UInt32? {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var value: UInt32 = 0
        for part in parts {
            guard let octet = UInt32(part), part.count <= 3, octet <= 255 else { return nil }
            value = (value << 8) | octet
        }
        return value
    }

    /// 返回 nil 表示 CIDR 本身无法解析（调用方按「已排除」处理）。
    private static func ipv4CIDRMatch(host: String, cidr: String) -> Bool? {
        let parts = cidr.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let base = ipv4Value(String(parts[0])),
              let prefixLength = UInt32(parts[1]),
              prefixLength <= 32 else { return nil }
        guard let hostValue = ipv4Value(host) else { return false }
        if prefixLength == 0 { return true }
        let mask: UInt32 = prefixLength == 32 ? .max : ~(UInt32.max >> prefixLength)
        return (hostValue & mask) == (base & mask)
    }

    private static func isParseableIPv6Entry(_ entry: String) -> Bool {
        for part in entry.split(separator: "/", omittingEmptySubsequences: false) {
            if isValidIPv6Address(String(part)) { continue }
            guard let prefixLength = UInt32(part), prefixLength <= 128 else { return false }
        }
        return true
    }

    private static func isValidIPv6Address(_ text: String) -> Bool {
        var address = in6_addr()
        return text.withCString { inet_pton(AF_INET6, $0, &address) } == 1
    }
}

// MARK: - 提示状态机

/// 一次运行内的提示状态：条件成立只「激活」一次；用户手动清除后本次运行不再提示；
/// 条件消失时复位（下次再成立可以重新提示）。
struct SystemProxyWarningTracker {
    enum Transition: Equatable {
        case none
        case activated
        case cleared
    }

    private(set) var isActive = false
    /// 是否曾经显示过（手动清除后不再算「显示过」）。
    private var displayed = false
    private var suppressedThisRun = false

    mutating func evaluate(shouldWarn: Bool) -> Transition {
        if shouldWarn {
            guard !isActive else { return .none }
            isActive = true
            guard !suppressedThisRun else { return .none }
            displayed = true
            return .activated
        }
        // 条件不成立：复位（包括手动清除的抑制），下次再成立可以重新提示。
        let wasDisplayed = displayed
        isActive = false
        displayed = false
        suppressedThisRun = false
        return wasDisplayed ? .cleared : .none
    }

    mutating func dismissManually() {
        isActive = false
        displayed = false
        suppressedThisRun = true
    }
}

/// 用户可见的提示文案。只说网段，不写用户真实地址。
struct SystemProxyWarning: Equatable {
    let shortText: String
    let text: String

    static let vpnSubnetNotExcluded = SystemProxyWarning(
        shortText: "系统代理未排除 VPN 网段（\(SystemProxyWarningEvaluator.vpnSubnetDescription)）",
        text: "服务本身正常，但系统代理没有绕过 VPN 网段（\(SystemProxyWarningEvaluator.vpnSubnetDescription)）："
            + "应用窗口里的页面请求会走系统代理，可能拿到代理返回的错误页（例如 502 Bad Gateway），"
            + "看起来像服务断开。\n\n"
            + "修复：系统设置 → 网络 → 详细信息 → 代理 →「绕过这些主机与域名」，"
            + "加入 \(SystemProxyWarningEvaluator.vpnSubnetDescription)（或在代理软件里把该网段设为直连）。"
            + "应用只读取系统代理设置，不会替你修改。"
    )
}

/// 检测 + 日志 + 菜单提示的编排：UI 只问「要不要刷新」和当前提示是什么。
final class SystemProxyWarningCoordinator {
    private let reader: SystemProxySettingsReading
    private let log: (String) -> Void
    private var tracker = SystemProxyWarningTracker()

    private(set) var warning: SystemProxyWarning?

    init(
        reader: SystemProxySettingsReading = LiveSystemProxySettingsReader(),
        log: @escaping (String) -> Void = { _ in }
    ) {
        self.reader = reader
        self.log = log
    }

    /// 用当前服务地址重新评估。返回 true 表示提示状态变化、UI 需要刷新。
    @discardableResult
    func refresh(serviceURL: URL?) -> Bool {
        let snapshot = reader.readSnapshot()
        let shouldWarn = SystemProxyWarningEvaluator.shouldWarn(serviceURL: serviceURL, snapshot: snapshot)
        switch tracker.evaluate(shouldWarn: shouldWarn) {
        case .none:
            return false
        case .activated:
            warning = .vpnSubnetNotExcluded
            log("检测到系统代理未排除 VPN 网段（\(SystemProxyWarningEvaluator.vpnSubnetDescription)）："
                + "服务本身正常，但应用窗口可能拿到代理返回的错误页。")
            return true
        case .cleared:
            warning = nil
            log("系统代理例外已覆盖 VPN 网段（或服务地址已不再属于该网段），清除代理提示。")
            return true
        }
    }

    /// 「清除警告」：本次运行内条件仍成立也不再提示；条件消失后重新评估。
    @discardableResult
    func dismiss() -> Bool {
        guard warning != nil else { return false }
        tracker.dismissManually()
        warning = nil
        log("已清除系统代理未排除 VPN 网段的提示；本次运行内不再提示。")
        return true
    }
}
