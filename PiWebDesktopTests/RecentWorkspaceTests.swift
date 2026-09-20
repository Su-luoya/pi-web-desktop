import XCTest

final class RecentWorkspaceTests: XCTestCase {
    private func makeDefaults() -> (UserDefaults, String) {
        let name = "RecentWorkspaceTests.\(UUID().uuidString)"
        return (UserDefaults(suiteName: name)!, name)
    }

    func testHistoryDeduplicatesMovesLatestToFrontAndCapsAtTen() {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let store = RecentWorkspaceStore(defaults: defaults)

        for index in 0..<12 {
            store.record(path: "/tmp/workspace-\(index)")
        }
        XCTAssertEqual(store.load().count, RecentWorkspaceStore.maximumCount)
        XCTAssertEqual(store.load().first, "/tmp/workspace-11")
        XCTAssertEqual(store.load().last, "/tmp/workspace-2")

        store.record(path: "  /tmp/workspace-5/../workspace-5  ")
        XCTAssertEqual(store.load().first, "/tmp/workspace-5")
        XCTAssertEqual(store.load().filter { $0 == "/tmp/workspace-5" }.count, 1)
        XCTAssertEqual(store.load().count, RecentWorkspaceStore.maximumCount)
    }

    func testHistoryPersistsAcrossStoreInstancesAndClears() {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        RecentWorkspaceStore(defaults: defaults).record(path: "/tmp/persistent-workspace")
        defaults.synchronize()

        let reloadedDefaults = UserDefaults(suiteName: name)!
        let reloaded = RecentWorkspaceStore(defaults: reloadedDefaults)
        XCTAssertEqual(reloaded.load(), ["/tmp/persistent-workspace"])

        reloaded.clear()
        XCTAssertTrue(RecentWorkspaceStore(defaults: defaults).load().isEmpty)
    }

    func testAppConfigurationUsesItsInjectedDefaultsForHistory() {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let configuration = AppConfiguration(
            supportURL: URL(fileURLWithPath: "/tmp/recent-workspace-support", isDirectory: true),
            logsRootURL: URL(fileURLWithPath: "/tmp/recent-workspace-logs", isDirectory: true),
            defaults: defaults
        )

        configuration.recentWorkspaceStore.record(path: "/tmp/injected-workspace")
        XCTAssertEqual(configuration.recentWorkspaceStore.load(), ["/tmp/injected-workspace"])
    }

    func testSwitchDecisionSkipsCurrentRejectsInvalidAndConfirmsUsableDirectory() {
        var directories = Set(["/tmp/current", "/tmp/usable"])
        let probe = WorkspaceDirectoryProbe(
            pathExists: { directories.contains($0) || $0 == "/tmp/file" },
            isDirectory: { directories.contains($0) },
            isWritable: { $0 == "/tmp/usable" || $0 == "/tmp/current" },
            createDirectory: { directories.insert($0) }
        )

        XCTAssertEqual(
            WorkspaceSwitchDecision.decide(requestedPath: "/tmp/current/", currentPath: "/tmp/current", probe: probe),
            .unchanged
        )
        XCTAssertEqual(
            WorkspaceSwitchDecision.decide(requestedPath: "relative/workspace", currentPath: "/tmp/current", probe: probe),
            .reject(.unusable(problem: .missing, path: "relative/workspace"))
        )
        XCTAssertEqual(
            WorkspaceSwitchDecision.decide(requestedPath: "/tmp/missing", currentPath: "/tmp/current", probe: probe),
            .reject(.unusable(problem: .missing, path: "/tmp/missing"))
        )
        XCTAssertEqual(
            WorkspaceSwitchDecision.decide(requestedPath: "/tmp/file", currentPath: "/tmp/current", probe: probe),
            .reject(.unusable(problem: .notDirectory, path: "/tmp/file"))
        )
        XCTAssertEqual(
            WorkspaceSwitchDecision.decide(requestedPath: "/tmp/usable", currentPath: "/tmp/current", probe: probe),
            .confirm(path: "/tmp/usable")
        )
    }

    func testSwitchDecisionNeverCreatesARequestedDirectory() {
        var createCalls: [String] = []
        let probe = WorkspaceDirectoryProbe(
            pathExists: { _ in false },
            isDirectory: { _ in false },
            isWritable: { _ in false },
            createDirectory: { createCalls.append($0) }
        )

        _ = WorkspaceSwitchDecision.decide(
            requestedPath: "/tmp/not-created",
            currentPath: "/tmp/current",
            probe: probe
        )
        XCTAssertTrue(createCalls.isEmpty)
    }
}
