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

    // MARK: 路径归一化（GitHub #135 F4）

    func testNormalizedPathExpandsTildeAndRejectsRootRelativeAndControlCharacters() {
        let expanded = ("~/work" as NSString).expandingTildeInPath
        let expandedResult = RecentWorkspaceStore.normalizedPath(expanded)
        XCTAssertEqual(RecentWorkspaceStore.normalizedPath("~/work"), expandedResult)
        XCTAssertFalse(expandedResult?.hasPrefix("~") ?? true)
        XCTAssertTrue(expandedResult?.hasSuffix("/work") ?? false)

        XCTAssertNil(RecentWorkspaceStore.normalizedPath("/"))
        XCTAssertNil(RecentWorkspaceStore.normalizedPath("/.."))
        XCTAssertNil(RecentWorkspaceStore.normalizedPath("relative/workspace"))
        XCTAssertNil(RecentWorkspaceStore.normalizedPath("   "))
        XCTAssertNil(RecentWorkspaceStore.normalizedPath("/tmp/bad\npath"))
        XCTAssertNil(RecentWorkspaceStore.normalizedPath("/tmp/bad\u{0}path"))
    }

    func testNormalizedPathRejectsPathsBeyondTheLengthLimit() {
        let maximum = RecentWorkspaceStore.maximumPathLength
        XCTAssertEqual(maximum, 1024)
        // "/tmp/" is five bytes, so the first path is exactly 1024 bytes and the
        // second one is one byte over the PATH_MAX-based limit. Only the promised
        // invariant is asserted: a 1024-byte input is accepted and a 1025-byte one
        // is rejected. The resolved string is deliberately not asserted —
        // Foundation may rewrite/truncate an overlong path during URL resolution.
        let atLimit = "/tmp/" + String(repeating: "a", count: maximum - 5)
        XCTAssertNotNil(RecentWorkspaceStore.normalizedPath(atLimit))
        let overLimit = "/tmp/" + String(repeating: "a", count: maximum - 4)
        XCTAssertNil(RecentWorkspaceStore.normalizedPath(overLimit))
    }

    func testNormalizedPathResolvesSymlinksAndStoreDropsRejectedPaths() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RecentWorkspaceSymlink-\(UUID().uuidString)", isDirectory: true)
        let target = root.appendingPathComponent("target", isDirectory: true)
        let link = root.appendingPathComponent("link", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        defer { try? FileManager.default.removeItem(at: root) }

        let expected = try XCTUnwrap(RecentWorkspaceStore.normalizedPath(target.path))
        XCTAssertEqual(RecentWorkspaceStore.normalizedPath(link.path), expected)
        XCTAssertNotEqual(RecentWorkspaceStore.normalizedPath(link.path), link.path)
        XCTAssertEqual(RecentWorkspaceStore.normalizedPath(target.path + "/../target"), expected)

        // 存储层同样收紧：根目录不进历史，符号链接存成解析后的同一形式。
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let store = RecentWorkspaceStore(defaults: defaults)
        store.record(path: "/")
        XCTAssertTrue(store.load().isEmpty)
        store.record(path: link.path)
        XCTAssertEqual(store.load(), [expected])
    }
}
