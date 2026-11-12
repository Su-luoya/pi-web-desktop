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
        XCTAssertNil(ProcessInspector.parseCommandLine(""))
        XCTAssertNil(ProcessInspector.parseCommandLine(nil))
        XCTAssertNil(ProcessInspector.parseCommandLine("  \n"))
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

    func testCommandLineIsTrimmedAndWhitespaceIsCollapsed() {
        XCTAssertEqual(
            ProcessInspector.parseCommandLine("  node   /opt/homebrew/bin/pi-web  --no-open \n"),
            "node /opt/homebrew/bin/pi-web --no-open"
        )
        // A single-token command line is a valid observation.
        XCTAssertEqual(ProcessInspector.parseCommandLine("pi-web\n"), "pi-web")
    }

    // MARK: - Command wiring

    func testListenerQueryUsesTheConfiguredPort() {
        let runner = FakeCommandRunner()
        runner.handler = { arguments in
            arguments.first == ProcessInspector.listenerCommand ? "4321\n" : "node /opt/homebrew/bin/pi-web\n"
        }
        let inspector = makeInspector(runner: runner)

        XCTAssertEqual(inspector.listenerPID(port: 30141), 4321)
        XCTAssertEqual(
            runner.invocations.last,
            ["/usr/sbin/lsof", "-nP", "-t", "-iTCP:30141", "-sTCP:LISTEN"]
        )

        runner.handler = { _ in "" }
        XCTAssertNil(inspector.listenerPID(port: 30141))
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

    func testProcessFactsCombineAllQueries() {
        let runner = FakeCommandRunner()
        runner.handler = { arguments in
            guard let formatIndex = arguments.firstIndex(of: "-o"), formatIndex + 1 < arguments.count else { return nil }
            switch arguments[formatIndex + 1] {
            case "pgid=": return "5150\n"
            case "lstart=": return "Wed Jul 30 12:00:00 2025\n"
            case "comm=": return "/opt/homebrew/bin/pi-web\n"
            case "args=": return "node /opt/homebrew/bin/pi-web --hostname 127.0.0.1 --port 30141 --no-open\n"
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
                resolvedExecutable: "/opt/homebrew/bin/pi-web",
                resolvedExecutableSource: .psComm,
                commandLine: "node /opt/homebrew/bin/pi-web --hostname 127.0.0.1 --port 30141 --no-open"
            )
        )
        XCTAssertEqual(runner.invocations, [
            ["/bin/ps", "-o", "pgid=", "-p", "5150"],
            ["/bin/ps", "-o", "lstart=", "-p", "5150"],
            ["/bin/ps", "-o", "comm=", "-p", "5150"],
            ["/bin/ps", "-o", "args=", "-p", "5150"]
        ])
    }

    func testProcPidPathIsPreferredOverPsComm() {
        let runner = FakeCommandRunner()
        runner.handler = { arguments in
            guard let formatIndex = arguments.firstIndex(of: "-o"), formatIndex + 1 < arguments.count else { return nil }
            switch arguments[formatIndex + 1] {
            case "pgid=": return "5150\n"
            case "lstart=": return "Wed Jul 30 12:00:00 2025\n"
            case "comm=": return "pi-web\n"
            case "args=": return "node /opt/homebrew/bin/pi-web --no-open\n"
            default: return nil
            }
        }
        let inspector = ProcessInspector(
            runner: runner,
            processIsAlive: { _ in true },
            processExecutablePath: { _ in "/opt/homebrew/bin/node" }
        )

        let facts = inspector.processFacts(of: 5150)
        XCTAssertEqual(facts?.resolvedExecutable, "/opt/homebrew/bin/node")
        XCTAssertEqual(facts?.resolvedExecutableSource, .procPidPath)
        // The weak `ps -o comm=` query is not even needed in this case.
        XCTAssertFalse(runner.invocations.contains(["/bin/ps", "-o", "comm=", "-p", "5150"]))
    }

    func testEmptyArgsQueryStillReturnsFactsWithAnEmptyCommandLine() {
        // An empty `ps -o args=` is an observation (nothing to compare), not a
        // missing fact: the verifier turns it into a mismatch and never signals.
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

        XCTAssertEqual(inspector.processFacts(of: 5150)?.commandLine, "")
    }

    func testFailedProcPidPathFallsBackToPsComm() {
        let runner = FakeCommandRunner()
        runner.handler = { arguments in
            guard let formatIndex = arguments.firstIndex(of: "-o"), formatIndex + 1 < arguments.count else { return nil }
            switch arguments[formatIndex + 1] {
            case "pgid=": return "5150\n"
            case "lstart=": return "Wed Jul 30 12:00:00 2025\n"
            case "comm=": return "pi-web\n"
            case "args=": return "pi-web --no-open\n"
            default: return nil
            }
        }
        let inspector = makeInspector(runner: runner)

        let facts = inspector.processFacts(of: 5150)
        XCTAssertEqual(facts?.resolvedExecutable, "pi-web")
        XCTAssertEqual(facts?.resolvedExecutableSource, .psComm)
    }

    func testExecutableQueryWithoutAnySourceMakesProcessFactsUnavailable() {
        let runner = FakeCommandRunner()
        runner.handler = { arguments in
            guard let formatIndex = arguments.firstIndex(of: "-o"), formatIndex + 1 < arguments.count else { return nil }
            switch arguments[formatIndex + 1] {
            case "pgid=": return "5150\n"
            case "lstart=": return "Wed Jul 30 12:00:00 2025\n"
            default: return nil
            }
        }
        XCTAssertNil(makeInspector(runner: runner).processFacts(of: 5150))
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

    // MARK: - 探针的超时、取消与线程约定（W4 M1）

    /// 假探针子进程：不启动任何真实命令。`waitForExit` 的回答由测试给定，
    /// 因此超时与取消路径不需要真实等待；信号调用次数可断言。
    private final class FakeProbeProcess: ProbeProcess {
        /// 每次 `waitForExit` 的回答；用完后重复最后一个。
        var waitAnswers: [Bool] = [true]
        var isRunning = true
        var terminationStatus: Int32 = 0
        var standardOutput = Data()
        var standardError = Data()
        private(set) var waitTimeouts: [TimeInterval] = []
        private(set) var terminateCount = 0
        private(set) var forceTerminateCount = 0

        init(waitAnswers: [Bool]) {
            self.waitAnswers = waitAnswers
        }

        func waitForExit(timeout: TimeInterval) -> Bool {
            waitTimeouts.append(timeout)
            return waitAnswers.count > 1 ? waitAnswers.removeFirst() : (waitAnswers.first ?? true)
        }

        func readStandardOutput() -> Data { standardOutput }
        func readStandardError() -> Data { standardError }

        @discardableResult
        func terminate() -> Bool {
            terminateCount += 1
            return true
        }

        @discardableResult
        func forceTerminate() -> Bool {
            forceTerminateCount += 1
            return true
        }
    }

    /// 一直“运行中”的假探针：`waitForExit` 阻塞到 `terminate()` 被调，用来从另一个
    /// 线程驱动取消路径（生产里就是 SIGTERM 让子进程退出）。
    private final class BlockingProbeProcess: ProbeProcess {
        let started = DispatchSemaphore(value: 0)
        private let release = DispatchSemaphore(value: 0)
        var isRunning = true
        var terminationStatus: Int32 = 0
        private(set) var terminateCount = 0
        private(set) var forceTerminateCount = 0

        func waitForExit(timeout: TimeInterval) -> Bool {
            started.signal()
            _ = release.wait(timeout: .now() + 5)
            return true
        }

        func readStandardOutput() -> Data { Data() }

        @discardableResult
        func terminate() -> Bool {
            terminateCount += 1
            release.signal()
            return true
        }

        @discardableResult
        func forceTerminate() -> Bool {
            forceTerminateCount += 1
            return true
        }
    }

    func testSuccessfulProbeReturnsOutputWithoutSignalling() {
        let process = FakeProbeProcess(waitAnswers: [true])
        process.standardOutput = Data("v22.19.0\n".utf8)
        let runner = SystemCommandRunner(timeout: 1, spawn: { _, _ in process })

        let result = runner.run(["/bin/echo"], timeout: 1)
        XCTAssertEqual(result, CommandRunResult(output: "v22.19.0\n"))
        XCTAssertEqual(process.terminateCount, 0)
        XCTAssertEqual(process.forceTerminateCount, 0)
        // 旧入口保持原语义：退出码 0 时返回标准输出。
        XCTAssertEqual(runner.run(["/bin/echo"]), "v22.19.0\n")
    }

    func testFailedProbeKeepsBothStreamsForDiagnosticsWithoutReturningSuccess() {
        let process = FakeProbeProcess(waitAnswers: [true])
        process.terminationStatus = 1
        process.standardOutput = Data("HTTPS setup required\n".utf8)
        process.standardError = Data("permission denied\n".utf8)
        let runner = SystemCommandRunner(spawn: { _, _ in process })

        let result = runner.run(["/fake/tool"], timeout: 1)
        XCTAssertNil(result.output)
        XCTAssertTrue(result.diagnosticOutput?.contains("HTTPS setup required") == true)
        XCTAssertTrue(result.diagnosticOutput?.contains("permission denied") == true)
        XCTAssertNil(runner.run(["/fake/tool"]))
        XCTAssertEqual(runner.runAllowingFailure(["/fake/tool"], timeout: 1).output, "HTTPS setup required\n")
    }

    func testSuccessfulProbeDoesNotMixStandardErrorIntoStructuredOutput() {
        let process = FakeProbeProcess(waitAnswers: [true])
        process.standardOutput = Data("{\"ok\":true}".utf8)
        process.standardError = Data("warning\n".utf8)
        let runner = SystemCommandRunner(spawn: { _, _ in process })

        let result = runner.run(["/fake/tool"], timeout: 1)
        XCTAssertEqual(result.output, "{\"ok\":true}")
        XCTAssertEqual(result.diagnosticOutput, "warning\n")
    }

    func testTimedOutProbeKeepsTheConsentPromptPrintedBeforeItWaited() {
        let process = FakeProbeProcess(waitAnswers: [false, true])
        process.standardOutput = Data("Enable HTTPS at https://login.example.test/consent\n".utf8)
        let runner = SystemCommandRunner(spawn: { _, _ in process })

        let result = runner.run(["/fake/tool"], timeout: 0.01)
        XCTAssertTrue(result.timedOut)
        XCTAssertNil(result.output)
        XCTAssertTrue(result.diagnosticOutput?.contains("https://login.example.test/consent") == true)
    }

    func testRealProbeDrainsBothPipesBeyondTheirBufferCapacity() {
        let script = "i=0; while [ $i -lt 4000 ]; do printf 'output-0123456789abcdef\\n'; printf 'error-0123456789abcdef\\n' >&2; i=$((i + 1)); done; exit 7"
        let runner = SystemCommandRunner()
        let result = runner.run(["/bin/sh", "-c", script], timeout: 10)

        XCTAssertFalse(result.timedOut)
        XCTAssertNil(result.output)
        XCTAssertTrue(result.diagnosticOutput?.contains("output-0123456789abcdef") == true)
        XCTAssertTrue(result.diagnosticOutput?.contains("error-0123456789abcdef") == true)
        XCTAssertGreaterThan(result.diagnosticOutput?.utf8.count ?? 0, 128 * 1024)
    }

    /// 探针超时：先 SIGTERM，宽限后仍未退出才 SIGKILL；结果标记 `timedOut`
    /// （不是普通不可用），调用方因此能写出“依赖探测超时”。
    func testTimedOutProbeTerminatesItsOwnChildAndReportsTimeout() {
        let process = FakeProbeProcess(waitAnswers: [false, false])
        let runner = SystemCommandRunner(timeout: 0.01, terminationGrace: 0.25, spawn: { _, _ in process })

        let result = runner.run(["/bin/echo"], timeout: 0.01)
        XCTAssertEqual(result, CommandRunResult(output: nil, timedOut: true))
        XCTAssertNil(result.output)
        XCTAssertFalse(result.cancelled)
        XCTAssertEqual(process.terminateCount, 1, "超时后只对本次子进程发一次 SIGTERM")
        XCTAssertEqual(process.forceTerminateCount, 1, "宽限后仍未退出才补一次 SIGKILL")
        XCTAssertEqual(process.waitTimeouts, [0.01, 0.25], "等待分别使用注入的超时与宽限")
    }

    /// SIGTERM 生效时不再补 SIGKILL。
    func testTimedOutProbeThatExitsDuringGraceIsNotForceKilled() {
        let process = FakeProbeProcess(waitAnswers: [false, true])
        let runner = SystemCommandRunner(timeout: 0.01, terminationGrace: 0.25, spawn: { _, _ in process })

        XCTAssertEqual(runner.run(["/bin/echo"], timeout: 0.01).timedOut, true)
        XCTAssertEqual(process.terminateCount, 1)
        XCTAssertEqual(process.forceTerminateCount, 0)
    }

    /// 取消路径：`cancelRunningProbe()` 只终止正在进行的这一次子进程，结果标记
    /// `cancelled`；再次探测不继承上一次的取消。
    func testCancellingAProbeOnlyTerminatesThatChildAndDoesNotStick() {
        let blocking = BlockingProbeProcess()
        let later = FakeProbeProcess(waitAnswers: [true])
        later.standardOutput = Data("ok".utf8)
        var spawned: [ProbeProcess] = [blocking, later]
        let runner = SystemCommandRunner(timeout: 5, terminationGrace: 0.01, spawn: { _, _ in spawned.removeFirst() })

        var firstResult: CommandRunResult?
        let finished = expectation(description: "probe finished")
        DispatchQueue.global().async {
            firstResult = runner.run(["/bin/echo"], timeout: 5)
            finished.fulfill()
        }
        XCTAssertEqual(blocking.started.wait(timeout: .now() + 5), .success, "探针应先进入等待")
        runner.cancelRunningProbe()
        wait(for: [finished], timeout: 5)

        XCTAssertEqual(firstResult, CommandRunResult(output: nil, cancelled: true))
        XCTAssertEqual(blocking.terminateCount, 1, "取消只对本次启动的子进程发一次 SIGTERM")
        XCTAssertEqual(blocking.forceTerminateCount, 0, "取消只表示不再等，不补 SIGKILL")

        // 取消不粘住：下一次探测正常返回。
        XCTAssertEqual(runner.run(["/bin/echo"], timeout: 5), CommandRunResult(output: "ok"))
        XCTAssertEqual(later.terminateCount, 0)
    }

    func testCancellingConcurrentProbesTerminatesEachChild() {
        let first = BlockingProbeProcess()
        let second = BlockingProbeProcess()
        let runner = SystemCommandRunner(spawn: { arguments, _ in
            arguments == ["first"] ? first : second
        })
        let firstFinished = expectation(description: "first probe cancelled")
        let secondFinished = expectation(description: "second probe cancelled")
        DispatchQueue.global().async {
            XCTAssertTrue(runner.run(["first"], timeout: 5).cancelled)
            firstFinished.fulfill()
        }
        XCTAssertEqual(first.started.wait(timeout: .now() + 5), .success)
        DispatchQueue.global().async {
            XCTAssertTrue(runner.run(["second"], timeout: 5).cancelled)
            secondFinished.fulfill()
        }
        XCTAssertEqual(second.started.wait(timeout: .now() + 5), .success)

        runner.cancelRunningProbe()
        wait(for: [firstFinished, secondFinished], timeout: 6)
        XCTAssertEqual(first.terminateCount, 1)
        XCTAssertEqual(second.terminateCount, 1)
        XCTAssertEqual(first.forceTerminateCount + second.forceTerminateCount, 0)
    }

    func testCancellingAfterTheLatestProbeFinishesStillTerminatesEarlierProbe() {
        let blocking = BlockingProbeProcess()
        let runner = SystemCommandRunner(spawn: { arguments, _ in
            if arguments == ["blocking"] { return blocking }
            return FakeProbeProcess(waitAnswers: [true])
        })
        let finished = expectation(description: "earlier probe cancelled")
        DispatchQueue.global().async {
            XCTAssertTrue(runner.run(["blocking"], timeout: 5).cancelled)
            finished.fulfill()
        }
        XCTAssertEqual(blocking.started.wait(timeout: .now() + 5), .success)
        XCTAssertFalse(runner.run(["quick"], timeout: 1).cancelled)
        runner.cancelRunningProbe()
        wait(for: [finished], timeout: 6)
        XCTAssertEqual(blocking.terminateCount, 1)
    }

    /// 没有正在进行的探针时取消是安全的（不崩溃、不发信号）；启动失败既不是超时
    /// 也不是取消。
    func testCancelWithoutActiveProbeIsSafeAndLaunchFailureIsPlainUnavailable() {
        let runner = SystemCommandRunner(timeout: 1, spawn: { _, _ in throw ProbeProcessError.missingExecutable })
        runner.cancelRunningProbe()

        XCTAssertEqual(runner.run([], timeout: 1), CommandRunResult(output: nil))
        XCTAssertEqual(runner.run([]), nil)
    }

    /// 主线程不阻塞：`CommandProbeDispatch` 把工作放到注入的后台队列，结果只经
    /// 注入的交付点送回。断言工作不在调用（主）线程执行，且交付发生在工作完成
    /// 之后——不需要真实命令、窗口或真实主队列。
    func testCommandProbeDispatchRunsWorkOffTheCallingThreadAndDeliversAfterIt() {
        let probeQueue = DispatchQueue(label: "process-inspector-probe-dispatch-tests")
        let recorder = DispatchProbeRecorder()
        let completed = expectation(description: "completion delivered")

        CommandProbeDispatch.runOffMain(
            queue: probeQueue,
            deliverOnMain: { block in
                recorder.noteDelivery()
                // 包成 `DispatchWorkItem` 才不用把非 `Sendable` 的 `block` 直接
                // 送进 `DispatchQueue.async` 的 `@Sendable` 参数（生产代码同款做法）。
                DispatchQueue.main.async(execute: DispatchWorkItem(block: block))
            },
            work: {
                recorder.noteWorkStartedOnTheCallingThread()
                recorder.noteWorkFinished()
                return 42
            },
            completion: { value in
                recorder.noteDeliveredValue(value)
                completed.fulfill()
            }
        )

        wait(for: [completed], timeout: 5)
        let report = recorder.snapshot
        XCTAssertFalse(report.workRanOnCallingThread, "探针不得在调用（主）线程执行")
        XCTAssertFalse(report.deliveredBeforeWorkFinished, "结果必须在工作完成之后交付")
        XCTAssertEqual(report.deliveredValue, 42)
    }

    /// 跨线程记录探针的线程与交付顺序。
    ///
    /// 语言模式 6 禁止把裸 `var` 跨隔离共享（那是真实数据竞争），所以用锁保护的
    /// 盒子：每次写入都持锁，读取拿一份快照，才能合法地断言。
    private final class DispatchProbeRecorder: @unchecked Sendable {
        struct Report {
            var workRanOnCallingThread = true
            var workFinished = false
            var deliveredBeforeWorkFinished = true
            var deliveredValue: Int?
        }

        private let lock = NSLock()
        private var report = Report()

        func noteWorkStartedOnTheCallingThread() {
            lock.lock()
            defer { lock.unlock() }
            report.workRanOnCallingThread = Thread.isMainThread
        }

        func noteWorkFinished() {
            lock.lock()
            defer { lock.unlock() }
            report.workFinished = true
        }

        func noteDelivery() {
            lock.lock()
            defer { lock.unlock() }
            report.deliveredBeforeWorkFinished = !report.workFinished
        }

        func noteDeliveredValue(_ value: Int) {
            lock.lock()
            defer { lock.unlock() }
            report.deliveredValue = value
        }

        var snapshot: Report {
            lock.lock()
            defer { lock.unlock() }
            return report
        }
    }

    // MARK: - Helpers

    private func makeInspector(
        runner: CommandRunning,
        alive: @escaping (pid_t) -> Bool = { _ in true }
    ) -> ProcessInspector {
        // `proc_pidpath` is never called from tests: the fallback source keeps
        // the fake `ps` output authoritative and the real process table untouched.
        ProcessInspector(runner: runner, processIsAlive: alive, processExecutablePath: { _ in nil })
    }
}
