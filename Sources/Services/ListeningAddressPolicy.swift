/// 监听地址的唯一判定入口（GitHub #39 / 安全审查 R-3）。
///
/// 保存、加载与启动三条路径共用 `RemoteAccessPolicy.addressVerdict(hostname:)`：
/// 直接改写 UserDefaults 能绕过的只有界面，不是这条规则。判定是纯函数，不读
/// Keychain、不写配置、不启动进程。
///
/// 本应用不再持有访问密码：远程监听（非 loopback）不再需要凭证门控。pi-web
/// 自身在缺 `PI_WEB_PASSWORD` 时只打印一行警告并继续启动，因此明文 HTTP 上的
/// 远程访问**没有任何认证**，只能放在可信网络里，或由用户自己在应用之外套上
/// HTTPS 反向代理或加密隧道。界面负责把这一点讲清楚，不做静默放行。

import Darwin
import Foundation

/// 监听地址的统一判定结果。
enum ServiceAddressVerdict: Equatable {
    /// 地址可用；`hostname` 是规范化后的形式（IPv6 字面量去掉方括号）。
    case allowed(hostname: String)
    /// 地址不可用；`hostname` 是原始输入，`message` 是具体原因。
    case rejected(hostname: String, message: String)

    /// 保存路径使用的短提示；地址可用时为 nil。
    var rejectionMessage: String? {
        guard case .rejected(_, let message) = self else { return nil }
        return message
    }

    /// 加载/启动路径使用的完整诊断：指认非法值、给出允许范围并说明不会启动。
    /// 地址可用时为 nil。
    var diagnosisMessage: String? {
        guard case .rejected(let hostname, let message) = self else { return nil }
        return "监听地址“\(ServiceAddressVerdict.displayHostname(hostname))”不可用：\(message)"
            + "允许的取值是 loopback 地址（\(ServiceConfiguration.defaultHostname)、::1、localhost）"
            + "或你显式配置的具体地址；服务不会启动，也不会静默改用其他地址。"
            + "请在“设置…→服务”中修改监听地址后重试。"
    }

    /// 展示用文本：空值与含换行/制表符的输入都能看清，且不破坏单条消息。
    static func displayHostname(_ hostname: String) -> String {
        guard !hostname.isEmpty else { return "（空）" }
        return hostname
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")
    }
}

/// 监听地址的纯校验逻辑：不读文件、不启动进程、不联网。
///
/// 唯一的规则是「地址必须能被明确解读」：通配地址、空值、前后空白、非法字符、
/// 非规范数值写法一律拒绝，且拒绝时服务不会启动、也不会被静默改成其他地址。
enum RemoteAccessPolicy {
    /// 明确拒绝的“所有接口”地址。默认值仍是 loopback；这些地址既不是默认值，
    /// 也不应该被一次误输入打开，所以和协议前缀、路径一起被拒绝。
    static let allInterfacesHostnames: Set<String> = ["0.0.0.0", "::", "[::]", "*"]

    /// 远程监听（非 loopback）在明文 HTTP 上没有任何认证时的固定提示文案：
    /// 设置窗口、启动失败提示与诊断导出共用同一条。
    static let unauthenticatedRemoteWarning =
        "监听地址不是本机回环地址：pi-web 会在这个地址上提供对 agent 的完全访问，"
        + "而本应用不提供访问密码，因此这条连接没有任何认证。"
        + "只在可信网络里这样使用；需要跨不可信网络访问时，请自行套上 HTTPS 反向代理"
        + "或加密隧道（例如 WireGuard、SSH 端口转发），并在 pi-web 一侧设置访问密码。"

    /// 规范化 hostname：去掉两端空白，并把 IPv6 字面量的方括号去掉。
    ///
    /// 存储和子进程参数都用不带方括号的形式（`::1`，与 `--hostname` 的约定
    /// 一致），只有 URL 主机需要方括号；`[::1]` 与 `::1` 因此等价。
    static func normalizedHostname(_ hostname: String) -> String {
        let trimmed = hostname.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("["), trimmed.hasSuffix("]"), trimmed.count > 2 else { return trimmed }
        let literal = String(trimmed.dropFirst().dropLast())
        return literal.contains(":") ? literal : trimmed
    }

