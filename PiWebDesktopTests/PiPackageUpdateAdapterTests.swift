import Foundation
import XCTest

// GitHub #22 的 unhosted 测试（扩展包更新的策略、计划、进程保护与失败记录）。
//
// 默认全部用同步替身：假进程表（直接构造 `PiProcessInspection`）、记录型命令
// 执行器、假版本重检测。因此测试不枚举真实进程、不执行真实 `pi`、不访问网络、
// 不发送任何信号。唯一使用真实子进程的是执行器自身的用例，它执行的也是临时
// 目录里的假脚本（用来证明超时“只放弃等待”，不会向子进程发送信号）。
//
// 唯一写 UserDefaults 的用例使用 suiteName 隔离的 domain，测试结束即删除。

final class PiPackageUpdateAdapterTests: XCTestCase {

    private let fixtureHome = "/tmp/pi-package-update-tests-home"
    private let piPath = "/opt/homebrew/bin/pi"
    private let packageName = "pi-extension-demo"
    private let referenceDate = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - 替身

    private final class LogSink {
        private(set) var messages: [String] = []
        func append(_ message: String) { messages.append(message) }
        var text: String { messages.joined(separator: "\n") }
    }

    private final class RecordingRunner: PiPackageUpdateRunning {
        private(set) var plans: [PiPackageUpdatePlan] = []
        private(set) var timeouts: [TimeInterval] = []
        private(set) var abandonCount = 0
        /// 非阻塞读状态（GitHub #107）：默认空闲，用例按需要打开。
        var isRunning = false
        var abandonedChildrenUnconfirmed = false
        var result: (PiPackageUpdatePlan) -> PiPackageUpdateCommandResult = { _ in
            PiPackageUpdateCommandResult(
                exitCode: 0,
                startedAt: Date(timeIntervalSince1970: 1_700_000_000),
                finishedAt: Date(timeIntervalSince1970: 1_700_000_002)
            )
        }

        func run(
            _ plan: PiPackageUpdatePlan,
            timeout: TimeInterval,
            completion: @escaping (PiPackageUpdateCommandResult) -> Void
        ) {
            plans.append(plan)
            timeouts.append(timeout)
            completion(result(plan))
        }

        func abandon() { abandonCount += 1 }
    }

    /// 同步世界：协调器的全部副作用都是替身，`deliver` 立即执行。
    private final class World {
        let runner = RecordingRunner()
        let log = LogSink()
        var inspections: [PiProcessInspection] = [.noProcesses]
        private(set) var inspectCount = 0
        var detectedVersions: [String: String] = [:]
        private(set) var detectCount = 0
        /// 事务替身（GitHub #107）：只记录 `applyDegradation` 的调用，不碰文件系统。
        var degradations: [UpdateDegradationPlan] = []
        let fixtureHome: String

        init(fixtureHome: String) { self.fixtureHome = fixtureHome }

        func makeCoordinator(timeout: TimeInterval = PiPackageUpdateCoordinator.defaultTimeout) -> PiPackageUpdateCoordinator {
            PiPackageUpdateCoordinator(environment: PiPackageUpdateCoordinator.Environment(
                inspectProcesses: {
                    self.inspectCount += 1
                    let index = min(self.inspectCount - 1, self.inspections.count - 1)
                    return self.inspections[max(0, index)]
                },
                runner: runner,
                detectPackageVersion: { name in
                    self.detectCount += 1
                    return self.detectedVersions[name]
                },
                redactor: LogRedactor(homeDirectory: self.fixtureHome),
                log: { message in self.log.append(message) },
                deliver: { work in work() },
                timeout: timeout,
                transaction: UpdateTransactionEnvironment(
                    probe: .disabled,
                    recordHistory: { _ in },
                    applyDegradation: { plan in self.degradations.append(plan) },
                    now: Date.init
                )
            ))
        }
    }

    // MARK: - 夹具

    private func candidate(
        name: String? = nil,
        installed: String? = "1.0.0",
        source: InstallSource = .npmGlobal,
        confidence: DetectionConfidence = .verified
    ) -> PiPackageCandidate {
        PiPackageCandidate(
            packageName: name ?? packageName,
            installedVersion: installed,
            source: source,
            confidence: confidence
        )
    }

    /// `origin` 的默认值是 `.network`：既有用例描述的是“本次运行刚从白名单主机
    /// 取得结果”的场景。缓存回退场景由专门用例显式传入（GitHub #59）。
    private func check(
        name: String? = nil,
        latest: String? = "2.0.0",
        status: UpdateCheckStatus = .updateAvailable,
        confidence: DetectionConfidence = .verified,
        origin: UpdateCheckOrigin = .network,
        cacheWrittenAt: Date? = nil
    ) -> PiPackageCheckOutcome {
        PiPackageCheckOutcome(
            packageName: name ?? packageName,
            latestVersion: latest,
            status: status,
            confidence: confidence,
            origin: origin,
            cacheWrittenAt: cacheWrittenAt
        )
    }

    private func input(
        policy: UpdateCheckPolicy = .askBeforeUpdate,
        packages: [PiPackageCandidate]? = nil,
        checks: [PiPackageCheckOutcome]? = nil,
        processes: PiProcessInspection = .noProcesses,
        piPath: String? = "/opt/homebrew/bin/pi",
        abandonedAttempts: [UpdateAbandonedAttempt] = []
    ) -> PiPackageUpdatePlanningInput {
        PiPackageUpdatePlanningInput(
            policy: policy,
            packages: packages ?? [candidate()],
            checks: checks ?? [check()],
            processes: processes,
            piExecutablePath: piPath,
            abandonedAttempts: abandonedAttempts
        )
    }

    private func installation(
        kind: ComponentKind = .piPackage,
        name: String? = "pi-extension-demo",
        version: String? = "1.0.0",
        source: InstallSource = .npmGlobal,
        confidence: DetectionConfidence = .verified
    ) -> ComponentInstallation {
        ComponentInstallation(
            kind: kind,
            packageName: name,
            version: version,
            executablePath: nil,
            resolvedPath: nil,
            symlinkChain: [],
            packageJSONPath: nil,
            source: source,
            confidence: confidence,
            evidence: ["fixture"],
            suggestedCommand: nil
        )
    }

    private func processRecord(pid: pid_t = 4242, parentPID: pid_t = 4000) -> PiProcessRecord {
        PiProcessRecord(
            pid: pid,
            parentPID: parentPID,
            startedAtText: "夹具时间",
            executablePath: piPath,
            scriptPath: nil,
            matchSource: .imagePath,
            commandSummary: piPath
        )
    }

    /// 从拒绝原因里取出被进程保护拦下的 Pi 进程 PID（非进程保护原因返回 nil）。
    private func blockedPids(_ reason: PiPackageUpdateRefusal) -> [pid_t]? {
        guard case .piRunning(let records) = reason else { return nil }
        return records.map(\.pid)
    }

    /// 「已放弃」记录夹具（GitHub #62）：扩展包组件、超时原因、只放弃等待。
    private func abandonedAttempt(
        reason: UpdateAbandonedAttempt.Reason = .timedOut
    ) -> UpdateAbandonedAttempt {
        UpdateAbandonedAttempt(
            componentKind: .piPackage,
            packageName: packageName,
            reason: reason,
            commandSummary: "~/.local/bin/pi update \\(packageName)",
            startedAt: referenceDate,
            timeout: 600,
            source: .npmGlobal,
            recordedAt: referenceDate,
            childProcessAction: .waitedWithoutSignals
        )
    }

    private func plan(
        path: String? = nil,
        name: String? = nil,
        installed: String = "1.0.0",
        target: String? = "2.0.0",
        source: InstallSource = .npmGlobal,
        confidence: DetectionConfidence = .verified
    ) -> PiPackageUpdatePlan? {
        PiPackageUpdatePlan.make(
            executablePath: path ?? piPath,
            packageName: name ?? packageName,
            installedVersion: installed,
            targetVersion: target,
            source: source,
            confidence: confidence
        )
    }

    private func tempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pi-package-update-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - 1. 三种策略

    /// 关闭 = 0 次检查、0 次通知、0 次执行。检查闭包不被调用是这里的关键断言。
    func testOffPolicyPerformsZeroChecksZeroNotificationsAndZeroExecutions() {
        var checkCount = 0
        let set = PiPackageUpdatePlanner.plan(
            policy: .off,
            packages: [candidate()],
            // 即使本机「有」运行中的 Pi 进程，关闭策略也不会去枚举进程或检查更新。
            processes: .runningProcesses([processRecord()]),
            piExecutablePath: piPath,
            check: {
                checkCount += 1
                return [self.check()]
            }
        )
        XCTAssertEqual(checkCount, 0, "关闭策略不得发起任何检查")
        XCTAssertFalse(set.didCheck)
        XCTAssertEqual(set.packageCount, 0)
        XCTAssertTrue(set.decisions.isEmpty)
        XCTAssertTrue(set.executablePlans.isEmpty)
        XCTAssertTrue(set.notices.isEmpty, "关闭策略不得通知")
        XCTAssertFalse(set.executionAvailable)
        XCTAssertEqual(set.refusalRecords.map(\.reason), [.policyOff])
        XCTAssertEqual(PiPackageUpdatePolicy.off.underlyingPolicy, UpdateCheckPolicy.off)
        XCTAssertFalse(PiPackageUpdatePolicy.off.checksForUpdates)
        XCTAssertFalse(PiPackageUpdatePolicy.off.notifiesAboutUpdates)
        XCTAssertFalse(PiPackageUpdatePolicy.off.offersExecutionEntry)
        // 调度层同样不为关闭策略安排复查（#17/#18 的间隔表）。
        XCTAssertNil(UpdateCheckIntervals.standard.interval(for: .piPackages, policy: .off))
        // 单个包的决策此时也只是 `.disabled`。
        let single = PiPackageUpdatePlanner.decide(
            candidate(),
            check: check(),
            policy: .off,
            processes: .noProcesses,
            piExecutablePath: piPath
        )
        XCTAssertEqual(single, .disabled(packageName: packageName))
        XCTAssertNil(single.anyPlan)
    }

    /// 策略不属于扩展包允许集合（每日 / 每周）时按不支持处理：不检查、不执行。
    func testUnsupportedPolicyDoesNotCheckOrExecute() {
        for policy in [UpdateCheckPolicy.daily, .weekly] {
            var checkCount = 0
            let set = PiPackageUpdatePlanner.plan(
                policy: policy,
                packages: [candidate()],
                piExecutablePath: piPath,
                check: { checkCount += 1; return [] }
            )
            XCTAssertNil(set.policy)
            XCTAssertEqual(checkCount, 0)
            XCTAssertFalse(set.didCheck)
            XCTAssertEqual(set.refusalRecords.map(\.reason), [.policyUnsupported])
        }
    }

