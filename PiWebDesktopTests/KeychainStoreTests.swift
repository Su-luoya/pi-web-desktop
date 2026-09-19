import Foundation
import Security
import XCTest

// MARK: - 内存替身

/// 内存 Keychain 替身：测试绝不访问真实 Keychain，也不依赖系统钥匙串状态。
final class InMemoryKeychainStore: KeychainStoring {
    var items: [String: String] = [:]
    var saveError: Error?
    var loadError: Error?
    var deleteError: Error?
    private(set) var savedAccounts: [String] = []

    func save(_ password: String, for account: String) throws {
        if let saveError { throw saveError }
        items[account] = password
        savedAccounts.append(account)
    }

    func load(for account: String) throws -> String {
        if let loadError { throw loadError }
        guard let value = items[account] else { throw KeychainStoreError.notFound }
        return value
    }

    func delete(for account: String) throws {
        if let deleteError { throw deleteError }
        items.removeValue(forKey: account)
    }

    func exists(for account: String) -> Bool {
        (try? load(for: account)).map { !$0.isEmpty } ?? false
    }
}

/// 错误描述里故意带上密码的替身，用来证明展示文本仍然不含秘密。
private struct LeakyKeychainError: LocalizedError {
    let secret: String
    var errorDescription: String? { "写入被拒绝：\(secret)" }
}

/// 每次调用都返回相同字节的随机源，让密码生成可以确定地测试。
private func constantRandomBytes(_ byte: UInt8) -> PasswordGenerator.RandomBytes {
    { count in Array(repeating: byte, count: count) }
}

/// Unhosted tests: `Sources/KeychainStore.swift`, `Sources/ServiceConfiguration.swift`,
/// `Sources/AppConfiguration.swift`, `Sources/ServiceManager.swift` and
/// `Sources/DiagnosticsCollector.swift` are compiled directly into this target.
/// Every keychain here is an in-memory double, so no real Keychain, user defaults
/// or user configuration is touched.
final class KeychainStoreTests: XCTestCase {
    private let secret = "unit-test-secret-Aa1!"
    private let fakeSupport = URL(fileURLWithPath: "/tmp/PiWebDesktopTests/keychain-support", isDirectory: true)
    private let fakeLogs = URL(fileURLWithPath: "/tmp/PiWebDesktopTests/keychain-logs", isDirectory: true)

    private func makeDefaults() -> (defaults: UserDefaults, name: String) {
        let name = "KeychainStoreTests.\(UUID().uuidString)"
        return (UserDefaults(suiteName: name)!, name)
    }

    private func makeAppConfiguration(_ defaults: UserDefaults) -> AppConfiguration {
        AppConfiguration(supportURL: fakeSupport, logsRootURL: fakeLogs, defaults: defaults)
    }

    /// 远程 hostname 的配置；使用文档保留域名，不写入任何私人主机名。
    private func remoteConfiguration() -> ServiceConfiguration {
        var configuration = ServiceConfiguration.default
        configuration.hostname = "pi.example.invalid"
        configuration.allowedHosts = "pi.example.invalid"
        return configuration
    }

    // MARK: 存储位置

    /// 密码写入 Keychain 后：UserDefaults 里不存在该字符串（也没有以密码命名的键），
    /// Keychain 替身里保存的是同一个字符串。
    func testPasswordLivesInTheKeychainAndNeverInUserDefaults() throws {
        let keychain = InMemoryKeychainStore()
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let appConfiguration = makeAppConfiguration(defaults)

        let outcome = RemoteAccessSetup.apply(
            requested: remoteConfiguration(),
            newPassword: secret,
            keychain: keychain
        )
        let configuration = try XCTUnwrap(outcome.configuration)
        appConfiguration.save(configuration)

        XCTAssertNil(outcome.error)
        XCTAssertEqual(try keychain.load(for: RemoteAccessPassword.account), secret)
        XCTAssertEqual(keychain.savedAccounts, [RemoteAccessPassword.account])

        let storedText = defaults.dictionaryRepresentation().values
            .map { String(describing: $0) }
            .joined(separator: "\n")
        XCTAssertFalse(storedText.contains(secret))
        XCTAssertFalse(storedText.lowercased().contains("password"))
        XCTAssertFalse(storedText.contains(RemoteAccessPassword.account))
        XCTAssertEqual(appConfiguration.serviceConfiguration.hostname, "pi.example.invalid")
    }