    /// URL 主机形式：IPv6 字面量必须加方括号。
    ///
    /// `http://::1:30141/` 不是合法 URL（`URLComponents` 对 `host = "::1"` 返回
    /// nil），`http://[::1]:30141/` 才是；主机名与 IPv4 不含冒号，原样返回。
    /// 空值按政策就是 loopback，这里也返回默认地址，绝不拼出空 host 的 URL。
    static func urlHost(for hostname: String) -> String {
        let host = normalizedHostname(hostname)
        guard !host.isEmpty else { return ServiceConfiguration.defaultHostname }
        guard host.contains(":") else { return host }
        return "[\(host)]"
    }

    /// 是否是合法的 IPv6 字面量（已去方括号）。用于拒绝 `host:port` 这类误输入。
    static func isIPv6Literal(_ hostname: String) -> Bool {
        var address = in6_addr()
        return hostname.contains(":") && inet_pton(AF_INET6, hostname, &address) == 1
    }

    /// loopback 判定：空值按 loopback 处理（默认配置），并覆盖 `localhost`、
    /// `*.localhost`、`::1` 与整个 `127.0.0.0/8`。
    static func isLoopbackHostname(_ hostname: String) -> Bool {
        let host = hostname.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if host.isEmpty || host == "localhost" || host == "::1" || host == "[::1]" { return true }
        if host.hasSuffix(".localhost") { return true }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count == 4, labels[0] == "127" else { return false }
        return labels.dropFirst().allSatisfy { UInt8($0) != nil }
    }