    /// 检查并通知：只提示版本与可复制的官方命令，没有执行入口。
    func testCheckAndNotifyOnlyNotifiesAndNeverExecutes() {
        var checkCount = 0
        let set = PiPackageUpdatePlanner.plan(
            policy: .checkAndNotify,
            packages: [candidate()],
            processes: .noProcesses,
            piExecutablePath: piPath,
            check: { checkCount += 1; return [self.check()] }
        )
        XCTAssertEqual(checkCount, 1)
        XCTAssertTrue(set.didCheck)
        XCTAssertTrue(set.executablePlans.isEmpty, "检查并通知不提供一键执行")
        XCTAssertFalse(set.executionAvailable)
        XCTAssertEqual(set.notices.count, 1)
        let notice = set.notices[0]
        XCTAssertEqual(notice.packageName, packageName)
        XCTAssertEqual(notice.installedVersion, "1.0.0")
        XCTAssertEqual(notice.targetVersion, "2.0.0")
        XCTAssertEqual(notice.source, .npmGlobal)
        XCTAssertEqual(notice.manualCommandText, "\(piPath) update npm:\(packageName)")
        XCTAssertFalse(notice.executionAvailable)
        XCTAssertNil(set.decisions[0].executablePlan)
        XCTAssertNil(set.decisions[0].anyPlan)
        XCTAssertEqual(set.decisions[0].refusalReason, .policyNotifiesOnly)
        let text = notice.displayLines(reasonText: PiPackageUpdateRefusal.policyNotifiesOnly.text).joined(separator: "\n")
        XCTAssertTrue(text.contains("不提供一键执行的原因是"))
        XCTAssertTrue(text.contains("只展示文本，应用不会执行"))
    }

    /// 询问后更新：未确认时不执行、不改状态，只记录取消原因。
    func testAskPolicyDoesNotExecuteBeforeConfirmation() throws {
        let set = PiPackageUpdatePlanner.decide(input())
        XCTAssertEqual(set.executablePlans.count, 1)
        let ready = try XCTUnwrap(set.executablePlans.first)
        XCTAssertEqual(ready.arguments, ["update", "npm:\(packageName)"])
        XCTAssertFalse(ready.isAutomaticallyExecutable, "扩展包永远不允许无人值守执行")
        XCTAssertTrue(ready.requiresUserConfirmation)
        XCTAssertEqual(set.decisions[0], .awaitingConfirmation(ready))

        let world = World(fixtureHome: fixtureHome)
        world.makeCoordinator().recordCancellation([ready])
        XCTAssertTrue(world.runner.plans.isEmpty, "未确认绝不执行")
        XCTAssertTrue(world.log.text.contains("用户取消"))
        XCTAssertEqual(
            PiPackageUpdatePlanner.cancellationRecords(for: [ready]).map(\.reason),
            [.userCancelled]
        )
    }

    /// 确认后：参数数组执行一次，记录退出码与耗时，并重新检测版本。
    func testConfirmationExecutesExactlyOnceWithExactArgumentArray() throws {
        let ready = try XCTUnwrap(plan())
        let world = World(fixtureHome: fixtureHome)
        world.detectedVersions = [packageName: "2.0.0"]
        var batch: PiPackageUpdateBatchOutcome?
        world.makeCoordinator(timeout: 42).runConfirmed([ready]) { batch = $0 }

        let outcome = try XCTUnwrap(batch)
        XCTAssertTrue(outcome.isSucceeded)
        guard case .succeeded(let plan, let newVersion, let record) = outcome.outcomes[0] else {
            return XCTFail("确认后应执行并重新检测，实际是 \(outcome.outcomes)")
        }
        XCTAssertEqual(plan.arguments, ["update", "npm:\(packageName)"])
        XCTAssertEqual(plan.executablePath, piPath)
        XCTAssertEqual(newVersion, "2.0.0")
        XCTAssertEqual(record.exitCode, 0)
        XCTAssertNil(record.failure)
        XCTAssertEqual(record.duration, 2, accuracy: 0.001)
        XCTAssertEqual(world.runner.plans.count, 1, "确认后只执行一次")
        XCTAssertEqual(world.runner.plans[0].arguments, ["update", "npm:\(packageName)"])
        XCTAssertEqual(world.runner.timeouts, [42])
        XCTAssertEqual(world.inspectCount, 1, "执行前必须复查一次进程")
        XCTAssertEqual(world.detectCount, 1, "执行后必须重新检测一次版本")
        XCTAssertEqual(world.runner.abandonCount, 0)
        XCTAssertNil(outcome.latestWarning)
    }

    /// 一批多个包：每个包执行前都复查一次进程，顺序与输入一致。
    func testBatchConfirmationExecutesEachPlanOnce() throws {
        let second = "pi-extension-other"
        let set = PiPackageUpdatePlanner.decide(input(
            packages: [candidate(), candidate(name: second, installed: "1.0.0")],
            checks: [check(), check(name: second, latest: "3.0.0")]
        ))
        let plans = set.executablePlans
        XCTAssertEqual(plans.map(\.packageName), [packageName, second])
        let world = World(fixtureHome: fixtureHome)
        world.detectedVersions = [packageName: "2.0.0", second: "3.0.0"]
        world.inspections = [.noProcesses, .noProcesses]
        var batch: PiPackageUpdateBatchOutcome?
        world.makeCoordinator().runConfirmed(plans) { batch = $0 }
        let outcome = try XCTUnwrap(batch)
        XCTAssertTrue(outcome.isSucceeded)
        XCTAssertEqual(world.runner.plans.map(\.packageName), [packageName, second])
        XCTAssertEqual(world.inspectCount, 2)
        XCTAssertEqual(world.runner.plans.map(\.arguments), [
            ["update", "npm:\(packageName)"],
            ["update", "npm:\(second)"]
        ])
    }

    // MARK: - 2. 进程保护

    func testRunningPiProcessesBlockTheExecuteEntry() {
        let records = [processRecord(pid: 4242), processRecord(pid: 4243, parentPID: 4242)]
        let set = PiPackageUpdatePlanner.decide(input(processes: .runningProcesses(records)))
        XCTAssertTrue(set.executablePlans.isEmpty, "有运行中的 Pi 进程时不得给出执行入口")
        XCTAssertFalse(set.executionAvailable)
        XCTAssertEqual(set.allPlans.count, 1, "计划本身仍然可见（用于展示与诊断）")
        guard case .executeBlocked(let plan, let reason) = set.decisions[0] else {
            return XCTFail("应拒绝执行，实际是 \(set.decisions)")
        }
        XCTAssertEqual(blockedPids(reason), [4242, 4243])
        XCTAssertTrue(reason.text.contains("拒绝执行"))
        XCTAssertTrue(reason.text.contains("不会向它们发送任何信号"))
        XCTAssertEqual(plan.arguments, ["update", "npm:\(packageName)"])
        XCTAssertEqual(set.refusalRecords.map(\.reason), [reason])
    }

    func testUnknownProcessStateBlocksTheExecuteEntry() {
        let unknownCases: [PiProcessInspectionUnknown] = [
            .enumerationFailed,
            .argumentsUnavailable(pid: 4242, interpreter: "node"),
            .identityUnavailable(pid: 4243, failure: .permissionDenied),
            .scriptPathUnconfirmed(pid: 4244, path: "/tmp/notes/pi")
        ]
        for unknown in unknownCases {
            let set = PiPackageUpdatePlanner.decide(input(processes: .unknown(unknown)))
            XCTAssertTrue(set.executablePlans.isEmpty, "状态不确定必须拒绝执行")
            guard case .executeBlocked(_, let reason) = set.decisions[0] else {
                return XCTFail("应拒绝执行，实际是 \(set.decisions)")
            }
            XCTAssertEqual(reason, .processStateUnknown(unknown))
            XCTAssertTrue(reason.text.contains("按不安全处理"))
        }
    }

    /// 规划时没有进程，但确认后执行前出现了 Pi 进程：拒绝执行，且不调用执行器。
    func testPreExecutionRecheckBlocksExecutionWhenProcessAppears() throws {
        let ready = try XCTUnwrap(plan())
        let world = World(fixtureHome: fixtureHome)
        world.inspections = [.runningProcesses([processRecord()])]
        var batch: PiPackageUpdateBatchOutcome?
        world.makeCoordinator().runConfirmed([ready]) { batch = $0 }
        let outcome = try XCTUnwrap(batch)
        guard case .refused(let refusedPlan, let reason) = outcome.outcomes[0] else {
            return XCTFail("执行前复查发现进程时必须拒绝，实际是 \(outcome.outcomes)")
        }
        XCTAssertEqual(refusedPlan.packageName, packageName)
        XCTAssertEqual(blockedPids(reason), [4242])
        XCTAssertTrue(world.runner.plans.isEmpty, "拒绝执行时绝不调用执行器")
        XCTAssertEqual(world.detectCount, 0)
        XCTAssertTrue(world.log.text.contains("执行前复查"))
        XCTAssertFalse(outcome.isSucceeded)
        XCTAssertNil(outcome.latestWarning, "拒绝不是执行失败，不写失败告警")
    }

    func testPreExecutionRecheckBlocksExecutionWhenStateBecomesUnknown() throws {
        let ready = try XCTUnwrap(plan())
        let world = World(fixtureHome: fixtureHome)
        world.inspections = [.unknown(.enumerationFailed)]
        var batch: PiPackageUpdateBatchOutcome?
        world.makeCoordinator().runConfirmed([ready]) { batch = $0 }
        let outcome = try XCTUnwrap(batch)
        guard case .refused(_, let reason) = outcome.outcomes[0] else {
            return XCTFail("状态不确定时必须拒绝，实际是 \(outcome.outcomes)")
        }
        XCTAssertEqual(reason, .processStateUnknown(.enumerationFailed))
        XCTAssertTrue(world.runner.plans.isEmpty)
    }

    /// 批量执行到一半时出现 Pi 进程：已完成的包保留结果，其余包全部拒绝。
    func testBatchStopsAndRefusesRemainingPlansWhenProcessAppears() throws {
        let second = "pi-extension-other"
        let set = PiPackageUpdatePlanner.decide(input(
            packages: [candidate(), candidate(name: second)],
            checks: [check(), check(name: second, latest: "3.0.0")]
        ))
        let plans = set.executablePlans
        XCTAssertEqual(plans.count, 2)
        let world = World(fixtureHome: fixtureHome)
        world.detectedVersions = [packageName: "2.0.0"]
        world.inspections = [.noProcesses, .runningProcesses([processRecord()])]
        var batch: PiPackageUpdateBatchOutcome?
        world.makeCoordinator().runConfirmed(plans) { batch = $0 }
        let outcome = try XCTUnwrap(batch)
        XCTAssertEqual(outcome.outcomes.count, 2)
        XCTAssertTrue(outcome.outcomes[0].isSucceeded)
        guard case .refused(let refusedPlan, _) = outcome.outcomes[1] else {
            return XCTFail("第二个包必须被拒绝，实际是 \(outcome.outcomes[1])")
        }
        XCTAssertEqual(refusedPlan.packageName, second)
        XCTAssertEqual(world.runner.plans.map(\.packageName), [packageName])
        XCTAssertEqual(world.inspectCount, 2)
    }

    /// 执行前复查通过后，`abandon()` 只放弃等待（应用退出路径），不发送信号。
    func testAbandonOnlyGivesUpWaiting() throws {
        let ready = try XCTUnwrap(plan())
        let world = World(fixtureHome: fixtureHome)
        world.runner.result = { _ in
            PiPackageUpdateCommandResult(
                exitCode: nil,
                abandoned: true,
                startedAt: self.referenceDate,
                finishedAt: self.referenceDate.addingTimeInterval(1)
            )
        }
        var batch: PiPackageUpdateBatchOutcome?
        world.makeCoordinator().runConfirmed([ready]) { batch = $0 }
        let outcome = try XCTUnwrap(batch)
        guard case .commandFailed(_, let failure, let record, _) = outcome.outcomes[0] else {
            return XCTFail("放弃等待必须记为失败，实际是 \(outcome.outcomes)")
        }
        XCTAssertEqual(failure, .abandoned)
        XCTAssertTrue(failure.text.contains("没有向任何进程发送信号"))
        XCTAssertNil(record.exitCode)
        XCTAssertEqual(outcome.latestWarning?.kind, .commandFailed)
    }

