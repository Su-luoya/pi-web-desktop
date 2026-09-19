import XCTest

final class ServiceConfigurationTests: XCTestCase {
    func testDefaultsUseLoopbackService() {
        let configuration = ServiceConfiguration.default
        XCTAssertEqual(configuration.hostname, "127.0.0.1")
        XCTAssertEqual(configuration.port, 30141)
        XCTAssertEqual(configuration.serviceURL.absoluteString, "http://127.0.0.1:30141/")
    }

    /// 退出行为默认“询问”，工作目录默认跟随应用默认目录（空字符串）。
    func testDefaultsUseAskAndTheAppDefaultWorkspace() {
        let configuration = ServiceConfiguration.default
        XCTAssertEqual(configuration.quitBehavior, .ask)
        XCTAssertEqual(configuration.workspacePath, "")
        XCTAssertEqual(configuration.workspacePath, ServiceConfiguration.defaultWorkspacePath)
    }

    /// 普通设置沿用现有键名：新增工作目录不改变既有键。
    func testStoredKeysKeepTheirNames() {
        let defaults = UserDefaults(suiteName: #function)!
        defer { defaults.removePersistentDomain(forName: #function) }

        var configuration = ServiceConfiguration.default
        configuration.port = 41234
        configuration.quitBehavior = .stopService
        configuration.workspacePath = "/tmp/PiWebDesktopTests/workspace"
        configuration.save(to: defaults)

        XCTAssertEqual(defaults.string(forKey: "service.hostname"), "127.0.0.1")
        XCTAssertEqual(defaults.integer(forKey: "service.port"), 41234)
        XCTAssertEqual(defaults.string(forKey: "service.quitBehavior"), "stopService")
        XCTAssertEqual(defaults.string(forKey: "service.workspacePath"), "/tmp/PiWebDesktopTests/workspace")

        let reloaded = ServiceConfiguration.load(from: defaults)
        XCTAssertEqual(reloaded.quitBehavior, .stopService)
        XCTAssertEqual(reloaded.workspacePath, "/tmp/PiWebDesktopTests/workspace")
        XCTAssertEqual(reloaded.port, 41234)
    }

    func testInvalidStoredPortFallsBackToDefault() {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.set(70000, forKey: "service.port")
        defer { defaults.removePersistentDomain(forName: #function) }
        XCTAssertEqual(ServiceConfiguration.load(from: defaults).port, ServiceConfiguration.defaultPort)
    }

    // MARK: 监听地址复用校验（GitHub #39 / 安全审查 R-3）

    /// 直接改写 UserDefaults 写入的通配地址、空值、带空白或非法字符的值：加载时
    /// 必须被标记为非法，并保留原始值（不静默回退到 loopback 或其他地址）。
    func testLoadingAHostileStoredHostnameMarksItUnusableWithoutSilentFallback() {
        let hostileValues = [
            "0.0.0.0", "::", "[::]", "*", "0", "0x0", "0.0.0", "00.0.0.0", "0.0.0.0.",
            "0:0:0:0:0:0:0:0", "::ffff:0.0.0.0", "[0.0.0.0]", "", "   ", " 0.0.0.0", "127.0.0.1 ",
            "127.0.0.1\n", "127.0.0.1:30141", "http://127.0.0.1", "pi example invalid"
        ]
        for (index, stored) in hostileValues.enumerated() {
            let name = "ServiceConfigurationTests.hostile.\(index)"
            let defaults = UserDefaults(suiteName: name)!
            defer { defaults.removePersistentDomain(forName: name) }
            defaults.set(stored, forKey: "service.hostname")

            let configuration = ServiceConfiguration.load(from: defaults)

            XCTAssertEqual(configuration.hostname, stored, "非法值不得被静默替换：\(stored.debugDescription)")
            let problem = configuration.hostnameProblem
            XCTAssertNotNil(problem, "\(stored.debugDescription) 应当被标记为非法")
            // 诊断必须指认非法值，并给出允许范围与“不会启动”。
            XCTAssertTrue(problem?.contains("不可用") == true, "\(stored.debugDescription)")
            XCTAssertTrue(
                problem?.contains(ServiceAddressVerdict.displayHostname(stored)) == true,
                "\(stored.debugDescription)"
            )
            XCTAssertTrue(problem?.contains(ServiceConfiguration.defaultHostname) == true, "\(stored.debugDescription)")
            XCTAssertTrue(problem?.contains("::1") == true, "\(stored.debugDescription)")
            XCTAssertTrue(problem?.contains("服务不会启动") == true, "\(stored.debugDescription)")
        }
    }

    /// loopback、可规范化的 IPv6 字面量与显式配置的具体地址加载后仍然可用；
    /// `[::1]` 与保存路径一致地规范化为 `::1`。
    func testLoadingUsableHostnamesKeepsThemUsable() {
        let cases: [(stored: String, normalized: String)] = [
            ("127.0.0.1", "127.0.0.1"),
            ("127.0.0.53", "127.0.0.53"),
            ("localhost", "localhost"),
            ("::1", "::1"),
            ("[::1]", "::1"),
            ("pi.example.invalid", "pi.example.invalid"),
            ("host-1.internal", "host-1.internal")
        ]
        for (index, entry) in cases.enumerated() {
            let name = "ServiceConfigurationTests.usable.\(index)"
            let defaults = UserDefaults(suiteName: name)!
            defer { defaults.removePersistentDomain(forName: name) }
            defaults.set(entry.stored, forKey: "service.hostname")

            let configuration = ServiceConfiguration.load(from: defaults)

            XCTAssertEqual(configuration.hostname, entry.normalized)
            XCTAssertNil(configuration.hostnameProblem, entry.stored)
        }
    }

    /// 键不存在仍回落到默认 loopback（既有行为），并且视为可用。
    func testMissingStoredHostnameFallsBackToTheDefaultLoopback() {
        let name = #function
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }

        let configuration = ServiceConfiguration.load(from: defaults)

        XCTAssertEqual(configuration.hostname, ServiceConfiguration.defaultHostname)
        XCTAssertNil(configuration.hostnameProblem)
    }

    /// 无法识别的退出行为取值回落到默认“询问”，而不是停在未定义状态。
    func testUnknownQuitBehaviourFallsBackToAsk() {
        let defaults = UserDefaults(suiteName: #function)!
        defer { defaults.removePersistentDomain(forName: #function) }
        defaults.set("stop-everything", forKey: "service.quitBehavior")

        let configuration = ServiceConfiguration.load(from: defaults)

        XCTAssertEqual(configuration.quitBehavior, .ask)
        XCTAssertEqual(QuitPlan.plan(for: configuration.quitBehavior).nextStep, .askUser)
    }

    /// 工作目录变化必须进入运行时签名，使保存设置后服务用新目录重启。
    func testWorkspacePathIsPartOfTheRuntimeSignature() {
        var configuration = ServiceConfiguration.default
        let before = configuration.runtimeSignature
        configuration.workspacePath = "/tmp/PiWebDesktopTests/workspace"
        XCTAssertNotEqual(before, configuration.runtimeSignature)
    }

    /// 存档端口越界或类型不对时回落到默认端口；合法边界值原样保留。
    func testPortValidationFallsBackForOutOfRangeAndNonNumericValues() {
        for stored in [0, -1, 65536, 99999] {
            let name = "\(#function).\(stored)"
            let defaults = UserDefaults(suiteName: name)!
            defer { defaults.removePersistentDomain(forName: name) }
            defaults.set(stored, forKey: "service.port")
            XCTAssertEqual(ServiceConfiguration.load(from: defaults).port, ServiceConfiguration.defaultPort, "\(stored)")
        }

        let nonNumericName = "\(#function).non-numeric"
        let nonNumeric = UserDefaults(suiteName: nonNumericName)!
        defer { nonNumeric.removePersistentDomain(forName: nonNumericName) }
        nonNumeric.set("30141", forKey: "service.port")
        XCTAssertEqual(ServiceConfiguration.load(from: nonNumeric).port, ServiceConfiguration.defaultPort)

        for stored in [1, 65535] {
            let name = "\(#function).boundary.\(stored)"
            let defaults = UserDefaults(suiteName: name)!
            defer { defaults.removePersistentDomain(forName: name) }
            defaults.set(stored, forKey: "service.port")
            XCTAssertEqual(ServiceConfiguration.load(from: defaults).port, stored)
        }
    }

    /// 每个服务字段都要经 UserDefaults 往返，保存后重新加载必须得到同一份配置。
    func testEveryServiceFieldRoundTripsThroughUserDefaults() {
        let name = #function
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }

        var configuration = ServiceConfiguration.default
        configuration.hostname = "127.0.0.53"
        configuration.port = 41234
        configuration.piWebPath = "/opt/homebrew/bin/pi-web"
        configuration.allowedHosts = "pi.example.invalid"
        configuration.httpProxy = "http://proxy.example.invalid:8080"
        configuration.httpsProxy = "http://secure-proxy.example.invalid:8443"
        configuration.noProxy = "localhost,.example.invalid"
        configuration.autoStart = false
        configuration.quitBehavior = .keepRunning
        configuration.workspacePath = "/tmp/PiWebDesktopTests/workspace"

        configuration.save(to: defaults)

        XCTAssertEqual(ServiceConfiguration.load(from: defaults), configuration)
    }

    /// 运行时签名必须覆盖每一个会进入启动参数或工作目录的字段；只影响行为的
    /// `autoStart` 与 `quitBehavior` 不应造成无谓重启。
    func testRuntimeSignatureCoversEveryServiceField() {
        let base = ServiceConfiguration.default
        var mutations: [(String, ServiceConfiguration)] = []
        var mutated = base
        mutated.hostname = "127.0.0.53"
        mutations.append(("hostname", mutated))
        mutated = base
        mutated.port = 41234
        mutations.append(("port", mutated))
        mutated = base
        mutated.piWebPath = "/opt/homebrew/bin/pi-web"
        mutations.append(("piWebPath", mutated))
        mutated = base
        mutated.allowedHosts = "pi.example.invalid"
        mutations.append(("allowedHosts", mutated))
        mutated = base
        mutated.httpProxy = "http://proxy.example.invalid:8080"
        mutations.append(("httpProxy", mutated))
        mutated = base
        mutated.httpsProxy = "http://secure-proxy.example.invalid:8443"
        mutations.append(("httpsProxy", mutated))
        mutated = base
        mutated.noProxy = "localhost,.example.invalid"
        mutations.append(("noProxy", mutated))
        mutated = base
        mutated.workspacePath = "/tmp/PiWebDesktopTests/workspace"
        mutations.append(("workspacePath", mutated))

        for (field, configuration) in mutations {
            XCTAssertNotEqual(base.runtimeSignature, configuration.runtimeSignature, field)
        }

        mutated = base
        mutated.autoStart = false
        XCTAssertEqual(base.runtimeSignature, mutated.runtimeSignature)
        mutated = base
        mutated.quitBehavior = .stopService
        XCTAssertEqual(base.runtimeSignature, mutated.runtimeSignature)
    }
}
