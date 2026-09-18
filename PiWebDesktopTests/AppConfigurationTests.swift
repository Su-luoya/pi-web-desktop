import Foundation
import XCTest

/// Unhosted tests: `Sources/AppConfiguration.swift`, `Sources/AppPaths.swift`,
/// `Sources/ServiceConfiguration.swift` and `Sources/QuitPolicy.swift` are
/// compiled directly into this target. Every `UserDefaults` here is a fresh
/// suite, so no real user defaults, support directory or log directory is
/// touched.
final class AppConfigurationTests: XCTestCase {
    private let fakeHome = URL(fileURLWithPath: "/tmp/PiWebDesktopTests/home", isDirectory: true)
    private let fakeTemporary = URL(fileURLWithPath: "/tmp/PiWebDesktopTests/tmp", isDirectory: true)
    private let fakeSupport = URL(fileURLWithPath: "/tmp/PiWebDesktopTests/support", isDirectory: true)
    private let fakeLogs = URL(fileURLWithPath: "/tmp/PiWebDesktopTests/logs/Pi Web Desktop", isDirectory: true)

    /// A fresh, empty suite keeps the test away from the real user defaults.
    private func makeEmptyDefaults() -> (defaults: UserDefaults, name: String) {
        let name = "AppConfigurationTests.\(UUID().uuidString)"
        return (UserDefaults(suiteName: name)!, name)
    }

    private func makeConfiguration(_ defaults: UserDefaults) -> AppConfiguration {
        AppConfiguration(supportURL: fakeSupport, logsRootURL: fakeLogs, defaults: defaults)
    }

    /// `service.*` 键的持久化文本；其他域的键不参与断言。
    private func serviceEntries(in defaults: UserDefaults) -> [String: String] {
        var entries: [String: String] = [:]
        for (key, value) in defaults.dictionaryRepresentation() where key.hasPrefix("service.") {
            entries[key] = String(describing: value)
        }
        return entries
    }

    func testInjectedRootsDriveEveryPath() {
        let (defaults, name) = makeEmptyDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let configuration = makeConfiguration(defaults)

        XCTAssertEqual(configuration.paths, AppPaths(supportDirectory: fakeSupport, logsDirectory: fakeLogs))
        XCTAssertEqual(configuration.supportURL, fakeSupport)
        XCTAssertEqual(configuration.logsDirectoryURL, fakeLogs)
        XCTAssertEqual(configuration.logURL, fakeLogs.appendingPathComponent("Pi Web Desktop.log"))
        XCTAssertEqual(configuration.defaultWorkspaceDirectory, fakeSupport.appendingPathComponent("Workspace", isDirectory: true))
        XCTAssertEqual(configuration.serviceOwnerURL, fakeSupport.appendingPathComponent("service-owner.json"))
        XCTAssertEqual(configuration.legacyServicePIDURL, fakeSupport.appendingPathComponent("service.pid"))
        XCTAssertEqual(configuration.appPIDURL, fakeSupport.appendingPathComponent("app.pid"))
        XCTAssertEqual(configuration.instanceLockURL, fakeSupport.appendingPathComponent("instance.lock"))
        XCTAssertFalse(configuration.isSmokeLaunch)
    }

    /// 设置分层：普通设置走 UserDefaults，运行状态在 Application Support 下，
    /// 日志在 `~/Library/Logs/Pi Web Desktop/`。
    func testDefaultLocationsLayRuntimeStateAndLogsApart() {
        let paths = AppPaths.standard(homeDirectory: fakeHome)

        XCTAssertEqual(
            paths.supportDirectory,
            fakeHome.appendingPathComponent("Library/Application Support/Pi Web Desktop", isDirectory: true)
        )
        XCTAssertEqual(
            paths.logsDirectory,
            fakeHome.appendingPathComponent("Library/Logs/Pi Web Desktop", isDirectory: true)
        )
        XCTAssertEqual(paths.logFileURL, paths.logsDirectory.appendingPathComponent("Pi Web Desktop.log"))
        XCTAssertEqual(paths.workspaceDirectory, paths.supportDirectory.appendingPathComponent("Workspace", isDirectory: true))
        XCTAssertFalse(paths.logFileURL.path.hasPrefix(paths.supportDirectory.path))
        XCTAssertTrue(paths.workspaceDirectory.path.hasPrefix(paths.supportDirectory.path))
    }

