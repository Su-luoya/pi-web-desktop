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
}