    /// 远程配置缺少非空密码时整次保存被拒绝：不写配置、不写 Keychain。
    func testRemoteConfigurationWithoutPasswordIsRejected() {
        let keychain = InMemoryKeychainStore()

        let outcome = RemoteAccessSetup.apply(requested: remoteConfiguration(), newPassword: nil, keychain: keychain)

        XCTAssertNil(outcome.configuration)
        XCTAssertEqual(outcome.error, RemoteAccessPolicy.missingPasswordMessage)
        XCTAssertTrue(keychain.items.isEmpty)
    }

    /// loopback 配置不需要密码；显式传入空密码会被拒绝。
    func testLoopbackConfigurationNeedsNoPassword() throws {
        let keychain = InMemoryKeychainStore()

        let outcome = RemoteAccessSetup.apply(requested: .default, newPassword: nil, keychain: keychain)
        XCTAssertEqual(outcome.configuration, .default)
        XCTAssertNil(outcome.error)

        let empty = RemoteAccessSetup.apply(requested: .default, newPassword: "   ", keychain: keychain)
        XCTAssertNil(empty.configuration)
        XCTAssertEqual(empty.error, "密码不能为空。")
        XCTAssertTrue(keychain.items.isEmpty)
    }

    /// 配置已经可以保存时，只更新密码不改配置（界面上的“保存密码”按钮）。
    func testSavingPasswordKeepsTheCurrentConfiguration() throws {
        let keychain = InMemoryKeychainStore()
        let remote = try XCTUnwrap(RemoteAccessSetup.apply(requested: remoteConfiguration(), newPassword: "first-value-Aa1!", keychain: keychain).configuration)

        let outcome = RemoteAccessSetup.apply(requested: remote, newPassword: secret, keychain: keychain)

        XCTAssertEqual(outcome.configuration, remote)
        XCTAssertNil(outcome.error)
        XCTAssertEqual(try keychain.load(for: RemoteAccessPassword.account), secret)
    }

    // MARK: Keychain 失败

    /// Keychain 失败时返回可读错误、不返回配置，并且错误描述里没有密码。
    func testKeychainFailureReturnsReadableErrorWithoutTheSecret() throws {
        let keychain = InMemoryKeychainStore()
        keychain.saveError = LeakyKeychainError(secret: secret)

        let outcome = RemoteAccessSetup.apply(requested: remoteConfiguration(), newPassword: secret, keychain: keychain)
        let error = try XCTUnwrap(outcome.error)

        XCTAssertNil(outcome.configuration)
        XCTAssertTrue(error.contains("Keychain"))
        XCTAssertFalse(error.contains(secret))
        XCTAssertTrue(error.contains(SecretScrubbing.placeholder))
        XCTAssertFalse(error.contains("unit-test-secret"))
    }

    /// 错误类型本身可读：notFound 与 status 都有描述，且不携带秘密或原始数据。
    func testKeychainErrorDescriptionsAreReadable() throws {
        XCTAssertEqual(KeychainStoreError.notFound.errorDescription, "Keychain 中没有找到该条目。")
        XCTAssertEqual(KeychainStoreError.undecodableData.errorDescription, "Keychain 中的条目内容无法读取。")

        let status = KeychainStoreError.status(errSecAuthFailed)
        let description = try XCTUnwrap(status.errorDescription)
        XCTAssertTrue(description.contains("Keychain 操作失败"))
        XCTAssertFalse(description.contains(secret))
    }

    // MARK: 删除密码

