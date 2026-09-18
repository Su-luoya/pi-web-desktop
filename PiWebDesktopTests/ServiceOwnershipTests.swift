import Foundation
import XCTest

/// Unhosted tests for the ownership record, the verification decision table and
/// the group-only signal contract.
///
/// Every test uses fake `ps` facts, an injected liveness function and an
/// injected store. No test touches, signals or terminates a real process.
final class ServiceOwnershipTests: XCTestCase {
    private let executable = "/opt/homebrew/bin/pi-web"
    private let realExecutable = "/opt/homebrew/bin/node"
    private let launchArguments = ["--hostname", "127.0.0.1", "--port", "30141", "--no-open"]
    /// What `/opt/homebrew/bin/pi-web` reports through `ps -o args=` after
    /// `exec`: the npm install is a `#!/usr/bin/env node` script, so argv[0] is
    /// the interpreter and the recorded digest is over this text.
    private let liveCommandText = "node /opt/homebrew/bin/pi-web --hostname 127.0.0.1 --port 30141 --no-open"
    private let launchedAt = "Wed Jul 30 12:00:00 2025"
    private let instanceID = "instance-A"

    // MARK: - Builders

    private func makeExpectation(
        port: Int = 30141,
        instanceID: String? = nil
    ) -> ServiceOwnershipExpectation {
        ServiceOwnershipExpectation(
            port: port,
            instanceID: instanceID ?? self.instanceID
        )
    }

    private func makeRecord(
        pid: pid_t = 5150,
        processGroupID: pid_t = 5150,
        launchedAt: String? = nil,
        resolvedExecutable: String? = nil,
        resolvedExecutableSource: ServiceExecutableSource = .procPidPath,
        argumentsDigest: String? = nil,
        port: Int = 30141,
        instanceID: String? = nil
    ) -> ServiceOwnershipRecord {
        ServiceOwnershipRecord(
            pid: pid,
            processGroupID: processGroupID,
            launchedAt: launchedAt ?? self.launchedAt,
            resolvedExecutable: resolvedExecutable ?? realExecutable,
            resolvedExecutableSource: resolvedExecutableSource,
            argumentsDigest: argumentsDigest ?? ServiceOwnershipRecord.commandDigest(ofCommandText: liveCommandText),
            port: port,
            instanceID: instanceID ?? self.instanceID,
            recordedAt: "2025-07-30T12:00:00Z"
        )
    }

    private func makeFacts(
        pid: pid_t = 5150,
        processGroupID: pid_t = 5150,
        launchedAt: String? = nil,
        resolvedExecutable: String? = nil,
        resolvedExecutableSource: ServiceExecutableSource = .procPidPath,
        commandLine: String? = nil
    ) -> ServiceProcessFacts {
        ServiceProcessFacts(
            pid: pid,
            processGroupID: processGroupID,
            launchedAt: launchedAt ?? self.launchedAt,
            resolvedExecutable: resolvedExecutable ?? realExecutable,
            resolvedExecutableSource: resolvedExecutableSource,
            commandLine: commandLine ?? liveCommandText
        )
    }

    private func verify(
        record: ServiceOwnershipRecord,
        expectation: ServiceOwnershipExpectation? = nil,
        alive: Bool = true,
        facts: ServiceProcessFacts? = nil,
        factsAvailable: Bool = true
    ) -> ServiceOwnershipVerdict {
        let fallbackFacts = makeFacts()
        return ServiceOwnershipVerifier.verify(
            record: record,
            expectation: expectation ?? makeExpectation(),
            processIsAlive: { _ in alive },
            facts: { _ in factsAvailable ? (facts ?? fallbackFacts) : nil }
        )
    }

    // MARK: - Matching record

    func testMatchingRecordIsManaged() {
        XCTAssertEqual(verify(record: makeRecord()), .managed)
    }

    // MARK: - PID reuse

