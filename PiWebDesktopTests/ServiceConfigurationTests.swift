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