    /// 删除 Keychain 密码后远程模式关闭：hostname 回到默认 loopback，其余配置不动。
    func testDeletingThePasswordClosesRemoteModeAndRestoresLoopback() throws {
        let keychain = InMemoryKeychainStore()
        let saved = try XCTUnwrap(
            RemoteAccessSetup.apply(requested: remoteConfiguration(), newPassword: secret, keychain: keychain).configuration
        )
        XCTAssertTrue(RemoteAccessPassword.isSet(in: keychain))

        try keychain.delete(for: RemoteAccessPassword.account)
        let closed = RemoteAccessPolicy.disablingRemoteAccess(in: saved)

        XCTAssertFalse(RemoteAccessPassword.isSet(in: keychain))
        XCTAssertEqual(closed.hostname, ServiceConfiguration.defaultHostname)
        XCTAssertEqual(closed.port, saved.port)
        XCTAssertEqual(closed.piWebPath, saved.piWebPath)
        XCTAssertEqual(closed.allowedHosts, saved.allowedHosts)
        XCTAssertEqual(closed.noProxy, saved.noProxy)

        // 关闭后的配置在没有密码时也能保存（回到 loopback 的路径不被门控挡住）。
        let outcome = RemoteAccessSetup.apply(requested: closed, newPassword: nil, keychain: keychain)
        XCTAssertEqual(outcome.configuration, closed)
        XCTAssertNil(outcome.error)
    }

    /// 删除本来就不存在的条目是幂等的；读取失败按“未设置”处理（fail closed）。
    func testDeletingMissingPasswordIsIdempotentAndReadFailuresCountAsUnset() throws {
        let keychain = InMemoryKeychainStore()
        XCTAssertNoThrow(try keychain.delete(for: RemoteAccessPassword.account))
        XCTAssertFalse(RemoteAccessPassword.isSet(in: keychain))
        XCTAssertFalse(keychain.exists(for: RemoteAccessPassword.account))

        keychain.loadError = KeychainStoreError.status(errSecAuthFailed)
        XCTAssertFalse(RemoteAccessPassword.isSet(in: keychain))
        XCTAssertNil(RemoteAccessPassword.load(from: keychain))

        keychain.loadError = nil
        keychain.items[RemoteAccessPassword.account] = ""
        XCTAssertFalse(RemoteAccessPassword.isSet(in: keychain), "空密码不算已设置")
        XCTAssertFalse(keychain.exists(for: RemoteAccessPassword.account))
    }

    // MARK: hostname 与门控

    func testLoopbackHostnameDetection() {
        for hostname in ["127.0.0.1", "127.0.0.53", "localhost", "LOCALHOST", "::1", "[::1]", "", "  127.0.0.1  "] {
            XCTAssertTrue(RemoteAccessPolicy.isLoopbackHostname(hostname), "\(hostname) 应当按 loopback 处理")
        }
        for hostname in ["0.0.0.0", "::", "[::]", "192.168.1.10", "pi.example.invalid", "127.0.0", "127.0.0.1.1"] {
            XCTAssertFalse(RemoteAccessPolicy.isLoopbackHostname(hostname), "\(hostname) 不是 loopback")
        }
    }

    /// 保存时拒绝“所有接口”地址、协议前缀、路径、空格和空值。
    func testHostnameValidationRejectsAllInterfacesAndMalformedValues() {
        for hostname in ["0.0.0.0", "::", "[::]", "*", "[0.0.0.0]", "", "   ", "http://pi.example.invalid", "pi.example.invalid/path", "pi example invalid", " pi.example.invalid", "pi.example.invalid\n"] {
            XCTAssertNotNil(RemoteAccessPolicy.hostnameValidationMessage(hostname), "\(hostname) 应当被拒绝")
        }
        for hostname in ["127.0.0.1", "pi.example.invalid", "[::1]", "host-1.internal"] {
            XCTAssertNil(RemoteAccessPolicy.hostnameValidationMessage(hostname), "\(hostname) 应当可以保存")
        }
    }