    func testReusedPIDWithDifferentLaunchTimeIsExternal() {
        // The PID is alive and even looks like pi-web, but the process started
        // at a different time than the record says: the recorded process is
        // gone and this PID now belongs to someone else.
        let record = makeRecord(launchedAt: "Wed Jul 30 12:00:00 2025")
        let verdict = verify(
            record: record,
            facts: makeFacts(launchedAt: "Wed Jul 30 13:00:00 2025")
        )
        XCTAssertEqual(verdict, .external(.launchTimeMismatch))
    }

    // MARK: - Launch time

    func testChangedLaunchTimeIsExternal() {
        let record = makeRecord(launchedAt: "Wed Jul 30 12:00:00 2025")
        let verdict = verify(record: record, facts: makeFacts(launchedAt: "Wed Jul 30 12:00:01 2025"))
        XCTAssertEqual(verdict, .external(.launchTimeMismatch))
        XCTAssertTrue(verdict.shouldRemoveRecord)
    }

    func testLaunchTimeComparisonUsesTheNormalizedParserValue() {
        // Both the stored and the live value come from `ps -o lstart=` through
        // ProcessInspector, so column spacing cannot create a false mismatch.
        let record = makeRecord(launchedAt: "Wed Jul 30 12:00:00 2025")
        let liveValue = ProcessInspector.parseProcessStartTime("Wed   Jul   30 12:00:00 2025")
        XCTAssertEqual(liveValue, "Wed Jul 30 12:00:00 2025")
        let verdict = verify(record: record, facts: makeFacts(launchedAt: liveValue))
        XCTAssertEqual(verdict, .managed)
    }

    // MARK: - Port reuse

    func testReusedPortWithDifferentInstanceIsExternal() {
        // The port matches, but the record belongs to an earlier app instance:
        // a service started by this instance is the only one it may stop.
        let record = makeRecord(port: 30141, instanceID: "instance-OLD")
        let verdict = verify(record: record, expectation: makeExpectation(port: 30141, instanceID: instanceID))
        XCTAssertEqual(verdict, .external(.instanceMismatch))
    }

    func testDifferentPortIsExternal() {
        let record = makeRecord(port: 30142)
        let verdict = verify(record: record, expectation: makeExpectation(port: 30141))
        XCTAssertEqual(verdict, .external(.portMismatch))
    }

    // MARK: - Live arguments

    func testChangedLiveCommandLineIsExternal() {
        // The record was written for one command line; the live process now
        // reports another one (for example a second instance on the same port).
        let verdict = verify(
            record: makeRecord(),
            facts: makeFacts(commandLine: "node /opt/homebrew/bin/pi-web --hostname 0.0.0.0 --port 30141 --no-open")
        )
        XCTAssertEqual(verdict, .external(.argumentsMismatch))
        XCTAssertTrue(verdict.shouldRemoveRecord)
    }

    func testEmptyLiveCommandLineIsExternal() {
        // `ps -o args=` yielded nothing: unreadable output is a mismatch, never
        // a pass, even though every other fact matches.
        let verdict = verify(record: makeRecord(), facts: makeFacts(commandLine: ""))
        XCTAssertEqual(verdict, .external(.argumentsMismatch))
        XCTAssertTrue(verdict.shouldRemoveRecord)
    }

    func testLiveCommandLineWhitespaceRunsAreNormalized() throws {
        // `ps` pads columns; the comparison collapses whitespace runs so it
        // cannot produce a false mismatch.
        let padded = try XCTUnwrap(ProcessInspector.parseCommandLine(
            "node   /opt/homebrew/bin/pi-web   --hostname   127.0.0.1 --port 30141 --no-open"
        ))
        let verdict = verify(record: makeRecord(), facts: makeFacts(commandLine: padded))
        XCTAssertEqual(verdict, .managed)
    }

    func testReorderedArgumentsAreExternal() {
        let verdict = verify(
            record: makeRecord(),
            facts: makeFacts(commandLine: "node /opt/homebrew/bin/pi-web --port 30141 --hostname 127.0.0.1 --no-open")
        )
        XCTAssertEqual(verdict, .external(.argumentsMismatch))
    }

