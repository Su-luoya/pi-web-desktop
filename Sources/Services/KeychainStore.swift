import Foundation
import Security

// MARK: - 错误

/// Keychain 操作失败的原因。
///
/// 错误只描述失败本身：不携带密码、密码长度或 Keychain 原始数据，因此可以安全地
/// 进入界面提示、日志和诊断文本。`OSStatus` 只出现在 `status` 分支里，调用方
/// 不需要解析它就能给出可读提示。

/// Remote access password storage and remote access gating.

enum KeychainStoreError: Error, Equatable, LocalizedError {
    /// 指定 account 下没有条目。
    case notFound
    /// `Security` 框架返回的错误码。
    case status(OSStatus)
    /// 条目的值无法按 UTF-8 解码；不携带原始数据。
    case undecodableData

    var errorDescription: String? {
        switch self {
        case .notFound:
            return "Keychain 中没有找到该条目。"
        case .status(let status):
            let detail = SecCopyErrorMessageString(status, nil) as String? ?? "未知错误"
            return "Keychain 操作失败（OSStatus \(status)：\(detail)）。"
        case .undecodableData:
            return "Keychain 中的条目内容无法读取。"
        }
    }
}

// MARK: - 协议

/// 远程访问密码的存储接口。
///
/// 生产实现是 `KeychainStore`（macOS Keychain）；测试使用内存替身，绝不访问真实
/// Keychain。协议只提供保存、读取、删除和存在性判断，没有“把密码写进普通设置”
/// 的入口，所以调用方不可能把秘密写进 UserDefaults、命令行、日志或诊断文本。
protocol KeychainStoring {
    /// 写入或覆盖 account 下的密码。
    func save(_ password: String, for account: String) throws
    /// 读取 account 下的密码；没有条目时抛 `KeychainStoreError.notFound`。
    func load(for account: String) throws -> String
    /// 删除 account 下的条目；条目本来就不存在时视为成功（幂等）。
    func delete(for account: String) throws
    /// account 下是否存在**非空**密码；任何读取失败都返回 false。
    func exists(for account: String) -> Bool
}

// MARK: - macOS Security 实现

/// `kSecClassGenericPassword` 实现：service 是当前 bundle identifier，account 是
/// 调用方给出的逻辑名（远程访问密码用 `RemoteAccessPassword.account`）。
///
/// 可访问性固定为 `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`：设备解锁过
/// 一次之后应用才能读取（托管服务在用户登录后启动，因此总是可用），并且条目不会
/// 随备份迁移到其他设备。密码只存在这里，不进入 UserDefaults、命令行、日志、
/// 诊断文本或错误消息。
struct KeychainStore: KeychainStoring {
    /// `kSecAttrService`。默认取当前 bundle identifier，测试可以注入固定值。
    let service: String

    init(service: String = KeychainStore.defaultService) {
        self.service = service
    }

    /// 服务名默认取当前 bundle identifier；缺少时回退到可执行名，不复制任何
    /// 身份或版本字面值。
    static var defaultService: String {
        Bundle.main.bundleIdentifier ?? "PiWebDesktop"
    }

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    func save(_ password: String, for account: String) throws {
        let attributes: [String: Any] = [
            kSecValueData as String: Data(password.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let updateStatus = SecItemUpdate(baseQuery(account: account) as CFDictionary, attributes as CFDictionary)
        switch updateStatus {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var insertQuery = baseQuery(account: account)
            for (key, value) in attributes { insertQuery[key] = value }
            let addStatus = SecItemAdd(insertQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw KeychainStoreError.status(addStatus) }
        default:
            throw KeychainStoreError.status(updateStatus)
        }
    }

    func load(for account: String) throws -> String {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            break
        case errSecItemNotFound:
            throw KeychainStoreError.notFound
        default:
            throw KeychainStoreError.status(status)
        }
        guard let data = item as? Data, let password = String(data: data, encoding: .utf8) else {
            throw KeychainStoreError.undecodableData
        }
        return password
    }

    func delete(for account: String) throws {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainStoreError.status(status)
        }
    }