    /// 默认服务设置：loopback、空代理、只含 loopback 的 noProxy、默认询问退出、
    /// 工作目录跟随应用默认目录。默认配置序列化到 UserDefaults 后不含任何个人
    /// 代理设置或远程 hostname。
    func testDefaultSettingsPersistOnlySafeValues() {
        let (defaults, name) = makeEmptyDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let configuration = makeConfiguration(defaults)

        XCTAssertEqual(configuration.serviceConfiguration, .default)
        configuration.save(.default)

        let stored = serviceEntries(in: defaults)
        XCTAssertEqual(stored["service.hostname"], "127.0.0.1")
        XCTAssertEqual(stored["service.port"], "30141")
        XCTAssertEqual(stored["service.httpProxy"], "")
        XCTAssertEqual(stored["service.httpsProxy"], "")
        XCTAssertEqual(stored["service.noProxy"], "localhost,127.0.0.1,::1")
        XCTAssertEqual(stored["service.allowedHosts"], "")
        XCTAssertEqual(stored["service.quitBehavior"], ServiceConfiguration.QuitBehavior.ask.rawValue)
        XCTAssertEqual(stored["service.workspacePath"], "")
        XCTAssertNil(stored["service.password"])

        let dumped = stored.map { "\($0.key)=\($0.value)" }.joined(separator: "\n")
        XCTAssertFalse(dumped.contains("@"))
        XCTAssertFalse(dumped.contains("http://"))
        XCTAssertFalse(dumped.contains("https://"))
        XCTAssertEqual(ServiceConfiguration.load(from: defaults).hostname, ServiceConfiguration.defaultHostname)
    }

    /// 设置在重新读取后保留：同一个 suite 上新开一个 `AppConfiguration` 能读回
    /// 刚保存的全部普通设置（含退出行为与工作目录）。
    func testSettingsSurviveReloadFromTheSameDefaults() {
        let (defaults, name) = makeEmptyDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        var saved = ServiceConfiguration.default
        saved.port = 41234
        saved.autoStart = false
        saved.quitBehavior = .keepRunning
        saved.workspacePath = "/tmp/PiWebDesktopTests/custom-workspace"
        saved.piWebPath = "/tmp/PiWebDesktopTests/bin/pi-web"
        makeConfiguration(defaults).save(saved)

        XCTAssertEqual(makeConfiguration(defaults).serviceConfiguration, saved)

        let reloadedDefaults = UserDefaults(suiteName: name)!
        let reloaded = makeConfiguration(reloadedDefaults).serviceConfiguration
        XCTAssertEqual(reloaded, saved)
        XCTAssertEqual(reloaded.quitBehavior, .keepRunning)
        XCTAssertEqual(reloaded.workspacePath, "/tmp/PiWebDesktopTests/custom-workspace")
    }

    func testWorkspaceDirectoryFollowsTheConfiguredOverride() {
        let (defaults, name) = makeEmptyDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let configuration = makeConfiguration(defaults)

        var service = ServiceConfiguration.default
        XCTAssertEqual(configuration.workspaceDirectory(for: service), configuration.defaultWorkspaceDirectory)

        service.workspacePath = "  /tmp/PiWebDesktopTests/custom-workspace  "
        XCTAssertEqual(configuration.workspaceDirectory(for: service).path, "/tmp/PiWebDesktopTests/custom-workspace")

        // 空字符串（或只有空白）表示跟随默认目录。
        service.workspacePath = "   "
        XCTAssertEqual(configuration.workspaceDirectory(for: service), configuration.defaultWorkspaceDirectory)
    }

    func testSmokeLaunchUsesTemporaryRootInsteadOfTheRealSupportDirectory() {
        let (defaults, name) = makeEmptyDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let smoke = AppConfiguration.forCurrentProcess(
            environment: ["PI_WEB_DESKTOP_SMOKE": "1"],
            homeDirectory: fakeHome,
            temporaryDirectory: fakeTemporary,
            processIdentifier: 4242,
            defaults: defaults
        )

        XCTAssertTrue(smoke.isSmokeLaunch)
        XCTAssertEqual(smoke.supportURL, fakeTemporary.appendingPathComponent("pi-web-desktop-smoke-4242", isDirectory: true))
        XCTAssertFalse(smoke.supportURL.path.hasPrefix(fakeHome.path))
        XCTAssertTrue(smoke.logURL.path.hasPrefix(smoke.supportURL.path))
        XCTAssertTrue(smoke.defaultWorkspaceDirectory.path.hasPrefix(smoke.supportURL.path))
        XCTAssertEqual(smoke.logsDirectoryURL, smoke.supportURL.appendingPathComponent("Logs", isDirectory: true))
    }

