import Foundation
import XCTest

/// Unhosted tests for `Sources/LogWriter.swift`. Every writer points at a fresh
/// temporary directory (never `~/Library/Logs`), uses the injected file manager
/// and a fixed clock, and rotates with a tiny threshold so the real rotation
/// path — including the 10 MB default value — is exercised without writing 10 MB.
///
/// GitHub #73 起子进程的 stdout/stderr 是 `openChildOutput()` 返回的**管道写端**：
/// 测试直接往这个句柄写字节来模拟子进程输出，等 `childOutputIsDrained` 与
/// `flush()` 后即可断言日志内容，不需要真的启动进程。
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
    /// 只认 `entry-` 开头的行：轮转说明行里带日期（`2023-11-14`），不加这个限制
    /// 会把月份当成序号。
    private func entryNumbers(in text: String) -> [Int] {
        text.split(separator: "\n").compactMap { line in
            guard line.hasPrefix("entry-") else { return nil }
            let parts = line.split(separator: "-")
            guard parts.count > 1 else { return nil }
            return Int(parts[1])
        }
    }

    // MARK: 子进程输出管道

    /// 轮询 `condition` 直到成立；超时用 `XCTFail` 结束并打印 `diagnostics`，而不是
    /// 让调用方继续对半写入的文件做一串看似无关的断言（GitHub #88）。
    ///
    /// 轮询间隔只决定“多久再看一眼”，正确性来自条件本身：固定 `sleep` 把时长当同步
    /// 保证，在慢 runner 上必现失败、在快 runner 上白白等待。只有无法用生产者已有的
    /// 排空原语（`flush()` / `childOutputIsDrained`）表达的等待才允许走这里。
    @discardableResult
    private func waitUntil(
        _ description: String,
        timeout: TimeInterval = 10,
        diagnostics: @autoclosure () -> String = "",
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: () -> Bool
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if condition() { return true }
            if Date() >= deadline { break }
            Thread.sleep(forTimeInterval: 0.01)
        }
        let detail = diagnostics()
        XCTFail(
            "等待超时（\(timeout)s）：\(description)" + (detail.isEmpty ? "" : "\n--- 现场 ---\n\(detail)"),
            file: file,
            line: line
        )
        return false
    }

    /// 超时诊断：当前日志、存在的轮转文件与失败记录一次给全，CI 上不必再猜是哪一步
    /// 没落地。
    private func logDiagnostics(_ writer: LogWriter) -> String {
        var lines = ["当前日志 \(logURL.path):", text(at: logURL)]
        for index in 1...8 where FileManager.default.fileExists(atPath: rotatedURL(index).path) {
            lines.append("轮转文件 .\(index) \(rotatedURL(index).path):")
            lines.append(text(at: rotatedURL(index)))
        }
        lines.append("failureDescription: \(writer.failureDescription ?? "无")")
        return lines.joined(separator: "\n")
    }

    /// 关闭管道写端（模拟子进程退出）并等读端排空、写入队列清空。这是确定性的同步点：
    /// `childOutputIsDrained` 由读取队列在读到 EOF 前把所有数据交给写入队列之后才置位
    /// （见 `LogWriter.readChildOutput`），再 `flush()` 写入队列，因此返回后日志文件
    /// 的内容才允许被断言。超时由 `waitUntil` 失败并打印现场。
    private func drainChildOutput(_ writer: LogWriter, timeout: TimeInterval = 10) {
        _ = waitUntil(
            "子进程输出读端排空（EOF）",
            timeout: timeout,
            diagnostics: logDiagnostics(writer)
        ) { writer.childOutputIsDrained }
        writer.flush()
    }

    /// 把 `lines` 写到管道写端，然后关闭并等落盘。
    private func writeChildOutput(_ writer: LogWriter, _ handle: FileHandle, _ lines: [String]) {
        for line in lines {
            try? handle.write(contentsOf: Data(line.utf8))
        }
        try? handle.close()
        drainChildOutput(writer)
    }

    private func visibleLogText() -> String {
        var combined = text(at: logURL)
        for index in 1...8 {
            combined += text(at: rotatedURL(index))
        }
        return combined
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
        XCTAssertNil(writer.failureDescription)
    }

    /// 轮转在日志里可见（GitHub #73）：新文件开头有一条说明，转到哪一份、保留几份。
    func testRotationIsVisibleInTheLog() {
        let policy = LogRotationPolicy(maximumBytes: 40, retainedFileCount: 2)
        let writer = makeWriter(policy: policy)
        writer.append("entry-1-" + String(repeating: "z", count: 60) + "\n")
        writer.append("entry-2-" + String(repeating: "z", count: 60) + "\n")

        let current = text(at: logURL)
        XCTAssertTrue(current.contains("日志已轮转"), current)
        XCTAssertTrue(current.contains("Pi Web Desktop.1.log"), current)
        XCTAssertTrue(current.contains("保留 2 份"), current)
        // 说明行不计入大小上限：它自身超过 40 字节也不能把新文件立刻再轮转一次。
        XCTAssertTrue(current.contains("entry-2-"), current)
        XCTAssertFalse(text(at: rotatedURL(2)).contains("日志已轮转"), "说明只写进当前日志")
    }

    // MARK: 子进程句柄与历史日志脱敏

    func testOpenChildOutputScrubsHistoricallyWrittenSecrets() throws {
        let writer = makeWriter(policy: LogRotationPolicy(maximumBytes: 1024, retainedFileCount: 2))
        try FileManager.default.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "token=old-history-secret\nplain history\n".write(to: logURL, atomically: true, encoding: .utf8)  // scan-secrets: allow(reason=redaction fixture)

        let handle = try writer.openChildOutput()
        writeChildOutput(writer, handle, ["child output\n"])

        let log = text(at: logURL)
        XCTAssertFalse(log.contains("old-history-secret"))
        XCTAssertTrue(log.contains("plain history"))
        XCTAssertTrue(log.contains("child output"))
        XCTAssertNil(writer.failureDescription)
    }

    /// 子进程输出同样逐行走注入的脱敏器（GitHub #73）：管道不是脱敏的旁路。
    func testChildOutputIsRedactedBeforeItReachesTheLog() throws {
        let writer = makeWriter()
        let handle = try writer.openChildOutput()
        writeChildOutput(writer, handle, [
            "child token=child-secret-value\n",  // scan-secrets: allow
            "child cwd \(fakeHome)/project\n",
            "child tail without newline"
        ])

        let log = text(at: logURL)
        XCTAssertFalse(log.contains("child-secret-value"), log)
        XCTAssertFalse(log.contains(fakeHome), log)
        XCTAssertTrue(log.contains("child cwd ~/project"), log)
        XCTAssertTrue(log.hasSuffix("child tail without newline"), log)
        XCTAssertNil(writer.failureDescription)
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
        drainChildOutput(writer)

        XCTAssertTrue(FileManager.default.fileExists(atPath: rotatedURL(1).path))
        XCTAssertTrue(text(at: rotatedURL(1)).contains("zzz"))
        XCTAssertFalse(text(at: rotatedURL(1)).contains("rotated-secret"), "轮转前必须先脱敏历史日志")
        let current = text(at: logURL)
        XCTAssertFalse(current.contains("zzz"))
        XCTAssertTrue(current.contains("日志已轮转"), current)
        XCTAssertNil(writer.failureDescription)
    }

    /// 历史日志的脱敏是后台流式工作（GitHub #73 / M5）：8 MB 历史日志不再让
    /// 启动路径（openChildOutput + 紧随其后的 record）同步冻结数秒。
    func testOpenChildOutputDoesNotBlockTheStartupPathOnALargeHistory() throws {
        let writer = makeWriter()
        try FileManager.default.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        var history = ""
        while history.utf8.count < 8 * 1024 * 1024 {
            history += "token=history-secret-value repeated context line\n"  // scan-secrets: allow
        }
        try history.write(to: logURL, atomically: true, encoding: .utf8)

        let started = Date()
        let handle = try writer.openChildOutput()
        _ = writer.record("服务已启动：PID 4321")
        let startupElapsed = Date().timeIntervalSince(started)
        // 同步脱敏整份 8 MB 日志需要数秒；后台排队时启动路径应该在毫秒级返回。
        XCTAssertLessThan(startupElapsed, 1.5, "启动路径被历史脱敏阻塞了 \(startupElapsed) 秒")

        try handle.close()
        drainChildOutput(writer, timeout: 120)
        let scrubbed = text(at: logURL)
        XCTAssertFalse(scrubbed.contains("history-secret-value"), "后台脱敏必须仍然完成")
        XCTAssertTrue(scrubbed.contains("服务已启动：PID 4321"), "脱敏重写不能吞掉之后写入的行")
        XCTAssertNil(writer.failureDescription)
    }

    // MARK: 轮转与并发写入（GitHub #73）

    /// H1 回归：轮转不再让子进程的输出落进旧 inode。
    ///
    /// 先让应用侧把日志推过阈值多次轮转，然后子进程才写哨兵行；哨兵必须出现在
    /// **当前**日志里。修复前子进程持有旧文件的 fd，哨兵会写进 `.1` 甚至已删除的
    /// inode，因此这个断言会失败。
    func testChildOutputWrittenAfterRotationsStaysInTheCurrentLog() throws {
        let policy = LogRotationPolicy(maximumBytes: 150, retainedFileCount: 3)
        let writer = makeWriter(policy: policy)
        let handle = try writer.openChildOutput()
        try handle.write(contentsOf: Data("child-before-rotations\n".utf8))

        // 多次轮转：每次 200 字节，150 字节阈值 → 至少 3 次轮转。
        for index in 1...6 {
            writer.append("entry-\(index)-" + String(repeating: "r", count: 190) + "\n")
        }
        // GitHub #88：`openChildOutput()` 先在写入队列上排了后台准备（历史脱敏 →
        // 轮转），上面的 `append` 因此可能被异步排队。断言文件系统之前必须用
        // `flush()` 把队列排空，不能假定调用返回时轮转已经落盘。
        writer.flush()
        XCTAssertTrue(FileManager.default.fileExists(atPath: rotatedURL(3).path), "至少要轮转过 3 次")

        try handle.write(contentsOf: Data("CHILD-SENTINEL-AFTER-ROTATIONS\n".utf8))
        try handle.close()
        drainChildOutput(writer)
        writer.flush()

        let current = text(at: logURL)
        XCTAssertTrue(current.contains("CHILD-SENTINEL-AFTER-ROTATIONS"), "轮转后的子进程输出必须出现在当前日志里：\(current)")
        XCTAssertEqual(visibleLogText().components(separatedBy: "CHILD-SENTINEL-AFTER-ROTATIONS").count, 2, "哨兵只出现一次")
        XCTAssertNil(writer.failureDescription)
    }

    /// 重启路径：重新打开子进程输出通道前，旧管道里已经缓冲的数据必须先读干净，
    /// 否则取消读端会把“子进程刚写完、应用侧还没读”的最后几行一起丢掉。
    func testReopeningChildOutputDrainsThePreviousPipeBeforeReplacingIt() throws {
        let writer = makeWriter()
        let first = try writer.openChildOutput()
        try first.write(contentsOf: Data("first-child-tail-without-newline".utf8))

        // 不关写端就重新打开（健康监控在毫秒级重启服务的路径）。
        let second = try writer.openChildOutput()
        writer.flush()
        XCTAssertTrue(
            text(at: logURL).contains("first-child-tail-without-newline"),
            text(at: logURL)
        )

        try second.write(contentsOf: Data("second-child-line\n".utf8))
        try second.close()
        drainChildOutput(writer)
        XCTAssertTrue(text(at: logURL).contains("second-child-line"))
        XCTAssertNil(writer.failureDescription)
    }

    /// 退出但保持服务运行（文档化的退出行为）：应用退出后读端交给排空进程，
    /// 服务的 stdout/stderr 仍然可写（内容丢弃），不会收到 `EPIPE`。
    ///
    /// 修复前这里会是“读端随应用退出而关闭”：Node 的 `process.stdout` 收到
    /// `EPIPE` 后变成未处理的 `error` 事件，服务直接退出。
    func testQuitHandsTheChildPipeToADrainerSoTheServiceKeepsWriting() throws {
        let writer = makeWriter()
        let handle = try writer.openChildOutput()
        try handle.write(contentsOf: Data("before-hand-off\n".utf8))

        let drainerPID = try XCTUnwrap(writer.handOffChildOutputToDrainer())
        XCTAssertGreaterThan(drainerPID, 1)
        // 排空进程必须真的在读，而不是立即退出（僵尸也能通过 kill(pid, 0)）。
        XCTAssertEqual(waitpid(drainerPID, nil, WNOHANG), 0, "排空进程不应该立即退出")
        XCTAssertEqual(kill(drainerPID, 0), 0)
        XCTAssertNil(writer.handOffChildOutputToDrainer(), "没有管道时不再重复交出")

        // 超过管道缓冲区（64 KB）的写入只有在真的有人在读的时候才能完成。
        // 后台执行 + 超时：万一排空进程没起来，这里失败而不是把测试挂死。
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            try? handle.write(contentsOf: Data(repeating: 0x63, count: 256 * 1024))
            finished.signal()
        }
        XCTAssertEqual(finished.wait(timeout: .now() + 20), .success, "管道没有被排空")

        try handle.close()
        // 写端关闭 → 排空进程读到 EOF 并退出（它是本测试进程的子进程，要收尸）。
        // 有界轮询而不是固定等待：慢 runner 上进程退出可以晚于任意短 sleep。
        let reaped = waitUntil("排空进程在写端关闭后自行退出", timeout: 10) {
            waitpid(drainerPID, nil, WNOHANG) == drainerPID
        }
        if !reaped { kill(drainerPID, SIGKILL) }

        let log = text(at: logURL)
        XCTAssertTrue(log.contains("before-hand-off"), log)
        XCTAssertFalse(log.contains("ccc"), "交出后应用侧不再记录子进程输出")
        XCTAssertNil(writer.failureDescription)
    }

    /// H2 回归：应用侧与子进程交替大量写入，既不丢行也不互相覆盖。
    func testConcurrentAppAndChildWritesLoseNoLines() throws {
        let policy = LogRotationPolicy(maximumBytes: 10 * 1024 * 1024, retainedFileCount: 2)
        let writer = makeWriter(policy: policy)
        let handle = try writer.openChildOutput()

        let appLineCount = 400
        let childLineCount = 400
        for index in 1...appLineCount {
            writer.append("APP-\(index)-" + String(repeating: "a", count: 40) + "\n")
            if index <= childLineCount {
                try handle.write(contentsOf: Data("CHILD-\(index)-\n".utf8))
            }
        }
        try handle.close()
        drainChildOutput(writer)
        writer.flush()

        let text = visibleLogText()
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let appNumbers = Set(lines.compactMap { line -> Int? in
            guard line.hasPrefix("APP-") else { return nil }
            return Int(line.dropFirst("APP-".count).prefix(while: { $0.isNumber }))
        })
        let childNumbers = Set(lines.compactMap { line -> Int? in
            guard line.hasPrefix("CHILD-") else { return nil }
            return Int(line.dropFirst("CHILD-".count).prefix(while: { $0.isNumber }))
        })
        XCTAssertEqual(appNumbers, Set(1...appLineCount), "应用侧丢行：缺 \(Set(1...appLineCount).subtracting(appNumbers).sorted())")
        XCTAssertEqual(childNumbers, Set(1...childLineCount), "子进程丢行：缺 \(Set(1...childLineCount).subtracting(childNumbers).sorted())")
        // 交替写入时每一行都必须完整：半行/粘连行会让行数与内容对不上。
        XCTAssertEqual(lines.filter { !$0.isEmpty }.count, appLineCount + childLineCount, text)
        XCTAssertNil(writer.failureDescription)
    }

    /// O_APPEND（GitHub #73 H2）：应用侧不再 `seekToEnd`，文件被外部改名后也不会
    /// 继续追加到旧 inode。
    func testAppendsSurviveAnExternalRenameWithoutWritingTheOldInode() throws {
        let writer = makeWriter(policy: LogRotationPolicy(maximumBytes: 1_000_000, retainedFileCount: 2))
        XCTAssertTrue(writer.append("before-external-rotation\n"))
        writer.flush()

        let moved = rotatedURL(1)
        try FileManager.default.moveItem(at: logURL, to: moved)
        let sizeAfterExternalMove = try XCTUnwrap(
            (try FileManager.default.attributesOfItem(atPath: moved.path)[.size]) as? NSNumber
        )
        XCTAssertTrue(writer.append("after-external-rotation\n"))
        writer.flush()

        let recreated = text(at: logURL)
        XCTAssertTrue(recreated.contains("after-external-rotation"), recreated)
        XCTAssertFalse(recreated.contains("before-external-rotation"), recreated)
        XCTAssertTrue(text(at: moved).contains("before-external-rotation"))
        // 直接断言“没有写旧 inode”：改名后的文件大小必须一字未变。
        XCTAssertEqual(
            (try FileManager.default.attributesOfItem(atPath: moved.path)[.size]) as? NSNumber,
            sizeAfterExternalMove
        )
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

        // 返回值表示“已接受写入”；真实结果由 failureDescription 暴露（不静默）。
        XCTAssertTrue(writer.append("hello"))
        XCTAssertTrue(writer.record("事件"))
        writer.flush()
        let failure = try XCTUnwrap(writer.failureDescription)
        XCTAssertTrue(failure.hasPrefix(LogWriter.timestamp(for: fixedDate)), failure)
        XCTAssertTrue(failure.contains("创建日志目录失败"), failure)
        XCTAssertTrue(writer.writeStatusDescription.contains("写入失败"))
    }

    /// 轮转失败（目录不可写）只记录，不中断写入：这一行仍然落到当前日志里。
    func testRotationFailureFallsBackToAppendingToTheOversizedFile() throws {
        let writer = makeWriter(policy: LogRotationPolicy(maximumBytes: 32, retainedFileCount: 2))
        XCTAssertTrue(writer.append("first-" + String(repeating: "f", count: 40) + "\n"))
        let directory = logURL.deletingLastPathComponent()
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: directory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path) }

        XCTAssertTrue(writer.append("after-failed-rotation\n"))
        writer.flush()

        let log = text(at: logURL)
        XCTAssertTrue(log.contains("after-failed-rotation"), log)
        XCTAssertFalse(FileManager.default.fileExists(atPath: rotatedURL(1).path))
        let failure = try XCTUnwrap(writer.failureDescription)
        XCTAssertTrue(failure.contains("轮转日志失败"), failure)
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
        XCTAssertTrue(writer.append("hello"))
        writer.flush()
        let failure = try XCTUnwrap(writer.failureDescription)
        XCTAssertFalse(failure.contains(blockedHome.path), failure)
        XCTAssertTrue(failure.contains("~"), failure)
    }
}