    // MARK: - 3. 来源约束

    /// pnpm / Homebrew / nvm / mise / git / 本地路径 / 未知来源：只有命令文本，没有执行入口。
    func testNonTrustedSourcesOnlyOfferCommandText() {
        let sources: [InstallSource] = [.pnpmGlobal, .homebrew, .nvm, .mise, .gitCheckout, .localPath, .unknown]
        for source in sources {
            for confidence in [DetectionConfidence.verified, .inferred, .unknown] {
                let set = PiPackageUpdatePlanner.decide(input(
                    packages: [candidate(source: source, confidence: confidence)]
                ))
                XCTAssertTrue(set.executablePlans.isEmpty, "来源 \(source) 不得有执行入口")
                XCTAssertFalse(set.executionAvailable)
                XCTAssertNil(set.decisions[0].anyPlan, "来源 \(source) 连计划都不应有")
                guard case .manualOnly(let notice, let reason) = set.decisions[0] else {
                    return XCTFail("来源 \(source) 应只给命令文本，实际是 \(set.decisions[0])")
                }
                XCTAssertEqual(reason, .sourceNotExecutable(source: source, confidence: confidence))
                XCTAssertEqual(notice.manualCommandText, "\(piPath) update --extensions")
                XCTAssertFalse(notice.executionAvailable)
                XCTAssertTrue(reason.text.contains("只展示官方命令文本"))
            }
        }
        // 命令文本本身就是官方 `pi update --extensions`，不是包管理器命令。
        let text = PiPackageUpdatePlanner.nonNPMGlobalManualCommandText(piExecutablePath: piPath)
        XCTAssertEqual(text, "\(piPath) update --extensions")
        XCTAssertFalse(text?.contains("npm install") == true)
        XCTAssertFalse(text?.contains("npm update") == true)
        XCTAssertFalse(text?.contains("pnpm") == true)
        // 可执行文件路径本身可能落在 Homebrew 前缀下（/opt/homebrew/bin/pi），这里只拒绝 Homebrew 命令。
        XCTAssertFalse(text?.contains("brew install") == true)
        XCTAssertFalse(text?.contains("brew upgrade") == true)
        XCTAssertFalse(text?.contains("sudo") == true)
    }

    /// 目标版本未经上游验证、不是语义化版本、或不高于本机版本时只提示。
    func testTargetVersionConstraintsOnlyNotify() {
        let cases: [(PiPackageCheckOutcome, PiPackageUpdateRefusal)] = [
            (check(latest: "2.0.0", confidence: .inferred), .targetNotVerified),
            (check(latest: "latest"), .invalidTargetVersion),
            (check(latest: "1.0.0"), .notNewerTargetVersion),
            (check(latest: "0.9.0"), .notNewerTargetVersion),
            (check(latest: nil, status: .updateAvailable), .noTargetVersion),
            (check(latest: nil, status: .unknown), .noTargetVersion)
        ]
        for (outcome, expected) in cases {
            let set = PiPackageUpdatePlanner.decide(input(checks: [outcome]))
            XCTAssertTrue(set.executablePlans.isEmpty)
            guard case .manualOnly(_, let reason) = set.decisions[0] else {
                return XCTFail("应只提示，实际是 \(set.decisions[0])")
            }
            XCTAssertEqual(reason, expected)
        }
        // 已是最新时不提示也不执行。
        let upToDate = PiPackageUpdatePlanner.decide(input(checks: [check(latest: "1.0.0", status: .upToDate)]))
        XCTAssertEqual(upToDate.decisions[0], .upToDate(
            packageName: packageName,
            installedVersion: "1.0.0",
            latestVersion: "1.0.0"
        ))
        XCTAssertTrue(upToDate.notices.isEmpty)
        // 本机版本未知时不提供执行入口。
        let unknownInstalled = PiPackageUpdatePlanner.decide(input(packages: [candidate(installed: nil)]))
        guard case .manualOnly(_, let reason) = unknownInstalled.decisions[0] else {
            return XCTFail("本机版本未知时应只提示，实际是 \(unknownInstalled.decisions[0])")
        }
        XCTAssertEqual(reason, .installedVersionUnknown)
    }

    /// 包名不在检测列表内：拒绝执行并记录原因。
    func testPackageNotInDetectionListIsRefused() {
        let candidates = [candidate()]
        XCTAssertEqual(
            PiPackageUpdatePlanner.executionRefusal(packageName: "pi-extension-unknown", candidates: candidates),
            .packageNotDetected(name: "pi-extension-unknown")
        )
        XCTAssertEqual(
            PiPackageUpdatePlanner.executionRefusal(packageName: "bad name", candidates: candidates),
            .invalidPackageName
        )
        XCTAssertNil(PiPackageUpdatePlanner.executionRefusal(packageName: packageName, candidates: candidates))
        // 检查结果里出现检测列表之外的包名同样记录拒绝。
        let set = PiPackageUpdatePlanner.decide(input(
            packages: [candidate()],
            checks: [check(), check(name: "pi-extension-orphan", latest: "2.0.0")]
        ))
        XCTAssertTrue(set.extraRefusals.contains {
            $0.packageName == "pi-extension-orphan" && $0.reason == .packageNotDetected(name: "pi-extension-orphan")
        })
    }

    /// 没有 `pi` 可执行文件（或路径不安全）时不给执行入口。
    func testMissingOrUnsafePiExecutableOnlyNotifies() {
        for path in [nil, "pi", "/usr/local/bin/pi;rm -rf /", "/usr/local/bin/pi && echo x"] as [String?] {
            let set = PiPackageUpdatePlanner.decide(input(piPath: path))
            XCTAssertTrue(set.executablePlans.isEmpty, "路径 \(path ?? "nil") 不得有执行入口")
            guard case .manualOnly(let notice, let reason) = set.decisions[0] else {
                return XCTFail("应只给文本，实际是 \(set.decisions[0])")
            }
            XCTAssertNil(notice.manualCommandText)
            XCTAssertTrue(reason == .piExecutableUnresolved || reason == .unsafeCommand)
        }
    }

    // MARK: - 3b. 来源硬前置：缓存回退不提供执行入口（GitHub #59）

    /// 目标版本只来自缓存（没有本次网络结果）时：即使其余条件全部满足，也不
    /// 提供可点的执行入口，只保留可复制的官方命令文本；扩展包仍然是“永不自动”。
    func testCacheFallbackOriginOnlyOffersManualCommand() {
        let cachedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let set = PiPackageUpdatePlanner.decide(input(
            checks: [check(origin: .cachedFallback, cacheWrittenAt: cachedAt)]
        ))

        XCTAssertTrue(set.executablePlans.isEmpty, "缓存回退不得给出执行入口")
        XCTAssertFalse(set.executionAvailable)
        XCTAssertTrue(set.allPlans.isEmpty)
        XCTAssertEqual(set.notices.count, 1)
        let notice = set.notices[0]
        XCTAssertEqual(notice.targetVersion, "2.0.0")
        XCTAssertEqual(notice.manualCommandText, "\(piPath) update npm:\(packageName)")
        XCTAssertFalse(notice.executionAvailable)
        let reason = PiPackageUpdateRefusal.targetNotFromNetwork(origin: .cachedFallback, cacheWrittenAt: cachedAt)
        XCTAssertEqual(set.decisions[0].refusalReason, reason)
        XCTAssertTrue(set.refusalRecords.contains { $0.reason == reason })
        XCTAssertTrue(reason.text.contains("本机缓存"))
        XCTAssertTrue(reason.text.contains(UpdateCheckTimestamp.text(cachedAt)))
        XCTAssertFalse(reason.text.contains("已验证"))
        XCTAssertFalse(reason.text.contains("官方"))
        // 拒绝原因写入日志/诊断：包含包名与固定原因文案。
        let logLines = set.logLines(redactingWith: LogRedactor(homeDirectory: fixtureHome))
        XCTAssertTrue(logLines.contains { $0.contains("本机缓存") })
    }

    /// “检查并通知”不提供执行入口，因此缓存回退仍然只提示，决策类型不变。
    func testCheckAndNotifyKeepsNotifyOnlyForCacheOrigin() {
        let set = PiPackageUpdatePlanner.decide(input(
            policy: .checkAndNotify,
            checks: [check(origin: .cachedFallback)]
        ))

        guard case .notifyOnly(let notice) = set.decisions[0] else {
            return XCTFail("检查并通知应仍为只通知，实际是 \(set.decisions[0])")
        }
        XCTAssertEqual(notice.targetVersion, "2.0.0")
        XCTAssertTrue(set.executablePlans.isEmpty)
        XCTAssertEqual(set.decisions[0].refusalReason, .policyNotifiesOnly)
    }

    /// `UpdateCheckResult` → `PiPackageCheckOutcome` 时来源与缓存写入时间一并带入，
    /// 否则执行入口会在映射处丢掉硬前置所需的证据。
    func testCheckOutcomeMappingCarriesOrigin() throws {
        let cachedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let result = UpdateCheckResult(
            target: UpdateCheckTarget(category: .piPackages, packageName: packageName),
            status: .updateAvailable,
            installedVersion: "1.0.0",
            latestVersion: "2.0.0",
            confidence: .verified,
            freshness: .cached,
            failure: .offline,
            httpStatusCode: nil,
            checkedAt: cachedAt,
            lastSuccessAt: cachedAt,
            origin: .cachedFallback,
            cacheWrittenAt: cachedAt
        )
        let outcome = try XCTUnwrap(PiPackageCheckOutcome(result: result))
        XCTAssertEqual(outcome.origin, .cachedFallback)
        XCTAssertEqual(outcome.cacheWrittenAt, cachedAt)
        XCTAssertEqual(PiPackageCheckOutcome.list(from: [result]).count, 1)
    }

    /// 缓存缺失与默认值同样不提供执行入口。
    func testUnavailableOriginAndDefaultNeverOfferExecution() {
        let set = PiPackageUpdatePlanner.decide(input(checks: [check(origin: .unavailable)]))
        XCTAssertTrue(set.executablePlans.isEmpty)
        XCTAssertEqual(
            set.decisions[0].refusalReason,
            .targetNotFromNetwork(origin: .unavailable, cacheWrittenAt: nil)
        )

        let bare = PiPackageCheckOutcome(
            packageName: packageName,
            latestVersion: "2.0.0",
            status: .updateAvailable,
            confidence: .verified
        )
        XCTAssertEqual(bare.origin, .unavailable)
        XCTAssertFalse(bare.origin.isEligibleForAutomaticInstall)
        let bareSet = PiPackageUpdatePlanner.decide(input(checks: [bare]))
        XCTAssertTrue(bareSet.executablePlans.isEmpty)
    }

    // MARK: - 4. 计划与参数数组