    /// `getaddrinfo` 会把 `0`、`0x0`、`000.000.000.000`、`0.0.0.0.`、
    /// `0:0:0:0:0:0:0:0`、`::ffff:0.0.0.0` 等写法解析成 `0.0.0.0`/`::`（macOS
    /// 实测都绑定所有接口），所以它们必须和字面值一样被拒绝（Issue #39 / R-3）。
    func testWildcardEquivalentsAreRejectedNotTreatedAsConcreteAddresses() {
        let wildcardEquivalents = [
            "0", "00", "000", "0x0", "0x00000000", "0.0", "0.0.0", "00.0.0.0", "0.0.0.00",
            "000.000.000.000", "0.0.0.0.", "0x0.0.0.0", "0x00.0x00.0x00.0x00",
            "0:0:0:0:0:0:0:0", "::0", "0::", "0:0::", "::0:0", "::ffff:0.0.0.0", "::ffff:0:0"
        ]
        for hostname in wildcardEquivalents {
            guard case .rejected(_, let message) = RemoteAccessPolicy.addressVerdict(hostname: hostname) else {
                XCTFail("\(hostname) 应当被拒绝，而不是当成具体地址")
                continue
            }
            let diagnosis = RemoteAccessPolicy.unusableHostnameMessage(hostname)
            XCTAssertNotNil(diagnosis)
            XCTAssertTrue(diagnosis?.contains("服务不会启动") == true, hostname)
            XCTAssertTrue(
                message.contains("所有网络接口") || message.contains("数值写法") || message.contains("每一段都不能为空"),
                "\(hostname)：\(message)"
            )
        }

        // 具体地址与主机名不受影响：规范点分四段、`127.0.0.0/8` 与普通主机名。
        for hostname in ["127.0.0.1", "127.0.0.53", "0.0.0.1", "0.1.0.0", "1.2.3.4", "pi.example.invalid"] {
            XCTAssertNil(RemoteAccessPolicy.hostnameValidationMessage(hostname), "\(hostname) 应当可以保存")
        }
    }

    /// 保存、加载与启动共用同一个 `addressVerdict` 判定：拒绝时给出具体原因，
    /// 加载/启动的诊断额外包含非法值、允许范围与“不会启动”；允许时返回规范化形式。
    func testAddressVerdictDrivesSaveLoadAndStartAlike() {
        for hostname in ["0.0.0.0", "::", "[::]", "*", "[0.0.0.0]", "0", "0x0", "0.0.0", "00.0.0.0", "0.0.0.0.", "0:0:0:0:0:0:0:0", "::ffff:0.0.0.0", "", "   ", " 127.0.0.1", "127.0.0.1 ", "127.0.0.1:30141", "http://127.0.0.1", "pi example invalid"] {
            guard case .rejected(_, let message) = RemoteAccessPolicy.addressVerdict(hostname: hostname) else {
                XCTFail("\(hostname.debugDescription) 应当被拒绝")
                continue
            }
            XCTAssertEqual(message, RemoteAccessPolicy.hostnameValidationMessage(hostname))
            let diagnosis = RemoteAccessPolicy.unusableHostnameMessage(hostname)
            XCTAssertNotNil(diagnosis, hostname.debugDescription)
            XCTAssertTrue(diagnosis?.contains(ServiceAddressVerdict.displayHostname(hostname)) == true)
            XCTAssertTrue(diagnosis?.contains(ServiceConfiguration.defaultHostname) == true)
            XCTAssertTrue(diagnosis?.contains("服务不会启动") == true)
        }

        for hostname in ["127.0.0.1", "127.0.0.53", "localhost", "::1", "[::1]", "pi.example.invalid"] {
            guard case .allowed(let normalized) = RemoteAccessPolicy.addressVerdict(hostname: hostname) else {
                XCTFail("\(hostname.debugDescription) 应当允许")
                continue
            }
            XCTAssertEqual(normalized, RemoteAccessPolicy.normalizedHostname(hostname))
            XCTAssertNil(RemoteAccessPolicy.hostnameValidationMessage(hostname))
            XCTAssertNil(RemoteAccessPolicy.unusableHostnameMessage(hostname))
        }

        // 非 loopback 的凭证门控仍是 #8 的 `allowsRemoteListening`（唯一来源），
        // 地址判定不代替它：通配地址由地址判定单独拒绝，有没有密码都不得放行。
        XCTAssertTrue(RemoteAccessPolicy.allowsRemoteListening(hostname: "0.0.0.0", password: secret))
        XCTAssertNotNil(RemoteAccessPolicy.unusableHostnameMessage("0.0.0.0"))
        XCTAssertFalse(RemoteAccessPolicy.allowsRemoteListening(hostname: "pi.example.invalid", password: nil))
        XCTAssertFalse(RemoteAccessPolicy.allowsRemoteListening(hostname: "pi.example.invalid", password: ""))
        XCTAssertTrue(RemoteAccessPolicy.allowsRemoteListening(hostname: "pi.example.invalid", password: secret))
    }

