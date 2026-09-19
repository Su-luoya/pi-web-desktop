import XCTest

/// GitHub #23：更新事务、验证、有限回滚与统一历史的 unhosted 测试。
///
/// 全部副作用都是替身：假安装器、假执行器、假文件系统探针、假健康检查。
/// 不执行真实 npm / pi、不联网、不碰真实用户目录、不枚举真实进程、不发送信号。
final class UpdateTransactionTests: XCTestCase {
    private let referenceDate = Date(timeIntervalSince1970: 1_700_000_000)
    /// 夹具“用户主目录”：只用于脱敏断言，不创建、不写入。
    private let fixtureHome = "/tmp/pi-web-update-transaction-tests-home"
    private let oldExecutable = "/tmp/pi-web-transaction-old/bin/pi-web"
    private let newExecutable = "/tmp/pi-web-transaction-new/bin/pi-web"

    // MARK: - 替身

    /// 假文件系统探针：只回答内存里登记的事实，没有任何写能力。
    private final class FakeProbe {
        var executables: Set<String> = []
        var readable: Set<String> = []
        var realPaths: [String: String] = [:]
        var sizes: [String: Int] = [:]
        var mtimes: [String: Date] = [:]
        var packageNamesAtJSON: [String: String] = [:]
        var packageNamesNear: [String: String] = [:]

        func make() -> UpdateArtifactProbe {
            UpdateArtifactProbe(
                isAvailable: true,
                isExecutableFile: { [self] path in executables.contains(path) },
                isReadableFile: { [self] path in readable.contains(path) },
                resolveRealPath: { [self] path in realPaths[path] },
                fileSize: { [self] path in sizes[path] },
                modificationDate: { [self] path in mtimes[path] },
                packageNameAtPackageJSON: { [self] path in packageNamesAtJSON[path] },
                packageNameNear: { [self] path in packageNamesNear[path] }
            )
        }
    }

    private final class HistoryRecorder {
        private(set) var entries: [UpdateHistoryEntry] = []
        func record(_ entry: UpdateHistoryEntry) { entries.append(entry) }
    }

    private final class LogSink {
        private(set) var messages: [String] = []
        func append(_ message: String) { messages.append(message) }
        var text: String { messages.joined(separator: "\n") }
    }

    private final class RecordingInstaller: PiWebUpdateInstalling {
        private(set) var plans: [PiWebUpdateInstallPlan] = []
        var result: (PiWebUpdateInstallPlan) -> PiWebUpdateInstallResult = { plan in
            PiWebUpdateInstallResult(
                exitCode: 0,
                startedAt: Date(timeIntervalSince1970: 1_700_000_000),
                finishedAt: Date(timeIntervalSince1970: 1_700_000_001)
            )
        }
        /// 安装“发生时”的副作用钩子（例如模拟旧路径被覆盖/删除）。
        var onInstall: () -> Void = {}

        func install(
            _ plan: PiWebUpdateInstallPlan,
            timeout: TimeInterval,
            completion: @escaping (PiWebUpdateInstallResult) -> Void
        ) {
            plans.append(plan)
            onInstall()
            completion(result(plan))
        }

        func cancel() {}
    }

    private final class RecordingCLIRunner: PiCLIUpdateRunning {
        private(set) var plans: [PiCLIUpdatePlan] = []
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
            completion(result(plan))
        }