    func testPlanIsNeverAutomaticallyExecutableAndUsesOnlyTheOfficialCommand() throws {
        XCTAssertEqual(PiPackageUpdatePolicy.allCases.count, 3, "扩展包只允许三种策略")
        XCTAssertEqual(PiPackageUpdatePolicy.allCases.map(\.title), ["关闭", "检查并通知", "询问后更新"])
        XCTAssertEqual(
            PiPackageUpdatePolicy.allCases.map(\.underlyingPolicy),
            [UpdateCheckPolicy.off, .checkAndNotify, .askBeforeUpdate]
        )
        XCTAssertTrue(PiPackageUpdatePolicy.askBeforeUpdate.offersExecutionEntry)
        XCTAssertFalse(PiPackageUpdatePolicy.checkAndNotify.offersExecutionEntry)
        let ready = try XCTUnwrap(plan())
        XCTAssertFalse(ready.isAutomaticallyExecutable)
        XCTAssertTrue(ready.requiresUserConfirmation)
        XCTAssertEqual(ready.arguments, ["update", "npm:\(packageName)"])
        XCTAssertEqual(ready.arguments.count, 2)
        XCTAssertEqual(ready.source, .npmGlobal)
        XCTAssertEqual(ready.confidence, .verified)
        XCTAssertEqual(ready.targetVersion, "2.0.0")
        XCTAssertEqual(PiPackageUpdatePlan.allowsUnattendedExecution, false)
        XCTAssertEqual(PiPackageUpdatePlan.commandName, "update")
        XCTAssertEqual(PiPackageUpdatePlan.packageSourceSpecPrefix, "npm:")
        // 计划里的可执行文件是 pi 自身，argv 不含任何 npm/pnpm 参数。
        let text = try XCTUnwrap(plan()).commandText
        XCTAssertTrue(text.hasPrefix("\(piPath) update npm:"))
        XCTAssertFalse(text.contains("install"))
        XCTAssertFalse(text.contains("-g"))
        XCTAssertFalse(text.contains("sudo"))
    }

    func testArgumentArrayHasNoShellMetacharactersAndNoSudo() throws {
        let plans = [
            try XCTUnwrap(plan()),
            try XCTUnwrap(plan(name: "@scope/pi-extension", target: "2.0.0"))
        ]
        let forbiddenCharacters = [" ", "\t", "\n", "\"", "'", "`", "$", ";", "|", "&", "(", ")", ">", "<", "*", "?", "!", "\\", "{", "}", "[", "]", "#", "%", "^"]
        for ready in plans {
            XCTAssertTrue(PiPackageUpdateArgumentPolicy.isSafe(ready.arguments))
            for argument in ready.arguments {
                XCTAssertFalse(PiPackageUpdateArgumentPolicy.forbiddenTokens.contains(argument))
                for character in forbiddenCharacters {
                    XCTAssertFalse(argument.contains(character), "参数 \(argument) 不应包含 \(character)")
                }
            }
            XCTAssertEqual(ready.arguments[0], "update")
            XCTAssertTrue(ready.arguments[1].hasPrefix("npm:"))
            XCTAssertFalse(ready.arguments.joined(separator: " ").contains("sudo"))
            XCTAssertEqual((ready.executablePath as NSString).lastPathComponent, "pi")
        }
    }

    func testUnsafePathsNamesSourcesAndVersionsAreRejected() {
        let unsafePaths = [
            "pi",
            "/usr/local/bin/pi ",
            " /usr/local/bin/pi",
            "/usr/local/bin/pi;rm -rf /",
            "/usr/local/bin/pi|cat",
            "/usr/local/bin/pi`id`",
            "/usr/local/bin/pi$(id)",
            "/usr/local/bin/pi\nupdate",
            "/usr/local/bin//bin/pi",
            "/usr/local/bin/",
            "/usr/local/bin/pi&",
            "/bin/sudo"
        ]
        for path in unsafePaths {
            XCTAssertNil(plan(path: path), "\(path) 不应通过命令安全校验")
        }
        let unsafeNames = [
            "",
            "pi-extension demo",
            "pi-extension;rm",
            "pi-extension$(id)",
            "pi-extension/../../escape",
            "..",
            ".",
            "pi-extension\u{2018}"
        ]
        for name in unsafeNames {
            XCTAssertNil(plan(name: name), "\(name) 不应通过包名校验")
            XCTAssertNil(PiPackageUpdatePlanner.manualCommandText(piExecutablePath: piPath, packageName: name))
        }
        // 来源与可信度必须在计划构造层就把住：非 npm 全局或未验证的来源没有计划。
        XCTAssertNil(plan(source: .pnpmGlobal))
        XCTAssertNil(plan(source: .homebrew))
        XCTAssertNil(plan(source: .unknown))
        XCTAssertNil(plan(confidence: .inferred))
        XCTAssertNil(plan(confidence: .unknown))
        // 版本必须是可比较的语义化版本。
        XCTAssertNil(plan(installed: "latest"))
        XCTAssertNil(plan(target: "2.0"))
        XCTAssertNotNil(plan(target: nil), "没有目标版本时仍可执行（由官方命令决定版本）")
        // 可执行文件只能是名为 pi 的官方可执行文件，不能是 sudo/env/其它二进制。
        XCTAssertNil(plan(path: "/bin/sudo"), "可执行文件必须是 pi")
        XCTAssertNil(plan(path: "/usr/bin/env"), "可执行文件必须是 pi")
        XCTAssertNil(PiPackageUpdatePlanner.manualCommandText(piExecutablePath: "/bin/sudo", packageName: packageName))
        XCTAssertNil(PiPackageUpdatePlanner.nonNPMGlobalManualCommandText(piExecutablePath: "/usr/bin/true"))
    }

    func testPlanDisplayLinesShowEverythingTheDialogMustShow() throws {
        let ready = try XCTUnwrap(plan(path: "\(fixtureHome)/bin/pi"))
        let redactor = LogRedactor(homeDirectory: fixtureHome)
        let text = ready.displayLines(redactingWith: redactor).joined(separator: "\n")
        XCTAssertTrue(text.contains("包名：\(packageName)"))
        XCTAssertTrue(text.contains("当前版本：1.0.0"))
        XCTAssertTrue(text.contains("目标版本：2.0.0"))
        XCTAssertTrue(text.contains("来源：npm 全局；可信度：已验证"))
        XCTAssertTrue(text.contains("参数数组：\"update\", \"npm:\(packageName)\""))
        XCTAssertTrue(text.contains("自动执行：不允许"))
        XCTAssertFalse(text.contains(fixtureHome), "对话框文本不得包含未脱敏的 Home 前缀")
        XCTAssertTrue(text.contains("~/bin/pi"))
    }

    // MARK: - 5. 失败四态

    private func failureResult(
        exitCode: Int32? = 1,
        timedOut: Bool = false,
        abandoned: Bool = false,
        launchFailed: Bool = false,
        stdoutTail: String? = nil,
        stderrTail: String? = nil
    ) -> PiPackageUpdateCommandResult {
        PiPackageUpdateCommandResult(
            exitCode: exitCode,
            launchFailed: launchFailed,
            timedOut: timedOut,
            abandoned: abandoned,
            startedAt: referenceDate,
            finishedAt: referenceDate.addingTimeInterval(2),
            stdoutTail: stdoutTail,
            stderrTail: stderrTail
        )
    }

    func testNonZeroExitIsRecordedAsFailureWithoutRetry() throws {
        let ready = try XCTUnwrap(plan())
        let world = World(fixtureHome: fixtureHome)
        world.runner.result = { _ in self.failureResult(
            exitCode: 7,
            stderrTail: "error: EACCES \(self.fixtureHome)/.npm\nAuthorization: Bearer super-secret-value\n"
        ) }
        var batch: PiPackageUpdateBatchOutcome?
        world.makeCoordinator().runConfirmed([ready]) { batch = $0 }
        let outcome = try XCTUnwrap(batch)
        guard case .commandFailed(_, let failure, let record, let outputTail) = outcome.outcomes[0] else {
            return XCTFail("非零退出码必须判失败，实际是 \(outcome.outcomes)")
        }
        XCTAssertEqual(failure, .nonZeroExit)
        XCTAssertEqual(record.exitCode, 7)
        XCTAssertEqual(record.duration, 2, accuracy: 0.001)
        XCTAssertEqual(world.runner.plans.count, 1, "失败后不自动重试")
        XCTAssertEqual(world.detectCount, 0, "命令失败时不做版本重检测")
        let warning = try XCTUnwrap(outcome.latestWarning)
        XCTAssertEqual(warning.kind, .commandFailed)
        XCTAssertEqual(warning.packageName, packageName)
        XCTAssertEqual(warning.oldVersion, "1.0.0")
        XCTAssertEqual(warning.targetVersion, "2.0.0")
        XCTAssertTrue(warning.text.contains("旧版本文件不会被应用回滚"))
        XCTAssertFalse(warning.text.contains("已回滚"))
        // 输出尾部：有界片段 + 脱敏，凭据与 Home 前缀都不得出现。
        let tail = try XCTUnwrap(outputTail)
        XCTAssertFalse(tail.contains("super-secret-value"), "命令输出里的凭据必须脱敏")
        XCTAssertFalse(tail.contains(fixtureHome), "命令输出里的 Home 前缀必须脱敏")
        XCTAssertFalse(world.log.text.contains("super-secret-value"))
        XCTAssertFalse(world.log.text.contains(fixtureHome))
        XCTAssertTrue(world.log.text.contains("退出码 7"))
        XCTAssertTrue(world.log.text.contains("2.0 秒"))
        XCTAssertFalse(outcome.isSucceeded)
    }

    func testTimeoutIsRecordedAsFailureAndOnlyAbandonsWaiting() throws {
        let ready = try XCTUnwrap(plan())
        let world = World(fixtureHome: fixtureHome)
        world.runner.result = { _ in self.failureResult(exitCode: nil, timedOut: true) }
        var batch: PiPackageUpdateBatchOutcome?
        world.makeCoordinator().runConfirmed([ready]) { batch = $0 }
        let outcome = try XCTUnwrap(batch)
        guard case .commandFailed(_, let failure, let record, _) = outcome.outcomes[0] else {
            return XCTFail("超时必须判失败，实际是 \(outcome.outcomes)")
        }
        XCTAssertEqual(failure, .timedOut)
        XCTAssertTrue(failure.text.contains("没有向任何进程发送信号"))
        XCTAssertNil(record.exitCode)
        XCTAssertEqual(world.runner.plans.count, 1)
        XCTAssertEqual(outcome.latestWarning?.kind, .commandFailed)
        XCTAssertEqual(world.runner.abandonCount, 0, "超时由执行器自己标记，协调器不额外调用 abandon")
    }

    func testAbandonedAndLaunchFailuresAreRecorded() throws {
        for (result, expected) in [
            (failureResult(exitCode: nil, abandoned: true), PiPackageUpdateCommandFailure.abandoned),
            (failureResult(exitCode: nil, launchFailed: true), .launchFailed)
        ] {
            let ready = try XCTUnwrap(plan())
            let world = World(fixtureHome: fixtureHome)
            world.runner.result = { _ in result }
            var batch: PiPackageUpdateBatchOutcome?
            world.makeCoordinator().runConfirmed([ready]) { batch = $0 }
            let outcome = try XCTUnwrap(batch)
            guard case .commandFailed(_, let failure, _, _) = outcome.outcomes[0] else {
                return XCTFail("必须判失败，实际是 \(outcome.outcomes)")
            }
            XCTAssertEqual(failure, expected)
            XCTAssertEqual(outcome.latestWarning?.kind, .commandFailed)
        }
    }

    func testExitZeroWithoutNewVersionIsAFailureState() throws {
        for detected in ["1.0.0", nil, "not-a-version"] {
            let ready = try XCTUnwrap(plan())
            let world = World(fixtureHome: fixtureHome)
            world.detectedVersions = [packageName: detected].compactMapValues { $0 }
            var batch: PiPackageUpdateBatchOutcome?
            world.makeCoordinator().runConfirmed([ready]) { batch = $0 }
            let outcome = try XCTUnwrap(batch)
            guard case .versionUnchanged(_, let detectedVersion, let record) = outcome.outcomes[0] else {
                return XCTFail("版本没有变化（或不可解析）必须判失败，实际是 \(outcome.outcomes)")
            }
            XCTAssertEqual(detectedVersion, detected)
            XCTAssertEqual(record.exitCode, 0)
            XCTAssertEqual(world.detectCount, 1)
            XCTAssertEqual(outcome.latestWarning?.kind, .versionUnchanged)
            XCTAssertTrue(world.log.text.contains("不会自动重试无上限"))
        }
    }

