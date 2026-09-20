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
        /// GitHub #63：inode、内容哈希与 npm `integrity` 同样只回答登记值。
        var inodes: [String: UInt64] = [:]
        var contentHashes: [String: String] = [:]
        /// 登记的“未做内容哈希”结果（超限/不可读）；优先于 `contentHashes`。
        var contentHashFailures: [String: UpdateArtifactContentHashResult] = [:]
        var npmIntegrities: [String: String] = [:]
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
                fileInode: { [self] path in inodes[path] },
                contentHash: { [self] path in
                    if let failure = contentHashFailures[path] { return failure }
                    if let hash = contentHashes[path] { return .hashed(hash) }
                    return .unsupported
                },
                npmIntegrity: { [self] path, _ in npmIntegrities[path] },
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
        var isRunning = false
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
        var isRunning = false
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
            targetOrigin: .network,
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

    /// GitHub #59：缓存回退（`cached-fallback`）不得驱动自动安装，协调器一级就要拒绝，且不写历史。
    func testCachedFallbackOriginBlocksCoordinatorBeforeAnyCommand() throws {
        let probe = FakeProbe()
        probe.executables.insert(newExecutable)
        probe.readable.insert(newExecutable)
        let world = RecordingInstaller()
        let history = HistoryRecorder()
        let log = LogSink()
        let coordinator = PiWebUpdateCoordinator(environment: PiWebUpdateCoordinator.Environment(
            installer: world,
            detectInstallation: { self.installation() },
            startServiceAndCheckHealth: { completion in completion(true) },
            redactor: LogRedactor(homeDirectory: self.fixtureHome),
            log: { log.append($0) },
            deliver: { work in work() },
            timeout: 60,
            transaction: transactionEnvironment(probe: probe.make(), history: history)
        ))
        var input = piWebInput(installation: installation())
        input.targetOrigin = .cachedFallback
        input.targetCacheWrittenAt = referenceDate.addingTimeInterval(-3600)
        var outcome: PiWebUpdateRunOutcome?
        coordinator.run(input) { outcome = $0 }

        XCTAssertEqual(outcome?.isSucceeded, false)
        XCTAssertEqual(world.plans.count, 0, "缓存回退不允许执行任何安装命令")
        XCTAssertTrue(history.entries.isEmpty, "被拒绝的判定不写更新历史")
        XCTAssertTrue(log.text.contains("缓存"), "拒绝原因里要写明来源是缓存")
        XCTAssertFalse(log.text.contains(self.fixtureHome))
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

    /// B-3：指纹里没有路径证据时，它记录的包名只是计划里的期望值，不能拿来当
    /// 「检测到的包名」核对身份——否则「身份名称一致」恒真，未验证的结论会被写进历史。
    func testPathlessFingerprintNameIsNotTreatedAsDetectedIdentity() {
        let report = UpdateVerifier.verify(
            UpdateVerificationInput(
                component: .piWeb,
                packageName: InstallCommandManifest.piWebPackageName,
                previousVersion: "0.9.0",
                targetVersion: "0.9.2",
                detectedVersion: "0.9.2",
                detectedPackageName: nil,
                detectedExecutablePath: nil,
                detectedResolvedPath: nil,
                detectedPackageJSONPath: nil,
                fingerprint: UpdateArtifactFingerprint.versionOnly(
                    version: "0.9.0",
                    packageName: InstallCommandManifest.piWebPackageName
                )
            ),
            probe: .disabled
        )
        XCTAssertEqual(report.result(for: .packageIdentity)?.status, .notChecked)
        XCTAssertTrue(report.result(for: .packageIdentity)?.detail.contains("无法核对身份") == true)
    }

    func testIdentityMismatchFailsPackageIdentityCheck() throws {
        let probe = FakeProbe()
        probe.executables.insert(newExecutable)
        probe.readable.insert(newExecutable)
        probe.realPaths[newExecutable] = newExecutable
        probe.packageNamesNear[newExecutable] = InstallCommandManifest.piWebPackageName
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
        // B-7：指纹没有内容哈希，也没有 size/mtime，等于没有任何可核对的元数据：
        // 未验证不等于通过，不能按“仍在更新前的文件上”处理。
        XCTAssertEqual(plan.kind, .cannotAutomaticallyRollback)
        XCTAssertEqual(plan.rollbackEligibility, .evidenceChangedOrMissing)
        XCTAssertTrue(plan.reason.contains("没有可核对的元数据"))
    }

    func testHealthCheckFailureDegradesToRetainedPreviousExecutable() throws {
        let probe = FakeProbe()
        probe.executables.formUnion([oldExecutable, newExecutable])
        probe.readable.formUnion([oldExecutable, newExecutable])
        probe.realPaths[oldExecutable] = oldExecutable
        probe.realPaths[newExecutable] = newExecutable
        probe.sizes[oldExecutable] = 100
        probe.mtimes[oldExecutable] = referenceDate
        // GitHub #63：旧路径同时登记身份、inode、内容哈希与 npm integrity，
        // 降级前必须逐个重新核对。
        probe.inodes[oldExecutable] = 4321
        probe.contentHashes[oldExecutable] = "sha256:" + String(repeating: "e", count: 64)
        probe.npmIntegrities[oldExecutable] = "sha512-" + String(repeating: "F", count: 86)
        probe.packageNamesNear[oldExecutable] = InstallCommandManifest.piWebPackageName
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
        XCTAssertEqual(plan.evidence?.level, .contentHash)
        XCTAssertEqual(plan.evidence?.contentHashVerified, true)
        XCTAssertTrue(plan.warningText.contains("已重新核对旧文件内容哈希"))
        XCTAssertFalse(plan.warningText.contains("不校验旧文件内容"))
        XCTAssertEqual(entry.evidenceLevel, .contentHash)
        XCTAssertTrue(entry.evidenceNote?.contains("内容哈希一致") == true)
        XCTAssertFalse(plan.warningText.contains(oldExecutable), "警告文本不得包含本机绝对路径")
        XCTAssertFalse(log.text.contains(oldExecutable))
        XCTAssertFalse(log.text.contains(fixtureHome))
    }

    // MARK: - 5. 证据消失 → 无法自动回滚

    func testEvidenceGoneCannotRollbackAndProducesNoWrongCommand() throws {
        let probe = FakeProbe()
        probe.executables.formUnion([oldExecutable, newExecutable])
        probe.realPaths[newExecutable] = newExecutable
        probe.packageNamesNear[oldExecutable] = InstallCommandManifest.piWebPackageName
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
            targetOrigin: .network,
            serviceIsRunning: false,
            npmExecutablePath: "/opt/homebrew/bin/npm",
            baseEnvironment: [
                "PATH": "/usr/bin:/bin",
                "HOME": self.fixtureHome,
                "PI_WEB_PASSWORD": "super-secret-value",  // scan-secrets: allow(reason=test fixture environment)
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
            targetOrigin: .network,
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

    // MARK: - 10. GitHub #63：有限降级的证据强度与证据等级

    /// 在 `$TMPDIR` 下的临时目录：只用于假 npm 包目录夹具，不碰真实用户目录。
    private func makeTemporaryDirectory() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pi-web-rollback-evidence-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// 内容被替换但大小与 mtime 完全相同：只有 inode / 内容哈希能检出，
    /// 判定必须是“无法自动回滚”，不得报“已降级”。
    func testReplacedContentWithSameSizeAndMtimeIsNotDegradedAsRollback() throws {
        let probe = FakeProbe()
        probe.executables.insert(oldExecutable)
        probe.realPaths[newExecutable] = newExecutable
        probe.sizes[oldExecutable] = 100
        probe.mtimes[oldExecutable] = referenceDate
        probe.packageNamesNear[oldExecutable] = InstallCommandManifest.piWebPackageName
        probe.inodes[oldExecutable] = 222
        probe.contentHashes[oldExecutable] = "sha256:" + String(repeating: "b", count: 64)

        func fingerprint(inode: UInt64, hash: String) -> UpdateArtifactFingerprint {
            UpdateArtifactFingerprint(
                executablePath: oldExecutable,
                resolvedPath: oldExecutable,
                version: "0.9.0",
                packageName: InstallCommandManifest.piWebPackageName,
                fileSize: 100,
                modifiedAt: referenceDate,
                fileInode: inode,
                contentHash: hash
            )
        }

        func plan(inode: UInt64, hash: String) -> UpdateDegradationPlan {
            UpdateDegradationPlanner.verificationFailure(
                component: .piWeb,
                source: .npmGlobal,
                fingerprint: fingerprint(inode: inode, hash: hash),
                newVersion: "0.9.2",
                newResolvedPath: newExecutable,
                failureReason: "版本重新检测达到目标失败",
                probe: probe.make()
            )
        }

        let originalHash = "sha256:" + String(repeating: "a", count: 64)
        // inode 变化（内容也已变化）：大小与 mtime 相同也不得降级。
        let inodeChanged = plan(inode: 111, hash: originalHash)
        XCTAssertEqual(inodeChanged.kind, .cannotAutomaticallyRollback)
        XCTAssertEqual(inodeChanged.rollbackEligibility, .evidenceChangedOrMissing)
        XCTAssertNil(inodeChanged.restoredExecutablePath)
        XCTAssertFalse(inodeChanged.performedAutomaticDegradation)
        XCTAssertTrue(inodeChanged.reason.contains("inode 与更新前记录不一致"))
        XCTAssertFalse(inodeChanged.warningText.contains("已降级"))

        // inode 被保持（例如原地改写）：只有内容哈希能检出。
        probe.inodes[oldExecutable] = 111
        let hashChanged = plan(inode: 111, hash: originalHash)
        XCTAssertEqual(hashChanged.kind, .cannotAutomaticallyRollback)
        XCTAssertNil(hashChanged.restoredExecutablePath)
        XCTAssertTrue(hashChanged.reason.contains("内容哈希与更新前记录不一致"))
        XCTAssertFalse(hashChanged.warningText.contains("已降级"))

        // 身份名称不一致或读不到：同样不得降级。
        probe.contentHashes[oldExecutable] = originalHash
        probe.packageNamesNear[oldExecutable] = "left-pad"
        let identityMismatch = plan(inode: 111, hash: originalHash)
        XCTAssertEqual(identityMismatch.kind, .cannotAutomaticallyRollback)
        XCTAssertTrue(identityMismatch.reason.contains("package.json 名称与更新前记录不一致"))

        probe.packageNamesNear.removeValue(forKey: oldExecutable)
        let identityUnreadable = plan(inode: 111, hash: originalHash)
        XCTAssertEqual(identityUnreadable.kind, .cannotAutomaticallyRollback)
        XCTAssertTrue(identityUnreadable.reason.contains("读不到旧文件所在包的 package.json 名称"))
    }

    /// inode 与内容哈希都一致时允许降级，证据等级为 `contentHash`；
    /// 哈希是更强的证据，记录在案的 size/mtime 不再阻塞（明示的等价规则）。
    func testConsistentInodeAndContentHashAllowDegradationAsContentHashEvidence() throws {
        let probe = FakeProbe()
        probe.executables.insert(oldExecutable)
        probe.realPaths[newExecutable] = newExecutable
        probe.packageNamesNear[oldExecutable] = InstallCommandManifest.piWebPackageName
        probe.inodes[oldExecutable] = 42
        let hash = "sha256:" + String(repeating: "c", count: 64)
        probe.contentHashes[oldExecutable] = hash
        // 当前文件的大小与 mtime 都与更新前记录的（故意）不同：内容哈希一致时
        // 不得因此阻塞。
        probe.sizes[oldExecutable] = 4096
        probe.mtimes[oldExecutable] = referenceDate.addingTimeInterval(120)

        let plan = UpdateDegradationPlanner.verificationFailure(
            component: .piWeb,
            source: .npmGlobal,
            fingerprint: UpdateArtifactFingerprint(
                executablePath: oldExecutable,
                resolvedPath: oldExecutable,
                version: "0.9.0",
                packageName: InstallCommandManifest.piWebPackageName,
                fileSize: 100,
                modifiedAt: referenceDate,
                fileInode: 42,
                contentHash: hash
            ),
            newVersion: "0.9.2",
            newResolvedPath: newExecutable,
            failureReason: "服务健康检查失败",
            probe: probe.make()
        )
        XCTAssertEqual(plan.kind, .degradedToPreviousArtifact)
        XCTAssertEqual(plan.rollbackEligibility, .eligibleRetainedEvidence)
        XCTAssertEqual(plan.restoredExecutablePath, oldExecutable)
        XCTAssertEqual(plan.evidence?.level, .contentHash)
        XCTAssertEqual(plan.evidence?.identityVerified, true)
        XCTAssertEqual(plan.evidence?.inodeVerified, true)
        XCTAssertEqual(plan.evidence?.contentHashVerified, true)
        XCTAssertTrue(plan.reason.contains("内容哈希一致"))
        XCTAssertTrue(plan.warningText.contains("这只是把调用方指回更新前记录的路径"))
        XCTAssertTrue(plan.warningText.contains("已重新核对旧文件内容哈希与身份名称一致"))
        XCTAssertFalse(plan.warningText.contains("不校验旧文件内容"))
    }

    /// 超限/不可读时证据等级降级，且文案必须写明“未做内容哈希”；降级仍可
    /// 进行，但必须如实标注未校验旧文件内容。
    func testUnavailableContentHashDowngradesEvidenceAndSaysSoInWording() throws {
        let probe = FakeProbe()
        probe.executables.insert(oldExecutable)
        probe.realPaths[newExecutable] = newExecutable
        probe.sizes[oldExecutable] = 100
        probe.mtimes[oldExecutable] = referenceDate
        probe.inodes[oldExecutable] = 7
        probe.packageNamesNear[oldExecutable] = InstallCommandManifest.piWebPackageName
        probe.contentHashFailures[oldExecutable] = .aboveSizeLimit

        func capture() -> UpdateArtifactFingerprint {
            UpdateArtifactFingerprint.capture(
                executablePath: oldExecutable,
                resolvedPath: oldExecutable,
                version: "0.9.0",
                packageName: InstallCommandManifest.piWebPackageName,
                probe: probe.make()
            )
        }

        let oversized = capture()
        XCTAssertNil(oversized.contentHash)
        XCTAssertEqual(oversized.contentHashUnavailableReason, .aboveSizeLimit)
        XCTAssertEqual(oversized.evidenceLevel, .inode)
        XCTAssertTrue(oversized.contentHashEvidenceText.contains("未做内容哈希"))
        XCTAssertTrue(oversized.summaryLine.contains("未做内容哈希"))
        XCTAssertTrue(oversized.npmIntegrityEvidenceText.contains("未获取"))

        let plan = UpdateDegradationPlanner.verificationFailure(
            component: .piWeb,
            source: .npmGlobal,
            fingerprint: oversized,
            newVersion: "0.9.2",
            newResolvedPath: newExecutable,
            failureReason: "版本重新检测达到目标失败",
            probe: probe.make()
        )
        XCTAssertEqual(plan.kind, .degradedToPreviousArtifact)
        XCTAssertEqual(plan.evidence?.level, .inode)
        XCTAssertEqual(plan.evidence?.contentHashVerified, false)
        XCTAssertTrue(plan.warningText.contains("不校验旧文件内容"))
        XCTAssertTrue(plan.warningText.contains("未做内容哈希"))
        XCTAssertTrue(plan.warningText.contains("超过大小上限"))
        XCTAssertTrue(UpdateHistoryDescription.rollbackDescription(for: plan).contains("不校验旧文件内容"))

        // 不可读 → 同一回退与同一“未做内容哈希”标注。
        probe.contentHashFailures[oldExecutable] = .unreadable
        let unreadable = capture()
        XCTAssertNil(unreadable.contentHash)
        XCTAssertEqual(unreadable.contentHashUnavailableReason, .unreadable)
        XCTAssertTrue(unreadable.contentHashEvidenceText.contains("未做内容哈希（文件不可读）"))

        // 没有探针能力时也如实标注，不伪造哈希。
        let withoutProbe = UpdateArtifactFingerprint.capture(
            executablePath: oldExecutable,
            resolvedPath: oldExecutable,
            version: "0.9.0",
            packageName: InstallCommandManifest.piWebPackageName,
            probe: .disabled
        )
        XCTAssertNil(withoutProbe.contentHash)
        XCTAssertEqual(withoutProbe.contentHashUnavailableReason, .probeUnavailable)
        XCTAssertEqual(withoutProbe.evidenceLevel, .pathOnly)
    }

    /// npm 完整性：取到就记录为附加证据，取不到就标注“未获取”，并且不影响
    /// 既有判定逻辑；形状非法的值不得写进指纹。
    func testNpmIntegrityIsRecordedOrMarkedNotObtainedWithoutChangingJudgement() throws {
        let probe = FakeProbe()
        probe.executables.insert(oldExecutable)
        probe.realPaths[newExecutable] = newExecutable
        probe.sizes[oldExecutable] = 100
        probe.mtimes[oldExecutable] = referenceDate
        probe.inodes[oldExecutable] = 9
        probe.packageNamesNear[oldExecutable] = InstallCommandManifest.piWebPackageName
        let hash = "sha256:" + String(repeating: "d", count: 64)
        probe.contentHashes[oldExecutable] = hash

        func capture() -> UpdateArtifactFingerprint {
            UpdateArtifactFingerprint.capture(
                executablePath: oldExecutable,
                resolvedPath: oldExecutable,
                version: "0.9.0",
                packageName: InstallCommandManifest.piWebPackageName,
                probe: probe.make()
            )
        }

        let withoutIntegrity = capture()
        XCTAssertNil(withoutIntegrity.npmIntegrity)
        XCTAssertEqual(withoutIntegrity.npmIntegrityEvidenceText, "npm 完整性未获取")
        XCTAssertTrue(withoutIntegrity.evidenceSummaryLine.contains("npm 完整性未获取"))

        let intact = "sha512-" + String(repeating: "A", count: 86)
        probe.npmIntegrities[oldExecutable] = intact
        let withIntegrity = capture()
        XCTAssertEqual(withIntegrity.npmIntegrity, intact)
        XCTAssertTrue(withIntegrity.npmIntegrityEvidenceText.contains("npm 完整性已记录"))

        probe.npmIntegrities[oldExecutable] = "totally-not-an-integrity-value"
        let bogus = capture()
        XCTAssertNil(bogus.npmIntegrity, "形状非法的完整性值不得写进指纹")
        XCTAssertTrue(bogus.npmIntegrityEvidenceText.contains("未获取"))

        // 有没有 integrity 不改变降级判定：只影响附加证据说明。
        probe.npmIntegrities.removeValue(forKey: oldExecutable)
        let plan = UpdateDegradationPlanner.verificationFailure(
            component: .piWeb,
            source: .npmGlobal,
            fingerprint: withoutIntegrity,
            newVersion: "0.9.2",
            newResolvedPath: newExecutable,
            failureReason: "版本重新检测达到目标失败",
            probe: probe.make()
        )
        XCTAssertEqual(plan.kind, .degradedToPreviousArtifact)
        XCTAssertEqual(plan.evidence?.npmIntegrityEvidenceText, "npm 完整性未获取")
        XCTAssertEqual(plan.evidence?.level, .contentHash)
        XCTAssertTrue(plan.warningText.contains("已重新核对旧文件内容哈希"))
        XCTAssertFalse(plan.warningText.contains("不校验旧文件内容"), "内容哈希已核对时不得写“不校验旧文件内容”")
    }

    /// 用真实的临时目录（假可执行文件 + 假 npm 包目录）验证生产探针：内容哈希、
    /// 身份读取与 npm `integrity` 读取都不执行 npm、不联网。
    func testLiveProbeReadsContentHashIdentityAndNpmIntegrityFromFakePackageDirectory() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let packageDir = root.appendingPathComponent(
            "lib/node_modules/@scope/pi-rollback-fixture", isDirectory: true
        )
        let binDir = packageDir.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
        let executable = binDir.appendingPathComponent("pi-rollback-fixture")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        try Data(#"{"name":"@scope/pi-rollback-fixture","version":"1.0.0"}"#.utf8)
            .write(to: packageDir.appendingPathComponent("package.json"))
        let integrity = "sha512-" + String(repeating: "A", count: 86)
        let lockfile = root.appendingPathComponent("lib/node_modules/.package-lock.json")
        let lockJSON = "{\"packages\":{\"node_modules/@scope/pi-rollback-fixture\":"
            + "{\"version\":\"1.0.0\",\"integrity\":\"\(integrity)\"}}}"
        try Data(lockJSON.utf8).write(to: lockfile)

        let fingerprint = UpdateArtifactFingerprint.capture(
            executablePath: executable.path,
            resolvedPath: executable.path,
            version: "1.0.0",
            packageName: "@scope/pi-rollback-fixture",
            probe: .live
        )
        XCTAssertEqual(
            fingerprint.contentHash,
            "sha256:306c6ca7407560340797866e077e053627ad409277d1b9da58106fce4cf717cb"
        )
        XCTAssertEqual(fingerprint.evidenceLevel, .contentHash)
        XCTAssertNotNil(fingerprint.fileInode)
        XCTAssertEqual(fingerprint.npmIntegrity, integrity)
        XCTAssertEqual(UpdateArtifactProbe.readPackageName(near: executable.path), "@scope/pi-rollback-fixture")

        // 没有锁文件 → 不伪造证据：直接返回 nil，由调用方展示“未获取”。
        try FileManager.default.removeItem(at: lockfile)
        XCTAssertNil(UpdateArtifactProbe.readNpmIntegrity(
            executablePath: executable.path,
            packageName: "@scope/pi-rollback-fixture"
        ))
        // 不存在的文件不读取内容，返回 unreadable。
        XCTAssertEqual(
            UpdateArtifactProbe.readContentHash(atPath: root.appendingPathComponent("missing").path),
            .unreadable
        )
        // 超过大小上限的文件不读取内容：退回元数据证据并标注“未做内容哈希”。
        let oversized = root.appendingPathComponent("oversized")
        FileManager.default.createFile(atPath: oversized.path, contents: Data("x".utf8))
        let handle = try FileHandle(forWritingTo: oversized)
        try handle.truncate(atOffset: UInt64(UpdateArtifactProbe.contentHashSizeLimitBytes + 1))
        try handle.close()
        XCTAssertEqual(UpdateArtifactProbe.readContentHash(atPath: oversized.path), .aboveSizeLimit)
        XCTAssertTrue(UpdateArtifactProbe.isIntegrityValue(integrity))
        XCTAssertFalse(UpdateArtifactProbe.isIntegrityValue("not-a-hash"))
    }

    /// 文案断言：“检查完成/已降级”不得写成“来源可信/安全检查通过”，
    /// 且“已降级”在证据等级不是 contentHash 时必须写明不校验旧文件内容。
    func testUserVisibleWordingAvoidsTrustClaims() throws {
        let forbiddenConclusions = ["来源可信", "官方来源已确认", "安全检查通过", "验证通过"]

        // 1) 验证阶段的成功记录只写具体事实（与目标版本一致 / 身份名称一致）。
        let probe = FakeProbe()
        probe.executables.insert(newExecutable)
        probe.readable.insert(newExecutable)
        probe.realPaths[newExecutable] = newExecutable
        probe.packageNamesNear[newExecutable] = InstallCommandManifest.piWebPackageName
        var journal = UpdateTransactionJournal(
            configuration: UpdateTransactionJournal.Configuration(
                component: .piWeb,
                source: .npmGlobal,
                previousVersion: "0.9.0",
                targetVersion: "0.9.2",
                fingerprint: UpdateArtifactFingerprint.versionOnly(version: "0.9.0", packageName: nil)
            ),
            now: { self.referenceDate }
        )
        let report = UpdateVerifier.report(
            UpdateVerifier.verify(
                UpdateVerificationInput(
                    component: .piWeb,
                    packageName: InstallCommandManifest.piWebPackageName,
                    previousVersion: "0.9.0",
                    targetVersion: "0.9.2",
                    detectedVersion: "0.9.2",
                    detectedPackageName: InstallCommandManifest.piWebPackageName,
                    detectedExecutablePath: newExecutable,
                    detectedResolvedPath: newExecutable,
                    detectedPackageJSONPath: nil,
                    fingerprint: UpdateArtifactFingerprint.versionOnly(version: "0.9.0", packageName: nil)
                ),
                probe: probe.make()
            ),
            healthCheck: .passed
        )
        XCTAssertTrue(journal.recordVerification(report, detectedVersion: "0.9.2"))
        let verifyReason = try XCTUnwrap(journal.phases.first { $0.phase == .verify }?.reason)
        XCTAssertTrue(verifyReason.contains("版本与目标版本一致"))
        XCTAssertTrue(verifyReason.contains("身份名称一致"))
        XCTAssertTrue(verifyReason.contains("未做代码签名或来源验证"))
        for conclusion in forbiddenConclusions {
            XCTAssertFalse(verifyReason.contains(conclusion), "verify 阶段文案不得出现 \(conclusion)")
        }

        // 2) “已降级”（证据等级 pathOnly）文案必须写明只指回路径且不校验旧内容。
        let rollbackProbe = FakeProbe()
        rollbackProbe.executables.insert(oldExecutable)
        rollbackProbe.realPaths[newExecutable] = newExecutable
        rollbackProbe.sizes[oldExecutable] = 100
        rollbackProbe.mtimes[oldExecutable] = referenceDate
        rollbackProbe.packageNamesNear[oldExecutable] = InstallCommandManifest.piWebPackageName
        let plan = UpdateDegradationPlanner.verificationFailure(
            component: .piWeb,
            source: .npmGlobal,
            fingerprint: UpdateArtifactFingerprint(
                executablePath: oldExecutable,
                resolvedPath: oldExecutable,
                version: "0.9.0",
                packageName: InstallCommandManifest.piWebPackageName,
                fileSize: 100,
                modifiedAt: referenceDate,
                contentHashUnavailableReason: .noPath
            ),
            newVersion: "0.9.2",
            newResolvedPath: newExecutable,
            failureReason: "服务健康检查失败",
            probe: rollbackProbe.make()
        )
        XCTAssertEqual(plan.kind, .degradedToPreviousArtifact)
        XCTAssertEqual(plan.evidence?.level, .pathOnly)
        var presentation = UpdateTransactionJournal(
            configuration: UpdateTransactionJournal.Configuration(
                component: .piWeb,
                source: .npmGlobal,
                previousVersion: "0.9.0",
                targetVersion: "0.9.2",
                fingerprint: plan.previousExecutablePath.map { path in
                    UpdateArtifactFingerprint(
                        executablePath: path,
                        resolvedPath: path,
                        version: "0.9.0",
                        packageName: InstallCommandManifest.piWebPackageName,
                        fileSize: 100,
                        modifiedAt: referenceDate
                    )
                } ?? UpdateArtifactFingerprint.versionOnly(version: "0.9.0", packageName: nil)
            ),
            now: { self.referenceDate }
        )
        presentation.recordPreflight()
        presentation.recordInstallSucceeded()
        presentation.recordCommitNotAttempted(reason: "验证阶段失败，未启用新版本")
        presentation.recordDegradation(plan)
        let entry = presentation.historyEntry(
            degradation: plan,
            advice: plan.manualAdvice,
            resultingVersion: "0.9.2"
        )
        let presenterText = UpdateHistoryPresenter.lines(for: entry).joined(separator: " ")
        let rollbackDescription = UpdateHistoryDescription.rollbackDescription(for: plan)
        for text in [plan.warningText, plan.reason, rollbackDescription, presenterText] {
            for conclusion in forbiddenConclusions {
                XCTAssertFalse(text.contains(conclusion), "用户可见文案不得出现 \(conclusion)：\(text)")
            }
        }
        XCTAssertTrue(plan.warningText.contains("这只是把调用方指回更新前记录的路径"))
        XCTAssertTrue(plan.warningText.contains("不校验旧文件内容"))
        XCTAssertTrue(rollbackDescription.contains("不校验旧文件内容"))
        XCTAssertTrue(presenterText.contains("降级证据等级：pathOnly"))
        XCTAssertTrue(presenterText.contains("证据说明："))
        // “无法自动回滚”保留原意：只报告 + 手动命令提示。
        let cannot = UpdateDegradationPlanner.verificationFailure(
            component: .piWeb,
            source: .homebrew,
            fingerprint: UpdateArtifactFingerprint.versionOnly(version: "0.9.0", packageName: nil),
            newVersion: "0.9.2",
            newResolvedPath: newExecutable,
            failureReason: "版本重新检测达到目标失败",
            probe: rollbackProbe.make()
        )
        XCTAssertEqual(cannot.kind, .cannotAutomaticallyRollback)
        XCTAssertTrue(cannot.warningText.contains("无法自动回滚"))
        XCTAssertTrue(cannot.warningText.contains("请按下面的手动方式处理："))
        XCTAssertFalse(cannot.performedAutomaticDegradation)
    }
}