    func testSmokeDetectionNeedsTheExactValue() {
        XCTAssertTrue(AppConfiguration.isSmokeLaunch(environment: ["PI_WEB_DESKTOP_SMOKE": "1"]))
        XCTAssertTrue(AppConfiguration.isSmokeLaunch(environment: ["PI_WEB_DESKTOP_SMOKE": "diagnostics"]))
        XCTAssertFalse(AppConfiguration.isSmokeLaunch(environment: ["PI_WEB_DESKTOP_SMOKE": "0"]))
        XCTAssertFalse(AppConfiguration.isSmokeLaunch(environment: ["PI_WEB_DESKTOP_SMOKE": ""]))
        XCTAssertFalse(AppConfiguration.isSmokeLaunch(environment: [:]))
    }

    func testSmokeLaunchModesAreDistinctAndBothUseTheTemporaryRoot() {
        XCTAssertEqual(AppConfiguration.smokeLaunchMode(environment: [:]), AppConfiguration.SmokeLaunchMode.none)
        XCTAssertEqual(AppConfiguration.smokeLaunchMode(environment: ["PI_WEB_DESKTOP_SMOKE": "1"]), .startup)
        XCTAssertEqual(AppConfiguration.smokeLaunchMode(environment: ["PI_WEB_DESKTOP_SMOKE": "diagnostics"]), .diagnostics)
        XCTAssertEqual(AppConfiguration.smokeLaunchMode(environment: ["PI_WEB_DESKTOP_SMOKE": "yes"]), .none)

        for value in ["1", "diagnostics"] {
            let smoke = AppConfiguration.forCurrentProcess(
                environment: ["PI_WEB_DESKTOP_SMOKE": value],
                homeDirectory: fakeHome,
                temporaryDirectory: fakeTemporary,
                processIdentifier: 4242,
                defaults: makeEmptyDefaults().defaults
            )
            XCTAssertTrue(smoke.isSmokeLaunch)
            XCTAssertEqual(smoke.supportURL, fakeTemporary.appendingPathComponent("pi-web-desktop-smoke-4242", isDirectory: true))
            XCTAssertFalse(smoke.supportURL.path.hasPrefix(fakeHome.path))
        }
    }

    func testFirstLaunchSetupStartsIncompleteAndPersistsOnlyWhenMarked() {
        let (defaults, name) = makeEmptyDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let configuration = makeConfiguration(defaults)

        XCTAssertFalse(configuration.hasCompletedFirstLaunchSetup)
        configuration.markFirstLaunchSetupCompleted()
        XCTAssertTrue(configuration.hasCompletedFirstLaunchSetup)

        // 另一个 suite（相当于干净安装）不受影响；标记只写注入的 defaults。
        let fresh = makeConfiguration(makeEmptyDefaults().defaults)
        XCTAssertFalse(fresh.hasCompletedFirstLaunchSetup)
    }

    func testNormalLaunchKeepsTheRealSupportLocations() {
        let normal = AppConfiguration.forCurrentProcess(
            environment: [:],
            homeDirectory: fakeHome,
            temporaryDirectory: fakeTemporary,
            processIdentifier: 4242,
            defaults: makeEmptyDefaults().defaults
        )

        XCTAssertFalse(normal.isSmokeLaunch)
        XCTAssertEqual(normal.supportURL, AppPaths.standard(homeDirectory: fakeHome).supportDirectory)
        XCTAssertEqual(normal.logsDirectoryURL, AppPaths.standard(homeDirectory: fakeHome).logsDirectory)
        XCTAssertEqual(
            normal.logURL,
            fakeHome.appendingPathComponent("Library/Logs/Pi Web Desktop/Pi Web Desktop.log")
        )
    }
}