    /// 监听地址的唯一判定函数（不含凭证）：保存、加载与启动三条路径共用。
    ///
    /// 判定顺序：空值 → 前后空白 → 通配地址 → 非法字符 → 空标签 →
    /// 方括号/冒号只允许 IPv6 字面量 → 语义通配与歧义数值。通过时返回规范化
    /// 形式，拒绝时返回可读原因。
    static func addressVerdict(hostname: String) -> ServiceAddressVerdict {
        let trimmed = hostname.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .rejected(
                hostname: hostname,
                message: "请填写监听地址；仅本机访问请使用 \(ServiceConfiguration.defaultHostname)。"
            )
        }
        guard trimmed == hostname else {
            return .rejected(hostname: hostname, message: "监听地址前后不能有空白字符。")
        }
        if allInterfacesHostnames.contains(trimmed.lowercased()) {
            return wildcardRejection(hostname: hostname, display: trimmed)
        }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_[]:")
        guard trimmed.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
            return .rejected(
                hostname: hostname,
                message: "监听地址只能包含字母、数字、点、连字符、下划线和 IPv6 方括号；不要填写协议、路径或空格。"
            )
        }
        // 首字符为 `-` 会被下游 argparse/minimist 当作**选项**而不是取值：
        // `--hostname --no-open` 让 pi-web 收起 `--no-open`（或直接报错），而应用
        // 侧仍按该文本拼 URL。上面的字符集本身允许连字符（IPv6/主机名需要），
        // 因此必须单独拦首字符。
        guard !trimmed.hasPrefix("-") else {
            return .rejected(
                hostname: hostname,
                message: "监听地址不能以连字符开头：它会被当作命令行选项解析，请填写主机名或 IP 地址。"
            )
        }
        // 空标签（前导/尾随点、连续点）不是合法写法：`0.0.0.0.` 会被系统解析成
        // `0.0.0.0`，所以不能只靠与通配文本比较。
        if trimmed.split(separator: ".", omittingEmptySubsequences: false).contains(where: { $0.isEmpty }) {
            return .rejected(
                hostname: hostname,
                message: "监听地址的每一段都不能为空；不要以点开头或结尾，也不要连续使用点。"
            )
        }
        // 方括号只允许用于 IPv6 字面量（`[::1]`）：`[0.0.0.0]`、`[localhost]`
        // 这类输入不是合法主机形式，直接拒绝。
        if trimmed.hasPrefix("[") || trimmed.hasSuffix("]") {
            let literal = String(trimmed.dropFirst().dropLast())
            guard trimmed.hasPrefix("["), trimmed.hasSuffix("]"), trimmed.count > 2,
                  isIPv6Literal(literal) else {
                return .rejected(
                    hostname: hostname,
                    message: "监听地址的方括号只允许用于 IPv6 字面量（例如 [::1]）。"
                )
            }
        }
        let unbracketed = normalizedHostname(trimmed)
        // IPv6 全零（`0:0:0:0:0:0:0:0` 等）与 IPv4-mapped 全零
        // （`::ffff:0.0.0.0`）在 macOS 上都绑定所有接口。
        if isIPv6Literal(unbracketed), isWildcardIPv6Literal(unbracketed) {
            return wildcardRejection(hostname: hostname, display: trimmed)
        }
        // 冒号只允许出现在 IPv6 字面量里：`example.invalid:8443` 这类输入是把端口
        // 写进了地址，直接拒绝，避免拼出无意义的 URL。
        if trimmed.contains(":"), !isIPv6Literal(unbracketed) {
            return .rejected(
                hostname: hostname,
                message: "监听地址里的冒号只允许用于 IPv6 字面量；端口请填写在“端口”字段。"
            )
        }
        // 纯数字/十六进制形态会被 `getaddrinfo` 按 inet_aton 语义解析（`0`、`0x0`
        // 与 `000.000.000.000` 都是 0.0.0.0），文本上无法确认具体地址：只接受
        // 规范点分四段，其余一律拒绝并要求改写规范形式。
        if isAmbiguousNumericHostname(trimmed) {
            return .rejected(
                hostname: hostname,
                message: "监听地址只支持规范的 IPv4 点分形式（例如 \(ServiceConfiguration.defaultHostname)）、"
                    + "IPv6 字面量（例如 ::1）或主机名；\(trimmed) 这类数值写法会被系统按其他规则解析，"
                    + "无法确认具体地址，请改写规范形式。"
            )
        }
        return .allowed(hostname: unbracketed)
    }

    /// 通配地址的统一拒绝文案（保存、加载、启动三个入口共用）。
    private static func wildcardRejection(hostname: String, display: String) -> ServiceAddressVerdict {
        .rejected(
            hostname: hostname,
            message: "不允许监听 \(display)：这会暴露本机的所有网络接口。"
                + "请填写具体的远程地址，或保持 \(ServiceConfiguration.defaultHostname)。"
        )
    }

    /// IPv6 全零与 IPv4-mapped 全零的判定。macOS 上两者都绑定所有接口：
    /// `0:0:0:0:0:0:0:0`、`::0`、`::ffff:0.0.0.0`、`::ffff:0:0` 等写法与
    /// `::` 等价，因此不能只按文本比较。
    private static func isWildcardIPv6Literal(_ literal: String) -> Bool {
        var address = in6_addr()
        guard inet_pton(AF_INET6, literal, &address) == 1 else { return false }
        let bytes = withUnsafeBytes(of: address) { Array($0) }
        guard bytes.count == 16 else { return false }
        if bytes.allSatisfy({ $0 == 0 }) { return true }
        let isIPv4Mapped = bytes[0..<10].allSatisfy({ $0 == 0 }) && bytes[10] == 0xFF && bytes[11] == 0xFF
        return isIPv4Mapped && bytes[12..<16].allSatisfy({ $0 == 0 })
    }

    /// 纯数字或十六进制形态的地址候选：`0`、`000.000.000.000`、`0x0`、
    /// `0x00.0x00.0x00.0x00` 等。`getaddrinfo` 按 inet_aton 语义解析这些写法
    /// （都是 `0.0.0.0`），文本上无法确认具体地址，因此只允许规范的十进制
    /// 点分四段（每段无前导零且不超过 255），其余交给用户改写。
    private static func isAmbiguousNumericHostname(_ hostname: String) -> Bool {
        let labels = hostname.split(separator: ".", omittingEmptySubsequences: false)
        guard !labels.isEmpty else { return false }
        for label in labels {
            guard !label.isEmpty else { return false }
            if label.allSatisfy({ $0.isNumber }) { continue }
            if label.count > 2, label.hasPrefix("0x") || label.hasPrefix("0X"),
               label.dropFirst(2).allSatisfy({ $0.isHexDigit }) { continue }
            return false
        }
        guard labels.count == 4 else { return true }
        let canonical = labels.allSatisfy { label in
            (label == "0" || !label.hasPrefix("0")) && UInt8(label) != nil
        }
        return !canonical
    }

    /// 保存设置前的 hostname 校验；nil 表示可以保存。委托给同一个
    /// `addressVerdict(hostname:)`，界面保存、加载与启动判定同源。
    static func hostnameValidationMessage(_ hostname: String) -> String? {
        addressVerdict(hostname: hostname).rejectionMessage
    }

    /// 加载/启动路径的完整诊断；nil 表示地址可用。
    static func unusableHostnameMessage(_ hostname: String) -> String? {
        addressVerdict(hostname: hostname).diagnosisMessage
    }
}
