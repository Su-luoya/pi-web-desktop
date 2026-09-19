import Foundation
import XCTest

// GitHub #21 的 unhosted 测试（Pi CLI 更新的决策、执行与失败记录部分）。
//
// 默认全部用同步替身：假进程表（`PiProcessProbing.fixture`）、记录型命令执行器、
// 假版本重检测。因此测试不枚举真实进程、不执行真实 `pi`、不访问网络、不发送任何
// 信号。唯一使用真实子进程的是执行器自身的一个用例，它执行的也是临时目录里的假
// 脚本（用来证明超时“只放弃等待”，不会向子进程发送信号）。
//
// 唯一写 UserDefaults 的用例使用 suiteName 隔离的 domain，测试结束即删除。

final class PiCLIUpdateAdapterTests: XCTestCase {

    private let fixtureHome = "/tmp/pi-cli-update-tests-home"
    private let piPath = "/opt/homebrew/bin/pi"
    private let referenceDate = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - 替身

    private final class LogSink {
        private(set) var messages: [String] = []
        func append(_ message: String) { messages.append(message) }
        var text: String { messages.joined(separator: "\n") }
    }

    private final class RecordingRunner: PiCLIUpdateRunning {
        private(set) var plans: [PiCLIUpdatePlan] = []
        private(set) var timeouts: [TimeInterval] = []
        private(set) var abandonCount = 0
        var result: (PiCLIUpdatePlan) -> PiCLIUpdateCommandResult = { _ in
            PiCLIUpdateCommandResult(
                exitCode: 0,
                startedAt: Date(timeIntervalSince1970: 1_700_000_000),
                finishedAt: Date(timeIntervalSince1970: 1_700_000_001)
            )
        }

        func run(
            _ plan: PiCLIUpdatePlan,
            timeout: TimeInterval,
            completion: @escaping (PiCLIUpdateCommandResult) -> Void
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
        var inspection: PiProcessInspection = .noProcesses
        private(set) var inspectCount = 0
        var detectedVersion: String? = "0.4.2"
        private(set) var detectCount = 0

        func makeCoordinator(timeout: TimeInterval = PiCLIUpdateCoordinator.defaultTimeout) -> PiCLIUpdateCoordinator {
            PiCLIUpdateCoordinator(environment: PiCLIUpdateCoordinator.Environment(
                inspectProcesses: {
                    self.inspectCount += 1
                    return self.inspection
                },
                runner: runner,
                detectInstallation: {
                    self.detectCount += 1
                    return self.detectedVersion.map { version in self.installation(version: version) }
                },
                redactor: LogRedactor(homeDirectory: self.fixtureHome),
                log: { message in self.log.append(message) },
                deliver: { work in work() },
                timeout: timeout
            ))
        }

        let fixtureHome: String
        let piPath = "/opt/homebrew/bin/pi"

        init(fixtureHome: String) { self.fixtureHome = fixtureHome }

        func installation(
            kind: ComponentKind = .piCLI,
            packageName: String? = InstallCommandManifest.piCLIPackageName,
            version: String? = "0.4.0",
            executablePath: String? = "/opt/homebrew/bin/pi",
            resolvedPath: String? = "/opt/homebrew/lib/node_modules/@earendil-works/pi-coding-agent/cli.js",
            source: InstallSource = .npmGlobal,
            confidence: DetectionConfidence = .verified
        ) -> ComponentInstallation {
            ComponentInstallation(
                kind: kind,
                packageName: packageName,
                version: version,
                executablePath: executablePath,
                resolvedPath: resolvedPath,
                symlinkChain: [],
                packageJSONPath: nil,
                source: source,
                confidence: confidence,
                evidence: ["fixture"],
                suggestedCommand: nil
            )
        }
    }

    private func installation(
        kind: ComponentKind = .piCLI,
        version: String? = "0.4.0",
        executablePath: String? = "/opt/homebrew/bin/pi",
        source: InstallSource = .npmGlobal,
        confidence: DetectionConfidence = .verified
    ) -> ComponentInstallation {
        ComponentInstallation(
            kind: kind,
            packageName: InstallCommandManifest.piCLIPackageName,
            version: version,
            executablePath: executablePath,
            resolvedPath: "/opt/homebrew/lib/node_modules/@earendil-works/pi-coding-agent/cli.js",
            symlinkChain: [],
            packageJSONPath: nil,
            source: source,
            confidence: confidence,
            evidence: ["fixture"],
            suggestedCommand: nil
        )
    }