    func exists(for account: String) -> Bool {
        guard let password = try? load(for: account) else { return false }
        return !password.isEmpty
    }
}

// MARK: - 远程访问密码

/// 远程访问密码的账户名和读取入口。
///
/// 密码只存放在 Keychain 的这一个条目里。这个命名空间只返回“密码本身”或
/// “是否已设置”的结论；界面、诊断和错误文本一律使用 `statusText(isSet:)`，
/// 它不包含密码值、密码长度或 Keychain 原始数据。
enum RemoteAccessPassword {
    /// `kSecAttrAccount`：唯一存放远程访问密码的条目。
    static let account = "remote-access-password"

    /// 读取已保存的密码；不存在、为空或读取失败都返回 nil。
    ///
    /// 失败即“无密码”（fail closed）：远程模式在读取失败时被拒绝，而不是退化成
    /// 无认证监听。
    static func load(from keychain: KeychainStoring, account: String = account) -> String? {
        guard let password = try? keychain.load(for: account), !password.isEmpty else { return nil }
        return password
    }

    /// 是否存在可用的非空密码。
    static func isSet(in keychain: KeychainStoring, account: String = account) -> Bool {
        load(from: keychain, account: account) != nil
    }

    /// 只用于界面和诊断的状态文案：不含密码值、密码长度或 Keychain 原始数据。
    static func statusText(isSet: Bool) -> String {
        isSet ? "已设置（仅存于 Keychain）" : "未设置"
    }
}

// MARK: - 秘密脱敏

/// 从任意文本里移除已知秘密。
///
/// 所有要把错误文本展示给用户的路径都会先过一遍这里，因此即使底层错误描述或
/// 测试替身意外带上了密码，界面、日志和诊断文本里也不会出现它。
enum SecretScrubbing {
    static let placeholder = "<redacted>"

    static func scrub(_ text: String, secrets: [String]) -> String {
        var result = text
        for secret in secrets where !secret.isEmpty {
            result = result.replacingOccurrences(of: secret, with: placeholder)
        }
        return result
    }
}

// MARK: - 远程模式门控

/// 监听地址的统一判定结果（GitHub #39 / 安全审查 R-3）。
///
/// 偏好窗口保存路径、`ServiceConfiguration.load` 与 `ServiceManager.startDecision`
/// 共用 `RemoteAccessPolicy.addressVerdict(hostname:)`：直接改写 UserDefaults 能
/// 绕过的只有界面，不是这条规则。
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

/// 远程监听的纯门控逻辑：不读 Keychain、不写配置、不启动进程。
///
/// 规则有两条：地址本身必须通过 `addressVerdict(hostname:)`（通配地址、空值、
/// 空白与非法字符一律拒绝），loopback 地址不需要密码，任何非 loopback 地址都要求
/// Keychain 中存在非空密码。删除密码后用 `disablingRemoteAccess(in:)` 把配置收回
/// 默认 loopback。
enum RemoteAccessPolicy {
    /// 明确拒绝的“所有接口”地址。默认值仍是 loopback；这些地址既不是默认值，
    /// 也不应该被一次误输入打开，所以和协议前缀、路径一起被拒绝。
    static let allInterfacesHostnames: Set<String> = ["0.0.0.0", "::", "[::]", "*"]

    /// 远程监听缺少密码时的固定提示文案（启动、保存、界面共用）。
    static let missingPasswordMessage = "远程监听需要先设置访问密码：请打开“设置…→远程访问”，输入或生成密码后再试。"

    /// 运行中密码被删除或读取失败、远程托管进程被停止时的固定提示。
    static let revokedPasswordMessage =
        "远程访问密码已被删除或无法读取，已停止远程服务并关闭远程模式；"
        + "监听地址已回到 \(ServiceConfiguration.defaultHostname)。"

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