    func testVersionHigherThanTargetIsSuccess() throws {
        let ready = try XCTUnwrap(plan())
        let world = World(fixtureHome: fixtureHome)
        world.detectedVersions = [packageName: "2.5.0"]
        var batch: PiPackageUpdateBatchOutcome?
        world.makeCoordinator().runConfirmed([ready]) { batch = $0 }
        let outcome = try XCTUnwrap(batch)
        guard case .succeeded(_, let newVersion, _) = outcome.outcomes[0] else {
            return XCTFail("超过目标版本也算成功，实际是 \(outcome.outcomes)")
        }
        XCTAssertEqual(newVersion, "2.5.0")
        XCTAssertNil(outcome.latestWarning)
        XCTAssertTrue(world.log.text.contains("1.0.0 → 2.5.0"))
    }

    func testUpdateVerifiedSemantics() {
        XCTAssertTrue(PiPackageUpdatePlanner.updateVerified(detected: "2.0.0", old: "1.0.0", target: "2.0.0"))
        XCTAssertTrue(PiPackageUpdatePlanner.updateVerified(detected: "2.0.1", old: "1.0.0", target: "2.0.0"))
        XCTAssertFalse(PiPackageUpdatePlanner.updateVerified(detected: "1.5.0", old: "1.0.0", target: "2.0.0"))
        XCTAssertFalse(PiPackageUpdatePlanner.updateVerified(detected: nil, old: "1.0.0", target: "2.0.0"))
        XCTAssertFalse(PiPackageUpdatePlanner.updateVerified(detected: "latest", old: "1.0.0", target: "2.0.0"))
        XCTAssertTrue(PiPackageUpdatePlanner.updateVerified(detected: "1.0.1", old: "1.0.0", target: nil))
        XCTAssertFalse(PiPackageUpdatePlanner.updateVerified(detected: "1.0.0", old: "1.0.0", target: nil))
    }

    // MARK: - 6. 脱敏

    func testLogsAndConfirmationTextAreRedacted() throws {
        let ready = try XCTUnwrap(plan(path: "\(fixtureHome)/bin/pi"))
        let redactor = LogRedactor(homeDirectory: fixtureHome)
        let decision = PiPackageUpdateDecision.awaitingConfirmation(ready)
        let logLine = decision.logLine(redactingWith: redactor)
        XCTAssertFalse(logLine.contains(fixtureHome))
        XCTAssertTrue(logLine.contains("~/bin/pi"))
        XCTAssertTrue(logLine.contains("npm:\(packageName)"))

        let confirmation = PiPackageUpdateConfirmation.text(
            plans: [ready],
            inspection: .runningProcesses([processRecord()]),
            redactingWith: redactor
        )
        XCTAssertFalse(confirmation.contains(fixtureHome), "确认框文本不得包含未脱敏的 Home 前缀")
        XCTAssertTrue(confirmation.contains("~/bin/pi"))
        XCTAssertTrue(confirmation.contains("包名：\(packageName)"))
        XCTAssertTrue(confirmation.contains("当前版本：1.0.0"))
        XCTAssertTrue(confirmation.contains("目标版本：2.0.0"))
        XCTAssertTrue(confirmation.contains("参数数组：\"update\", \"npm:\(packageName)\""))
        XCTAssertTrue(confirmation.contains("风险说明"))
        XCTAssertTrue(confirmation.contains("不会向它们发送任何信号"))
        XCTAssertTrue(confirmation.contains("进程 PID：4242"))
        XCTAssertTrue(confirmation.contains("取消是默认按钮"))
        XCTAssertFalse(confirmation.contains("sudo "), "确认框不得把 sudo 作为要执行的命令展示")
        XCTAssertTrue(confirmation.contains("不调用 sudo"), "确认框应说明不会调用 sudo")
        XCTAssertFalse(confirmation.contains("Bearer"))
        for forbidden in ["password", "token", "secret", "api_key"] {
            XCTAssertFalse(confirmation.lowercased().contains(forbidden))
        }
    }

    func testStatusPresenterShowsPoliciesRefusalsAndWarning() {
        let offText = PiPackageUpdateStatusPresenter.lines(
            policy: .off,
            planSet: .disabledForPolicyOff,
            inspection: nil,
            warning: nil
        ).joined(separator: "\n")
        XCTAssertTrue(offText.contains("策略 关闭"))
        XCTAssertTrue(offText.contains("不做无人值守更新"))
        XCTAssertTrue(offText.contains("尚未检查"))
        XCTAssertTrue(offText.contains("查看 Pi 扩展包更新…"))

        let blocked = PiPackageUpdatePlanner.decide(input(processes: .runningProcesses([processRecord()])))
        let blockedText = PiPackageUpdateStatusPresenter.lines(
            policy: .askBeforeUpdate,
            planSet: blocked,
            inspection: .runningProcesses([processRecord()]),
            warning: PiPackageUpdateWarning(
                kind: .commandFailed,
                packageName: packageName,
                oldVersion: "1.0.0",
                targetVersion: "2.0.0",
                reason: "更新命令以非零退出码结束"
            )
        ).joined(separator: "\n")
        XCTAssertTrue(blockedText.contains("检测到 1 个运行中的 Pi 进程"))
        XCTAssertTrue(blockedText.contains("拒绝记录"))
        XCTAssertTrue(blockedText.contains("Pi 扩展包更新未完成"))
        XCTAssertTrue(blockedText.contains("已就绪但被拒绝执行"))
    }

    // MARK: - 7. 输入映射与持久警告

    func testInputMappingFromComponentInstallationsAndCheckResults() {
        let components = [
            installation(),
            installation(name: "pi-extension-no-version", version: nil, source: .unknown, confidence: .unknown),
            installation(name: nil),                                       // 没有包名：跳过
            installation(kind: .piCLI, name: "pi-coding-agent"),           // 不是扩展包：跳过
            installation(name: "bad name"),                                // 包名不合法：跳过
            installation(name: "pi-extension-demo")                        // 重复：只保留第一条
        ]
        let candidates = PiPackageCandidate.list(from: components)
        XCTAssertEqual(candidates.map(\.packageName), ["pi-extension-demo", "pi-extension-no-version"])
        XCTAssertEqual(candidates[1].source, .unknown)

        let results = [
            UpdateCheckResult(
                target: UpdateCheckTarget(category: .piPackages, packageName: "pi-extension-demo"),
                status: .updateAvailable,
                installedVersion: "1.0.0",
                latestVersion: "2.0.0",
                confidence: .verified,
                freshness: .fresh
            ),
            UpdateCheckResult(
                target: UpdateCheckTarget(category: .piCLI, packageName: nil),
                status: .updateAvailable,
                installedVersion: "0.4.0",
                latestVersion: "0.5.0",
                confidence: .verified,
                freshness: .fresh
            ),
            UpdateCheckResult(
                target: UpdateCheckTarget(category: .piPackages, packageName: "pi-extension-demo"),
                status: .unknown,
                installedVersion: "1.0.0",
                latestVersion: nil,
                confidence: .unknown,
                freshness: .none,
                failure: .transport
            )
        ]
        let checks = PiPackageCheckOutcome.list(from: results)
        XCTAssertEqual(checks.count, 2, "只保留扩展包分类的结果")
        XCTAssertEqual(checks[0].status, .updateAvailable)
        XCTAssertEqual(checks[1].failureText, UpdateCheckFailure.transport.text)
    }

    func testWarningStoreRoundTripAndClearing() throws {
        let suiteName = "pi-package-update-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertNil(PiPackageUpdateWarningStore.load(from: defaults))
        let warning = PiPackageUpdateWarning(
            kind: .versionUnchanged,
            packageName: "@scope/pi-extension",
            oldVersion: "1.0.0",
            newVersion: "1.0.0",
            targetVersion: "2.0.0",
            reason: "更新命令已结束，但重新检测到的版本是 1.0.0，未达到目标版本",
            recordedAt: referenceDate
        )
        PiPackageUpdateWarningStore.save(warning, to: defaults)
        XCTAssertEqual(PiPackageUpdateWarningStore.load(from: defaults), warning)
        XCTAssertTrue(warning.text.contains("旧版本文件不会被应用回滚"))
        XCTAssertTrue(warning.shortText.contains("@scope/pi-extension"))
        XCTAssertTrue(UpdateSettingKeys.allKeys.contains(UpdateSettingKeys.piPackageUpdateWarningPackage))
        XCTAssertTrue(UpdateSettingKeys.allKeys.contains(UpdateSettingKeys.piPackageUpdateWarningKind))

        PiPackageUpdateWarningStore.save(nil, to: defaults)
        XCTAssertNil(PiPackageUpdateWarningStore.load(from: defaults))
        for key in UpdateSettingKeys.allPiPackageUpdateWarningKeys {
            XCTAssertNil(defaults.object(forKey: key), "\(key) 应被清除")
        }
    }

    func testWarningStoreRejectsInvalidPackageNamesAndVersions() throws {
        let suiteName = "pi-package-update-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        // 包名不合法时整条记录都不写入。
        PiPackageUpdateWarningStore.save(
            PiPackageUpdateWarning(kind: .commandFailed, packageName: "bad name", reason: "x"),
            to: defaults
        )
        XCTAssertNil(PiPackageUpdateWarningStore.load(from: defaults))

        // 版本不可解析时只丢版本字段，记录本身保留。
        PiPackageUpdateWarningStore.save(
            PiPackageUpdateWarning(
                kind: .commandFailed,
                packageName: packageName,
                oldVersion: "latest",
                targetVersion: "2.0.0",
                reason: "fixture"
            ),
            to: defaults
        )
        let loaded = PiPackageUpdateWarningStore.load(from: defaults)
        XCTAssertNil(loaded?.oldVersion)
        XCTAssertEqual(loaded?.targetVersion, "2.0.0")
    }

    // MARK: - 8. 真执行器（只执行临时目录里的假脚本）

    private final class Locked<T> {
        private let lock = NSLock()
        private var storage: T?
        var value: T? {
            get { lock.lock(); defer { lock.unlock() }; return storage }
            set { lock.lock(); storage = newValue; lock.unlock() }
        }
    }

    private func waitForValue<T>(_ box: Locked<T>, timeout: TimeInterval) -> T? {
        let deadline = Date().addingTimeInterval(timeout)
        while box.value == nil, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        return box.value
    }

    private func waitForFile(_ path: String, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !FileManager.default.fileExists(atPath: path), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        return FileManager.default.fileExists(atPath: path)
    }

    /// 可执行的假 `pi` 脚本：只写内容，不执行真实 `pi`。
    private func makeFakePi(in directory: URL, body: String) throws -> String {
        let url = directory.appendingPathComponent("pi")
        try ("#!/bin/sh\n" + body + "\n").write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url.path
    }

    private func plan(forScript script: String) throws -> PiPackageUpdatePlan {
        try XCTUnwrap(plan(path: script))
    }

