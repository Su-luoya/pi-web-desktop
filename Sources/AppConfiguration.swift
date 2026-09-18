import Foundation

/// App-owned filesystem locations and the UserDefaults-backed service settings.
///
/// Every path the app reads or writes is derived from `supportURL` and
/// `logsRootURL`, so tests and the smoke launch can inject temporary directories
/// instead of the user's real `Application Support` and `Logs` folders. Defaults
/// stay unchanged: `~/Library/Application Support/Pi Web Desktop`,
/// `~/Library/Logs/Pi Web Desktop.log` and the loopback service defaults from
/// `ServiceConfiguration`.
struct AppConfiguration {
    /// Environment variable that switches the process into the smoke launch.
    static let smokeLaunchEnvironmentKey = "PI_WEB_DESKTOP_SMOKE"
    static let smokeLaunchEnvironmentValue = "1"
    /// Fixed marker the smoke launch prints once the main window exists.
    static let smokeReadyMarker = "smoke: ready"

    /// Runtime state root: PID files, instance lock and service workspace.
    /// Defaults to `~/Library/Application Support/Pi Web Desktop`.
    let supportURL: URL

    /// Directory that holds `Pi Web Desktop.log`. Defaults to `~/Library/Logs`.
    let logsRootURL: URL

    /// True when the process was started with `PI_WEB_DESKTOP_SMOKE=1`.
    let isSmokeLaunch: Bool

    private let defaults: UserDefaults

    init(
        supportURL: URL,
        logsRootURL: URL,
        defaults: UserDefaults = .standard,
        isSmokeLaunch: Bool = false
    ) {
        self.supportURL = supportURL
        self.logsRootURL = logsRootURL
        self.defaults = defaults
        self.isSmokeLaunch = isSmokeLaunch
    }

    var logURL: URL { logsRootURL.appendingPathComponent("Pi Web Desktop.log") }
    var serviceWorkingDirectory: URL { supportURL.appendingPathComponent("Workspace", isDirectory: true) }
    var managedPIDURL: URL { supportURL.appendingPathComponent("service.pid") }
    var appPIDURL: URL { supportURL.appendingPathComponent("app.pid") }
    var instanceLockURL: URL { supportURL.appendingPathComponent("instance.lock") }

    /// Service settings as stored in UserDefaults. The default values are the
    /// safe ones from `ServiceConfiguration`: loopback host, empty proxies and a
    /// loopback-only noProxy list.
    var serviceConfiguration: ServiceConfiguration { ServiceConfiguration.load(from: defaults) }

    /// Persists service settings through the same injected UserDefaults.
    func save(_ configuration: ServiceConfiguration) { configuration.save(to: defaults) }

    static func defaultSupportURL(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        homeDirectory.appendingPathComponent("Library/Application Support/Pi Web Desktop", isDirectory: true)
    }

    static func defaultLogsRootURL(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        homeDirectory.appendingPathComponent("Library/Logs", isDirectory: true)
    }

    /// `$TMPDIR/pi-web-desktop-smoke-<pid>`: the smoke launch must not touch the
    /// user's real support directory.
    static func smokeSupportURL(
        temporaryDirectory: URL = FileManager.default.temporaryDirectory,
        processIdentifier: Int32 = ProcessInfo.processInfo.processIdentifier
    ) -> URL {
        temporaryDirectory.appendingPathComponent("pi-web-desktop-smoke-\(processIdentifier)", isDirectory: true)
    }

    static func isSmokeLaunch(environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        environment[smokeLaunchEnvironmentKey] == smokeLaunchEnvironmentValue
    }

    /// Configuration for the current process. A smoke launch gets a temporary
    /// support/log root; every other launch keeps the real user directories.
    static func forCurrentProcess(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory,
        processIdentifier: Int32 = ProcessInfo.processInfo.processIdentifier,
        defaults: UserDefaults = .standard
    ) -> AppConfiguration {
        if isSmokeLaunch(environment: environment) {
            let root = smokeSupportURL(temporaryDirectory: temporaryDirectory, processIdentifier: processIdentifier)
            return AppConfiguration(
                supportURL: root,
                logsRootURL: root.appendingPathComponent("Logs", isDirectory: true),
                defaults: defaults,
                isSmokeLaunch: true
            )
        }
        return AppConfiguration(
            supportURL: defaultSupportURL(homeDirectory: homeDirectory),
            logsRootURL: defaultLogsRootURL(homeDirectory: homeDirectory),
            defaults: defaults
        )
    }
}
