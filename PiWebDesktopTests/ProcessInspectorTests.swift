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
        XCTAssertNil(ProcessInspector.parseProcessGroupID(""))
        XCTAssertNil(ProcessInspector.parseProcessGroupID(nil))
        XCTAssertNil(ProcessInspector.parseProcessStartTime(""))
        XCTAssertNil(ProcessInspector.parseProcessStartTime(" \n"))
        XCTAssertNil(ProcessInspector.parseResolvedExecutable(""))
        XCTAssertNil(ProcessInspector.parseResolvedExecutable(nil))
    }

    func testMalformedLinesAreRejected() {
        XCTAssertNil(ProcessInspector.parsePIDRecord("not-a-pid"))
        XCTAssertNil(ProcessInspector.parsePIDRecord("0"))
        XCTAssertNil(ProcessInspector.parsePIDRecord("1"))
        XCTAssertNil(ProcessInspector.parsePIDRecord("-4321"))
        XCTAssertNil(ProcessInspector.parseListenerPID("not-a-pid"))
        XCTAssertNil(ProcessInspector.parseListenerPID("0\n"))
        XCTAssertNil(ProcessInspector.parseListenerPID("1\n"))
        XCTAssertNil(ProcessInspector.parseProcessGroupID("not-a-pid"))
        XCTAssertNil(ProcessInspector.parseProcessGroupID("0"))
        XCTAssertNil(ProcessInspector.parseProcessGroupID("1"))
        XCTAssertNil(ProcessInspector.parseProcessGroupID("-5150"))
        XCTAssertEqual(ProcessInspector.parseProcessGroupID("  5150\n"), 5150)
        XCTAssertEqual(ProcessInspector.parsePIDRecord("  4321\n"), 4321)
        XCTAssertNil(ProcessInspector.parseResolvedExecutable("\n \n"))
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

    func testLaunchTimeWhitespaceIsCollapsed() {
        XCTAssertEqual(
            ProcessInspector.parseProcessStartTime("  Wed Jul 30 12:00:00 2025 \n"),
            "Wed Jul 30 12:00:00 2025"
        )
        XCTAssertEqual(
            ProcessInspector.parseProcessStartTime("Wed  Jul   30  12:00:00  2025"),
            "Wed Jul 30 12:00:00 2025"
        )
    }

    func testResolvedExecutableIsTrimmed() {
        XCTAssertEqual(
            ProcessInspector.parseResolvedExecutable("  /opt/homebrew/bin/pi-web\n"),
            "/opt/homebrew/bin/pi-web"
        )
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

    func testProcessDescriptionReadsTheCommandLine() {
        let runner = FakeCommandRunner()
        runner.handler = { _ in "node /opt/homebrew/bin/other-server\n" }
        let inspector = makeInspector(runner: runner)

        XCTAssertEqual(inspector.processDescription(of: 4321), "node /opt/homebrew/bin/other-server")

        runner.handler = { _ in "" }
        XCTAssertEqual(inspector.processDescription(of: 4321), "未知")
    }

    func testInjectedLivenessIsUsedInsteadOfKill() {
        let inspector = ProcessInspector(runner: FakeCommandRunner()) { pid in pid == 4321 }
        XCTAssertTrue(inspector.isProcessAlive(4321))
        XCTAssertFalse(inspector.isProcessAlive(9999))
    }

    // MARK: - Process facts

    func testProcessFactsCombineTheThreeQueries() {
        let runner = FakeCommandRunner()
        runner.handler = { arguments in
            guard let formatIndex = arguments.firstIndex(of: "-o"), formatIndex + 1 < arguments.count else { return nil }
            switch arguments[formatIndex + 1] {
            case "pgid=": return "5150\n"
            case "lstart=": return "Wed Jul 30 12:00:00 2025\n"
            case "comm=": return "/opt/homebrew/bin/pi-web\n"
            default: return nil
            }
        }
        let inspector = makeInspector(runner: runner)

        XCTAssertEqual(
            inspector.processFacts(of: 5150),
            ServiceProcessFacts(
                pid: 5150,
                processGroupID: 5150,
                launchedAt: "Wed Jul 30 12:00:00 2025",
                resolvedExecutable: "/opt/homebrew/bin/pi-web"
            )
        )
        XCTAssertEqual(runner.invocations, [
            ["/bin/ps", "-o", "pgid=", "-p", "5150"],
            ["/bin/ps", "-o", "lstart=", "-p", "5150"],
            ["/bin/ps", "-o", "comm=", "-p", "5150"]
        ])
    }

    func testMissingSingleFactMakesProcessFactsUnavailable() {
        let runner = FakeCommandRunner()
        runner.handler = { arguments in arguments.contains("pgid=") ? "5150\n" : nil }
        let inspector = makeInspector(runner: runner)

        XCTAssertNil(inspector.processFacts(of: 5150))
    }

    func testProcessFactsRejectUnusablePIDsWithoutProbing() {
        let runner = FakeCommandRunner()
        let inspector = makeInspector(runner: runner)

        XCTAssertNil(inspector.processFacts(of: 1))
        XCTAssertNil(inspector.processFacts(of: 0))
        XCTAssertTrue(runner.invocations.isEmpty)
    }

    // MARK: - Helpers

    private func makeInspector(
        runner: CommandRunning,
        alive: @escaping (pid_t) -> Bool = { _ in true }
    ) -> ProcessInspector {
        ProcessInspector(runner: runner, processIsAlive: alive)
    }
}