    /// 保存流程本身也复用同一地址规则：通配地址即使提供了密码也不能保存，
    /// 且错误文本与界面保存路径一致、不包含密码。
    func testSaveFlowRejectsWildcardHostnameEvenWithAPassword() {
        let keychain = InMemoryKeychainStore()

        var requested = remoteConfiguration()
        requested.hostname = "0.0.0.0"
        let outcome = RemoteAccessSetup.apply(requested: requested, newPassword: secret, keychain: keychain)

        XCTAssertNil(outcome.configuration)
        XCTAssertEqual(outcome.error, RemoteAccessPolicy.hostnameValidationMessage("0.0.0.0"))
        XCTAssertFalse(outcome.error?.contains(secret) == true)
        XCTAssertTrue(keychain.items.isEmpty, "地址校验先于密码写入")
    }

    /// `::1` 与 `[::1]` 都要能保存，并且拼出合法的 `http://[::1]:…/` URL。
    /// `http://::1:30141/` 不是合法 URL，`URLComponents` 对未加方括号的 IPv6
    /// host 会返回 nil（旧实现会静默回落到 127.0.0.1）。
    func testIPv6HostnamesPassValidationAndProduceABracketedURL() {
        for hostname in ["::1", "[::1]"] {
            XCTAssertNil(RemoteAccessPolicy.hostnameValidationMessage(hostname), "\(hostname) 应当可以保存")
            let normalized = RemoteAccessPolicy.normalizedHostname(hostname)
            XCTAssertEqual(normalized, "::1")
            XCTAssertTrue(RemoteAccessPolicy.isLoopbackHostname(normalized))

            let urlHost = RemoteAccessPolicy.urlHost(for: normalized)
            XCTAssertEqual(urlHost, "[::1]")
            let url = URL(string: "http://\(urlHost):30141/")
            XCTAssertEqual(url?.absoluteString, "http://[::1]:30141/")
            XCTAssertEqual(url?.host, "::1")
            XCTAssertEqual(url?.port, 30141)

            var configuration = ServiceConfiguration.default
            configuration.hostname = hostname
            XCTAssertEqual(configuration.serviceURL.absoluteString, "http://[::1]:30141/")
            XCTAssertEqual(configuration.serviceURL.host, "::1")
            XCTAssertEqual(configuration.serviceURL.port, 30141)
        }
    }

    func testURLHostBracketsOnlyIPv6Literals() {
        XCTAssertEqual(RemoteAccessPolicy.urlHost(for: "127.0.0.1"), "127.0.0.1")
        XCTAssertEqual(RemoteAccessPolicy.urlHost(for: "pi.example.invalid"), "pi.example.invalid")
        XCTAssertEqual(RemoteAccessPolicy.urlHost(for: "[::1]"), "[::1]")
        XCTAssertEqual(RemoteAccessPolicy.urlHost(for: "::ffff:127.0.0.1"), "[::ffff:127.0.0.1]")
        XCTAssertEqual(RemoteAccessPolicy.urlHost(for: ""), ServiceConfiguration.defaultHostname)
        XCTAssertEqual(RemoteAccessPolicy.urlHost(for: "   "), ServiceConfiguration.defaultHostname)
        XCTAssertTrue(RemoteAccessPolicy.isIPv6Literal("::1"))
        XCTAssertFalse(RemoteAccessPolicy.isIPv6Literal("[::1]"))
        XCTAssertFalse(RemoteAccessPolicy.isIPv6Literal("pi.example.invalid"))
        XCTAssertFalse(RemoteAccessPolicy.isIPv6Literal("127.0.0.1"))
    }

    /// 把端口写进地址（`host:port`）在保存时就给出针对性拒绝，而不是拼出无效 URL。
    func testHostnameValidationRejectsValuesWithAnEmbeddedPort() {
        for hostname in ["pi.example.invalid:30141", "127.0.0.1:30141", "example.com:"] {
            XCTAssertNotNil(RemoteAccessPolicy.hostnameValidationMessage(hostname), "\(hostname) 应当被拒绝")
        }
    }

