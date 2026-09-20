import Foundation
import XCTest

/// Unhosted tests for `Sources/LogWriter.swift`. Every writer points at a fresh
/// temporary directory (never `~/Library/Logs`), uses the injected file manager
/// and a fixed clock, and rotates with a tiny threshold so the real rotation
/// path — including the 10 MB default value — is exercised without writing 10 MB.
final class LogWriterTests: XCTestCase {
    private let fakeHome = "/tmp/PiWebDesktopTests/home"
    private let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)
    private var root: URL!

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pi-web-log-writer-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let root { try? FileManager.default.removeItem(at: root) }
        root = nil
        super.tearDown()
    }

    private var logURL: URL { root.appendingPathComponent("Logs/Pi Web Desktop.log") }

    private func makeWriter(policy: LogRotationPolicy = .standard) -> LogWriter {
        let date = fixedDate
        return LogWriter(
            logFileURL: logURL,
            policy: policy,
            fileManager: .default,
            redactor: LogRedactor(homeDirectory: fakeHome),
            now: { date }
        )
    }

    private func text(at url: URL) -> String {
        (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    private func rotatedURL(_ index: Int) -> URL {
        LogWriter.rotatedFileURL(for: logURL, index: index)
    }

    /// 轮转文件里的 `entry-<n>-` 序号，用来断言先后顺序而不是具体字节数。
    private func entryNumbers(in text: String) -> [Int] {
        text.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "-")
            guard parts.count > 1 else { return nil }
            return Int(parts[1])
        }
    }

    // MARK: 写入与脱敏

    func testAppendCreatesTheDirectoryAndRedactsEveryLine() {
        let writer = makeWriter()
        XCTAssertTrue(writer.append("""
        plain line
        token=test-secret-value  // scan-secrets: allow(reason=redaction fixture)
        Authorization: Bearer header-secret
        cwd \(fakeHome)/work
        """))
        let log = text(at: logURL)
        XCTAssertTrue(log.contains("plain line"))
        XCTAssertFalse(log.contains("test-secret-value"))
        XCTAssertFalse(log.contains("header-secret"))
        XCTAssertFalse(log.contains(fakeHome))
        XCTAssertTrue(log.contains("cwd ~/work"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: logURL.deletingLastPathComponent().path))
        XCTAssertNil(writer.failureDescription)
    }

    func testRecordUsesTheInjectedClock() {
        let writer = makeWriter()
        XCTAssertTrue(writer.record("服务已启动：PID 4321"))
        let stamp = LogWriter.timestamp(for: fixedDate)
        XCTAssertEqual(text(at: logURL), "[\(stamp)] 服务已启动：PID 4321")
    }

    func testEmptyInputIsIgnored() {
        let writer = makeWriter()
        XCTAssertTrue(writer.append(""))
        XCTAssertFalse(FileManager.default.fileExists(atPath: logURL.path))
        XCTAssertNil(writer.failureDescription)
    }

    /// GitHub #38：写入路径同样要覆盖引号值、带空白的键值分隔符与 `key:` 续行。
    func testAppendRedactsQuotedAndContinuationValues() {
        let writer = makeWriter()
        XCTAssertTrue(writer.append("""
        password="a b c"
        secret = "spaced value"  // scan-secrets: allow(reason=redaction fixture)
        token:
          continuation-value
        """))
        let log = text(at: logURL)
        for secret in ["a b c", "spaced value", "continuation-value"] {
            XCTAssertFalse(log.contains(secret), "leaked \(secret): \(log)")
        }
        XCTAssertEqual(log.components(separatedBy: "\n").filter { $0.contains(LogRedactor.marker) }.count, 3, log)
        XCTAssertNil(writer.failureDescription)
    }

    // MARK: 轮转

    func testDefaultPolicyMatchesTheDocumentedLimits() {
        XCTAssertEqual(LogRotationPolicy.standard.maximumBytes, 10 * 1024 * 1024)
        XCTAssertEqual(LogRotationPolicy.standard.retainedFileCount, 5)
    }

    /// 小阈值重复轮转：文件名固定为 `<base>.<index>.log`，保留份数有上限，
    /// 且越新的内容越靠前（`.1` 比 `.3` 新）。
    func testRepeatedSmallThresholdRotationKeepsNamesAndRetentionCap() {
        let policy = LogRotationPolicy(maximumBytes: 80, retainedFileCount: 3)
        let writer = makeWriter(policy: policy)
        let payload = String(repeating: "x", count: 60)
        for index in 1...12 {
            XCTAssertTrue(writer.append("entry-\(index)-\(payload)\n"))
        }

        XCTAssertEqual(rotatedURL(1).lastPathComponent, "Pi Web Desktop.1.log")
        XCTAssertEqual(rotatedURL(2).lastPathComponent, "Pi Web Desktop.2.log")
        XCTAssertTrue(FileManager.default.fileExists(atPath: rotatedURL(3).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: rotatedURL(4).path), "保留份数必须封顶")

        // 所有轮转都要真的发生过，而不是每次都写进同一个文件。
        XCTAssertTrue(FileManager.default.fileExists(atPath: logURL.path))
        XCTAssertTrue(text(at: logURL).contains("entry-12-"), text(at: logURL))
        XCTAssertTrue(text(at: logURL).contains("entry-11-"), text(at: logURL))
        XCTAssertFalse(text(at: logURL).contains("entry-1-"))

        let newest = entryNumbers(in: text(at: rotatedURL(1)))
        let oldest = entryNumbers(in: text(at: rotatedURL(3)))
        XCTAssertFalse(newest.isEmpty)
        XCTAssertFalse(oldest.isEmpty)
        XCTAssertGreaterThan(newest.max() ?? 0, oldest.max() ?? 0)
        XCTAssertNil(writer.failureDescription)
    }

    func testManyRotationsNeverExceedTheRetentionCap() {
        let policy = LogRotationPolicy(maximumBytes: 40, retainedFileCount: 2)
        let writer = makeWriter(policy: policy)
        for index in 1...40 {
            writer.append("entry-\(index)-" + String(repeating: "y", count: 25) + "\n")
        }
        let rotatedNames = (1...8)
            .map { rotatedURL($0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
            .map(\.lastPathComponent)
        XCTAssertEqual(rotatedNames, ["Pi Web Desktop.1.log", "Pi Web Desktop.2.log"])
    }

    // MARK: 子进程句柄与历史日志脱敏

    func testOpenChildOutputScrubsHistoricallyWrittenSecrets() throws {
        let writer = makeWriter(policy: LogRotationPolicy(maximumBytes: 1024, retainedFileCount: 2))
        try FileManager.default.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "token=old-history-secret\nplain history\n".write(to: logURL, atomically: true, encoding: .utf8)  // scan-secrets: allow(reason=redaction fixture)

        let handle = try writer.openChildOutput()
        try handle.write(contentsOf: Data("child output\n".utf8))
        try handle.close()

        let log = text(at: logURL)
        XCTAssertFalse(log.contains("old-history-secret"))
        XCTAssertTrue(log.contains("plain history"))
        XCTAssertTrue(log.contains("child output"))
    }

    /// GitHub #38 R-1：就地脱敏必须幂等——第二次 scrub 不能吞掉第一次留下的 `}`。
    func testScrubbingAnAlreadyRedactedLogIsByteStable() {
        let writer = makeWriter()
        XCTAssertTrue(writer.append("{\"token\": \"json-secret-value\"} trailing-context\n"))
        XCTAssertTrue(writer.scrubExistingLog())
        let once = text(at: logURL)
        XCTAssertFalse(once.contains("json-secret-value"), once)
        XCTAssertTrue(once.contains("}"), once)
        XCTAssertTrue(once.contains("trailing-context"), once)

        XCTAssertTrue(writer.scrubExistingLog())
        XCTAssertEqual(text(at: logURL), once)
        XCTAssertNil(writer.failureDescription)
    }

    func testOpenChildOutputRotatesAnOversizedLogAfterScrubbingIt() throws {
        let writer = makeWriter(policy: LogRotationPolicy(maximumBytes: 64, retainedFileCount: 2))
        try FileManager.default.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try ("token=rotated-secret\n" + String(repeating: "z", count: 100) + "\n")  // scan-secrets: allow(reason=redaction fixture)
            .write(to: logURL, atomically: true, encoding: .utf8)

        let handle = try writer.openChildOutput()
        try handle.close()

        XCTAssertTrue(FileManager.default.fileExists(atPath: rotatedURL(1).path))
        XCTAssertTrue(text(at: rotatedURL(1)).contains("zzz"))
        XCTAssertFalse(text(at: rotatedURL(1)).contains("rotated-secret"), "轮转前必须先脱敏历史日志")
        XCTAssertEqual(text(at: logURL), "")
    }

    // MARK: 失败路径

    func testWriteFailureIsRecordedInsteadOfCrashing() throws {
        // 日志目录的位置被同名文件占据：createDirectory 必然失败。
        let blockedDirectory = root.appendingPathComponent("blocked", isDirectory: true)
        try Data("not a directory".utf8).write(to: blockedDirectory)
        let date = fixedDate
        let writer = LogWriter(
            logFileURL: blockedDirectory.appendingPathComponent("Pi Web Desktop.log"),
            policy: .standard,
            fileManager: .default,
            redactor: LogRedactor(homeDirectory: fakeHome),
            now: { date }
        )

        XCTAssertFalse(writer.append("hello"))
        XCTAssertFalse(writer.record("事件"))
        let failure = try XCTUnwrap(writer.failureDescription)
        XCTAssertTrue(failure.hasPrefix(LogWriter.timestamp(for: fixedDate)), failure)
        XCTAssertTrue(writer.writeStatusDescription.contains("写入失败"))
    }

    func testOpenChildOutputReportsAReadableErrorWhenTheDirectoryCannotBeUsed() throws {
        let blockedDirectory = root.appendingPathComponent("blocked-handle", isDirectory: true)
        try Data("not a directory".utf8).write(to: blockedDirectory)
        let writer = LogWriter(
            logFileURL: blockedDirectory.appendingPathComponent("Pi Web Desktop.log"),
            policy: .standard,
            fileManager: .default,
            redactor: LogRedactor(homeDirectory: fakeHome)
        )
        do {
            _ = try writer.openChildOutput()
            XCTFail("openChildOutput should throw when the log directory cannot be used")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("日志"))
        }
        XCTAssertNotNil(writer.failureDescription)
    }

    /// 失败记录本身也要脱敏：错误文本里的完整路径不能带出用户名。
    func testFailureMessageIsRedacted() throws {
        let blockedHome = root.appendingPathComponent("fake-home", isDirectory: true)
        try Data("x".utf8).write(to: blockedHome)
        let writer = LogWriter(
            logFileURL: blockedHome.appendingPathComponent("Pi Web Desktop.log"),
            policy: .standard,
            fileManager: .default,
            redactor: LogRedactor(homeDirectory: blockedHome.path)
        )
        XCTAssertFalse(writer.append("hello"))
        let failure = try XCTUnwrap(writer.failureDescription)
        XCTAssertFalse(failure.contains(blockedHome.path), failure)
        XCTAssertTrue(failure.contains("~"), failure)
    }
}