    func testCommandDigestIsStableAndNormalizesWhitespace() {
        let digest = ServiceOwnershipRecord.commandDigest(ofCommandText: liveCommandText)
        XCTAssertEqual(digest.count, 64)
        XCTAssertEqual(digest, ServiceOwnershipRecord.commandDigest(ofCommandText: liveCommandText))
        XCTAssertEqual(digest, ServiceOwnershipRecord.commandDigest(ofCommandText: "  node   /opt/homebrew/bin/pi-web --hostname 127.0.0.1  --port 30141 --no-open  "))
        XCTAssertNotEqual(digest, ServiceOwnershipRecord.commandDigest(ofCommandText: "node /opt/homebrew/bin/pi-web --hostname 127.0.0.1 --port 30142 --no-open"))
        XCTAssertNotEqual(digest, ServiceOwnershipRecord.commandDigest(ofCommandText: ""))
    }

    func testCommandTextIsTheCanonicalExecutablePlusArgumentsForm() {
        // Native executables report exactly this text through `ps -o args=`;
        // npm/shebang installs report the interpreter instead, which is why the
        // launch path records the observed live text.
        XCTAssertEqual(
            ServiceOwnershipRecord.commandText(executablePath: executable, arguments: launchArguments),
            "/opt/homebrew/bin/pi-web --hostname 127.0.0.1 --port 30141 --no-open"
        )
        XCTAssertEqual(
            ServiceOwnershipRecord.commandDigest(executablePath: executable, arguments: launchArguments),
            ServiceOwnershipRecord.commandDigest(ofCommandText: "/opt/homebrew/bin/pi-web --hostname 127.0.0.1 --port 30141 --no-open")
        )
    }

    // MARK: - Executable and process group

    func testChangedExecutableIsExternal() {
        let verdict = verify(record: makeRecord(), facts: makeFacts(resolvedExecutable: "/opt/homebrew/bin/other-server"))
        XCTAssertEqual(verdict, .external(.executableMismatch))
    }

    func testFallbackExecutableSourceStillRequiresTheCommandLineToMatch() {
        // `ps -o comm=` provenance is weak evidence on its own; the recorded
        // command-line digest is what keeps the verdict sound.
        let record = makeRecord(resolvedExecutable: "pi-web", resolvedExecutableSource: .psComm)
        XCTAssertEqual(verify(record: record, facts: makeFacts(resolvedExecutable: "pi-web", resolvedExecutableSource: .psComm)), .managed)
        XCTAssertEqual(
            verify(
                record: record,
                facts: makeFacts(
                    resolvedExecutable: "pi-web",
                    resolvedExecutableSource: .psComm,
                    commandLine: "node /opt/homebrew/bin/pi-web --hostname 0.0.0.0 --port 30141 --no-open"
                )
            ),
            .external(.argumentsMismatch)
        )
    }

    func testChangedProcessGroupIsExternal() {
        let verdict = verify(record: makeRecord(), facts: makeFacts(processGroupID: 9999))
        XCTAssertEqual(verdict, .external(.processGroupMismatch))
    }

    func testRecordThatIsNotAGroupLeaderIsInvalid() {
        // The app only ever writes records for group leaders it spawned; a
        // record with a different group id was not written by this launch path.
        let verdict = verify(record: makeRecord(pid: 5150, processGroupID: 5000))
        XCTAssertEqual(verdict, .external(.invalidRecord))
    }

    func testRecordWithUnusableFieldsIsInvalid() {
        XCTAssertEqual(verify(record: makeRecord(pid: 1, processGroupID: 1)), .external(.invalidRecord))
        XCTAssertEqual(verify(record: makeRecord(port: 0)), .external(.invalidRecord))
        XCTAssertEqual(verify(record: makeRecord(instanceID: "")), .external(.invalidRecord))
    }