    func testRemoteListeningRequiresANonEmptyPassword() {
        XCTAssertTrue(RemoteAccessPolicy.allowsRemoteListening(hostname: "127.0.0.1", password: nil))
        XCTAssertTrue(RemoteAccessPolicy.allowsRemoteListening(hostname: "127.0.0.1", password: ""))
        XCTAssertFalse(RemoteAccessPolicy.allowsRemoteListening(hostname: "pi.example.invalid", password: nil))
        XCTAssertFalse(RemoteAccessPolicy.allowsRemoteListening(hostname: "pi.example.invalid", password: ""))
        XCTAssertTrue(RemoteAccessPolicy.allowsRemoteListening(hostname: "pi.example.invalid", password: secret))
        XCTAssertNil(RemoteAccessPolicy.remoteAccessRequirementMessage(hostname: "127.0.0.1", password: nil))
        XCTAssertEqual(
            RemoteAccessPolicy.remoteAccessRequirementMessage(hostname: "pi.example.invalid", password: nil),
            RemoteAccessPolicy.missingPasswordMessage
        )
    }

    // MARK: 密码生成

    func testGeneratedPasswordMeetsThePolicy() throws {
        let generated = try XCTUnwrap(PasswordGenerator.generate())

        XCTAssertGreaterThanOrEqual(generated.count, PasswordGenerator.minimumLength)
        XCTAssertTrue(generated.contains { PasswordGenerator.uppercaseLetters.contains($0) })
        XCTAssertTrue(generated.contains { PasswordGenerator.lowercaseLetters.contains($0) })
        XCTAssertTrue(generated.contains { PasswordGenerator.digits.contains($0) })
        XCTAssertTrue(generated.contains { PasswordGenerator.symbols.contains($0) })
        XCTAssertTrue(generated.allSatisfy { PasswordGenerator.alphabet.contains($0) })
    }

    func testGeneratedPasswordUsesAtLeastTheMinimumLength() throws {
        let short = try XCTUnwrap(PasswordGenerator.generate(length: 8))
        XCTAssertEqual(short.count, PasswordGenerator.minimumLength)
        let requested = try XCTUnwrap(PasswordGenerator.generate(length: 40))
        XCTAssertEqual(requested.count, 40)
    }

    /// 固定随机源下结果稳定，且结构保证（四类字符齐全）仍然成立。
    func testGeneratedPasswordIsStableForAFixedRandomSource() throws {
        let source = constantRandomBytes(0)
        let first = try XCTUnwrap(PasswordGenerator.generate(length: 24, randomBytes: source))
        let second = try XCTUnwrap(PasswordGenerator.generate(length: 24, randomBytes: source))
        XCTAssertEqual(first, second)
        XCTAssertTrue(first.contains { PasswordGenerator.uppercaseLetters.contains($0) })
        XCTAssertTrue(first.contains { PasswordGenerator.lowercaseLetters.contains($0) })
        XCTAssertTrue(first.contains { PasswordGenerator.digits.contains($0) })
        XCTAssertTrue(first.contains { PasswordGenerator.symbols.contains($0) })
    }

    /// 随机源失败、字节数不足或恒定落在拒绝区间时返回 nil（不死循环）。
    func testGeneratedPasswordFailsWhenTheRandomSourceIsUnusable() {
        XCTAssertNil(PasswordGenerator.generate(randomBytes: { _ in nil }))
        XCTAssertNil(PasswordGenerator.generate(randomBytes: { _ in [0, 1] }))
        XCTAssertNil(PasswordGenerator.generate(randomBytes: constantRandomBytes(0xFF)))
    }

    // MARK: 脱敏

    func testStatusTextAndSecretScrubbingNeverExposeTheSecret() {
        XCTAssertEqual(RemoteAccessPassword.statusText(isSet: true), "已设置（仅存于 Keychain）")
        XCTAssertEqual(RemoteAccessPassword.statusText(isSet: false), "未设置")
        XCTAssertFalse(RemoteAccessPassword.statusText(isSet: true).contains(secret))
        XCTAssertEqual(SecretScrubbing.scrub("失败：\(secret)", secrets: [secret]), "失败：\(SecretScrubbing.placeholder)")
        XCTAssertEqual(SecretScrubbing.scrub("失败：无", secrets: [""]), "失败：无")
    }

