import XCTest
@testable import PiWebDesktop

final class ServiceConfigurationTests: XCTestCase {
    func testDefaultsUseLoopbackService() {
        let configuration = ServiceConfiguration.default
        XCTAssertEqual(configuration.hostname, "127.0.0.1")
        XCTAssertEqual(configuration.port, 30141)
        XCTAssertEqual(configuration.serviceURL.absoluteString, "http://127.0.0.1:30141/")
    }

    func testInvalidStoredPortFallsBackToDefault() {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.set(70000, forKey: "service.port")
        defer { defaults.removePersistentDomain(forName: #function) }
        XCTAssertEqual(ServiceConfiguration.load(from: defaults).port, ServiceConfiguration.defaultPort)
    }
}