    /// 远程监听是否被允许：loopback 恒为 true；非 loopback 必须有非空密码。
    ///
    /// 这是 #8 的纯凭证门控；地址本身是否合法由 `addressVerdict(hostname:)`
    /// 判定，启动路径必须两者都通过（`ServiceManager.isStartPermitted` /
    /// `startDecision(credentials:)`），所以这里沿用 loopback 语义，不把非法地址
    /// 混入凭证收敛路径。
    static func allowsRemoteListening(hostname: String, password: String?) -> Bool {
        isLoopbackHostname(hostname) || !(password ?? "").isEmpty
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

    /// 远程监听的前置条件提示；nil 表示满足（loopback，或已有非空密码）。
    static func remoteAccessRequirementMessage(hostname: String, password: String?) -> String? {
        allowsRemoteListening(hostname: hostname, password: password) ? nil : missingPasswordMessage
    }

    /// 关闭远程模式：hostname 回到默认 loopback，其余字段（端口、允许的主机名、
    /// 代理、行为）保持不动。
    static func disablingRemoteAccess(in configuration: ServiceConfiguration) -> ServiceConfiguration {
        guard !isLoopbackHostname(configuration.hostname) else { return configuration }
        var updated = configuration
        updated.hostname = ServiceConfiguration.defaultHostname
        return updated
    }
}

// MARK: - 设置保存流程

/// 设置界面保存远程访问配置的纯逻辑（可单元测试）。
///
/// 密码只写入注入的 `KeychainStoring`；返回的配置由调用方通过 `AppConfiguration`
/// 写进 UserDefaults，中间任何错误文本都不包含密码。
enum RemoteAccessSetup {
    struct Outcome: Equatable {
        /// 允许保存时的配置；被拒绝时为 nil。
        var configuration: ServiceConfiguration?
        /// 可读的拒绝原因；成功时为 nil。
        var error: String?
    }

    /// 保存一次设置。`newPassword` 为 nil 表示沿用 Keychain 中已有的密码；非空
    /// 表示先写入新密码。监听地址先经共用判定（通配地址、空值、空白与非法字符
    /// 拒绝），远程 hostname 没有可用密码时也拒绝；两种拒绝都不返回配置，
    /// 调用方因此不会写入 UserDefaults。
    static func apply(
        requested: ServiceConfiguration,
        newPassword: String?,
        keychain: KeychainStoring,
        account: String = RemoteAccessPassword.account
    ) -> Outcome {
        // 监听地址与偏好窗口保存路径、加载、启动共用同一规则（GitHub #39 /
        // 安全审查 R-3）：通配地址、空值、空白与非法字符即使提供了密码也不能
        // 保存；这一步先于密码写入，不会为无法保存的配置改动 Keychain。
        if let message = RemoteAccessPolicy.hostnameValidationMessage(requested.hostname) {
            return Outcome(configuration: nil, error: message)
        }
        var effectivePassword = RemoteAccessPassword.load(from: keychain, account: account)
        if let newPassword {
            guard !newPassword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return Outcome(configuration: nil, error: "密码不能为空。")
            }
            do {
                try keychain.save(newPassword, for: account)
            } catch {
                // 即使底层错误描述意外包含密码，展示文本里也不会出现它。
                let reason = SecretScrubbing.scrub(readableMessage(for: error), secrets: [newPassword])
                return Outcome(configuration: nil, error: "无法把密码写入 Keychain：\(reason)。设置未保存。")
            }
            effectivePassword = newPassword
        }
        if let message = RemoteAccessPolicy.remoteAccessRequirementMessage(
            hostname: requested.hostname,
            password: effectivePassword
        ) {
            return Outcome(configuration: nil, error: message)
        }
        return Outcome(configuration: requested, error: nil)
    }