    /// 诊断文本只报告密码状态，永远不包含密码值或长度。
    func testDiagnosticsTextReportsOnlyThePasswordState() {
        let input = DiagnosticsInput(
            appVersion: "9.9.9",
            appBuild: "42",
            piWebVersion: "1.2.3",
            piWebVersionConfidence: "verified",
            piWebPath: "/opt/homebrew/bin/pi-web",
            piWebPathConfidence: "verified",
            piCLIVersion: "0.5.0",
            piCLIVersionConfidence: "verified",
            nodeVersion: "v22.19.0",
            nodeVersionConfidence: "verified",
            serviceAddress: "http://pi.example.invalid:30141/",
            port: "30141",
            status: "正在运行（本应用管理）",
            management: .managed(pid: "4321"),
            listenerPID: "4321",
            listenerProcess: "/opt/homebrew/bin/pi-web --hostname pi.example.invalid --port 30141 --no-open",
            managedPID: "4321",
            workspaceDirectory: "/tmp/PiWebDesktopTests/Workspace",
            configurationDirectory: "~/.pi/agent",
            launchCommand: "/opt/homebrew/bin/pi-web --hostname pi.example.invalid --port 30141 --no-open",
            launchEnvironment: "PI_WEB_NO_OPEN=1",
            logPath: "/tmp/PiWebDesktopTests/logs/Pi Web Desktop.log",
            logWriteStatus: "正常",
            remoteAccessPasswordStatus: RemoteAccessPassword.statusText(isSet: true)
        )

        let text = DiagnosticsCollector.text(for: input)

        XCTAssertTrue(text.contains("远程访问密码: 已设置（仅存于 Keychain）"))
        XCTAssertFalse(text.contains(secret))
        XCTAssertFalse(text.contains("PI_WEB_PASSWORD"))
        // 这一行只携带状态：既没有密码值，也没有密码长度。
        let passwordLine = text.components(separatedBy: "\n").first { $0.hasPrefix("远程访问密码: ") }
        XCTAssertEqual(passwordLine, "远程访问密码: 已设置（仅存于 Keychain）")
    }

    // MARK: 启动环境

    /// 只有“远程 + 非空密码”才注入 `PI_WEB_PASSWORD`，而且只出现在子进程环境里。
    func testLaunchSpecificationCarriesThePasswordOnlyThroughTheEnvironment() throws {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let appConfiguration = makeAppConfiguration(defaults)
        let executable = "/opt/homebrew/bin/pi-web"
        let remote = remoteConfiguration()

        let remoteSpecification = ServiceLaunchSpecification.make(
            configuration: remote,
            piWebPath: executable,
            appConfiguration: appConfiguration,
            baseEnvironment: ["BASE": "1"],
            remoteAccessPassword: secret
        )
        XCTAssertEqual(remoteSpecification.environment["PI_WEB_PASSWORD"], secret)
        XCTAssertEqual(remoteSpecification.executablePath, executable)
        XCTAssertFalse(remoteSpecification.arguments.contains(secret))
        XCTAssertFalse(remoteSpecification.arguments.joined(separator: " ").contains(secret))

        let missingPasswordSpecification = ServiceLaunchSpecification.make(
            configuration: remote,
            piWebPath: executable,
            appConfiguration: appConfiguration,
            baseEnvironment: ["BASE": "1"],
            remoteAccessPassword: nil
        )
        XCTAssertNil(missingPasswordSpecification.environment["PI_WEB_PASSWORD"])

        // loopback 模式：即使 Keychain 有密码也不注入，并清掉继承来的同名变量。
        let loopbackSpecification = ServiceLaunchSpecification.make(
            configuration: .default,
            piWebPath: executable,
            appConfiguration: appConfiguration,
            baseEnvironment: ["BASE": "1", "PI_WEB_PASSWORD": "inherited-secret"],
            remoteAccessPassword: secret
        )
        XCTAssertNil(loopbackSpecification.environment["PI_WEB_PASSWORD"])
        XCTAssertEqual(loopbackSpecification.environment["BASE"], "1")
    }