    /// 真执行器：参数数组执行（脚本回显 `$@`）、退出码、stdout/stderr 尾部与耗时。
    func testRealExecutorRecordsExitCodeAndOutputTails() throws {
        let directory = try tempDirectory()
        let script = try makeFakePi(in: directory, body: "echo \"args:$@\"\necho \"to-stderr\" >&2\nexit 0")
        let command = ProcessPiPackageUpdateCommand(baseEnvironment: ["PATH": "/usr/bin:/bin", "HOME": fixtureHome])
        let box = Locked<PiPackageUpdateCommandResult>()
        command.run(try plan(forScript: script), timeout: 30) { box.value = $0 }
        let result = try XCTUnwrap(waitForValue(box, timeout: 20))
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertNil(result.failure)
        XCTAssertEqual(result.stdoutTail, "args:update npm:\(packageName)\n", "argv 必须是参数数组 update npm:<包名>")
        XCTAssertEqual(result.stderrTail, "to-stderr\n")
        XCTAssertGreaterThanOrEqual(result.duration, 0)
    }

    /// 超时只放弃等待：不发送信号，子进程会继续跑完并留下它自己写的标记文件。
    func testRealExecutorTimeoutOnlyAbandonsWaiting() throws {
        let directory = try tempDirectory()
        let marker = directory.appendingPathComponent("late-marker")
        let script = try makeFakePi(
            in: directory,
            body: "sleep 1\necho done > \"\(marker.path)\"\nsleep 1\nexit 0"
        )
        let command = ProcessPiPackageUpdateCommand(baseEnvironment: ["PATH": "/usr/bin:/bin", "HOME": fixtureHome])
        let box = Locked<PiPackageUpdateCommandResult>()
        command.run(try plan(forScript: script), timeout: 0.3) { box.value = $0 }
        let result = try XCTUnwrap(waitForValue(box, timeout: 10))
        XCTAssertEqual(result.failure, .timedOut)
        XCTAssertNil(result.exitCode)
        XCTAssertTrue(PiPackageUpdateCommandFailure.timedOut.text.contains("没有向任何进程发送信号"))
        // 关键负向断言：命令被“放弃等待”之后仍然继续运行（没有被终止）。
        XCTAssertTrue(waitForFile(marker.path, timeout: 10), "超时不得向子进程发送信号")
    }

    /// `abandon()`（应用退出）同样不发送信号：命令继续跑，只是不再等它。
    func testRealExecutorAbandonDoesNotSignalTheChild() throws {
        let directory = try tempDirectory()
        let marker = directory.appendingPathComponent("abandon-marker")
        let script = try makeFakePi(
            in: directory,
            body: "sleep 1\necho done > \"\(marker.path)\"\nexit 0"
        )
        let command = ProcessPiPackageUpdateCommand(baseEnvironment: ["PATH": "/usr/bin:/bin", "HOME": fixtureHome])
        let box = Locked<PiPackageUpdateCommandResult>()
        command.run(try plan(forScript: script), timeout: 30) { box.value = $0 }
        command.abandon()
        let result = try XCTUnwrap(waitForValue(box, timeout: 10))
        XCTAssertEqual(result.failure, .abandoned)
        XCTAssertTrue(waitForFile(marker.path, timeout: 10), "放弃等待不得向子进程发送信号")
    }

    /// F1（GitHub #121）：结果投递不在状态队列上——completion 自己阻塞时，状态查询
    /// （`isRunning`/`abandonedChildrenUnconfirmed`，`stateQueue.sync`）也必须立即返回，
    /// 否则一个慢回调就能拖住 UI 与退出流程。
    func testRealExecutorDeliversResultOffTheStateQueue() throws {
        let directory = try tempDirectory()
        let script = try makeFakePi(in: directory, body: "sleep 0.2\nexit 0")
        let command = ProcessPiPackageUpdateCommand(baseEnvironment: ["PATH": "/usr/bin:/bin", "HOME": fixtureHome])
        let entered = expectation(description: "completion 已被回调")
        let release = DispatchSemaphore(value: 0)
        command.run(try plan(forScript: script), timeout: 30) { _ in
            entered.fulfill()
            _ = release.wait(timeout: .now() + 30)
        }
        defer { release.signal() }
        wait(for: [entered], timeout: 20)

        // completion 仍被上面的信号量挡着：状态查询不得排队等它。
        let start = Date()
        _ = command.isRunning
        _ = command.abandonedChildrenUnconfirmed
        XCTAssertLessThan(
            Date().timeIntervalSince(start),
            1,
            "状态查询不得被阻塞的 completion 挡住（F1）"
        )
    }

