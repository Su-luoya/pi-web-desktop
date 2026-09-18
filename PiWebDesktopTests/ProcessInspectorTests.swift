import Foundation
import XCTest

/// Returns canned command output so the inspector never touches a real process.
/// Liveness is injected as well, so no `kill` probe is executed either.
private final class FakeCommandRunner: CommandRunning {
    var handler: ([String]) -> String? = { _ in nil }
    private(set) var invocations: [[String]] = []

    func run(_ arguments: [String]) -> String? {
        invocations.append(arguments)
        return handler(arguments)
    }
}

final class ProcessInspectorTests: XCTestCase {
    // MARK: - Pure parsing

    func testEmptyOutputMeansNoProcess() {
        XCTAssertNil(ProcessInspector.parsePIDRecord(""))
        XCTAssertNil(ProcessInspector.parsePIDRecord(nil))
        XCTAssertNil(ProcessInspector.parseListenerPID(""))
        XCTAssertNil(ProcessInspector.parseListenerPID(nil))
        XCTAssertNil(ProcessInspector.parseProcessDescription(""))
        XCTAssertNil(ProcessInspector.parseProcessDescription("  \n"))
        XCTAssertEqual(ProcessInspector.parseParentPID(""), 0)
        XCTAssertFalse(ProcessInspector.isPiWebCommand(""))
        XCTAssertFalse(ProcessInspector.isPiWebCommand(nil))
    }

    func testMalformedLinesAreRejected() {
        XCTAssertNil(ProcessInspector.parsePIDRecord("not-a-pid"))
        XCTAssertNil(ProcessInspector.parsePIDRecord("0"))
        XCTAssertNil(ProcessInspector.parsePIDRecord("1"))
        XCTAssertNil(ProcessInspector.parsePIDRecord("-4321"))
        XCTAssertNil(ProcessInspector.parseListenerPID("not-a-pid"))
        XCTAssertNil(ProcessInspector.parseListenerPID("0\n"))
        XCTAssertNil(ProcessInspector.parseListenerPID("1\n"))
        XCTAssertEqual(ProcessInspector.parseParentPID("not-a-pid"), 0)
        XCTAssertEqual(ProcessInspector.parseParentPID("  501\n"), 501)
        XCTAssertEqual(ProcessInspector.parsePIDRecord("  4321\n"), 4321)
    }

    func testListenerPIDUsesTheFirstLineOfMultiplePIDs() {
        XCTAssertEqual(ProcessInspector.parseListenerPID("4321\n9876\n"), 4321)
        XCTAssertEqual(ProcessInspector.parseListenerPID("4321\n"), 4321)
        XCTAssertEqual(ProcessInspector.parseListenerPID("  4321  \n"), 4321)
    }

    func testProcessDescriptionIsTrimmed() {
        XCTAssertEqual(ProcessInspector.parseProcessDescription("  node /opt/homebrew/bin/pi-web\n"), "node /opt/homebrew/bin/pi-web")
        XCTAssertNil(ProcessInspector.parseProcessDescription("\n \n"))
    }

    // MARK: - Command wiring

    func testListenerQueryUsesTheConfiguredPort() {
        let runner = FakeCommandRunner()
        runner.handler = { arguments in
            arguments.first == ProcessInspector.listenerCommand ? "4321\n" : "node /opt/homebrew/bin/pi-web\n"
        }
        let inspector = makeInspector(runner: runner)

        XCTAssertEqual(inspector.listenerPID(port: 30141), 4321)
        XCTAssertEqual(inspector.listenerPIDDescription(port: 30141), "4321")
        XCTAssertEqual(
            runner.invocations.last,
            ["/usr/sbin/lsof", "-nP", "-t", "-iTCP:30141", "-sTCP:LISTEN"]
        )

        XCTAssertEqual(inspector.listenerProcessDescription(port: 30141), "node /opt/homebrew/bin/pi-web")

        runner.handler = { _ in "" }
        XCTAssertNil(inspector.listenerPID(port: 30141))
        XCTAssertEqual(inspector.listenerPIDDescription(port: 30141), "无")
        XCTAssertEqual(inspector.listenerProcessDescription(port: 30141), "无")
    }

