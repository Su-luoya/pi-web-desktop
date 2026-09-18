import Foundation
import XCTest

/// Unhosted tests: `Sources/AppConfiguration.swift` and
/// `Sources/ServiceConfiguration.swift` are compiled directly into this target.
final class AppConfigurationTests: XCTestCase {
    private let fakeHome = URL(fileURLWithPath: "/tmp/PiWebDesktopTests/home", isDirectory: true)
    private let fakeTemporary = URL(fileURLWithPath: "/tmp/PiWebDesktopTests/tmp", isDirectory: true)
    private let fakeSupport = URL(fileURLWithPath: "/tmp/PiWebDesktopTests/support", isDirectory: true)
    private let fakeLogs = URL(fileURLWithPath: "/tmp/PiWebDesktopTests/logs", isDirectory: true)

    /// A fresh, empty suite keeps the test away from the real user defaults.
    private func makeEmptyDefaults() -> UserDefaults {
        UserDefaults(suiteName: "AppConfigurationTests.\(UUID().uuidString)")!
    }

    func testInjectedRootsDriveEveryPath() {
        let defaults = makeEmptyDefaults()
        let configuration = AppConfiguration(supportURL: fakeSupport, logsRootURL: fakeLogs, defaults: defaults)

        XCTAssertEqual(configuration.supportURL, fakeSupport)
        XCTAssertEqual(configuration.logURL, fakeLogs.appendingPathComponent("Pi Web Desktop.log"))
        XCTAssertEqual(configuration.serviceWorkingDirectory, fakeSupport.appendingPathComponent("Workspace", isDirectory: true))
        XCTAssertEqual(configuration.managedPIDURL, fakeSupport.appendingPathComponent("service.pid"))
        XCTAssertEqual(configuration.appPIDURL, fakeSupport.appendingPathComponent("app.pid"))
        XCTAssertEqual(configuration.instanceLockURL, fakeSupport.appendingPathComponent("instance.lock"))
        XCTAssertFalse(configuration.isSmokeLaunch)
    }

    func testDefaultLocationsDeriveFromInjectedHomeDirectory() {
        XCTAssertEqual(
            AppConfiguration.defaultSupportURL(homeDirectory: fakeHome),
            fakeHome.appendingPathComponent("Library/Application Support/Pi Web Desktop", isDirectory: true)
        )
        XCTAssertEqual(
            AppConfiguration.defaultLogsRootURL(homeDirectory: fakeHome),
            fakeHome.appendingPathComponent("Library/Logs", isDirectory: true)
        )
    }

    func testDefaultServiceSettingsStayLoopbackAndUnproxied() {
        let configuration = AppConfiguration(supportURL: fakeSupport, logsRootURL: fakeLogs, defaults: makeEmptyDefaults())
        let service = configuration.serviceConfiguration

        XCTAssertEqual(service.hostname, "127.0.0.1")
        XCTAssertEqual(service.port, 30141)
        XCTAssertEqual(service.httpProxy, "")
        XCTAssertEqual(service.httpsProxy, "")
        XCTAssertEqual(service.noProxy, "localhost,127.0.0.1,::1")
        XCTAssertTrue(service.autoStart)
    }

    func testSmokeLaunchUsesTemporaryRootInsteadOfTheRealSupportDirectory() {
        let smoke = AppConfiguration.forCurrentProcess(
            environment: ["PI_WEB_DESKTOP_SMOKE": "1"],
            homeDirectory: fakeHome,
            temporaryDirectory: fakeTemporary,
            processIdentifier: 4242,
            defaults: makeEmptyDefaults()
        )

        XCTAssertTrue(smoke.isSmokeLaunch)
        XCTAssertEqual(smoke.supportURL, fakeTemporary.appendingPathComponent("pi-web-desktop-smoke-4242", isDirectory: true))
        XCTAssertFalse(smoke.supportURL.path.hasPrefix(fakeHome.path))
        XCTAssertTrue(smoke.logURL.path.hasPrefix(smoke.supportURL.path))
    }

    func testSmokeDetectionNeedsTheExactValue() {
        XCTAssertTrue(AppConfiguration.isSmokeLaunch(environment: ["PI_WEB_DESKTOP_SMOKE": "1"]))
        XCTAssertFalse(AppConfiguration.isSmokeLaunch(environment: ["PI_WEB_DESKTOP_SMOKE": "0"]))
        XCTAssertFalse(AppConfiguration.isSmokeLaunch(environment: ["PI_WEB_DESKTOP_SMOKE": ""]))
        XCTAssertFalse(AppConfiguration.isSmokeLaunch(environment: [:]))
    }

    func testNormalLaunchKeepsTheRealSupportLocations() {
        let normal = AppConfiguration.forCurrentProcess(
            environment: [:],
            homeDirectory: fakeHome,
            temporaryDirectory: fakeTemporary,
            processIdentifier: 4242,
            defaults: makeEmptyDefaults()
        )

        XCTAssertFalse(normal.isSmokeLaunch)
        XCTAssertEqual(normal.supportURL, AppConfiguration.defaultSupportURL(homeDirectory: fakeHome))
        XCTAssertEqual(normal.logURL, AppConfiguration.defaultLogsRootURL(homeDirectory: fakeHome).appendingPathComponent("Pi Web Desktop.log"))
    }
}