    /// F2（GitHub #121）：一次读把多字节字符截断时不能丢掉，尾部要留到下一块。
    func testRealExecutorDecodesUTF8SplitAcrossReadChunks() throws {
        let directory = try tempDirectory()
        // 逐字节写“☃”（E2 98 83），中间 sleep 让可读性回调分两次拿到不完整的序列；
        // 旧实现把两块都当非法 UTF-8 丢弃，尾部是空字符串。
        let script = try makeFakePi(
            in: directory,
            body: "printf '\\342'\nsleep 0.3\nprintf '\\230\\203'\nsleep 0.3\nexit 0"
        )
        let command = ProcessPiPackageUpdateCommand(baseEnvironment: ["PATH": "/usr/bin:/bin", "HOME": fixtureHome])
        let box = Locked<PiPackageUpdateCommandResult>()
        command.run(try plan(forScript: script), timeout: 30) { box.value = $0 }
        let result = try XCTUnwrap(waitForValue(box, timeout: 20))
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdoutTail, "☃", "跨读取块的 UTF-8 序列必须在收尾时补齐（F2）")
    }

    /// B-1（审查 W2）：同一个执行器实例连续执行两次，两次都必须回调。旧实现把
    /// `finished` 当实例级一次性标记，第二次 run 会被静默丢弃。
    func testRealExecutorSecondRunOnSameInstanceCallsBack() throws {
        let directory = try tempDirectory()
        let script = try makeFakePi(in: directory, body: "echo ok\nexit 0")
        let command = ProcessPiPackageUpdateCommand(baseEnvironment: ["PATH": "/usr/bin:/bin", "HOME": fixtureHome])
        for index in 1...2 {
            let box = Locked<PiPackageUpdateCommandResult>()
            command.run(try plan(forScript: script), timeout: 30) { box.value = $0 }
            let result = try XCTUnwrap(waitForValue(box, timeout: 20), "第 \(index) 次 run 必须回调（B-1）")
            XCTAssertEqual(result.exitCode, 0)
            XCTAssertFalse(result.notAttempted, "第 \(index) 次 run 是顺序执行的，不得被判为「未执行」")
            XCTAssertNil(result.failure)
        }
    }

    /// B-1：同一实例上还有一次运行没结束时，新的 run 必须立刻回调 `.notAttempted`，
    /// 不得静默 return（否则调用方永远等不到 completion）。
    func testRealExecutorBusyRunCallsBackAsNotAttempted() throws {
        let directory = try tempDirectory()
        let script = try makeFakePi(in: directory, body: "sleep 3\nexit 0")
        let command = ProcessPiPackageUpdateCommand(baseEnvironment: ["PATH": "/usr/bin:/bin", "HOME": fixtureHome])
        let updatePlan = try plan(forScript: script)
        let first = Locked<PiPackageUpdateCommandResult>()
        let second = Locked<PiPackageUpdateCommandResult>()
        command.run(updatePlan, timeout: 30) { first.value = $0 }
        // 两次 run 在状态队列上先进先出：第二次必定落在“忙”分支。
        command.run(updatePlan, timeout: 30) { second.value = $0 }
        let rejected = try XCTUnwrap(waitForValue(second, timeout: 10), "忙时拒绝也必须回调")
        XCTAssertTrue(rejected.notAttempted)
        XCTAssertEqual(rejected.failure, .notAttempted)
        XCTAssertNil(rejected.exitCode)
        // 先到的运行不受影响，照常跑完。
        let finished = try XCTUnwrap(waitForValue(first, timeout: 20))
        XCTAssertEqual(finished.exitCode, 0)
        XCTAssertFalse(finished.notAttempted)
        XCTAssertNil(finished.failure)
    }

    /// W3（复核发现的中危并发风险）：超时只放弃等待、不终止子进程，所以旧子进程
    /// 可能还在运行。在它的退出被确认之前，新的 run 必须走「忙」拒绝路径
    /// （`.notAttempted`、不新增子进程），不得与旧子进程并发写同一个 prefix；
    /// 旧子进程退出被确认后计数结清，后续 run 必须恢复正常（不是永久拒绝）。
    func testRealExecutorRejectsRunUntilAbandonedChildExitIsConfirmed() throws {
        let directory = try tempDirectory()
        let spawns = directory.appendingPathComponent("spawns")
        let gate = directory.appendingPathComponent("gate")
        // 子进程用 gate 文件自己决定何时退出：只要断言还没做完，旧子进程就不可能
        // 先退出，因此「拒绝/结清」两段的先后顺序不依赖任何亚秒级时序。
        // 每个子进程启动时写一行 start、退出时写一行 exited，用行数判断到底启动了
        // 几个子进程（而不是只看回调）。
        let script = try makeFakePi(
            in: directory,
            body: "echo start >> \"\(spawns.path)\"\n"
                + "while [ ! -f \"\(gate.path)\" ]; do sleep 0.1; done\n"
                + "echo exited >> \"\(spawns.path)\"\nexit 0"
        )
        // 无论断言从哪一步抛出，都要放掉旧子进程，避免测试留下永久循环的子进程。
        defer { FileManager.default.createFile(atPath: gate.path, contents: Data()) }
        let command = ProcessPiPackageUpdateCommand(baseEnvironment: ["PATH": "/usr/bin:/bin", "HOME": fixtureHome])
        let updatePlan = try plan(forScript: script)
        func spawnCount(_ marker: String) -> Int {
            guard let data = FileManager.default.contents(atPath: spawns.path) else { return 0 }
            return String(decoding: data, as: UTF8.self)
                .split(separator: "\n")
                .filter { String($0) == marker }
                .count
        }

        // 1. 超时放弃等待：旧子进程被 gate 挡住，必定还活着。
        let first = Locked<PiPackageUpdateCommandResult>()
        command.run(updatePlan, timeout: 0.3) { first.value = $0 }
        let timedOut = try XCTUnwrap(waitForValue(first, timeout: 10))
        XCTAssertEqual(timedOut.failure, .timedOut)
        XCTAssertNil(timedOut.exitCode)
        XCTAssertEqual(spawnCount("start"), 1, "第一次运行只应启动一个子进程")

        // 2. 旧子进程还没退出：第二次 run 必须被拒绝，且真的没有再启动子进程。
        let second = Locked<PiPackageUpdateCommandResult>()
        command.run(updatePlan, timeout: 30) { second.value = $0 }
        let rejected = try XCTUnwrap(waitForValue(second, timeout: 10), "放弃等待窗口内必须回调「未执行」")
        XCTAssertTrue(rejected.notAttempted)
        XCTAssertEqual(rejected.failure, .notAttempted)
        XCTAssertNil(rejected.exitCode)
        XCTAssertEqual(spawnCount("start"), 1, "被拒绝的 run 不得启动第二个子进程")
        XCTAssertTrue(
            rejected.awaitingAbandonedChildExit,
            "拒绝原因是「上一次命令已放弃等待、退出未确认」，必须能被调用方区分出来"
        )

        // 3. 放掉旧子进程，等它的退出被确认：计数必须结清，run 必须能再执行。
        //    用轮询而不是固定睡眠，既证明不是永久拒绝，也不绑定亚秒级时序。
        FileManager.default.createFile(atPath: gate.path, contents: Data())
        var settled: PiPackageUpdateCommandResult?
        let deadline = Date().addingTimeInterval(15)
        while settled == nil, Date() < deadline {
            let box = Locked<PiPackageUpdateCommandResult>()
            command.run(updatePlan, timeout: 30) { box.value = $0 }
            let result = try XCTUnwrap(waitForValue(box, timeout: 20))
            if result.notAttempted {
                RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            } else {
                settled = result
            }
        }
        let last = try XCTUnwrap(settled, "旧子进程退出确认后「放弃等待」计数必须结清，run 不得被永久拒绝")
        XCTAssertEqual(last.exitCode, 0)
        XCTAssertNil(last.failure)
        XCTAssertEqual(spawnCount("start"), 2, "结清后应恰好再启动一个新的子进程")
    }

    /// W3 计时器修正的回归：第一次运行正常完成、计时器被取消并释放之后，第二次
    /// 运行自己的超时计时器必须照常触发（弱捕获不能把身份判定改坏，也不能让计时器
    /// 提前析构）。既有排水宽限用例（B-2）同样表达宽限计时器的语义。
    func testRealExecutorTimeoutStillFiresOnRunAfterNormalCompletion() throws {
        let quickDirectory = try tempDirectory()
        let slowDirectory = try tempDirectory()
        let quick = try makeFakePi(in: quickDirectory, body: "exit 0")
        let slow = try makeFakePi(in: slowDirectory, body: "sleep 5\nexit 0")
        let command = ProcessPiPackageUpdateCommand(baseEnvironment: ["PATH": "/usr/bin:/bin", "HOME": fixtureHome])
        let first = Locked<PiPackageUpdateCommandResult>()
        command.run(try plan(forScript: quick), timeout: 30) { first.value = $0 }
        let normal = try XCTUnwrap(waitForValue(first, timeout: 20))
        XCTAssertEqual(normal.exitCode, 0)
        XCTAssertNil(normal.failure)

        let second = Locked<PiPackageUpdateCommandResult>()
        command.run(try plan(forScript: slow), timeout: 0.3) { second.value = $0 }
        let timedOut = try XCTUnwrap(waitForValue(second, timeout: 10), "第二次运行的超时计时器必须触发")
        XCTAssertEqual(timedOut.failure, .timedOut)
        XCTAssertNil(timedOut.exitCode)
    }

    /// B-2（审查 W2）：进程已经以 0 退出、只是管道还没读到 EOF（后台子进程持有
    /// 写端）时，超时不得把这次运行判成 timedOut，也不得写「已放弃」记录。
    func testRealExecutorSuccessfulExitWinsOverDrainGraceTimeout() throws {
        let directory = try tempDirectory()
        // 后台子进程持有 stdout 写端：父脚本退出后管道不会立刻 EOF，
        // 结束流程会走「等排水宽限」这条路径。
        let script = try makeFakePi(in: directory, body: "sleep 5 &\nexit 0")
        let abandonedCount = Locked<Int>()
        // 宽限窗口（3s）远大于超时（1s）：超时必定落在「进程已退出、管道还没读到
        // EOF」的窗口内——确定性地覆盖 B-2 的竞态，不依赖机器快慢。
        let command = ProcessPiPackageUpdateCommand(
            baseEnvironment: ["PATH": "/usr/bin:/bin", "HOME": fixtureHome],
            recordAbandonedAttempt: { _ in abandonedCount.value = (abandonedCount.value ?? 0) + 1 },
            pipeDrainGrace: 3
        )
        let box = Locked<PiPackageUpdateCommandResult>()
        command.run(try plan(forScript: script), timeout: 1) { box.value = $0 }
        let result = try XCTUnwrap(waitForValue(box, timeout: 20))
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertFalse(result.timedOut, "已观测到退出码 0 时不得判定为超时")
        XCTAssertFalse(result.notAttempted)
        XCTAssertNil(result.failure)
        XCTAssertEqual(abandonedCount.value ?? 0, 0, "成功退出不得写「已放弃」记录")
    }

    /// B-3（复核）：`abandon()` 落在「进程已退出、只是在等管道读到 EOF」的宽限窗口里
    /// 时并不算放弃等待：结果照常按真实退出码投递，也不得写一条 `finishedAt == nil`
    /// 的「已放弃」记录（那是失实的历史，登记也永远无人结清）。
    func testRealExecutorAbandonDuringDrainGraceKeepsSuccessfulExit() throws {
        let directory = try tempDirectory()
        let marker = directory.appendingPathComponent("parent-exited")
        // 后台子进程持有 stdout 写端：父脚本退出后管道不会立刻 EOF，结束流程会停在
        // 「等排水宽限」这条路径上。宽限（5s）远大于断言耗时，abandon() 必定落在窗口内。
        let script = try makeFakePi(
            in: directory,
            body: "sleep 5 &\necho done > \"\(marker.path)\"\nexit 0"
        )
        let abandonedCount = Locked<Int>()
        let command = ProcessPiPackageUpdateCommand(
            baseEnvironment: ["PATH": "/usr/bin:/bin", "HOME": fixtureHome],
            recordAbandonedAttempt: { _ in abandonedCount.value = (abandonedCount.value ?? 0) + 1 },
            pipeDrainGrace: 5
        )
        let box = Locked<PiPackageUpdateCommandResult>()
        command.run(try plan(forScript: script), timeout: 30) { box.value = $0 }
        XCTAssertTrue(waitForFile(marker.path, timeout: 20), "父脚本必须已经跑到退出前的最后一步")
        // 父脚本只剩一句 exit：再留一点余量让退出被观察到，使 abandon() 确定地落在
        // 排水宽限窗口里（宽限 5s，不受这点耗时影响）。
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        command.abandon()
        let result = try XCTUnwrap(waitForValue(box, timeout: 20))
        XCTAssertEqual(result.exitCode, 0, "排水窗口里的 abandon() 不得把真实退出码改写成 nil")
        XCTAssertFalse(result.abandoned, "排水窗口里的 abandon() 不算放弃等待")
        XCTAssertFalse(result.timedOut)
        XCTAssertNil(result.failure)
        XCTAssertEqual(abandonedCount.value ?? 0, 0, "排水窗口里的 abandon() 不得写「已放弃」记录")
    }

    /// B-1/W3（复核）：「上一次命令已放弃等待、退出还没确认」导致的拒绝必须能与
    /// 「真正重叠」区分开，并给出「重启应用可恢复」的可见原因。
    func testBusyRunAwaitingAbandonedChildExitReportsRecoverableReason() throws {
        let ready = try XCTUnwrap(plan())
        let world = World(fixtureHome: fixtureHome)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        world.runner.result = { _ in
            PiPackageUpdateCommandResult(
                exitCode: nil,
                notAttempted: true,
                awaitingAbandonedChildExit: true,
                startedAt: now,
                finishedAt: now
            )
        }
        var batch: PiPackageUpdateBatchOutcome?
        world.makeCoordinator().runConfirmed([ready]) { batch = $0 }

        let outcome = try XCTUnwrap(batch)
        guard case .notAttempted(let name, let reason) = outcome.outcomes[0] else {
            return XCTFail("执行器拒绝时必须如实记为「未执行」，实际是 \(outcome.outcomes)")
        }
        XCTAssertEqual(name, packageName)
        XCTAssertEqual(reason, .executorBusyAwaitingAbandonedChildExit)
        XCTAssertTrue(
            reason.text.contains("重启应用即可恢复"),
            "未确认退出的拒绝必须给出可恢复路径：\(reason.text)"
        )
        XCTAssertTrue(world.log.text.contains("重启应用即可恢复"), "日志同样要给出可恢复路径")
        XCTAssertEqual(world.runner.plans.count, 1)
    }

    /// 对照组：真正重叠（旧子进程还在运行）时的拒绝仍是笼统的「执行器忙」，不冒充
    /// 「重启应用可恢复」——那个窗口重启才有用。
    func testBusyRunWithoutUnconfirmedChildReportsExecutorBusy() throws {
        let ready = try XCTUnwrap(plan())
        let world = World(fixtureHome: fixtureHome)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        world.runner.result = { _ in
            PiPackageUpdateCommandResult(
                exitCode: nil,
                notAttempted: true,
                startedAt: now,
                finishedAt: now
            )
        }
        var batch: PiPackageUpdateBatchOutcome?
        world.makeCoordinator().runConfirmed([ready]) { batch = $0 }

        let outcome = try XCTUnwrap(batch)
        guard case .notAttempted(_, let reason) = outcome.outcomes[0] else {
            return XCTFail("执行器拒绝时必须如实记为「未执行」，实际是 \(outcome.outcomes)")
        }
        XCTAssertEqual(reason, .executorBusy)
        XCTAssertFalse(reason.text.contains("重启应用即可恢复"), "重叠不是重启才能恢复的窗口")
    }

    /// B-1：协调器连续两批更新都必须回调（旧实现里第二批会被静默丢弃）。
    func testRealExecutorServesTwoConsecutiveCoordinatorBatches() throws {
        let directory = try tempDirectory()
        let script = try makeFakePi(in: directory, body: "echo run\nexit 0")
        let command = ProcessPiPackageUpdateCommand(baseEnvironment: ["PATH": "/usr/bin:/bin", "HOME": fixtureHome])
        let log = LogSink()
        let coordinator = PiPackageUpdateCoordinator(environment: PiPackageUpdateCoordinator.Environment(
            inspectProcesses: { .noProcesses },
            runner: command,
            detectPackageVersion: { _ in "2.0.0" },
            redactor: LogRedactor(homeDirectory: fixtureHome),
            log: { log.append($0) },
            deliver: { $0() },
            timeout: 30
        ))
        for name in [packageName, "pi-extension-other"] {
            let box = Locked<PiPackageUpdateBatchOutcome>()
            let batchPlan = try XCTUnwrap(plan(path: script, name: name))
            coordinator.runConfirmed([batchPlan]) { box.value = $0 }
            let outcome = try XCTUnwrap(waitForValue(box, timeout: 20), "第 \(name) 批必须回调")
            XCTAssertTrue(outcome.isSucceeded, "第 \(name) 批应当成功：\(outcome.outcomes)")
        }
    }

    func testEnvironmentWhitelistKeepsOnlySafeKeysAndPrependsPiDirectory() {
        let environment = PiPackageUpdateEnvironment.environment(
            base: [
                "PATH": "/usr/bin:/bin",
                "HOME": fixtureHome,
                "TMPDIR": "/tmp",
                "NPM_TOKEN": "npm-secret",
                "AWS_SECRET_ACCESS_KEY": "aws-secret",
                "HTTPS_PROXY": "http://proxy.example.test:3128",
                "LANG": "zh_CN.UTF-8"
            ],
            piExecutablePath: piPath
        )
        XCTAssertNil(environment["NPM_TOKEN"], "凭据类环境变量不得透传")
        XCTAssertNil(environment["AWS_SECRET_ACCESS_KEY"])
        XCTAssertNil(environment["HTTPS_PROXY"], "代理变量不在白名单内")
        XCTAssertEqual(environment["HOME"], fixtureHome)
        XCTAssertEqual(environment["LANG"], "zh_CN.UTF-8")
        let directories = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        XCTAssertEqual(directories.first, "/opt/homebrew/bin", "pi 所在目录必须排在最前（node 由 env 查找）")
        XCTAssertTrue(directories.contains("/usr/bin"))
        XCTAssertTrue(directories.contains("/bin"))
        XCTAssertEqual(Set(directories).count, directories.count, "PATH 不应有重复目录")
        XCTAssertEqual(
            PiPackageUpdateEnvironment.keyDescription(["B": "2", "A": "1", "TOKEN": "x"]),
            "A, B, TOKEN",
            "只记录键名，不记录值"
        )
    }

    // MARK: - 9. 源码负向断言（没有信号、没有 shell、没有 sudo）

    /// 仓库根目录（测试文件位于 `<root>/PiWebDesktopTests/`）。
    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func sourceText(relativePath: String) throws -> String {
        try String(contentsOf: repositoryRoot().appendingPathComponent(relativePath), encoding: .utf8)
    }

    /// 去掉 `//` 行注释与行尾注释后的代码文本：注释里提到被禁止的 API 名字是允许的，
    /// 真正要断言的是代码里没有这些调用。
    private func codeText(of source: String) -> String {
        source
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> String in
                let trimmed = line.drop { $0 == " " || $0 == "\t" }
                guard !trimmed.hasPrefix("//") else { return "" }
                guard let range = line.range(of: "//") else { return String(line) }
                return String(line[line.startIndex..<range.lowerBound])
            }
            .joined(separator: "\n")
    }

    /// 适配器与执行器的代码里不得出现任何“向进程发送信号 / 终止进程”的调用，也不得调用
    /// shell 或 `sudo`：扩展包更新只允许 `pi` 自身以参数数组执行。
    func testSourcesContainNoSignalOrShellAPIs() throws {
        let forbidden = [
            "kill(", "killpg(", "raise(", "signal(", "SIGTERM", "SIGKILL", "SIGINT",
            ".terminate(", ".interrupt(", "posix_spawn", "/bin/sh", "/bin/bash", "shellPath",
            "sudo(", "sudo -", "Process.arguments"
        ]
        for relativePath in [
            "Sources/PiPackageUpdateAdapter.swift",
            "Sources/PiProcessInspector.swift"
        ] {
            let code = codeText(of: try sourceText(relativePath: relativePath))
            for token in forbidden {
                XCTAssertFalse(code.contains(token), "\(relativePath) 的代码里不得出现 \(token)")
            }
        }
    }

    /// 命令执行只经由参数数组：执行器设置 `process.arguments`，参数安全校验的禁止 token 表
    /// 里确实包含 `sudo` 与各种 shell。
    func testExecutableIsOnlyStartedThroughTheArgumentArray() throws {
        let text = try sourceText(relativePath: "Sources/PiPackageUpdateAdapter.swift")
        XCTAssertTrue(text.contains("process.arguments = plan.arguments"))
        XCTAssertTrue(text.contains("static let forbiddenTokens: Set<String> = [\"sudo\", \"sh\""))
        XCTAssertFalse(text.contains("shellPath"))
        XCTAssertFalse(text.contains("NSAppleScript"))
    }

    // MARK: - 9. GitHub #107（W2B B-12 / B-13、非阻塞读状态接口）

    /// B-12：判定顺序是「进程保护 → 已放弃记录」。检测到运行中的 Pi 进程（或进程
    /// 状态不确定）时直接拒绝执行，不再先要求用户确认一条注定执行不下去的记录；
    /// 进程状态恢复后，同一条记录仍然会要求确认（记录没有被跳过）。
    func testProcessRefusalOutranksAbandonedAttemptConfirmation() {
        let attempt = abandonedAttempt()

        let blocked = PiPackageUpdatePlanner.decide(input(
            processes: .runningProcesses([processRecord(pid: 4242)]),
            abandonedAttempts: [attempt]
        ))
        XCTAssertTrue(blocked.abandonedConfirmationPlans.isEmpty, "进程保护先判：不得要求确认「已放弃」记录")
        XCTAssertFalse(blocked.executionAvailable)
        guard case .executeBlocked(_, let reason) = blocked.decisions[0] else {
            return XCTFail("有运行中的 Pi 进程时必须拒绝执行，实际是 \(blocked.decisions)")
        }
        XCTAssertEqual(blockedPids(reason), [4242])
        XCTAssertEqual(blocked.allPlans.count, 1, "计划本身仍然可见（用于展示与诊断）")

        let unknown = PiPackageUpdatePlanner.decide(input(
            processes: .unknown(.enumerationFailed),
            abandonedAttempts: [attempt]
        ))
        XCTAssertTrue(unknown.abandonedConfirmationPlans.isEmpty, "状态不确定同样先拒绝，不引导确认记录")
        guard case .executeBlocked(_, let unknownReason) = unknown.decisions[0] else {
            return XCTFail("进程状态不确定时必须拒绝执行，实际是 \(unknown.decisions)")
        }
        XCTAssertEqual(unknownReason, .processStateUnknown(.enumerationFailed))

        let confirmation = PiPackageUpdatePlanner.decide(input(
            processes: .noProcesses,
            abandonedAttempts: [attempt]
        ))
        guard case .awaitingAbandonedConfirmation(_, let confirmed) = confirmation.decisions[0] else {
            return XCTFail("进程消失后必须要求确认「已放弃」记录，实际是 \(confirmation.decisions)")
        }
        XCTAssertEqual(confirmed, attempt)
        XCTAssertEqual(confirmation.abandonedConfirmationPlans.count, 1)
        XCTAssertFalse(confirmation.executionAvailable, "未确认前不得给出执行入口")
    }

    /// B-13：安装失败（非零退出）分支必须像验证失败分支一样调用 `applyDegradation`。
    /// 扩展包没有可重新指向的可执行文件，这个 kind 的 apply 在生产里是 no-op：
    /// 这里用替身断言调用确实发生（三条失败路径的降级语义一致）。
    func testInstallFailureAppliesDegradationExactlyOnce() throws {
        let ready = try XCTUnwrap(plan())
        let world = World(fixtureHome: fixtureHome)
        world.runner.result = { _ in
            PiPackageUpdateCommandResult(
                exitCode: 1,
                startedAt: self.referenceDate,
                finishedAt: self.referenceDate.addingTimeInterval(3),
                stdoutTail: "npm ERR!\n",
                stderrTail: ""
            )
        }
        var batch: PiPackageUpdateBatchOutcome?
        world.makeCoordinator().runConfirmed([ready]) { batch = $0 }
        let outcome = try XCTUnwrap(batch)
        XCTAssertEqual(world.runner.plans.count, 1)
        XCTAssertEqual(world.degradations.count, 1, "安装失败必须调用一次 applyDegradation")
        XCTAssertEqual(world.degradations.map(\.kind), [.installFailedKeepingPreviousVersion])
        XCTAssertEqual(
            world.degradations.first?.performedAutomaticDegradation,
            false,
            "扩展包没有可自动重指向的可执行文件：该 kind 的 apply 是 no-op"
        )
        guard case .commandFailed(let failedPlan, let failure, let record, _) = outcome.outcomes[0] else {
            return XCTFail("命令失败必须如实记录，实际是 \(outcome.outcomes)")
        }
        XCTAssertEqual(failedPlan.arguments, ["update", "npm:\(packageName)"])
        XCTAssertEqual(failure, .nonZeroExit)
        XCTAssertEqual(record.exitCode, 1)
        XCTAssertEqual(world.detectCount, 0, "安装失败不必重新检测版本")
    }

    /// B-13 对照：验证失败分支（既有调用点）与安装失败分支调用同一个替身；
    /// 成功路径不调用（只记「无需降级」）。
    func testVerificationFailureStillAppliesDegradationAndSuccessNeverDoes() throws {
        let ready = try XCTUnwrap(plan())

        let verifyWorld = World(fixtureHome: fixtureHome)
        verifyWorld.detectedVersions = [packageName: "1.0.0"]
        var verifyBatch: PiPackageUpdateBatchOutcome?
        verifyWorld.makeCoordinator().runConfirmed([ready]) { verifyBatch = $0 }
        let verifyOutcome = try XCTUnwrap(verifyBatch)
        guard case .versionUnchanged = verifyOutcome.outcomes[0] else {
            return XCTFail("命令成功但版本没变应按验证失败处理，实际是 \(verifyOutcome.outcomes)")
        }
        XCTAssertEqual(verifyWorld.degradations.count, 1, "验证失败分支调用 applyDegradation")
        XCTAssertNotEqual(verifyWorld.degradations.first?.kind, .notNeeded)

        let successWorld = World(fixtureHome: fixtureHome)
        successWorld.detectedVersions = [packageName: "2.0.0"]
        var successBatch: PiPackageUpdateBatchOutcome?
        successWorld.makeCoordinator().runConfirmed([ready]) { successBatch = $0 }
        XCTAssertTrue(try XCTUnwrap(successBatch).isSucceeded)
        XCTAssertTrue(successWorld.degradations.isEmpty, "成功路径不得调用 applyDegradation")
    }

    /// 读状态接口（GitHub #107）：`isRunning` / `abandonedChildrenUnconfirmed` 都是
    /// 非阻塞读，菜单在点击之前就能给出可见原因。在真执行器上验证三次过渡：
    /// 空闲 → 运行中 → 放弃等待但退出未确认 → 结清。
    func testExecutorReadStateFeedsTheMenuEntryState() throws {
        let directory = try tempDirectory()
        let gate = directory.appendingPathComponent("menu-gate")
        let script = try makeFakePi(
            in: directory,
            body: "while [ ! -f \"\(gate.path)\" ]; do sleep 0.1; done\nexit 0"
        )
        defer { FileManager.default.createFile(atPath: gate.path, contents: Data()) }
        let command = ProcessPiPackageUpdateCommand(baseEnvironment: ["PATH": "/usr/bin:/bin", "HOME": fixtureHome])
        let updatePlan = try plan(forScript: script)

        func entryState() -> UpdateEntryState {
            UpdateEntryState.component(
                transactionInProgress: false,
                childInFlight: command.isRunning,
                abandonedChildrenUnconfirmed: command.abandonedChildrenUnconfirmed
            )
        }

        XCTAssertEqual(entryState(), .free, "空闲时菜单项必须可用")
        XCTAssertNil(entryState().menuTitleSuffix)

        let box = Locked<PiPackageUpdateCommandResult>()
        command.run(updatePlan, timeout: 0.3) { box.value = $0 }
        XCTAssertTrue(command.isRunning, "运行期间必须报告「忙」，且不需要等子进程")
        XCTAssertFalse(command.abandonedChildrenUnconfirmed)
        let busy = entryState()
        XCTAssertTrue(busy.isBlocked)
        XCTAssertEqual(busy.menuTitleSuffix, "（正在更新）")
        XCTAssertTrue(busy.rejectionDetail.contains("尚未结束"))

        let timedOut = try XCTUnwrap(waitForValue(box, timeout: 10))
        XCTAssertEqual(timedOut.failure, .timedOut)
        XCTAssertTrue(command.abandonedChildrenUnconfirmed, "放弃等待窗口内必须报告「未确认退出」")
        XCTAssertTrue(command.isRunning, "放弃等待窗口内仍然算「忙」")
        let awaiting = entryState()
        XCTAssertTrue(awaiting.isBlocked)
        XCTAssertEqual(awaiting.menuTitleSuffix, "（上一次更新未确认退出，重启应用可恢复）")
        XCTAssertTrue(awaiting.rejectionDetail.contains("重启应用"))

        FileManager.default.createFile(atPath: gate.path, contents: Data())
        let deadline = Date().addingTimeInterval(15)
        while command.abandonedChildrenUnconfirmed, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertFalse(command.abandonedChildrenUnconfirmed, "退出确认后不得继续报告「未确认退出」")
        XCTAssertFalse(command.isRunning)
        XCTAssertEqual(entryState(), .free, "结清后菜单项必须恢复可用")
    }
}