    /// 默认服务配置仍是 loopback，不因为远程访问支持而改变。
    func testDefaultConfigurationStaysLoopback() {
        XCTAssertEqual(ServiceConfiguration.default.hostname, ServiceConfiguration.defaultHostname)
        XCTAssertTrue(RemoteAccessPolicy.isLoopbackHostname(ServiceConfiguration.default.hostname))
        XCTAssertEqual(ServiceConfiguration.defaultHostname, "127.0.0.1")
    }

    // MARK: Keychain 替身的更多失败路径

    /// 读取失败按“未设置”处理：同时又提供了新密码才能保存；不提供新密码时
    /// 仍按缺密码拒绝，且两次都不会写入 UserDefaults 或真实 Keychain。
    func testReadFailureNeedsANewPasswordToSaveRemoteAccess() throws {
        let keychain = InMemoryKeychainStore()
        keychain.loadError = KeychainStoreError.status(errSecAuthFailed)

        let rejected = RemoteAccessSetup.apply(
            requested: remoteConfiguration(),
            newPassword: nil,
            keychain: keychain
        )
        XCTAssertNil(rejected.configuration)
        XCTAssertEqual(rejected.error, RemoteAccessPolicy.missingPasswordMessage)
        XCTAssertTrue(keychain.items.isEmpty)

        let accepted = RemoteAccessSetup.apply(
            requested: remoteConfiguration(),
            newPassword: secret,
            keychain: keychain
        )
        XCTAssertEqual(accepted.configuration, remoteConfiguration())
        XCTAssertNil(accepted.error)
        keychain.loadError = nil
        XCTAssertEqual(try keychain.load(for: RemoteAccessPassword.account), secret)
    }

    /// 非 LocalizedError 的失败也要有可读文本（固定兜底），且不包含密码。
    func testNonLocalizedKeychainFailureStaysReadableAndRedacted() throws {
        struct PlainFailure: Error {}
        let keychain = InMemoryKeychainStore()
        keychain.saveError = PlainFailure()

        let outcome = RemoteAccessSetup.apply(
            requested: remoteConfiguration(),
            newPassword: secret,
            keychain: keychain
        )
        let error = try XCTUnwrap(outcome.error)

        XCTAssertNil(outcome.configuration)
        XCTAssertEqual(outcome.error?.contains("未知错误"), true)
        XCTAssertEqual(outcome.error?.contains("PlainFailure"), false)
        XCTAssertFalse(error.contains(secret))
        XCTAssertEqual(RemoteAccessSetup.readableMessage(for: PlainFailure()), "未知错误")
        XCTAssertEqual(RemoteAccessSetup.readableMessage(for: KeychainStoreError.notFound), "Keychain 中没有找到该条目。")
        XCTAssertEqual(RemoteAccessSetup.readableMessage(for: KeychainStoreError.undecodableData), "Keychain 中的条目内容无法读取。")
    }

    /// 一条文本里出现多个秘密时全部替换；空秘密不参与替换（否则会把整段
    /// 文本拆掉）。
    func testSecretScrubbingReplacesEveryOccurrenceAndIgnoresEmptySecrets() {
        let other = "unit-test-secret-Bb2!"
        let text = "a=\(secret) b=\(other) c=\(secret)"

        let scrubbed = SecretScrubbing.scrub(text, secrets: [secret, other, ""])

        XCTAssertEqual(
            scrubbed,
            "a=\(SecretScrubbing.placeholder) b=\(SecretScrubbing.placeholder) c=\(SecretScrubbing.placeholder)"
        )
        XCTAssertFalse(scrubbed.contains(secret))
        XCTAssertFalse(scrubbed.contains(other))
        XCTAssertEqual(SecretScrubbing.scrub(text, secrets: [""]), text)
    }

    /// 关闭远程模式对 loopback 配置是幂等的，且不会顺手改动端口、代理或行为。
    func testDisablingRemoteAccessIsIdempotentForLoopback() {
        var configuration = ServiceConfiguration.default
        configuration.port = 41234
        configuration.allowedHosts = "pi.example.invalid"
        configuration.httpProxy = "http://proxy.example.invalid:8080"
        configuration.workspacePath = "/tmp/PiWebDesktopTests/workspace"
        configuration.quitBehavior = .stopService

        XCTAssertEqual(RemoteAccessPolicy.disablingRemoteAccess(in: configuration), configuration)
    }
}