    // MARK: - Stale record

    func testRecordWhoseProcessIsGoneIsExternal() {
        let verdict = verify(record: makeRecord(), alive: false)
        XCTAssertEqual(verdict, .external(.processNotAlive))
        XCTAssertTrue(verdict.shouldRemoveRecord)
    }

    // MARK: - Unverifiable facts

    func testUnavailableProcessFactsAreExternal() {
        let verdict = verify(record: makeRecord(), factsAvailable: false)
        XCTAssertEqual(verdict, .external(.processFactsUnavailable))
    }

    func testUnverifiableFactsKeepTheRecordForALaterCheck() {
        // A transient `ps` failure must not delete the only ownership proof;
        // the app still refuses to signal anything in this state.
        XCTAssertFalse(ServiceOwnershipVerdict.external(.processFactsUnavailable).shouldRemoveRecord)
        XCTAssertTrue(ServiceOwnershipVerdict.external(.instanceMismatch).shouldRemoveRecord)
        XCTAssertTrue(ServiceOwnershipVerdict.external(.launchTimeMismatch).shouldRemoveRecord)
        XCTAssertTrue(ServiceOwnershipVerdict.external(.argumentsMismatch).shouldRemoveRecord)
        XCTAssertTrue(ServiceOwnershipVerdict.external(.executableMismatch).shouldRemoveRecord)
        XCTAssertTrue(ServiceOwnershipVerdict.external(.processGroupMismatch).shouldRemoveRecord)
        XCTAssertTrue(ServiceOwnershipVerdict.external(.processNotAlive).shouldRemoveRecord)
        XCTAssertTrue(ServiceOwnershipVerdict.external(.invalidRecord).shouldRemoveRecord)
        XCTAssertFalse(ServiceOwnershipVerdict.managed.shouldRemoveRecord)
    }

    // MARK: - Signal guard

    func testProcessGroupLivenessRefusesUnusableIdentifiers() {
        // Signal 0 is a probe and never terminates anything, so this asserts
        // the `pgid > 1` guard without any risk of touching a real process.
        let signaler = POSIXServiceSignaler()
        XCTAssertFalse(signaler.isProcessGroupAlive(0))
        XCTAssertFalse(signaler.isProcessGroupAlive(1))
        XCTAssertFalse(signaler.isProcessGroupAlive(-1))
    }

    // MARK: - JSON store

    func testRecordRoundTripsThroughTheJSONStore() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("service-owner.json")
        let store = FileServiceOwnershipStore()
        let record = makeRecord()

        try store.save(record, to: url)

        XCTAssertEqual(store.loadRecord(from: url), record)
        let json = try XCTUnwrap(String(data: try Data(contentsOf: url), encoding: .utf8))
        for key in ["pid", "processGroupID", "launchedAt", "resolvedExecutable", "resolvedExecutableSource", "argumentsDigest", "port", "instanceID", "recordedAt"] {
            XCTAssertTrue(json.contains("\"\(key)\""), "record JSON is missing \(key)")
        }
        XCTAssertTrue(json.contains("\"proc_pidpath\""), "record JSON is missing the provenance value")
    }

    func testCorruptRecordIsTreatedAsMissingAndRemoved() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("service-owner.json")
        try "not json\n".write(to: url, atomically: true, encoding: .utf8)

        XCTAssertNil(FileServiceOwnershipStore().loadRecord(from: url))
        // An undecodable record is never an ownership proof; it is dropped
        // instead of lingering forever. Nothing is signalled for it.
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testRemovingARecordFileLeavesNoTrace() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("service-owner.json")
        let store = FileServiceOwnershipStore()
        try store.save(makeRecord(), to: url)

        store.removeRecord(at: url)

        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertNil(store.loadRecord(from: url))
        // Removing a missing record is a no-op rather than a crash.
        store.removeRecord(at: url)
    }

    // MARK: - Helpers

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("PiWebDesktopTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