    func testPiWebProcessNameMatching() {
        XCTAssertTrue(ProcessInspector.isPiWebCommand("node /opt/homebrew/bin/pi-web --hostname 127.0.0.1 --port 30141 --no-open"))
        XCTAssertTrue(ProcessInspector.isPiWebCommand("NODE /OPT/HOMEBREW/BIN/PI-WEB"))
        XCTAssertFalse(ProcessInspector.isPiWebCommand("node /opt/homebrew/bin/other-server"))
        XCTAssertFalse(ProcessInspector.isPiWebCommand("node /usr/local/bin/pi-server --port 3000"))

        let runner = FakeCommandRunner()
        runner.handler = { _ in "node /opt/homebrew/bin/other-server\n" }
        let inspector = makeInspector(runner: runner)
        XCTAssertFalse(inspector.isPiWebProcess(4321))
        XCTAssertEqual(inspector.processDescription(of: 4321), "node /opt/homebrew/bin/other-server")

        runner.handler = { _ in "" }
        XCTAssertEqual(inspector.processDescription(of: 4321), "未知")
        XCTAssertEqual(inspector.parentProcess(of: 4321), 0)
    }

    func testInjectedLivenessIsUsedInsteadOfKill() {
        let inspector = ProcessInspector(runner: FakeCommandRunner(), fileManager: .default) { pid in pid == 4321 }
        XCTAssertTrue(inspector.isProcessAlive(4321))
        XCTAssertFalse(inspector.isProcessAlive(9999))
    }

    // MARK: - Managed PID records

    func testManagedPIDRecordIsAcceptedWhenAliveAndPiWeb() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let pidFile = directory.appendingPathComponent("service.pid")
        try "4321\n".write(to: pidFile, atomically: true, encoding: .utf8)

        let runner = FakeCommandRunner()
        runner.handler = { _ in "node /opt/homebrew/bin/pi-web --hostname 127.0.0.1\n" }
        let inspector = makeInspector(runner: runner, alive: { $0 == 4321 })

        XCTAssertEqual(inspector.managedServicePID(pidFileURL: pidFile), 4321)
        XCTAssertTrue(FileManager.default.fileExists(atPath: pidFile.path))
    }

    func testStaleManagedPIDRecordIsRemoved() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let pidFile = directory.appendingPathComponent("service.pid")
        try "4321\n".write(to: pidFile, atomically: true, encoding: .utf8)

        let runner = FakeCommandRunner()
        runner.handler = { _ in "node /opt/homebrew/bin/pi-web\n" }
        let inspector = makeInspector(runner: runner, alive: { _ in false })

        XCTAssertNil(inspector.managedServicePID(pidFileURL: pidFile))
        XCTAssertFalse(FileManager.default.fileExists(atPath: pidFile.path))
    }

    func testForeignProcessRecordIsRemoved() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let pidFile = directory.appendingPathComponent("service.pid")
        try "4321\n".write(to: pidFile, atomically: true, encoding: .utf8)

        let runner = FakeCommandRunner()
        runner.handler = { _ in "node /opt/homebrew/bin/other-server\n" }
        let inspector = makeInspector(runner: runner, alive: { _ in true })

        XCTAssertNil(inspector.managedServicePID(pidFileURL: pidFile))
        XCTAssertFalse(FileManager.default.fileExists(atPath: pidFile.path))
    }

    func testUnparsableRecordIsRemovedWithoutProbingLiveness() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let pidFile = directory.appendingPathComponent("service.pid")
        try "not-a-pid\n".write(to: pidFile, atomically: true, encoding: .utf8)

        let runner = FakeCommandRunner()
        let inspector = makeInspector(runner: runner, alive: { _ in
            XCTFail("liveness must not be probed for an unparsable record")
            return true
        })

        XCTAssertNil(inspector.managedServicePID(pidFileURL: pidFile))
        XCTAssertFalse(FileManager.default.fileExists(atPath: pidFile.path))
        XCTAssertTrue(runner.invocations.isEmpty)
    }

    func testMissingRecordFileIsNil() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let pidFile = directory.appendingPathComponent("service.pid")

        let inspector = makeInspector(runner: FakeCommandRunner(), alive: { _ in true })
        XCTAssertNil(inspector.managedServicePID(pidFileURL: pidFile))
    }

    // MARK: - Helpers

    private func makeInspector(
        runner: CommandRunning,
        alive: @escaping (pid_t) -> Bool = { _ in true }
    ) -> ProcessInspector {
        ProcessInspector(runner: runner, fileManager: .default, processIsAlive: alive)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("PiWebDesktopTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