    /// 把任意错误转成可读文本；没有描述时使用固定兜底文案。
    static func readableMessage(for error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? "未知错误"
    }
}

// MARK: - 高强度密码生成

/// 本地高强度密码生成：不联网、不引入依赖。
///
/// 字符集包含大写字母、小写字母、数字和符号，长度下限 24，并保证四类字符各
/// 至少出现一次。随机字节来自 `SecRandomCopyBytes`（CSPRNG）；测试可以注入固定
/// 字节来源或失败结果，因此不需要真实随机数。
enum PasswordGenerator {
    /// 允许的最短长度；更短的要求会被抬到这个下限。
    static let minimumLength = 24
    /// 界面上“生成高强度密码”使用的默认长度。
    static let defaultLength = 32

    static let uppercaseLetters = "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
    static let lowercaseLetters = "abcdefghijklmnopqrstuvwxyz"
    static let digits = "0123456789"
    static let symbols = "!@#$%^&*()-_=+[]{}:,.?"
    /// 全部可用字符；顺序固定，测试可以断言类别齐全。
    static let alphabet = uppercaseLetters + lowercaseLetters + digits + symbols

    /// CSPRNG 字节来源；返回的字节数不足时生成失败。
    typealias RandomBytes = (Int) -> [UInt8]?

    /// 默认随机源：`SecRandomCopyBytes`。失败返回 nil，由调用方给出可读错误。
    static func secureRandomBytes(count: Int) -> [UInt8]? {
        guard count >= 0 else { return nil }
        guard count > 0 else { return [] }
        var bytes = [UInt8](repeating: 0, count: count)
        let status: OSStatus = bytes.withUnsafeMutableBytes { buffer in
            guard let base = buffer.baseAddress else { return errSecParam }
            return SecRandomCopyBytes(kSecRandomDefault, count, base)
        }
        return status == errSecSuccess ? bytes : nil
    }

    /// 生成密码；随机源失败时返回 nil。`length` 小于 `minimumLength` 时按
    /// `minimumLength` 处理。
    static func generate(length: Int = defaultLength, randomBytes: RandomBytes = secureRandomBytes) -> String? {
        let targetLength = max(length, minimumLength)
        var characters: [Character] = []
        // 每类先取一个，保证大小写字母、数字和符号都出现。
        for group in [uppercaseLetters, lowercaseLetters, digits, symbols] {
            guard let character = pickOne(from: group, randomBytes: randomBytes) else { return nil }
            characters.append(character)
        }
        while characters.count < targetLength {
            guard let character = pickOne(from: alphabet, randomBytes: randomBytes) else { return nil }
            characters.append(character)
        }
        // Fisher–Yates 洗牌：索引同样来自随机源，类别字符不会固定在开头。
        for index in stride(from: characters.count - 1, to: 0, by: -1) {
            guard let offset = randomIndex(upperBound: index + 1, randomBytes: randomBytes) else { return nil }
            characters.swapAt(index, offset)
        }
        return String(characters)
    }

    private static func pickOne(from group: String, randomBytes: RandomBytes) -> Character? {
        let characters = Array(group)
        guard let index = randomIndex(upperBound: characters.count, randomBytes: randomBytes) else { return nil }
        return characters[index]
    }

    /// `0..<upperBound` 上的均匀索引（拒绝采样）。重试次数有上限，随机源恒定返回
    /// 落在拒绝区间的字节时返回 nil 而不是死循环。
    private static func randomIndex(upperBound: Int, randomBytes: RandomBytes) -> Int? {
        guard upperBound > 1 else { return 0 }
        let limit = UInt32.max - (UInt32.max % UInt32(upperBound))
        for _ in 0 ..< 16 {
            guard let bytes = randomBytes(4), bytes.count == 4 else { return nil }
            let value = bytes.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            if value < limit { return Int(value % UInt32(upperBound)) }
        }
        return nil
    }
}