        func abandon() {}
    }

    private final class RecordingPackageRunner: PiPackageUpdateRunning {
        private(set) var plans: [PiPackageUpdatePlan] = []
        var result: (PiPackageUpdatePlan) -> PiPackageUpdateCommandResult = { _ in
            PiPackageUpdateCommandResult(
                exitCode: 0,
                startedAt: Date(timeIntervalSince1970: 1_700_000_000),
                finishedAt: Date(timeIntervalSince1970: 1_700_000_001)
            )
        }

        func run(
            _ plan: PiPackageUpdatePlan,
            timeout: TimeInterval,
            completion: @escaping (PiPackageUpdateCommandResult) -> Void
        ) {
            plans.append(plan)
            completion(result(plan))
        }

        func abandon() {}
    }

    // MARK: - 夹具构造

    private func installation(
        kind: ComponentKind = .piWeb,
        packageName: String? = InstallCommandManifest.piWebPackageName,
        version: String? = "0.9.0",
        executablePath: String? = "/opt/homebrew/bin/pi-web",
        resolvedPath: String? = "/opt/homebrew/lib/node_modules/@agegr/pi-web/bin/pi-web.js",
        packageJSONPath: String? = nil,
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
            packageJSONPath: packageJSONPath,
            source: source,
            confidence: confidence,
            evidence: ["fixture"],
            suggestedCommand: InstallCommandManifest.updateGuidance(for: kind, source: source)?.command
        )
    }

    private func makePiWebPlan() throws -> PiWebUpdateInstallPlan {
        try XCTUnwrap(PiWebUpdateInstallPlan.make(
            packageName: InstallCommandManifest.piWebPackageName,
            installedVersion: "0.9.0",
            targetVersion: "0.9.2",
            npmExecutablePath: "/opt/homebrew/bin/npm",
            baseEnvironment: ["PATH": "/usr/bin:/bin", "HOME": fixtureHome],
            source: .npmGlobal,
            confidence: .verified
        ))
    }

    private func piWebInput(installation: ComponentInstallation?) -> PiWebUpdatePlanningInput {
        var preferences = UpdateCheckPreferences.factoryDefaults
        preferences.autoUpdatePiWebBeforeLaunch = true
        return PiWebUpdatePlanningInput(
            preferences: preferences,
            installation: installation,
            targetVersion: "0.9.2",
            targetStatus: .updateAvailable,
            targetConfidence: .verified,
            serviceIsRunning: false,
            npmExecutablePath: "/opt/homebrew/bin/npm",
            baseEnvironment: ["PATH": "/usr/bin:/bin"]
        )
    }

    private func transactionEnvironment(
        probe: UpdateArtifactProbe,
        history: HistoryRecorder,
        degradedPlans: @escaping (UpdateDegradationPlan) -> Void = { _ in }
    ) -> UpdateTransactionEnvironment {
        UpdateTransactionEnvironment(
            probe: probe,
            recordHistory: { entry in history.record(entry) },
            applyDegradation: degradedPlans,
            now: { self.referenceDate }
        )
    }

    // MARK: - 1. 全流程成功路径

    func testSuccessfulTransactionRecordsPreflightInstallVerifyCommit() throws {
        let probe = FakeProbe()
        let fingerprintPath = oldExecutable
        probe.executables.insert(fingerprintPath)
        probe.readable.insert(fingerprintPath)
        probe.realPaths[fingerprintPath] = fingerprintPath
        probe.sizes[fingerprintPath] = 4096
        probe.mtimes[fingerprintPath] = referenceDate
        probe.packageNamesNear[fingerprintPath] = InstallCommandManifest.piWebPackageName

        var journal = UpdateTransactionJournal(
            configuration: UpdateTransactionJournal.Configuration(
                component: .piWeb,
                source: .npmGlobal,
                previousVersion: "0.9.0",
                targetVersion: "0.9.2",
                fingerprint: UpdateArtifactFingerprint.capture(
                    installation: installation(
                        version: "0.9.0",
                        executablePath: fingerprintPath,
                        resolvedPath: fingerprintPath
                    ),
                    probe: probe.make()
                )
            ),
            now: { self.referenceDate }
        )
        XCTAssertEqual(journal.recordPreflight().version, "0.9.0")
        journal.recordInstallSucceeded()

        let report = UpdateVerifier.report(
            UpdateVerifier.verify(
                UpdateVerificationInput(
                    component: .piWeb,
                    packageName: InstallCommandManifest.piWebPackageName,
                    previousVersion: "0.9.0",
                    targetVersion: "0.9.2",
                    detectedVersion: "0.9.2",
                    detectedPackageName: InstallCommandManifest.piWebPackageName,
                    detectedExecutablePath: fingerprintPath,
                    detectedResolvedPath: fingerprintPath,
                    detectedPackageJSONPath: nil,
                    fingerprint: journal.configuration.fingerprint
                ),
                probe: probe.make()
            ),
            healthCheck: .passed
        )
        XCTAssertTrue(report.isVerified)
        XCTAssertTrue(journal.recordVerification(report, detectedVersion: "0.9.2"))
        journal.recordDegradationNotNeeded()
        journal.recordCommit(version: "0.9.2")

        XCTAssertEqual(journal.phases.map(\.phase), [.preflight, .install, .verify, .degrade, .commit])
        XCTAssertEqual(journal.phases.map(\.status), [.succeeded, .succeeded, .succeeded, .skipped, .succeeded])
        XCTAssertEqual(journal.completedPhase, .commit)

        let entry = journal.historyEntry(
            degradation: nil,
            advice: UpdateManualAdviceBuilder.advice(component: .piWeb, source: .npmGlobal)
        )
        XCTAssertTrue(entry.isSuccessful)
        XCTAssertEqual(entry.fromVersion, "0.9.0")
        XCTAssertEqual(entry.toVersion, "0.9.2")
        XCTAssertNil(entry.degradationKind)
        XCTAssertNil(entry.failureReason)
        XCTAssertTrue(entry.phases.first { $0.phase == .commit }?.reason.contains("不做自动卸载") == true)
        XCTAssertEqual(UpdateHistoryPresenter.lines(for: entry).first?.contains("最近一次更新"), true)
    }

    func testCoordinatorSuccessPathRecordsHistoryAndProbeLayers() throws {
        let probe = FakeProbe()
        probe.executables.insert(newExecutable)
        probe.readable.insert(newExecutable)
        probe.realPaths[newExecutable] = newExecutable
        probe.sizes[newExecutable] = 8192
        probe.mtimes[newExecutable] = referenceDate
        probe.packageNamesNear[newExecutable] = InstallCommandManifest.piWebPackageName
        let history = HistoryRecorder()
        let world = RecordingInstaller()
        let log = LogSink()
        let preflight = installation(
            version: "0.9.0",
            executablePath: newExecutable,
            resolvedPath: newExecutable
        )
        let postflight = installation(
            version: "0.9.2",
            executablePath: newExecutable,
            resolvedPath: newExecutable
        )
        let coordinator = PiWebUpdateCoordinator(environment: PiWebUpdateCoordinator.Environment(
            installer: world,
            detectInstallation: { postflight },
            startServiceAndCheckHealth: { completion in completion(true) },
            redactor: LogRedactor(homeDirectory: self.fixtureHome),
            log: { log.append($0) },
            deliver: { work in work() },
            timeout: 60,
            transaction: transactionEnvironment(probe: probe.make(), history: history)
        ))
        var outcome: PiWebUpdateRunOutcome?
        coordinator.run(piWebInput(installation: preflight)) { outcome = $0 }

        XCTAssertEqual(outcome?.isSucceeded, true)
        XCTAssertEqual(world.plans.count, 1)
        let entry = try XCTUnwrap(history.entries.first)
        XCTAssertTrue(entry.isSuccessful)
        XCTAssertEqual(entry.component.kind, .piWeb)
        XCTAssertEqual(entry.source, .npmGlobal)
        XCTAssertEqual(entry.fromVersion, "0.9.0")
        XCTAssertEqual(entry.toVersion, "0.9.2")
        XCTAssertEqual(entry.completedPhase, .commit)
        XCTAssertNil(entry.degradationKind)
        XCTAssertFalse(log.text.contains(fixtureHome))
    }

    // MARK: - 2. 验证能力边界

    func testVerifierCoversFiveLayersAndWritesCapabilityBoundaries() throws {
        let probe = FakeProbe()
        probe.executables.insert(newExecutable)
        probe.readable.insert(newExecutable)
        probe.realPaths[newExecutable] = newExecutable
        probe.packageNamesAtJSON["/tmp/pi-web/package.json"] = InstallCommandManifest.piWebPackageName
        let report = UpdateVerifier.verify(
            UpdateVerificationInput(
                component: .piWeb,
                packageName: InstallCommandManifest.piWebPackageName,
                previousVersion: "0.9.0",
                targetVersion: "0.9.2",
                detectedVersion: "0.9.2",
                detectedPackageName: nil,
                detectedExecutablePath: newExecutable,
                detectedResolvedPath: newExecutable,
                detectedPackageJSONPath: "/tmp/pi-web/package.json",
                fingerprint: UpdateArtifactFingerprint.versionOnly(version: "0.9.0", packageName: nil)
            ),
            probe: probe.make()
        )
        XCTAssertEqual(report.checks.map(\.check), UpdateVerificationCheck.allCases)
        XCTAssertEqual(report.result(for: .executablePresent)?.status, .passed)
        XCTAssertEqual(report.result(for: .realPathReadable)?.status, .passed)
        XCTAssertEqual(report.result(for: .versionReached)?.status, .passed)
        XCTAssertEqual(report.result(for: .packageIdentity)?.status, .passed)
        XCTAssertEqual(report.result(for: .healthCheck)?.status, .notChecked)
        XCTAssertTrue(report.isVerified, "健康检查未运行时，其余检查都通过仍算通过（健康检查不会被当作通过，由调用方补）")
        for check in UpdateVerificationCheck.allCases {
            XCTAssertFalse(check.capabilityBoundary.isEmpty)
        }
        XCTAssertTrue(UpdateVerificationCheck.notVerifiedCapabilities.contains { $0.contains("代码签名") })
        XCTAssertTrue(UpdateVerificationCheck.notVerifiedCapabilities.contains { $0.contains("官方签名") })
    }

    func testDisabledProbeReportsFileLayersAsNotCheckedNotPassed() throws {
        let report = UpdateVerifier.verify(
            UpdateVerificationInput(
                component: .piWeb,
                packageName: InstallCommandManifest.piWebPackageName,
                previousVersion: "0.9.0",
                targetVersion: "0.9.2",
                detectedVersion: "0.9.2",
                detectedPackageName: InstallCommandManifest.piWebPackageName,
                detectedExecutablePath: newExecutable,
                detectedResolvedPath: nil,
                detectedPackageJSONPath: nil,
                fingerprint: UpdateArtifactFingerprint.versionOnly(version: "0.9.0", packageName: nil)
            ),
            probe: .disabled
        )
        XCTAssertEqual(report.result(for: .executablePresent)?.status, .notChecked)
        XCTAssertEqual(report.result(for: .realPathReadable)?.status, .notChecked)
        XCTAssertEqual(report.result(for: .versionReached)?.status, .passed)
        // 文件层未验证不会伪装成通过：报告里明确写“未验证”，也不会因此把整体
        // 判定为失败（版本与身份层已经验证）。
        XCTAssertTrue(report.isVerified)
        XCTAssertTrue(report.summaryLines.contains { $0.contains("未验证") })
    }

    // MARK: - 3. install 失败：状态未变、历史语义、无成功报告

    func testInstallFailureKeepsStateAndRecordsNoSuccess() throws {
        let probe = FakeProbe()
        probe.executables.insert(newExecutable)
        probe.readable.insert(newExecutable)
        probe.realPaths[newExecutable] = newExecutable
        probe.sizes[newExecutable] = 100
        probe.mtimes[newExecutable] = referenceDate
        let history = HistoryRecorder()
        let world = RecordingInstaller()
        world.result = { _ in
            PiWebUpdateInstallResult(
                exitCode: 3,
                startedAt: Date(timeIntervalSince1970: 1_700_000_000),
                finishedAt: Date(timeIntervalSince1970: 1_700_000_001)
            )
        }
        let log = LogSink()
        let coordinator = PiWebUpdateCoordinator(environment: PiWebUpdateCoordinator.Environment(
            installer: world,
            detectInstallation: { XCTFail("安装失败时不得重新检测版本"); return nil },
            startServiceAndCheckHealth: { _ in XCTFail("安装失败时不得启动服务") },
            redactor: LogRedactor(homeDirectory: self.fixtureHome),
            log: { log.append($0) },
            deliver: { work in work() },
            timeout: 60,
            transaction: transactionEnvironment(probe: probe.make(), history: history)
        ))
        var outcome: PiWebUpdateRunOutcome?
        coordinator.run(piWebInput(installation: installation(
            version: "0.9.0",
            executablePath: newExecutable,
            resolvedPath: newExecutable
        ))) { outcome = $0 }

        XCTAssertEqual(outcome?.isSucceeded, false)
        let entry = try XCTUnwrap(history.entries.first)
        XCTAssertFalse(entry.isSuccessful)
        XCTAssertEqual(entry.completedPhase, .preflight)
        XCTAssertEqual(entry.terminationPhase, .degrade)
        XCTAssertEqual(entry.degradationKind, .installFailedKeepingPreviousVersion)
        XCTAssertEqual(entry.fromVersion, "0.9.0")
        XCTAssertNil(entry.toVersion)
        XCTAssertEqual(entry.phases.first { $0.phase == .install }?.status, .failed)
        XCTAssertEqual(entry.phases.first { $0.phase == .commit }?.status, .notAttempted)
        XCTAssertTrue(entry.failureReason?.contains("非零退出码") == true)
        XCTAssertTrue(entry.rollbackDescription?.contains("未尝试回滚") == true)
        XCTAssertFalse(log.text.contains(fixtureHome))
    }

    // MARK: - 4. verify 失败与降级

    func testVersionUnchangedIsStillUsingPreviousArtifact() throws {
        let probe = FakeProbe()
        probe.executables.insert(newExecutable)
        probe.sizes[newExecutable] = 100
        probe.mtimes[newExecutable] = referenceDate
        let plan = UpdateDegradationPlanner.verificationFailure(
            component: .piWeb,
            source: .npmGlobal,
            fingerprint: UpdateArtifactFingerprint(
                executablePath: newExecutable,
                resolvedPath: newExecutable,
                version: "0.9.0",
                packageName: InstallCommandManifest.piWebPackageName,
                fileSize: 100,
                modifiedAt: referenceDate
            ),
            newVersion: "0.9.0",
            newResolvedPath: newExecutable,
            failureReason: "版本重新检测达到目标失败：重新检测到 0.9.0（更新前 0.9.0；版本需达到目标）",
            probe: probe.make()
        )
        XCTAssertEqual(plan.kind, .stillUsingPreviousArtifact)
        XCTAssertEqual(plan.rollbackEligibility, .alreadyOnPreviousArtifact)
        XCTAssertFalse(plan.performedAutomaticDegradation)
        XCTAssertTrue(plan.warningText.contains("仍在使用更新前的版本"))
        XCTAssertTrue(plan.warningText.contains("0.9.0"))
    }

    func testIdentityMismatchFailsPackageIdentityCheck() throws {
        let probe = FakeProbe()
        probe.executables.insert(newExecutable)
        probe.readable.insert(newExecutable)
        probe.realPaths[newExecutable] = newExecutable
        let report = UpdateVerifier.verify(
            UpdateVerificationInput(
                component: .piWeb,
                packageName: InstallCommandManifest.piWebPackageName,
                previousVersion: "0.9.0",
                targetVersion: "0.9.2",
                detectedVersion: "0.9.2",
                detectedPackageName: "left-pad",
                detectedExecutablePath: newExecutable,
                detectedResolvedPath: newExecutable,
                detectedPackageJSONPath: nil,
                fingerprint: UpdateArtifactFingerprint.versionOnly(version: "0.9.0", packageName: nil)
            ),
            probe: probe.make()
        )
        XCTAssertEqual(report.result(for: .packageIdentity)?.status, .failed)
        XCTAssertFalse(report.isVerified)
        XCTAssertTrue(report.failureReason?.contains("包名") == true)

        let plan = UpdateDegradationPlanner.verificationFailure(
            component: .piWeb,
            source: .npmGlobal,
            fingerprint: UpdateArtifactFingerprint(
                executablePath: newExecutable,
                resolvedPath: newExecutable,
                version: "0.9.0",
                packageName: InstallCommandManifest.piWebPackageName,
                fileSize: nil,
                modifiedAt: nil
            ),
            newVersion: "0.9.2",
            newResolvedPath: newExecutable,
            failureReason: report.failureReason ?? "",
            probe: probe.make()
        )
        // 路径未变且指纹一致（无 size/mtime 记录）：仍按“仍在更新前的文件上”处理。
        XCTAssertEqual(plan.kind, .stillUsingPreviousArtifact)
    }

    func testHealthCheckFailureDegradesToRetainedPreviousExecutable() throws {
        let probe = FakeProbe()
        probe.executables.formUnion([oldExecutable, newExecutable])
        probe.readable.formUnion([oldExecutable, newExecutable])
        probe.realPaths[oldExecutable] = oldExecutable
        probe.realPaths[newExecutable] = newExecutable
        probe.sizes[oldExecutable] = 100
        probe.mtimes[oldExecutable] = referenceDate
        probe.packageNamesNear[newExecutable] = InstallCommandManifest.piWebPackageName

        let history = HistoryRecorder()
        let applied = NSMutableArray()
        let world = RecordingInstaller()
        let log = LogSink()
        let coordinator = PiWebUpdateCoordinator(environment: PiWebUpdateCoordinator.Environment(
            installer: world,
            detectInstallation: {
                self.installation(
                    version: "0.9.2",
                    executablePath: self.newExecutable,
                    resolvedPath: self.newExecutable
                )
            },
            startServiceAndCheckHealth: { completion in completion(false) },
            redactor: LogRedactor(homeDirectory: self.fixtureHome),
            log: { log.append($0) },
            deliver: { work in work() },
            timeout: 60,
            transaction: transactionEnvironment(
                probe: probe.make(),
                history: history,
                degradedPlans: { applied.add($0) }
            )
        ))
        var outcome: PiWebUpdateRunOutcome?
        coordinator.run(piWebInput(installation: installation(
            version: "0.9.0",
            executablePath: oldExecutable,
            resolvedPath: oldExecutable
        ))) { outcome = $0 }

        XCTAssertEqual(outcome?.isSucceeded, false)
        let entry = try XCTUnwrap(history.entries.first)
        XCTAssertEqual(entry.degradationKind, .degradedToPreviousArtifact)
        XCTAssertEqual(entry.completedPhase, .install)
        XCTAssertEqual(entry.phases.first { $0.phase == .verify }?.status, .failed)
        XCTAssertEqual(entry.rollbackDescription?.contains("已降级"), true)
        let plan = try XCTUnwrap(applied.firstObject as? UpdateDegradationPlan)
        XCTAssertEqual(plan.kind, .degradedToPreviousArtifact)
        XCTAssertEqual(plan.restoredExecutablePath, oldExecutable)
        XCTAssertEqual(plan.restoredVersion, "0.9.0")
        XCTAssertTrue(plan.warningText.contains("已降级"))
        XCTAssertFalse(plan.warningText.contains(oldExecutable), "警告文本不得包含本机绝对路径")
        XCTAssertFalse(log.text.contains(oldExecutable))
        XCTAssertFalse(log.text.contains(fixtureHome))
    }

    // MARK: - 5. 证据消失 → 无法自动回滚

    func testEvidenceGoneCannotRollbackAndProducesNoWrongCommand() throws {
        let probe = FakeProbe()
        probe.executables.formUnion([oldExecutable, newExecutable])
        probe.realPaths[newExecutable] = newExecutable
        probe.sizes[oldExecutable] = 100
        probe.mtimes[oldExecutable] = referenceDate
        // 旧路径在版本指纹里记录为 100 字节；这里模拟安装覆盖后变成另一个大小。
        let staleFingerprint = UpdateArtifactFingerprint(
            executablePath: oldExecutable,
            resolvedPath: oldExecutable,
            version: "0.9.0",
            packageName: InstallCommandManifest.piWebPackageName,
            fileSize: 100,
            modifiedAt: referenceDate
        )
        probe.sizes[oldExecutable] = 200

        let plan = UpdateDegradationPlanner.verificationFailure(
            component: .piWeb,
            source: .npmGlobal,
            fingerprint: staleFingerprint,
            newVersion: "0.9.2",
            newResolvedPath: newExecutable,
            failureReason: "版本重新检测达到目标失败",
            probe: probe.make()
        )
        XCTAssertEqual(plan.kind, .cannotAutomaticallyRollback)
        XCTAssertEqual(plan.rollbackEligibility, .evidenceChangedOrMissing)
        XCTAssertFalse(plan.performedAutomaticDegradation)
        XCTAssertNil(plan.restoredExecutablePath)
        XCTAssertTrue(plan.warningText.contains("无法自动回滚"))
        XCTAssertTrue(plan.reason.contains("已被覆盖"))
        XCTAssertFalse(plan.warningText.contains(oldExecutable))
        XCTAssertFalse(plan.reason.contains(oldExecutable))
        // 手动建议来自静态清单，不可能指向本机路径。
        XCTAssertEqual(plan.manualAdvice.commandText, InstallCommandManifest.updateNPMPiWeb.command)
        XCTAssertFalse(plan.manualAdvice.commandText?.contains(oldExecutable) == true)
    }

    // MARK: - 6. 非 npm 来源：从不回滚，只提示与命令文本

    func testNonNPMGlobalSourcesNeverRollback() throws {
        let probe = FakeProbe()
        probe.executables.insert(oldExecutable)
        probe.sizes[oldExecutable] = 100
        probe.mtimes[oldExecutable] = referenceDate
        let fingerprint = UpdateArtifactFingerprint(
            executablePath: oldExecutable,
            resolvedPath: oldExecutable,
            version: "0.9.0",
            packageName: InstallCommandManifest.piWebPackageName,
            fileSize: 100,
            modifiedAt: referenceDate
        )
        let sources: [InstallSource] = [.pnpmGlobal, .homebrew, .nvm, .mise, .gitCheckout, .localPath, .unknown]
        for source in sources {
            let plan = UpdateDegradationPlanner.verificationFailure(
                component: .piWeb,
                source: source,
                fingerprint: fingerprint,
                newVersion: "0.9.2",
                newResolvedPath: newExecutable,
                failureReason: "验证失败",
                probe: probe.make()
            )
            XCTAssertEqual(plan.kind, .cannotAutomaticallyRollback, "\(source) 不得自动回滚")
            XCTAssertEqual(plan.rollbackEligibility, .sourceDoesNotSupportRollback)
            XCTAssertFalse(plan.performedAutomaticDegradation)
            XCTAssertNil(plan.restoredExecutablePath)
            XCTAssertTrue(plan.warningText.contains("无法自动回滚"), "\(source) 警告必须写明无法自动回滚")
            XCTAssertTrue(plan.reason.contains(source.displayName))
            XCTAssertFalse(plan.manualAdvice.guidanceText.isEmpty)
            if source == .pnpmGlobal {
                XCTAssertEqual(plan.manualAdvice.commandText, InstallCommandManifest.updatePNPMPiWeb.command)
            } else {
                XCTAssertNil(plan.manualAdvice.commandText, "\(source) 不应给出包管理器命令")
            }
        }
    }

    // MARK: - 7. 历史存储：脱敏、校验、上限

    func testHistoryStoreRoundTripsSanitizesAndRedacts() throws {
        let suiteName = "pi-web-desktop-update-transaction-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let entry = UpdateHistoryEntry(
            recordedAt: referenceDate,
            component: .piWeb,
            source: .npmGlobal,
            fromVersion: "0.9.0",
            toVersion: "0.9.2",
            completedPhase: .commit,
            terminationPhase: .commit,
            phases: [
                UpdateTransactionPhaseResult(
                    phase: .preflight,
                    status: .succeeded,
                    reason: "已记录更新前指纹；不读取凭据",
                    recordedAt: referenceDate
                ),
                UpdateTransactionPhaseResult(
                    phase: .commit,
                    status: .succeeded,
                    reason: "已启用新版本 0.9.2；不做自动卸载",
                    recordedAt: referenceDate
                )
            ],
            degradationKind: nil,
            failureReason: nil,
            manualCommandText: InstallCommandManifest.updateNPMPiWeb.command,
            manualGuidanceText: InstallCommandManifest.updateNPMPiWeb.note,
            rollbackDescription: nil
        )
        UpdateHistoryStore.record(entry, to: defaults)
        let loaded = UpdateHistoryStore.load(from: defaults)
        XCTAssertEqual(loaded, [entry])

        let data = try XCTUnwrap(defaults.data(forKey: UpdateSettingKeys.updateHistory))
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertFalse(text.contains(fixtureHome))
        for secret in ["password", "token", "secret", "Bearer", "NODE_OPTIONS"] {
            XCTAssertFalse(text.lowercased().contains(secret.lowercased()), "历史不得包含 \(secret)")
        }
        XCTAssertFalse(text.contains("/opt/homebrew"), "历史不得包含本机绝对路径")
    }

    func testHistoryStoreCapsEntriesAndDropsInvalidStoredFields() throws {
        let suiteName = "pi-web-desktop-update-transaction-cap-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        for index in 0..<(UpdateHistoryStore.maximumEntries + 5) {
            let entry = UpdateHistoryEntry(
                recordedAt: referenceDate.addingTimeInterval(TimeInterval(index)),
                component: .piCLI,
                source: .npmGlobal,
                fromVersion: "0.4.\(index)",
                toVersion: nil,
                completedPhase: .install,
                terminationPhase: .install,
                phases: [],
                degradationKind: .installFailedKeepingPreviousVersion,
                failureReason: "更新失败，仍在使用旧版本",
                manualCommandText: nil,
                manualGuidanceText: "请按来源文档手动处理。",
                rollbackDescription: "安装失败，系统状态未改变，未尝试回滚"
            )
            UpdateHistoryStore.record(entry, to: defaults)
        }
        let loaded = UpdateHistoryStore.load(from: defaults)
        XCTAssertEqual(loaded.count, UpdateHistoryStore.maximumEntries)
        XCTAssertEqual(loaded.first?.recordedAt, referenceDate.addingTimeInterval(
            TimeInterval(UpdateHistoryStore.maximumEntries + 4)
        ), "最新记录必须排在最前")

        // 手工写入非法版本与超长文本：读取时被丢弃/截断，不进入诊断展示。
        let handcrafted = Data("""
        [{"recordedAt":0,"componentKind":"pi","packageName":"","source":"npm-global",
          "fromVersion":"not-a-version","toVersion":null,"completedPhase":"nonsense",
          "terminationPhase":null,"phases":[{"phase":"verify","status":"failed",
          "reason":"x","recordedAt":0}],"degradationKind":null,"failureReason":null,
          "manualCommandText":null,"manualGuidanceText":null,"rollbackDescription":null}]
        """.utf8)
        let decoded = UpdateHistoryStore.decode(handcrafted)
        XCTAssertEqual(decoded?.count, 1)
        XCTAssertNil(decoded?.first?.fromVersion)
        XCTAssertNil(decoded?.first?.completedPhase)
        XCTAssertEqual(decoded?.first?.phases.count, 1)

        UpdateHistoryStore.clear(from: defaults)
        XCTAssertTrue(UpdateHistoryStore.load(from: defaults).isEmpty)
    }

    func testCoordinatorHistoryAndLogsRedactHomeSecretsAndEnvironmentValues() throws {
        let probe = FakeProbe()
        probe.executables.insert(newExecutable)
        probe.readable.insert(newExecutable)
        probe.realPaths[newExecutable] = newExecutable
        probe.packageNamesNear[newExecutable] = InstallCommandManifest.piWebPackageName
        let history = HistoryRecorder()
        let world = RecordingInstaller()
        let log = LogSink()
        let coordinator = PiWebUpdateCoordinator(environment: PiWebUpdateCoordinator.Environment(
            installer: world,
            detectInstallation: {
                self.installation(
                    version: "0.9.2",
                    executablePath: self.newExecutable,
                    resolvedPath: self.newExecutable
                )
            },
            startServiceAndCheckHealth: { completion in completion(true) },
            redactor: LogRedactor(homeDirectory: self.fixtureHome),
            log: { log.append($0) },
            deliver: { work in work() },
            timeout: 60,
            transaction: transactionEnvironment(probe: probe.make(), history: history)
        ))
        var preferences = UpdateCheckPreferences.factoryDefaults
        preferences.autoUpdatePiWebBeforeLaunch = true
        let input = PiWebUpdatePlanningInput(
            preferences: preferences,
            installation: installation(
                version: "0.9.0",
                executablePath: self.newExecutable,
                resolvedPath: self.newExecutable
            ),
            targetVersion: "0.9.2",
            targetStatus: .updateAvailable,
            targetConfidence: .verified,
            serviceIsRunning: false,
            npmExecutablePath: "/opt/homebrew/bin/npm",
            baseEnvironment: [
                "PATH": "/usr/bin:/bin",
                "HOME": self.fixtureHome,
                "PI_WEB_PASSWORD": "super-secret-value",
                "AWS_SECRET_ACCESS_KEY": "aws-secret",
                "NODE_OPTIONS": "--require /tmp/evil.js"
            ]
        )
        var outcome: PiWebUpdateRunOutcome?
        coordinator.run(input) { outcome = $0 }
        XCTAssertEqual(outcome?.isSucceeded, true)

        let entry = try XCTUnwrap(history.entries.first)
        let historyData = try XCTUnwrap(UpdateHistoryStore.encode([entry]))
        let historyText = try XCTUnwrap(String(data: historyData, encoding: .utf8))
        for forbidden in [
            self.fixtureHome, "super-secret-value", "aws-secret", "--require /tmp/evil.js",
            "PI_WEB_PASSWORD", "AWS_SECRET_ACCESS_KEY", "NODE_OPTIONS"
        ] {
            XCTAssertFalse(log.text.contains(forbidden), "日志不得包含 \(forbidden)")
            XCTAssertFalse(historyText.contains(forbidden), "历史不得包含 \(forbidden)")
        }
        // 历史里不得出现任何本机绝对路径。
        for forbidden in ["/opt/homebrew", "/tmp/pi-web"] {
            XCTAssertFalse(historyText.contains(forbidden), "历史不得包含路径 \(forbidden)")
        }
    }

    // MARK: - 8. 参数数组与信号负向断言

    func testArgumentArraysContainNoShellMetacharactersOrSudo() throws {
        let webPlan = try makePiWebPlan()
        XCTAssertTrue(PiWebUpdateArgumentPolicy.isSafe(webPlan.arguments))
        for argument in webPlan.arguments { XCTAssertFalse(argument.contains("sudo")) }

        let cliPlan = try XCTUnwrap(PiCLIUpdatePlan.make(
            executablePath: "/opt/homebrew/bin/pi",
            installedVersion: "0.4.0",
            targetVersion: "0.4.2",
            source: .npmGlobal,
            confidence: .verified
        ))
        XCTAssertEqual(cliPlan.arguments, PiCLIUpdatePlan.requiredArguments)
        XCTAssertFalse(cliPlan.arguments.contains { $0.contains("sudo") || $0.contains("sh") })

        let packagePlan = try XCTUnwrap(PiPackageUpdatePlan.make(
            executablePath: "/opt/homebrew/bin/pi",
            packageName: "@scope/pi-extension",
            installedVersion: "1.0.0",
            targetVersion: "1.1.0",
            source: .npmGlobal,
            confidence: .verified
        ))
        XCTAssertTrue(PiPackageUpdateArgumentPolicy.isSafe(packagePlan.arguments))
        for argument in packagePlan.arguments {
            XCTAssertFalse(argument.contains("sudo"))
            XCTAssertFalse(argument.unicodeScalars.contains { ";&|$`()<>*?!\n".unicodeScalars.contains($0) })
        }
    }

    /// 仓库根目录（测试文件位于 `<root>/PiWebDesktopTests/`）。
    /// 在仓库内运行时用 `#filePath` 推导；在本地无 Xcode 的独立运行器里则
    /// 回退到当前工作目录，保证同一断言两种环境都能执行。
    private func repositoryRoot() -> URL {
        let derived = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        if FileManager.default.fileExists(atPath: derived.appendingPathComponent("Sources/UpdateTransaction.swift").path) {
            return derived
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    }

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

    func testFrameworkAndCLIAndPackageSourcesContainNoSignalOrShellAPIs() throws {
        let forbidden = [
            "kill(", "killpg(", "raise(", "signal(", "SIGTERM", "SIGKILL", "SIGINT",
            ".terminate(", ".interrupt(", "posix_spawn", "/bin/sh", "/bin/bash", "shellPath",
            "sudo(", "sudo -"
        ]
        for relativePath in [
            "Sources/UpdateTransaction.swift",
            "Sources/UpdateVerifier.swift",
            "Sources/PiCLIUpdateAdapter.swift",
            "Sources/PiPackageUpdateAdapter.swift"
        ] {
            let code = codeText(of: try String(
                contentsOf: repositoryRoot().appendingPathComponent(relativePath),
                encoding: .utf8
            ))
            for token in forbidden {
                XCTAssertFalse(code.contains(token), "\(relativePath) 的代码里不得出现 \(token)")
            }
        }
    }

    func testDegradationPlannerExecutionHasNoUninstallOrFileMutationAPIs() throws {
        let code = codeText(of: try String(
            contentsOf: repositoryRoot().appendingPathComponent("Sources/UpdateTransaction.swift"),
            encoding: .utf8
        ))
        for token in ["removeItem", "moveItem", "copyItem", "createFile", "uninstall", "sudo"] {
            XCTAssertFalse(code.contains(token), "UpdateTransaction.swift 不得出现 \(token)")
        }
    }

    // MARK: - 9. Pi CLI / 扩展包接入同一框架

    func testPiCLICoordinatorRecordsHistoryOnSuccess() throws {
        let probe = FakeProbe()
        probe.executables.insert("/opt/homebrew/bin/pi")
        probe.readable.insert("/opt/homebrew/bin/pi")
        probe.realPaths["/opt/homebrew/bin/pi"] = "/opt/homebrew/bin/pi"
        probe.packageNamesNear["/opt/homebrew/bin/pi"] = InstallCommandManifest.piCLIPackageName
        let history = HistoryRecorder()
        let runner = RecordingCLIRunner()
        let log = LogSink()
        var preferences = UpdateCheckPreferences.factoryDefaults
        preferences.autoUpdatePiBeforeLaunch = true
        let coordinator = PiCLIUpdateCoordinator(environment: PiCLIUpdateCoordinator.Environment(
            inspectProcesses: { .noProcesses },
            runner: runner,
            detectInstallation: {
                self.installation(
                    kind: .piCLI,
                    packageName: InstallCommandManifest.piCLIPackageName,
                    version: "0.4.2",
                    executablePath: "/opt/homebrew/bin/pi",
                    resolvedPath: "/opt/homebrew/bin/pi"
                )
            },
            redactor: LogRedactor(homeDirectory: self.fixtureHome),
            log: { log.append($0) },
            deliver: { work in work() },
            timeout: 600,
            transaction: transactionEnvironment(probe: probe.make(), history: history)
        ))
        var outcome: PiCLIUpdateRunOutcome?
        coordinator.run(PiCLIUpdatePlanningInput(
            preferences: preferences,
            installation: installation(
                kind: .piCLI,
                packageName: InstallCommandManifest.piCLIPackageName,
                version: "0.4.0",
                executablePath: "/opt/homebrew/bin/pi",
                resolvedPath: "/opt/homebrew/bin/pi"
            ),
            targetVersion: "0.4.2",
            targetStatus: .updateAvailable,
            targetConfidence: .verified,
            processes: .noProcesses
        )) { outcome = $0 }

        XCTAssertEqual(outcome?.isSucceeded, true)
        let entry = try XCTUnwrap(history.entries.first)
        XCTAssertEqual(entry.component.kind, .piCLI)
        XCTAssertTrue(entry.isSuccessful)
        XCTAssertEqual(entry.completedPhase, .commit)
        XCTAssertFalse(log.text.contains(fixtureHome))
    }

    func testPiPackageCoordinatorNeverRollsBackAndGivesGuidance() throws {
        let probe = FakeProbe()
        let history = HistoryRecorder()
        let runner = RecordingPackageRunner()
        runner.result = { _ in
            PiPackageUpdateCommandResult(
                exitCode: 1,
                startedAt: Date(timeIntervalSince1970: 1_700_000_000),
                finishedAt: Date(timeIntervalSince1970: 1_700_000_001)
            )
        }
        let log = LogSink()
        let coordinator = PiPackageUpdateCoordinator(environment: PiPackageUpdateCoordinator.Environment(
            inspectProcesses: { .noProcesses },
            runner: runner,
            detectPackageVersion: { _ in "1.0.0" },
            redactor: LogRedactor(homeDirectory: self.fixtureHome),
            log: { log.append($0) },
            deliver: { work in work() },
            timeout: 600,
            transaction: transactionEnvironment(probe: probe.make(), history: history)
        ))
        let plan = try XCTUnwrap(PiPackageUpdatePlan.make(
            executablePath: "/opt/homebrew/bin/pi",
            packageName: "@scope/pi-extension",
            installedVersion: "1.0.0",
            targetVersion: "1.1.0",
            source: .npmGlobal,
            confidence: .verified
        ))
        var outcome: PiPackageUpdateBatchOutcome?
        coordinator.runConfirmed([plan]) { outcome = $0 }

        XCTAssertEqual(outcome?.isSucceeded, false)
        let entry = try XCTUnwrap(history.entries.first)
        XCTAssertEqual(entry.component.kind, .piPackage)
        XCTAssertEqual(entry.component.packageName, "@scope/pi-extension")
        XCTAssertEqual(entry.degradationKind, .installFailedKeepingPreviousVersion)
        XCTAssertFalse(entry.isSuccessful)
        // 扩展包没有独立可执行文件路径证据：不可能出现自动回滚。
        XCTAssertNotEqual(entry.degradationKind, .degradedToPreviousArtifact)
        XCTAssertNil(entry.manualCommandText, "扩展包不得给出动态命令")
        XCTAssertFalse(entry.manualGuidanceText?.isEmpty ?? true)
    }

    func testPackageVerificationFailureCannotRollbackWithoutPathEvidence() throws {
        let probe = FakeProbe()
        let plan = UpdateDegradationPlanner.verificationFailure(
            component: .piPackage("@scope/pi-extension"),
            source: .npmGlobal,
            fingerprint: UpdateArtifactFingerprint.versionOnly(version: "1.0.0", packageName: "@scope/pi-extension"),
            newVersion: "1.0.0",
            newResolvedPath: nil,
            failureReason: "版本未达到目标",
            probe: probe.make()
        )
        // 版本未变化：如实报告“仍在使用更新前的版本”，不移动任何文件。
        XCTAssertEqual(plan.kind, .stillUsingPreviousArtifact)
        XCTAssertFalse(plan.performedAutomaticDegradation)
    }
}
