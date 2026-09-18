import Foundation

/// App-owned filesystem locations and the UserDefaults-backed service settings.
///
/// Every path the app reads or writes is derived from `paths` (see `AppPaths`),
/// so tests and the smoke launch can inject temporary directories instead of the
/// user's real `Application Support` and `Logs` folders. Defaults stay unchanged
/// for runtime state: `~/Library/Application Support/Pi Web Desktop`; logs live
/// in `~/Library/Logs/Pi Web Desktop`, and service settings keep the loopback
/// defaults from `ServiceConfiguration`.
struct AppConfiguration {
    /// Smoke 启动模式。两种模式都使用临时 support 目录、跳过单实例锁和服务
    /// 自动启动，也都不写真实 UserDefaults。
    enum SmokeLaunchMode: Equatable {
        case none
        /// `PI_WEB_DESKTOP_SMOKE=1`：建立主窗口后打印 `smoke: ready`。
        case startup
        /// `PI_WEB_DESKTOP_SMOKE=diagnostics`：打开诊断状态页后打印
        /// `smoke: diagnostics ready`。不运行真实探针。
        case diagnostics
    }

    /// Environment variable that switches the process into a smoke launch.
    static let smokeLaunchEnvironmentKey = "PI_WEB_DESKTOP_SMOKE"
    static let smokeLaunchEnvironmentValue = "1"
    static let smokeDiagnosticsLaunchEnvironmentValue = "diagnostics"
    /// Fixed marker the startup smoke launch prints once the main window exists.
    static let smokeReadyMarker = "smoke: ready"
    /// Fixed marker the diagnostics smoke launch prints once the status page exists.
    static let smokeDiagnosticsReadyMarker = "smoke: diagnostics ready"

    /// 运行状态、日志与默认工作目录的位置提供者（可注入）。
    let paths: AppPaths

    /// Which smoke launch (if any) this process is running.
    let smokeLaunchMode: SmokeLaunchMode

    /// True for any smoke launch mode.
    var isSmokeLaunch: Bool { smokeLaunchMode != .none }

    private let defaults: UserDefaults

    private enum SetupKey {
        /// Set once a first-launch diagnostics review passed (`canStartService`).
        static let firstLaunchSetupCompleted = "firstLaunch.setupCompleted"
    }

    init(paths: AppPaths, defaults: UserDefaults = .standard, smokeLaunchMode: SmokeLaunchMode = .none) {
        self.paths = paths
        self.defaults = defaults
        self.smokeLaunchMode = smokeLaunchMode
    }

    /// 便捷初始化：直接给出两个根目录（单元测试与 smoke 用）。
    init(
        supportURL: URL,
        logsRootURL: URL,
        defaults: UserDefaults = .standard,
        smokeLaunchMode: SmokeLaunchMode = .none
    ) {
        self.init(
            paths: AppPaths(supportDirectory: supportURL, logsDirectory: logsRootURL),
            defaults: defaults,
            smokeLaunchMode: smokeLaunchMode
        )
    }

    /// Runtime state root: PID files, instance lock and the default workspace.
    var supportURL: URL { paths.supportDirectory }

    /// Log directory. Defaults to `~/Library/Logs/Pi Web Desktop`.
    var logsDirectoryURL: URL { paths.logsDirectory }

    var logURL: URL { paths.logFileURL }

    /// 默认工作目录 `~/Library/Application Support/Pi Web Desktop/Workspace`。
    /// 首次使用时创建；用户在偏好窗口选择其他目录后，`service.workspacePath`
    /// 覆盖它（见 `workspaceDirectory(for:)`）。
    var defaultWorkspaceDirectory: URL { paths.workspaceDirectory }

    /// 生效的工作目录：配置里的绝对路径优先，空字符串表示使用默认目录。
    func workspaceDirectory(for configuration: ServiceConfiguration) -> URL {
        guard let configured = configuration.workspacePath.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty else {
            return paths.workspaceDirectory
        }
        return URL(fileURLWithPath: configured, isDirectory: true)
    }

    /// Ownership record of the app-managed service. It is the only evidence
    /// that allows the app to stop a process (see `ServiceOwnershipRecord`).
    var serviceOwnerURL: URL { paths.serviceOwnerRecordURL }

    /// Legacy single-PID record written by older builds. It is only removed on
    /// startup and never used as an ownership proof again.
    var legacyServicePIDURL: URL { paths.legacyServicePIDURL }

    var appPIDURL: URL { paths.appPIDURL }
    var instanceLockURL: URL { paths.instanceLockURL }

    /// Service settings as stored in UserDefaults. The default values are the
    /// safe ones from `ServiceConfiguration`: loopback host, empty proxies and a
    /// loopback-only noProxy list.
    var serviceConfiguration: ServiceConfiguration { ServiceConfiguration.load(from: defaults) }

    /// Persists service settings through the same injected UserDefaults.
    func save(_ configuration: ServiceConfiguration) { configuration.save(to: defaults) }

    /// True once a first-launch diagnostics review passed on this machine.
    /// A fresh install (or a value written by an older build) starts as false,
    /// so the first launch shows the diagnostics surface before the main window.
    var hasCompletedFirstLaunchSetup: Bool { defaults.bool(forKey: SetupKey.firstLaunchSetupCompleted) }

    /// Records that the first-launch review passed. Called only after a ready
    /// `DependencyReport`; a blocked report never marks setup complete.
    func markFirstLaunchSetupCompleted() { defaults.set(true, forKey: SetupKey.firstLaunchSetupCompleted) }

    static func isSmokeLaunch(environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        smokeLaunchMode(environment: environment) != .none
    }

    /// `1` → startup smoke, `diagnostics` → diagnostics smoke, anything else → none.
    static func smokeLaunchMode(environment: [String: String] = ProcessInfo.processInfo.environment) -> SmokeLaunchMode {
        switch environment[smokeLaunchEnvironmentKey] {
        case smokeLaunchEnvironmentValue: return .startup
        case smokeDiagnosticsLaunchEnvironmentValue: return .diagnostics
        default: return .none
        }
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
            return AppConfiguration(
                paths: AppPaths.smoke(temporaryDirectory: temporaryDirectory, processIdentifier: processIdentifier),
                defaults: defaults,
                smokeLaunchMode: smokeLaunchMode(environment: environment)
            )
        }
        return AppConfiguration(paths: AppPaths.standard(homeDirectory: homeDirectory), defaults: defaults)
    }
}