    private func input(
        installation: ComponentInstallation?,
        targetVersion: String? = "0.4.2",
        targetStatus: UpdateCheckStatus = .updateAvailable,
        targetConfidence: DetectionConfidence = .verified,
        processes: PiProcessInspection = .noProcesses,
        autoUpdate: Bool = true
    ) -> PiCLIUpdatePlanningInput {
        var preferences = UpdateCheckPreferences.factoryDefaults
        preferences.autoUpdatePiBeforeLaunch = autoUpdate
        return PiCLIUpdatePlanningInput(
            preferences: preferences,
            installation: installation,
            targetVersion: targetVersion,
            targetStatus: targetStatus,
            targetConfidence: targetConfidence,
            processes: processes
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

    private func tempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pi-cli-update-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - 1. 设置与前置条件

    func testDefaultSettingIsOffAndKeyIsNamespaced() {
        XCTAssertFalse(UpdateCheckPreferences.defaultAutoUpdatePiBeforeLaunch)
        XCTAssertFalse(UpdateCheckPreferences.factoryDefaults.autoUpdatePiBeforeLaunch)
        XCTAssertTrue(UpdateCheckPreferences.autoUpdatePiBeforeLaunchIsEffective)
        let key = UpdateSettingKeys.autoUpdatePiBeforeLaunch
        XCTAssertEqual(key, "updateChecks.pi.autoUpdateBeforeLaunch")
        XCTAssertTrue(UpdateSettingKeys.writtenPreferencesKeys.contains(key))
        XCTAssertTrue(UpdateSettingKeys.allKeys.contains(key))
        XCTAssertTrue(UpdateSettingKeys.allPreferencesKeys.contains(key))
    }

    func testSettingDisabledOnlyOffersManualCommand() {
        let decision = PiCLIUpdatePlanner.decide(input(installation: installation(), autoUpdate: false))
        guard case .manualOnly(let commandText, let reason) = decision else {
            return XCTFail("设置关闭时必须只给手动入口，实际是 \(decision)")
        }
        XCTAssertEqual(reason, .settingDisabled)
        XCTAssertEqual(commandText, "\(piPath) update --self")
        XCTAssertFalse(decision.isAutomatic)
    }

    func testSettingDisabledNeverInvokesRunner() {
        let world = World(fixtureHome: fixtureHome)
        var outcome: PiCLIUpdateRunOutcome?
        world.makeCoordinator().run(input(installation: installation(), autoUpdate: false)) { outcome = $0 }
        guard case .notAttempted(let reason, let commandText) = outcome else {
            return XCTFail("不应执行命令，实际是 \(String(describing: outcome))")
        }
        XCTAssertEqual(reason, .settingDisabled)
        XCTAssertEqual(commandText, "\(piPath) update --self")
        XCTAssertTrue(world.runner.plans.isEmpty)
        XCTAssertEqual(world.inspectCount, 0, "设置关闭时不应做进程检查")
    }

    func testMissingInstallationIsUnavailable() {
        let decision = PiCLIUpdatePlanner.decide(input(installation: nil))
        guard case .unavailable(let reason) = decision else {
            return XCTFail("没有安装信息时不应给出命令，实际是 \(decision)")
        }
        XCTAssertEqual(reason, .missingInstallation)
        XCTAssertNil(decision.plan)
    }

    func testUnresolvedExecutablePathIsUnavailable() {
        let decision = PiCLIUpdatePlanner.decide(input(installation: installation(executablePath: nil)))
        XCTAssertEqual(decision, .unavailable(reason: .executableUnresolved))
    }

    func testOnlyVerifiedPackageManagerSourceAllowsAutomaticUpdate() {
        for source in [InstallSource.homebrew, .gitCheckout, .localPath, .unknown, .nvm, .mise, .officialInstaller] {
            let decision = PiCLIUpdatePlanner.decide(input(installation: installation(source: source)))
            guard case .manualOnly(let commandText, let reason) = decision else {
                return XCTFail("来源 \(source) 不应自动更新，实际是 \(decision)")
            }
            XCTAssertEqual(reason, .sourceNotVerifiedPackageManager(source: source, confidence: .verified))
            XCTAssertEqual(commandText, "\(piPath) update --self")
        }
        // pnpm 全局同样是已验证的包管理器来源。
        let pnpm = PiCLIUpdatePlanner.decide(input(installation: installation(source: .pnpmGlobal)))
        XCTAssertTrue(pnpm.isAutomatic)
        // 可信度不是 verified 时同样只给手动入口。
        let inferred = PiCLIUpdatePlanner.decide(input(installation: installation(confidence: .inferred)))
        XCTAssertEqual(
            inferred,
            .manualOnly(
                commandText: "\(piPath) update --self",
                reason: .sourceNotVerifiedPackageManager(source: .npmGlobal, confidence: .inferred)
            )
        )
    }

    func testTargetVersionMustBeAvailableVerifiedAndHigher() {
        XCTAssertEqual(
            PiCLIUpdatePlanner.decide(input(installation: installation(), targetVersion: nil)),
            .manualOnly(commandText: "\(piPath) update --self", reason: .noTargetVersion)
        )
        XCTAssertEqual(
            PiCLIUpdatePlanner.decide(input(installation: installation(), targetStatus: .upToDate)),
            .manualOnly(commandText: "\(piPath) update --self", reason: .noTargetVersion)
        )
        XCTAssertEqual(
            PiCLIUpdatePlanner.decide(input(installation: installation(), targetConfidence: .inferred)),
            .manualOnly(commandText: "\(piPath) update --self", reason: .targetNotVerified)
        )
        XCTAssertEqual(
            PiCLIUpdatePlanner.decide(input(installation: installation(), targetVersion: "latest")),
            .manualOnly(commandText: "\(piPath) update --self", reason: .invalidTargetVersion)
        )
        XCTAssertEqual(
            PiCLIUpdatePlanner.decide(input(installation: installation(), targetVersion: "0.4.0")),
            .manualOnly(commandText: "\(piPath) update --self", reason: .noNewerTargetVersion)
        )
        XCTAssertEqual(
            PiCLIUpdatePlanner.decide(input(installation: installation(version: "1.0.0"), targetVersion: "0.4.2")),
            .manualOnly(commandText: "\(piPath) update --self", reason: .noNewerTargetVersion)
        )
        XCTAssertEqual(
            PiCLIUpdatePlanner.decide(input(installation: installation(version: nil))),
            .manualOnly(commandText: "\(piPath) update --self", reason: .noNewerTargetVersion)
        )
    }

    // MARK: - 2. 进程保护优先于自动更新

    func testAllPreconditionsMetWithoutProcessesIsAutomatic() {
        let decision = PiCLIUpdatePlanner.decide(input(installation: installation()))
        guard case .automatic(let plan) = decision else {
            return XCTFail("全部前置条件满足时应允许自动更新，实际是 \(decision)")
        }
        XCTAssertEqual(plan.executablePath, piPath)
        XCTAssertEqual(plan.arguments, ["update", "--self"])
        XCTAssertEqual(plan.installedVersion, "0.4.0")
        XCTAssertEqual(plan.targetVersion, "0.4.2")
        XCTAssertEqual(plan.commandText, "\(piPath) update --self")
    }

    func testRunningPiProcessesDeferAutomaticUpdateAndNeverRunCommand() {
        let records = [processRecord(pid: 4242), processRecord(pid: 4243, parentPID: 4242)]
        let world = World(fixtureHome: fixtureHome)
        let request = input(
            installation: installation(),
            processes: .runningProcesses(records)
        )
        let decision = PiCLIUpdatePlanner.decide(request)
        guard case .deferred(let plan, let reason) = decision else {
            return XCTFail("有运行中的 Pi 进程时必须推迟，实际是 \(decision)")
        }
        XCTAssertEqual(plan.arguments, ["update", "--self"])
        XCTAssertEqual(reason.records.map(\.pid), [4242, 4243])
        XCTAssertFalse(decision.isAutomatic)

        var outcome: PiCLIUpdateRunOutcome?
        world.makeCoordinator().run(request) { outcome = $0 }
        guard case .deferred = outcome else {
            return XCTFail("协调器不应执行命令，实际是 \(String(describing: outcome))")
        }
        XCTAssertTrue(world.runner.plans.isEmpty, "推迟时绝不执行 pi update --self")
        XCTAssertEqual(world.inspectCount, 0, "决策已经推迟，不应再做执行前复查")
        XCTAssertTrue(world.log.text.contains("推迟"))
        XCTAssertTrue(world.log.text.contains("应用不会结束任何 Pi 进程"))
    }

    func testUnknownProcessStateDefersAutomaticUpdate() {
        let unknownCases: [PiProcessInspectionUnknown] = [
            .enumerationFailed,
            .argumentsUnavailable(pid: 4242, interpreter: "node"),
            .identityUnavailable(pid: 4243, failure: .permissionDenied),
            .scriptPathUnconfirmed(pid: 4244, path: "/tmp/notes/pi")
        ]
        for unknown in unknownCases {
            let decision = PiCLIUpdatePlanner.decide(
                input(installation: installation(), processes: .unknown(unknown))
            )
            guard case .deferred(_, let reason) = decision else {
                return XCTFail("不确定的进程状态必须推迟，实际是 \(decision)")
            }
            XCTAssertEqual(reason, .processStateUnknown(unknown))
            XCTAssertTrue(reason.text.contains("按不安全处理"))
            XCTAssertTrue(reason.text.contains("应用不会结束任何进程"))
        }
    }

    /// 决策与执行之间可能有新的 Pi 进程启动：执行前必须复查，复查不通过就推迟。
    func testPreExecutionRecheckDefersWhenProcessAppears() {
        let world = World(fixtureHome: fixtureHome)
        world.inspection = .runningProcesses([processRecord()])
        var outcome: PiCLIUpdateRunOutcome?
        world.makeCoordinator().run(input(installation: installation())) { outcome = $0 }
        guard case .deferred(let reason) = outcome else {
            return XCTFail("执行前复查发现进程时必须推迟，实际是 \(String(describing: outcome))")
        }
        XCTAssertEqual(reason.records.map(\.pid), [4242])
        XCTAssertEqual(world.inspectCount, 1)
        XCTAssertTrue(world.runner.plans.isEmpty)
        XCTAssertTrue(world.log.text.contains("执行前复查"))
    }

    func testPreExecutionRecheckDefersWhenStateBecomesUnknown() {
        let world = World(fixtureHome: fixtureHome)
        world.inspection = .unknown(.enumerationFailed)
        var outcome: PiCLIUpdateRunOutcome?
        world.makeCoordinator().run(input(installation: installation())) { outcome = $0 }
        guard case .deferred(let reason) = outcome else {
            return XCTFail("执行前复查失败时必须推迟，实际是 \(String(describing: outcome))")
        }
        XCTAssertEqual(reason, .processStateUnknown(.enumerationFailed))
        XCTAssertTrue(world.runner.plans.isEmpty)
    }

    /// 复查为 `noProcesses` 时才执行，并且只执行一次（没有无上限重试）。
    func testExecutionHappensOnceWithTheExactArgumentArray() {
        let world = World(fixtureHome: fixtureHome)
        world.detectedVersion = "0.4.2"
        var outcome: PiCLIUpdateRunOutcome?
        world.makeCoordinator(timeout: 123).run(input(installation: installation())) { outcome = $0 }
        guard case .succeeded(let plan, let oldVersion, let newVersion) = outcome else {
            return XCTFail("版本达到目标时必须判成功，实际是 \(String(describing: outcome))")
        }
        XCTAssertEqual(oldVersion, "0.4.0")
        XCTAssertEqual(newVersion, "0.4.2")
        XCTAssertEqual(plan.arguments, ["update", "--self"])
        XCTAssertEqual(world.runner.plans.count, 1, "一次运行只执行一次命令")
        XCTAssertEqual(world.runner.plans[0].arguments, PiCLIUpdatePlan.requiredArguments)
        XCTAssertEqual(world.runner.plans[0].executablePath, piPath)
        XCTAssertEqual(world.runner.timeouts, [123])
        XCTAssertEqual(world.inspectCount, 1, "自动路径必须有执行前复查")
        XCTAssertEqual(world.runner.abandonCount, 0, "执行成功不需要放弃等待")
    }

    // MARK: - 3. 执行失败与版本验证

    private func failureResult(
        exitCode: Int32? = 1,
        timedOut: Bool = false,
        abandoned: Bool = false,
        launchFailed: Bool = false,
        stdoutTail: String? = nil,
        stderrTail: String? = nil
    ) -> PiCLIUpdateCommandResult {
        PiCLIUpdateCommandResult(
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
        let world = World(fixtureHome: fixtureHome)
        world.runner.result = { _ in self.failureResult(
            exitCode: 7,
            stderrTail: "error: EACCES \(self.fixtureHome)/.npm\nAuthorization: Bearer super-secret-value\n"
        ) }
        var outcome: PiCLIUpdateRunOutcome?
        world.makeCoordinator().run(input(installation: installation())) { outcome = $0 }
        guard case .commandFailed(let plan, let failure, let oldVersion, let targetVersion, let outputTail) = outcome else {
            return XCTFail("非零退出码必须判失败，实际是 \(String(describing: outcome))")
        }
        XCTAssertEqual(failure, .nonZeroExit)
        XCTAssertEqual(oldVersion, "0.4.0")
        XCTAssertEqual(targetVersion, "0.4.2")
        XCTAssertEqual(plan.arguments, ["update", "--self"])
        XCTAssertEqual(world.runner.plans.count, 1, "失败后不自动重试")
        XCTAssertEqual(world.detectCount, 0, "命令失败时不做版本重检测")
        // 警告记录：只说“未完成”，不声称成功、不声称回滚。
        let warning = try XCTUnwrap(outcome).warning
        XCTAssertEqual(warning?.kind, PiCLIUpdateWarning.Kind.commandFailed)
        XCTAssertEqual(warning?.oldVersion, "0.4.0")
        XCTAssertEqual(warning?.targetVersion, "0.4.2")
        XCTAssertTrue(warning?.text.contains("旧版本语义保持不变") == true)
        XCTAssertFalse(warning?.text.contains("已回滚") == true)
        // 输出尾部：有界片段 + 脱敏，凭据与 Home 前缀都不得出现。
        let tail = try XCTUnwrap(outputTail)
        XCTAssertFalse(tail.contains("super-secret-value"), "命令输出里的凭据必须脱敏")
        XCTAssertFalse(tail.contains(fixtureHome), "命令输出里的 Home 前缀必须脱敏")
        XCTAssertFalse(world.log.text.contains("super-secret-value"))
        XCTAssertFalse(world.log.text.contains(fixtureHome))
        XCTAssertTrue(world.log.text.contains("退出码 7"))
        XCTAssertTrue(world.log.text.contains("2.0 秒"))
    }

    func testTimeoutIsRecordedAsFailureAndOnlyAbandonsWaiting() {
        let world = World(fixtureHome: fixtureHome)
        world.runner.result = { _ in self.failureResult(exitCode: nil, timedOut: true) }
        var outcome: PiCLIUpdateRunOutcome?
        world.makeCoordinator().run(input(installation: installation())) { outcome = $0 }
        guard case .commandFailed(_, let failure, _, _, _) = outcome else {
            return XCTFail("超时必须判失败，实际是 \(String(describing: outcome))")
        }
        XCTAssertEqual(failure, .timedOut)
        XCTAssertTrue(failure.text.contains("没有向任何进程发送信号"))
        XCTAssertEqual(world.runner.plans.count, 1)
    }

    func testAbandonedAndLaunchFailuresAreRecorded() {
        for (result, expected, expectsSignalNote) in [
            (failureResult(exitCode: nil, abandoned: true), PiCLIUpdateCommandFailure.abandoned, true),
            (failureResult(exitCode: nil, launchFailed: true), .launchFailed, false)
        ] {
            let world = World(fixtureHome: fixtureHome)
            world.runner.result = { _ in result }
            var outcome: PiCLIUpdateRunOutcome?
            world.makeCoordinator().run(input(installation: installation())) { outcome = $0 }
            guard case .commandFailed(_, let failure, _, _, _) = outcome else {
                return XCTFail("必须判失败，实际是 \(String(describing: outcome))")
            }
            XCTAssertEqual(failure, expected)
            if expectsSignalNote {
                XCTAssertTrue(failure.text.contains("没有向任何进程发送信号"))
            } else {
                XCTAssertTrue(failure.text.contains("无法启动更新命令"))
            }
        }
    }

    func testExitZeroWithoutNewVersionIsAFailureState() {
        for detected in ["0.4.0", nil, "not-a-version"] {
            let world = World(fixtureHome: fixtureHome)
            world.detectedVersion = detected
            var outcome: PiCLIUpdateRunOutcome?
            world.makeCoordinator().run(input(installation: installation())) { outcome = $0 }
            guard case .versionUnchanged(let plan, let detectedVersion, let oldVersion, let targetVersion) = outcome else {
                return XCTFail("版本没有变化（或不可解析）必须判失败，实际是 \(String(describing: outcome))")
            }
            XCTAssertEqual(plan.arguments, ["update", "--self"])
            XCTAssertEqual(detectedVersion, detected)
            XCTAssertEqual(oldVersion, "0.4.0")
            XCTAssertEqual(targetVersion, "0.4.2")
            XCTAssertEqual(try XCTUnwrap(outcome).warning?.kind, PiCLIUpdateWarning.Kind.versionUnchanged)
            XCTAssertEqual(world.detectCount, 1)
            XCTAssertTrue(world.log.text.contains("不会自动重试无上限"))
        }
    }

    func testVersionHigherThanTargetIsSuccess() {
        let world = World(fixtureHome: fixtureHome)
        world.detectedVersion = "0.5.0"
        var outcome: PiCLIUpdateRunOutcome?
        world.makeCoordinator().run(input(installation: installation())) { outcome = $0 }
        guard case .succeeded(_, let oldVersion, let newVersion) = outcome else {
            return XCTFail("超过目标版本也算成功，实际是 \(String(describing: outcome))")
        }
        XCTAssertEqual(oldVersion, "0.4.0")
        XCTAssertEqual(newVersion, "0.5.0")
        XCTAssertNil(try XCTUnwrap(outcome).warning)
        XCTAssertTrue(world.log.text.contains("0.4.0 → 0.5.0"))
    }

    func testUpdateVerifiedSemantics() {
        XCTAssertTrue(PiCLIUpdatePlanner.updateVerified(detected: "0.4.2", old: "0.4.0", target: "0.4.2"))
        XCTAssertTrue(PiCLIUpdatePlanner.updateVerified(detected: "0.4.3", old: "0.4.0", target: "0.4.2"))
        XCTAssertFalse(PiCLIUpdatePlanner.updateVerified(detected: "0.4.1", old: "0.4.0", target: "0.4.2"))
        XCTAssertFalse(PiCLIUpdatePlanner.updateVerified(detected: nil, old: "0.4.0", target: "0.4.2"))
        XCTAssertFalse(PiCLIUpdatePlanner.updateVerified(detected: "latest", old: "0.4.0", target: "0.4.2"))
        // 没有目标版本（手动路径）：只要版本发生变化就算成功。
        XCTAssertTrue(PiCLIUpdatePlanner.updateVerified(detected: "0.4.1", old: "0.4.0", target: nil))
        XCTAssertFalse(PiCLIUpdatePlanner.updateVerified(detected: "0.4.0", old: "0.4.0", target: nil))
    }

    // MARK: - 4. 手动路径

    func testManualPlanOnlyNeedsResolvedExecutableAndVersion() {
        let manual = PiCLIUpdatePlanner.manualPlan(
            installation: installation(source: .gitCheckout, confidence: .inferred),
            targetVersion: nil
        )
        XCTAssertEqual(manual?.arguments, ["update", "--self"])
        XCTAssertNil(manual?.targetVersion)
        XCTAssertEqual(manual?.source, .gitCheckout)
        XCTAssertNil(PiCLIUpdatePlanner.manualPlan(installation: nil, targetVersion: nil))
        XCTAssertNil(PiCLIUpdatePlanner.manualPlan(installation: installation(version: nil), targetVersion: nil))
        XCTAssertNil(PiCLIUpdatePlanner.manualPlan(installation: installation(executablePath: nil), targetVersion: nil))
        XCTAssertNil(PiCLIUpdatePlanner.manualPlan(installation: installation(kind: .piWeb), targetVersion: nil))
        // 目标版本不可解析时按“未知目标”处理，不阻止手动更新。
        XCTAssertNil(
            PiCLIUpdatePlanner.manualPlan(installation: installation(), targetVersion: "latest")?.targetVersion
        )
    }

    /// 手动路径不再做进程门控（用户已经在确认框里看到进程信息并显式确认），
    /// 执行内容与自动路径完全相同。
    func testManualRunExecutesEvenWithRunningPiProcesses() throws {
        let world = World(fixtureHome: fixtureHome)
        world.detectedVersion = "0.4.2"
        let plan = try XCTUnwrap(PiCLIUpdatePlanner.manualPlan(installation: installation(), targetVersion: "0.4.2"))
        var outcome: PiCLIUpdateRunOutcome?
        world.makeCoordinator().runManual(plan) { outcome = $0 }
        guard case .succeeded(_, _, let newVersion) = outcome else {
            return XCTFail("手动路径应执行并重新检测，实际是 \(String(describing: outcome))")
        }
        XCTAssertEqual(newVersion, "0.4.2")
        XCTAssertEqual(world.runner.plans.count, 1)
        XCTAssertEqual(world.runner.plans[0].arguments, ["update", "--self"])
        XCTAssertEqual(world.inspectCount, 0, "手动路径不依赖进程检查（确认框已经展示过）")
        XCTAssertTrue(world.log.text.contains("手动更新"))
    }

    func testUnsafeExecutablePathsAreRejected() {
        let unsafe = [
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
            "/tmp/\u{2018}pi\u{2019}"
        ]
        for path in unsafe {
            XCTAssertNil(
                PiCLIUpdatePlan.make(
                    executablePath: path,
                    installedVersion: "0.4.0",
                    targetVersion: nil,
                    source: .npmGlobal,
                    confidence: .verified
                ),
                "\(path) 不应通过命令安全校验"
            )
            XCTAssertNil(PiCLIUpdatePlanner.manualCommandText(executablePath: path))
        }
        XCTAssertNil(PiCLIUpdatePlanner.manualCommandText(executablePath: nil))
        XCTAssertEqual(PiCLIUpdatePlanner.manualCommandText(executablePath: piPath), "\(piPath) update --self")
    }

    func testInvalidVersionsAreRejected() {
        XCTAssertNil(PiCLIUpdatePlan.make(
            executablePath: piPath,
            installedVersion: "latest",
            targetVersion: nil,
            source: .npmGlobal,
            confidence: .verified
        ))
        XCTAssertNil(PiCLIUpdatePlan.make(
            executablePath: piPath,
            installedVersion: "0.4.0",
            targetVersion: "0.4",
            source: .npmGlobal,
            confidence: .verified
        ))
        XCTAssertNotNil(PiCLIUpdatePlan.make(
            executablePath: piPath,
            installedVersion: "0.4.0",
            targetVersion: "0.4.2",
            source: .npmGlobal,
            confidence: .verified
        ))
    }

    func testEnvironmentWhitelistKeepsOnlySafeKeysAndPrependsPiDirectory() {
        let environment = PiCLIUpdateEnvironment.environment(
            base: [
                "PATH": "/usr/bin:/bin",
                "HOME": fixtureHome,
                "TMPDIR": "/tmp",
                "NPM_TOKEN": "npm-secret",
                "AWS_SECRET_ACCESS_KEY": "aws-secret",
                "HTTPS_PROXY": "http://proxy.example.test:3128",
                "LANG": "zh_CN.UTF-8"
            ],
            executablePath: piPath
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
    }

    // MARK: - 5. 持久警告

    func testWarningStoreRoundTripAndClearing() throws {
        let suiteName = "pi-cli-update-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertNil(PiCLIUpdateWarningStore.load(from: defaults))
        let warning = PiCLIUpdateWarning(
            kind: .commandFailed,
            oldVersion: "0.4.0",
            newVersion: "0.4.0",
            targetVersion: "0.4.2",
            reason: "更新命令以非零退出码结束",
            recordedAt: referenceDate
        )
        PiCLIUpdateWarningStore.save(warning, to: defaults)
        XCTAssertEqual(PiCLIUpdateWarningStore.load(from: defaults), warning)
        XCTAssertTrue(warning.text.contains("旧版本语义保持不变"))
        XCTAssertTrue(warning.shortText.contains("0.4.0"))

        PiCLIUpdateWarningStore.save(nil, to: defaults)
        XCTAssertNil(PiCLIUpdateWarningStore.load(from: defaults))
        for key in UpdateSettingKeys.allPiCLIUpdateWarningKeys {
            XCTAssertNil(defaults.object(forKey: key), "\(key) 应被清除")
        }
    }

    func testWarningStoreRejectsUnparsableVersions() throws {
        let suiteName = "pi-cli-update-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        PiCLIUpdateWarningStore.save(
            PiCLIUpdateWarning(kind: .versionUnchanged, oldVersion: "latest", targetVersion: "0.4.2", reason: "x"),
            to: defaults
        )
        let loaded = PiCLIUpdateWarningStore.load(from: defaults)
        XCTAssertNil(loaded?.oldVersion)
        XCTAssertEqual(loaded?.targetVersion, "0.4.2")
    }

    // MARK: - 6. 展示文案

    func testStatusPresenterShowsUncheckedStateAndDeferralReason() {
        var preferences = UpdateCheckPreferences.factoryDefaults
        let unchecked = PiCLIUpdateStatusPresenter.lines(
            preferences: preferences,
            inspection: nil,
            decision: nil,
            warning: nil
        ).joined(separator: "\n")
        XCTAssertTrue(unchecked.contains("尚未检查"))
        XCTAssertTrue(unchecked.contains("已关闭"))
        XCTAssertTrue(unchecked.contains("立即更新 Pi CLI…"))

        preferences.autoUpdatePiBeforeLaunch = true
        let request = input(
            installation: installation(),
            processes: .runningProcesses([processRecord()])
        )
        let deferred = PiCLIUpdateStatusPresenter.lines(
            preferences: preferences,
            inspection: .runningProcesses([processRecord()]),
            decision: PiCLIUpdatePlanner.decide(request),
            warning: PiCLIUpdateWarning(kind: .commandFailed, oldVersion: "0.4.0", targetVersion: "0.4.2", reason: "fixture")
        ).joined(separator: "\n")
        XCTAssertTrue(deferred.contains("检测到 1 个运行中的 Pi 进程"))
        XCTAssertTrue(deferred.contains("推迟原因"))
        XCTAssertTrue(deferred.contains("Pi CLI 更新未完成"))
    }

    func testManualConfirmationTextShowsProcessesRiskAndNoSignalPromise() {
        let text = PiCLIManualUpdateConfirmation.text(
            plan: PiCLIUpdatePlanner.manualPlan(installation: installation(), targetVersion: "0.4.2"),
            commandText: "\(piPath) update --self",
            inspection: .runningProcesses([processRecord()]),
            redactingWith: LogRedactor(homeDirectory: fixtureHome)
        )
        XCTAssertTrue(text.contains("参数数组：\"update\", \"--self\""))
        XCTAssertTrue(text.contains("进程 PID：4242"))
        XCTAssertTrue(text.contains("判定依据：真实镜像路径的可执行文件名是 pi"))
        XCTAssertTrue(text.contains("风险说明"))
        XCTAssertTrue(text.contains("不会向它们发送任何信号"))
        XCTAssertTrue(text.contains("不保证成功，也不做回滚"))
    }

    func testDecisionLogLinesAreRedacted() {
        let redactor = LogRedactor(homeDirectory: fixtureHome)
        let homeInstallation = installation(executablePath: "\(fixtureHome)/bin/pi")
        let decision = PiCLIUpdatePlanner.decide(input(installation: homeInstallation))
        let line = decision.logLine(redactingWith: redactor)
        XCTAssertFalse(line.contains(fixtureHome), "日志不得包含未脱敏的 Home 前缀")
        XCTAssertTrue(line.contains("~/bin/pi"))
        XCTAssertTrue(line.contains("update"))
    }

    // MARK: - 7. 真执行器（只执行临时目录里的假脚本）

    private final class Locked<T> {
        private let lock = NSLock()
        private var storage: T?
        var value: T? {
            get { lock.lock(); defer { lock.unlock() }; return storage }
            set { lock.lock(); storage = newValue; lock.unlock() }
        }
    }

    /// 轮询等待（替身/真执行器在内部队列回调，不用 XCTestExpectation）。
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

    private func plan(forScript script: String) throws -> PiCLIUpdatePlan {
        try XCTUnwrap(PiCLIUpdatePlan.make(
            executablePath: script,
            installedVersion: "0.4.0",
            targetVersion: "0.4.2",
            source: .npmGlobal,
            confidence: .verified
        ))
    }

    /// 真执行器：参数数组执行（脚本回显 `$@`）、退出码、stdout/stderr 尾部与耗时。
    func testRealExecutorRecordsExitCodeAndOutputTails() throws {
        let directory = try tempDirectory()
        let script = try makeFakePi(in: directory, body: "echo \"args:$@\"\necho \"to-stderr\" >&2\nexit 0")
        let command = ProcessPiCLIUpdateCommand(baseEnvironment: ["PATH": "/usr/bin:/bin", "HOME": fixtureHome])
        let box = Locked<PiCLIUpdateCommandResult>()
        command.run(try plan(forScript: script), timeout: 30) { box.value = $0 }
        let result = try XCTUnwrap(waitForValue(box, timeout: 20))
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertNil(result.failure)
        XCTAssertEqual(result.stdoutTail, "args:update --self\n", "argv 必须是参数数组 update --self")
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
        let command = ProcessPiCLIUpdateCommand(baseEnvironment: ["PATH": "/usr/bin:/bin", "HOME": fixtureHome])
        let box = Locked<PiCLIUpdateCommandResult>()
        command.run(try plan(forScript: script), timeout: 0.3) { box.value = $0 }
        let result = try XCTUnwrap(waitForValue(box, timeout: 10))
        XCTAssertEqual(result.failure, .timedOut)
        XCTAssertNil(result.exitCode)
        XCTAssertTrue(PiCLIUpdateCommandFailure.timedOut.text.contains("没有向任何进程发送信号"))
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
        let command = ProcessPiCLIUpdateCommand(baseEnvironment: ["PATH": "/usr/bin:/bin", "HOME": fixtureHome])
        let box = Locked<PiCLIUpdateCommandResult>()
        command.run(try plan(forScript: script), timeout: 30) { box.value = $0 }
        command.abandon()
        let result = try XCTUnwrap(waitForValue(box, timeout: 10))
        XCTAssertEqual(result.failure, .abandoned)
        XCTAssertTrue(waitForFile(marker.path, timeout: 10), "放弃等待不得向子进程发送信号")
    }
}
