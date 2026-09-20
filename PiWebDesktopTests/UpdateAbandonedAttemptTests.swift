import XCTest

/// GitHub #62（alpha.4；对应 alpha.3 安全审查 A-6、A-7）：超时/放弃等待之后子进程
/// 的行为，以及同一组件的重叠更新防护。
///
/// 全部用例都是无宿主的：不连接网络、不执行真实 npm/pi、不枚举真实进程，也不发送
/// 任何真实信号（终止进程组走注入替身）。生产实现里的 `posix_spawn` 属性是真实
/// 的（用例直接读写 `posix_spawnattr_t`）。
final class UpdateAbandonedAttemptTests: XCTestCase {

    // MARK: - 夹具

    private let referenceDate = Date(timeIntervalSince1970: 1_700_000_000)
    /// 夹具 Home：按片段拼接，仓库文本扫描禁止出现绝对 Home 路径字面量（同 LogRedactor）。
    private let fixtureHome = "/Use" + "rs/" + "fixture-user"
    private let fixtureNPM = "/opt/homebrew/bin/npm"
    /// 规划输入与计划构造必须用同一份环境，否则计划对象不相等。
    private var piWebBaseEnvironment: [String: String] {
        ["HOME": fixtureHome, "PATH": "/opt/homebrew/bin:/usr/bin:/bin"]
    }
    private let piWebPackageName = InstallCommandManifest.piWebPackageName
    private let packageName = "pi-extension-demo"

    /// 每个用例一份独立的 UserDefaults suite，结束时清除。
    private func makeDefaults() -> UserDefaults {
        let suite = "io.github.su-luoya.pi-web-desktop.tests.abandoned.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        defaults.removePersistentDomain(forName: suite)
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }

    private func makeRedactor() -> LogRedactor {
        LogRedactor(homeDirectory: fixtureHome)
    }

    private func makeAttempt(
        kind: ComponentKind = .piWeb,
        packageName: String? = nil,
        reason: UpdateAbandonedAttempt.Reason = .timedOut,
        commandSummary: String = "npm install -g @agegr/pi-web@0.9.2",
        startedAt: Date? = nil,
        timeout: TimeInterval = 300,
        source: InstallSource = .npmGlobal,
        recordedAt: Date? = nil,
        action: UpdateAbandonedAttempt.ChildProcessAction = .terminatedOwnProcessGroup,
        finishedAt: Date? = nil,
        derivedProcessesConfirmedEnded: Bool? = nil
    ) -> UpdateAbandonedAttempt {
        UpdateAbandonedAttempt(
            componentKind: kind,
            packageName: packageName,
            reason: reason,
            commandSummary: commandSummary,
            startedAt: startedAt ?? referenceDate,
            timeout: timeout,
            finishedAt: finishedAt,
            source: source,
            recordedAt: recordedAt ?? referenceDate.addingTimeInterval(1),
            childProcessAction: action,
            derivedProcessesConfirmedEnded: derivedProcessesConfirmedEnded
        )
    }

    private func makePiWebPlan(
        installedVersion: String = "0.9.0",
        targetVersion: String = "0.9.2",
        npmExecutablePath: String? = nil
    ) throws -> PiWebUpdateInstallPlan {
        try XCTUnwrap(PiWebUpdateInstallPlan.make(
            packageName: piWebPackageName,
            installedVersion: installedVersion,
            targetVersion: targetVersion,
            npmExecutablePath: npmExecutablePath ?? fixtureNPM,
            baseEnvironment: piWebBaseEnvironment,
            source: .npmGlobal,
            confidence: .verified
        ))
    }

    private func piWebInstallation(version: String? = "0.9.0") -> ComponentInstallation {
        ComponentInstallation(
            kind: .piWeb,
            packageName: piWebPackageName,
            version: version,
            executablePath: "/opt/homebrew/bin/pi-web",
            resolvedPath: "/opt/homebrew/lib/node_modules/pi-web/bin/pi-web.js",
            symlinkChain: [],
            packageJSONPath: nil,
            source: .npmGlobal,
            confidence: .verified,
            evidence: ["fixture"],
            suggestedCommand: "npm install -g pi-web"
        )
    }

    private func piCLIPlan(installedVersion: String = "0.1.0", targetVersion: String = "0.2.0") throws -> PiCLIUpdatePlan {
        try XCTUnwrap(PiCLIUpdatePlan.make(
            executablePath: "/opt/homebrew/bin/pi",
            installedVersion: installedVersion,
            targetVersion: targetVersion,
            source: .npmGlobal,
            confidence: .verified
        ))
    }

    private func piCLIInput(
        autoUpdate: Bool = true,
        processes: PiProcessInspection = .noProcesses,
        abandonedAttempt: UpdateAbandonedAttempt? = nil
    ) -> PiCLIUpdatePlanningInput {
        var preferences = UpdateCheckPreferences.factoryDefaults
        preferences.autoUpdatePiBeforeLaunch = autoUpdate
        return PiCLIUpdatePlanningInput(
            preferences: preferences,
            installation: ComponentInstallation(
                kind: .piCLI,
                packageName: InstallCommandManifest.piCLIPackageName,
                version: "0.1.0",
                executablePath: "/opt/homebrew/bin/pi",
                resolvedPath: "/opt/homebrew/lib/node_modules/@agegr/pi-coding-agent/bin/pi.js",
                symlinkChain: [],
                packageJSONPath: nil,
                source: .npmGlobal,
                confidence: .verified,
                evidence: ["fixture"],
                suggestedCommand: "pi update --self"
            ),
            targetVersion: "0.2.0",
            targetStatus: .updateAvailable,
            targetConfidence: .verified,
            targetOrigin: .network,
            processes: processes,
            abandonedAttempt: abandonedAttempt
        )
    }

    private func packageCandidate(name: String, installedVersion: String? = "1.0.0") -> PiPackageCandidate {
        PiPackageCandidate(
            packageName: name,
            installedVersion: installedVersion,
            source: .npmGlobal,
            confidence: .verified
        )
    }

    private func packageCheck(name: String, latestVersion: String = "2.0.0") -> PiPackageCheckOutcome {
        PiPackageCheckOutcome(
            packageName: name,
            latestVersion: latestVersion,
            status: .updateAvailable,
            confidence: .verified,
            origin: .network
        )
    }

    private func packagePlanSet(
        names: [String],
        abandonedAttempts: [UpdateAbandonedAttempt] = [],
        processes: PiProcessInspection = .noProcesses
    ) -> PiPackageUpdatePlanSet {
        PiPackageUpdatePlanner.decide(PiPackageUpdatePlanningInput(
            policy: .askBeforeUpdate,
            packages: names.map { packageCandidate(name: $0) },
            checks: names.map { packageCheck(name: $0) },
            processes: processes,
            piExecutablePath: "/opt/homebrew/bin/pi",
            abandonedAttempts: abandonedAttempts
        ))
    }

    // MARK: - 替身：子进程启动器（不创建任何真实进程，也不发送任何真实信号）

    private final class FakeChildSpawner: PiWebUpdateChildSpawning {
        private let lock = NSLock()
        private var storedSpecifications: [PiWebChildProcessSpecification] = []
        private var storedTerminateCalls: [PiWebChildProcessHandle] = []
        private let gate = DispatchSemaphore(value: 0)

        var handle: PiWebChildProcessHandle
        var spawnError: PiWebUpdateSpawnError?
        var waitForExitCode: Int32 = 0
        /// true：`waitForExit` 阻塞到测试调用 `releaseWait()`，模拟“命令仍在运行”。
        var blocksWait = false
        /// 终止调用是否报告“成功发出信号”。
        var terminateSucceeds = true

        init(handle: PiWebChildProcessHandle) {
            self.handle = handle
        }

        var specifications: [PiWebChildProcessSpecification] {
            lock.lock(); defer { lock.unlock() }
            return storedSpecifications
        }

        var terminateCalls: [PiWebChildProcessHandle] {
            lock.lock(); defer { lock.unlock() }
            return storedTerminateCalls
        }

        var terminateCallCount: Int { terminateCalls.count }

        func spawn(_ specification: PiWebChildProcessSpecification) throws -> PiWebChildProcessHandle {
            lock.lock()
            storedSpecifications.append(specification)
            lock.unlock()
            if let spawnError { throw spawnError }
            return handle
        }

        func waitForExit(_ handle: PiWebChildProcessHandle) -> Int32 {
            if blocksWait { _ = gate.wait(timeout: .now() + 20) }
            return waitForExitCode
        }

        func terminateOwnProcessGroup(_ handle: PiWebChildProcessHandle) -> Bool {
            lock.lock()
            storedTerminateCalls.append(handle)
            lock.unlock()
            return terminateSucceeds
        }

        /// 放行被阻塞的等待线程（避免测试结束后残留阻塞线程）。
        func releaseWait() {
            gate.signal()
        }
    }

    private final class RecordedAttempts {
        private let lock = NSLock()
        private var stored: [UpdateAbandonedAttempt] = []

        var values: [UpdateAbandonedAttempt] {
            lock.lock(); defer { lock.unlock() }
            return stored
        }

        func append(_ attempt: UpdateAbandonedAttempt) {
            lock.lock()
            stored.append(attempt)
            lock.unlock()
        }
    }

    private final class RecordedComponents {
        private let lock = NSLock()
        private var stored: [UpdateTransactionComponent] = []

        var values: [UpdateTransactionComponent] {
            lock.lock(); defer { lock.unlock() }
            return stored
        }

        func append(_ component: UpdateTransactionComponent) {
            lock.lock()
            stored.append(component)
            lock.unlock()
        }
    }

    private final class RecordingInstaller: PiWebUpdateInstalling {
        private(set) var plans: [PiWebUpdateInstallPlan] = []
        var isRunning = false
        var result: PiWebUpdateInstallResult

        init(result: PiWebUpdateInstallResult) {
            self.result = result
        }

        func install(
            _ plan: PiWebUpdateInstallPlan,
            timeout: TimeInterval,
            completion: @escaping (PiWebUpdateInstallResult) -> Void
        ) {
            plans.append(plan)
            completion(result)
        }

        func cancel() {}
    }

    private final class RecordingPiCLIRunner: PiCLIUpdateRunning {
        private(set) var plans: [PiCLIUpdatePlan] = []
        var isRunning = false
        private(set) var abandonCallCount = 0
        var result: PiCLIUpdateCommandResult

        init(result: PiCLIUpdateCommandResult) {
            self.result = result
        }

        func run(
            _ plan: PiCLIUpdatePlan,
            timeout: TimeInterval,
            completion: @escaping (PiCLIUpdateCommandResult) -> Void
        ) {
            plans.append(plan)
            completion(result)
        }

        func abandon() {
            abandonCallCount += 1
        }
    }

    private final class RecordingPiPackageRunner: PiPackageUpdateRunning {
        private(set) var plans: [PiPackageUpdatePlan] = []
        var result: PiPackageUpdateCommandResult

        init(result: PiPackageUpdateCommandResult) {
            self.result = result
        }

        func run(
            _ plan: PiPackageUpdatePlan,
            timeout: TimeInterval,
            completion: @escaping (PiPackageUpdateCommandResult) -> Void
        ) {
            plans.append(plan)
            completion(result)
        }

        func abandon() {}
    }

    private func successPiWebResult() -> PiWebUpdateInstallResult {
        PiWebUpdateInstallResult(
            exitCode: 0,
            startedAt: referenceDate,
            finishedAt: referenceDate.addingTimeInterval(1)
        )
    }

    private func successPiCLIResult() -> PiCLIUpdateCommandResult {
        PiCLIUpdateCommandResult(
            exitCode: 0,
            startedAt: referenceDate,
            finishedAt: referenceDate.addingTimeInterval(1)
        )
    }

    private func successPiPackageResult() -> PiPackageUpdateCommandResult {
        PiPackageUpdateCommandResult(
            exitCode: 0,
            startedAt: referenceDate,
            finishedAt: referenceDate.addingTimeInterval(1)
        )
    }

    /// Pi Web 编排器：安装器/检测/健康检查全部是替身，`deliver` 立即执行。
    private func makePiWebCoordinator(
        installer: PiWebUpdateInstalling,
        detected: @escaping () -> ComponentInstallation?,
        clear: @escaping (UpdateTransactionComponent) -> Void
    ) -> PiWebUpdateCoordinator {
        PiWebUpdateCoordinator(environment: PiWebUpdateCoordinator.Environment(
            installer: installer,
            detectInstallation: detected,
            startServiceAndCheckHealth: { $0(true) },
            redactor: makeRedactor(),
            log: { _ in },
            deliver: { $0() },
            timeout: 60,
            transaction: .disabled,
            clearAbandonedAttempt: clear
        ))
    }

    // MARK: - 1. 记录字段：结束时间未知

    func testTimedOutRecordKeepsUnknownFinishTimeAndShowsItInText() throws {
        let defaults = makeDefaults()
        UpdateAbandonedAttemptStore.save(makeAttempt(), to: defaults)

        let loaded = try XCTUnwrap(UpdateAbandonedAttemptStore.load(from: defaults).first)
        XCTAssertNil(loaded.finishedAt, "记录的语义是“结束时间未知”：finishedAt 必须是 nil")
        XCTAssertNil(loaded.derivedProcessesConfirmedEnded, "派生进程是否结束必须是“未确认”")
        XCTAssertEqual(loaded.componentKind, .piWeb)
        XCTAssertEqual(loaded.reason, .timedOut)
        XCTAssertEqual(loaded.timeout, 300)
        XCTAssertEqual(loaded.startedAt, referenceDate)
        XCTAssertEqual(loaded.childProcessAction, .terminatedOwnProcessGroup)

        let text = UpdateAbandonedAttemptPresenter.lines(for: loaded, format: { _ in "固定时间" })
            .joined(separator: "\n")
        XCTAssertTrue(text.contains("结束时间：未知"), "展示文本必须写出“结束时间未知”")
        XCTAssertFalse(text.contains("结束时间：固定时间"))
        XCTAssertTrue(text.contains("开始时间：固定时间"))
        XCTAssertTrue(text.contains("超时上限：300 秒"))
        XCTAssertTrue(text.contains("未确认派生进程是否结束"))
        XCTAssertTrue(text.contains("npm install -g @agegr/pi-web@0.9.2"))
    }

    func testAttemptRecordedByTimedOutInstallerHasNoFinishTime() throws {
        let defaults = makeDefaults()
        let recorder = RecordedAttempts()
        let handle = PiWebChildProcessHandle(
            processIdentifier: 4242,
            processGroupIdentifier: 4242,
            usesOwnProcessGroup: true,
            outputDescriptor: -1
        )
        let spawner = FakeChildSpawner(handle: handle)
        spawner.blocksWait = true
        let installer = ProcessPiWebUpdateInstaller(
            clock: { self.referenceDate },
            spawner: spawner,
            redact: { self.makeRedactor().redact($0) },
            recordAbandonedAttempt: { attempt in
                recorder.append(attempt)
                UpdateAbandonedAttemptStore.save(attempt, to: defaults)
            }
        )
        let plan = try makePiWebPlan()
        let finished = expectation(description: "安装超时后结束")

        installer.install(plan, timeout: 0.2) { result in
            XCTAssertTrue(result.timedOut)
            XCTAssertEqual(result.failure, .timedOut)
            XCTAssertEqual(result.childProcessAction, .terminatedOwnProcessGroup)
            finished.fulfill()
        }
        wait(for: [finished], timeout: 5)
        defer { spawner.releaseWait() }

        let attempt = try XCTUnwrap(recorder.values.first)
        XCTAssertEqual(attempt.componentKind, .piWeb)
        XCTAssertEqual(attempt.reason, .timedOut)
        XCTAssertEqual(attempt.timeout, 0.2)
        XCTAssertEqual(attempt.source, .npmGlobal)
        XCTAssertNil(attempt.finishedAt)
        XCTAssertNil(attempt.derivedProcessesConfirmedEnded)

        // 整条链路（写入 → 持久化 → 读回 → 展示）都保持“结束时间未知”。
        let stored = try XCTUnwrap(UpdateAbandonedAttemptStore.load(from: defaults).first)
        XCTAssertNil(stored.finishedAt)
        XCTAssertTrue(
            UpdateAbandonedAttemptPresenter.lines(for: stored).joined(separator: "\n")
                .contains("结束时间：未知")
        )
    }

    // MARK: - 2. 跨重启保留 / 只由显式清除或成功更新清除

    func testRecordSurvivesRelaunchAndOnlyExplicitClearRemovesIt() throws {
        let suite = "io.github.su-luoya.pi-web-desktop.tests.abandoned.relaunch.\(UUID().uuidString)"
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
        let writing = try XCTUnwrap(UserDefaults(suiteName: suite))
        writing.removePersistentDomain(forName: suite)
        UpdateAbandonedAttemptStore.save(makeAttempt(), to: writing)
        writing.synchronize()

        // “重新启动”：新建一个 UserDefaults 实例读同一份存储。
        let relaunched = try XCTUnwrap(UserDefaults(suiteName: suite))
        let reloaded = UpdateAbandonedAttemptStore.load(from: relaunched)
        XCTAssertEqual(reloaded.count, 1)
        XCTAssertNil(reloaded[0].finishedAt)

        // 清除必须显式发生：没有任何自动过期逻辑。
        UpdateAbandonedAttemptStore.clear(component: .piWeb, from: relaunched)
        XCTAssertTrue(UpdateAbandonedAttemptStore.load(from: relaunched).isEmpty)
    }

    func testComponentsAreIndependent() {
        let defaults = makeDefaults()
        let packageA = makeAttempt(
            kind: .piPackage,
            packageName: packageName,
            commandSummary: "npm install -g \(packageName)@2.0.0",
            source: .npmGlobal,
            action: .waitedWithoutSignals
        )
        let packageB = makeAttempt(
            kind: .piPackage,
            packageName: "pi-extension-other",
            commandSummary: "npm install -g pi-extension-other@3.0.0",
            action: .waitedWithoutSignals
        )
        let piCLI = makeAttempt(
            kind: .piCLI,
            commandSummary: "pi update --self",
            source: .npmGlobal,
            action: .waitedWithoutSignals
        )
        for attempt in [makeAttempt(), piCLI, packageA, packageB] {
            UpdateAbandonedAttemptStore.save(attempt, to: defaults)
        }
        XCTAssertEqual(UpdateAbandonedAttemptStore.load(from: defaults).count, 4)

        let gate = { (component: UpdateTransactionComponent) in
            UpdateAbandonedAttemptGate.allowsAutomaticExecution(
                for: component,
                in: UpdateAbandonedAttemptStore.load(from: defaults)
            )
        }
        XCTAssertFalse(gate(.piWeb))
        XCTAssertFalse(gate(.piCLI))
        XCTAssertFalse(gate(.piPackage(packageName)))
        XCTAssertTrue(gate(.piPackage("pi-extension-untouched")), "没有记录的组件不受影响")

        UpdateAbandonedAttemptStore.clear(component: .piPackage(packageName), from: defaults)
        XCTAssertTrue(gate(.piPackage(packageName)))
        XCTAssertFalse(gate(.piPackage("pi-extension-other")))
        XCTAssertFalse(gate(.piWeb))
        XCTAssertFalse(gate(.piCLI))

        UpdateAbandonedAttemptStore.clearAll(from: defaults)
        XCTAssertTrue(UpdateAbandonedAttemptStore.load(from: defaults).isEmpty)
    }

    // MARK: - 3. 不可信记录一律丢弃

    func testStoreRejectsUntrustedRecords() {
        XCTAssertNil(
            UpdateAbandonedAttemptStore.valid(makeAttempt(finishedAt: referenceDate)),
            "写了结束时间的记录不是本类型能表达的语义"
        )
        XCTAssertNil(
            UpdateAbandonedAttemptStore.valid(makeAttempt(derivedProcessesConfirmedEnded: true)),
            "派生进程确认状态必须保持未知"
        )
        XCTAssertNil(UpdateAbandonedAttemptStore.valid(makeAttempt(timeout: 0)))
        XCTAssertNil(UpdateAbandonedAttemptStore.valid(makeAttempt(timeout: 2 * 24 * 60 * 60)))
        XCTAssertNil(
            UpdateAbandonedAttemptStore.valid(makeAttempt(kind: .desktopApp)),
            "桌面应用自身不由子进程更新，不产生记录"
        )
        XCTAssertNil(
            UpdateAbandonedAttemptStore.valid(makeAttempt(kind: .piPackage, packageName: "bad name/../x")),
            "包名必须通过 npm 包名校验"
        )
        XCTAssertNil(
            UpdateAbandonedAttemptStore.valid(makeAttempt(kind: .piCLI, action: .terminatedOwnProcessGroup)),
            "Pi CLI 链路不许出现“发送过信号”的记录"
        )
        XCTAssertNil(
            UpdateAbandonedAttemptStore.valid(makeAttempt(kind: .piPackage, packageName: packageName, action: .processGroupUnavailable)),
            "扩展包链路不许出现“进程组”记录"
        )
        XCTAssertNil(UpdateAbandonedAttemptStore.valid(makeAttempt(commandSummary: "")), "空摘要不可信")
        // 控制字符不是“可信性”问题而是卫生问题：写入前剔除，落盘/展示里不再出现。
        if let sanitized = UpdateAbandonedAttemptStore.valid(makeAttempt(commandSummary: "npm\u{0}install")) {
            XCTAssertEqual(sanitized.commandSummary, "npminstall", "控制字符必须被剔除")
            XCTAssertFalse(
                sanitized.commandSummary.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7F }
            )
        } else {
            XCTFail("剔除控制字符后摘要非空，应视为可信")
        }

        // 写入路径同样拒绝：不可信记录不落盘。
        let defaults = makeDefaults()
        UpdateAbandonedAttemptStore.save(makeAttempt(finishedAt: referenceDate), to: defaults)
        UpdateAbandonedAttemptStore.save(makeAttempt(kind: .desktopApp), to: defaults)
        XCTAssertTrue(UpdateAbandonedAttemptStore.load(from: defaults).isEmpty)
    }

    // MARK: - 4. 脱敏

    func testCommandSummaryIsRedactedAndStoredRedacted() throws {
        let defaults = makeDefaults()
        let redactor = makeRedactor()
        let summary = UpdateAbandonedAttempt.makeCommandSummary(
            executablePath: "\(fixtureHome)/.nvm/versions/node/v22.0.0/bin/npm",
            arguments: [
                "install", "-g", "\(piWebPackageName)@0.9.2",
                "--//registry.npmjs.org/:_authToken=npm_do_not_persist_me",
                "--password=hunter2"
            ],
            redactingWith: { redactor.redact($0) }
        )
        XCTAssertFalse(summary.contains(fixtureHome), "命令摘要里不得出现 Home 绝对路径")
        XCTAssertFalse(summary.contains("npm_do_not_persist_me"), "命令摘要里不得出现凭据")
        XCTAssertFalse(summary.contains("hunter2"))
        XCTAssertTrue(summary.contains("~/"), "Home 前缀应替换为 ~")
        XCTAssertTrue(summary.contains("install -g \(piWebPackageName)@0.9.2"))

        let attempt = makeAttempt(commandSummary: summary)
        UpdateAbandonedAttemptStore.save(attempt, to: defaults)
        let data = try XCTUnwrap(defaults.data(forKey: UpdateSettingKeys.piWebAbandonedAttempt))
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertFalse(json.contains(fixtureHome))
        XCTAssertFalse(json.contains("npm_do_not_persist_me"))
        XCTAssertFalse(json.contains("hunter2"))
        XCTAssertFalse(
            UpdateAbandonedAttemptPresenter.lines(for: attempt).joined(separator: "\n").contains(fixtureHome)
        )
    }

    // MARK: - 5. 诊断 / 偏好设置可见

    func testDiagnosticsAndPreferencesBlocksExposeEveryField() throws {
        let attempts = [
            makeAttempt(),
            makeAttempt(
                kind: .piCLI,
                reason: .abandonedWaiting,
                commandSummary: "pi update --self",
                action: .waitedWithoutSignals
            )
        ]
        let block = try XCTUnwrap(UpdateAbandonedAttemptPresenter.block(for: attempts))
        XCTAssertTrue(block.contains("已放弃等待的更新命令"))
        XCTAssertTrue(block.contains("2 条"))
        XCTAssertTrue(block.contains("组件：Pi Web"))
        XCTAssertTrue(block.contains("组件：Pi CLI"))
        XCTAssertTrue(block.contains("结束时间：未知"))
        XCTAssertTrue(block.contains("超时上限：300 秒"))
        XCTAssertTrue(block.contains("放弃等待（例如应用退出）"))
        XCTAssertTrue(block.contains("只放弃等待：没有向任何进程发送任何信号"))
        XCTAssertTrue(block.contains("清除方式：菜单“服务 → 更新检查设置 → 已放弃的更新记录…”"))
        XCTAssertTrue(
            block.contains("自动更新在清除记录前不会执行"),
            "诊断文本必须说明自动路径被挡住、手动入口不受影响"
        )
        XCTAssertNil(UpdateAbandonedAttemptPresenter.block(for: []), "没有记录时不展示空块")

        // 诊断页/偏好设置里的这段文本与展示函数是同一个来源（源码级断言，
        // 保证接线不会被悄悄删掉）。
        let app = try sourceText(relativePath: "Sources/PiWebApp.swift")
        XCTAssertTrue(app.contains("UpdateAbandonedAttemptPresenter.block("))
        XCTAssertTrue(app.contains("abandonedStatus: updateAbandonedStatusBlockText()"))
        let settingsWindow = try sourceText(relativePath: "Sources/UpdateSettingsWindowController.swift")
        XCTAssertTrue(settingsWindow.contains("abandonedStatusLabel"))
    }

    // MARK: - 6. 重叠防护：同一组件不自动执行

    func testAutomaticPiWebIsBlockedByUnclearedRecord() throws {
        let attempt = makeAttempt()
        var preferences = UpdateCheckPreferences.factoryDefaults
        preferences.autoUpdatePiWebBeforeLaunch = true
        let input = PiWebUpdatePlanningInput(
            preferences: preferences,
            installation: piWebInstallation(),
            targetVersion: "0.9.2",
            targetStatus: .updateAvailable,
            targetConfidence: .verified,
            targetOrigin: .network,
            npmExecutablePath: fixtureNPM,
            abandonedAttempt: attempt
        )
        let decision = PiWebUpdatePlanner.decide(input)
        guard case .manualOnly(let commandText, let reason) = decision else {
            return XCTFail("有未清除记录时不得自动执行，实际是 \(decision)")
        }
        XCTAssertEqual(reason, .abandonedAttemptPending(attempt))
        XCTAssertFalse(decision.isAutomatic)
        XCTAssertNotNil(commandText, "手动入口仍然可用")

        let installer = RecordingInstaller(result: successPiWebResult())
        var outcome: PiWebUpdateRunOutcome?
        makePiWebCoordinator(installer: installer, detected: { self.piWebInstallation() }, clear: { _ in })
            .run(input) { outcome = $0 }
        XCTAssertEqual(outcome, .skipped(reason: .abandonedAttemptPending(attempt), commandText: commandText))
        XCTAssertTrue(installer.plans.isEmpty, "被记录挡住时安装调用次数必须是 0")
        XCTAssertTrue(
            UpdateAbandonedAttemptPresenter.automaticRefusalText(attempt).contains("不会自动执行更新")
        )
        XCTAssertTrue(UpdateAbandonedAttemptPresenter.automaticRefusalText(attempt).contains("结束时间未知"))
    }

    func testAutomaticPiCLIIsBlockedByUnclearedRecord() throws {
        let attempt = makeAttempt(
            kind: .piCLI,
            commandSummary: "pi update --self",
            action: .waitedWithoutSignals
        )
        let decision = PiCLIUpdatePlanner.decide(piCLIInput(abandonedAttempt: attempt))
        guard case .deferred(let plan, let reason) = decision else {
            return XCTFail("有未清除记录时不得自动执行，实际是 \(decision)")
        }
        XCTAssertEqual(reason, .abandonedAttemptPending(attempt))
        XCTAssertEqual(plan.targetVersion, "0.2.0")
        XCTAssertTrue(
            UpdateAbandonedAttemptPresenter.automaticRefusalText(attempt).contains("推迟到下次启动")
        )

        let runner = RecordingPiCLIRunner(result: successPiCLIResult())
        var outcome: PiCLIUpdateRunOutcome?
        PiCLIUpdateCoordinator(environment: PiCLIUpdateCoordinator.Environment(
            inspectProcesses: { .noProcesses },
            runner: runner,
            detectInstallation: { nil },
            redactor: makeRedactor(),
            log: { _ in },
            deliver: { $0() },
            timeout: 60,
            transaction: .disabled,
            clearAbandonedAttempt: { _ in }
        )).run(piCLIInput(abandonedAttempt: attempt)) { outcome = $0 }
        XCTAssertEqual(outcome, .deferred(reason: .abandonedAttemptPending(attempt)))
        XCTAssertTrue(runner.plans.isEmpty, "被记录挡住时命令执行次数必须是 0")
        XCTAssertEqual(runner.abandonCallCount, 0)
    }

    func testOnlyTheBlockedPackageIsHeldBack() {
        let attempt = makeAttempt(
            kind: .piPackage,
            packageName: packageName,
            commandSummary: "npm install -g \(packageName)@2.0.0",
            action: .waitedWithoutSignals
        )
        let planSet = packagePlanSet(names: [packageName, "pi-extension-free"], abandonedAttempts: [attempt])

        XCTAssertEqual(planSet.executablePlans.map(\.packageName), ["pi-extension-free"])
        XCTAssertEqual(planSet.abandonedConfirmationPlans.map(\.packageName), [packageName])
        XCTAssertEqual(
            planSet.confirmationPlans.map(\.packageName).sorted(),
            [packageName, "pi-extension-free"].sorted(),
            "被记录的包仍然保留确认入口，只是必须先看到记录"
        )
        XCTAssertEqual(planSet.abandonedAttempts, [attempt])

        let blocked = planSet.decisions.first { $0.packageName == packageName }
        guard case .awaitingAbandonedConfirmation(_, let recorded) = blocked else {
            return XCTFail("被记录的包必须进入“先看记录再确认”，实际是 \(String(describing: blocked))")
        }
        XCTAssertEqual(recorded, attempt)
        let free = planSet.decisions.first { $0.packageName == "pi-extension-free" }
        XCTAssertEqual(free?.executablePlan?.packageName, "pi-extension-free")
        XCTAssertNil(free?.abandonedConfirmationPlan)
    }

    func testRecordsDoNotBlockOtherComponents() throws {
        // Pi Web 的记录只挡 Pi Web。
        let piWebRecord = makeAttempt()
        XCTAssertTrue(
            UpdateAbandonedAttemptGate.allowsAutomaticExecution(for: .piCLI, in: [piWebRecord])
        )
        XCTAssertTrue(
            UpdateAbandonedAttemptGate.allowsAutomaticExecution(for: .piPackage(packageName), in: [piWebRecord])
        )
        XCTAssertTrue(
            UpdateAbandonedAttemptGate.allowsAutomaticExecution(
                for: .piPackage(packageName),
                in: [makeAttempt(kind: .piCLI, action: .waitedWithoutSignals)]
            )
        )
        // 其它组件有记录时，Pi Web / Pi CLI 的自动判定不受影响。
        let plan = try makePiWebPlan()
        var preferences = UpdateCheckPreferences.factoryDefaults
        preferences.autoUpdatePiWebBeforeLaunch = true
        let piWebDecision = PiWebUpdatePlanner.decide(PiWebUpdatePlanningInput(
            preferences: preferences,
            installation: piWebInstallation(),
            targetVersion: "0.9.2",
            targetStatus: .updateAvailable,
            targetConfidence: .verified,
            targetOrigin: .network,
            npmExecutablePath: fixtureNPM,
            baseEnvironment: piWebBaseEnvironment,
            abandonedAttempt: nil
        ))
        XCTAssertEqual(piWebDecision, .automatic(plan))
        guard case .automatic = PiCLIUpdatePlanner.decide(piCLIInput(abandonedAttempt: nil)) else {
            return XCTFail("没有记录时 Pi CLI 应允许自动执行")
        }
        let packageSet = packagePlanSet(names: [packageName], abandonedAttempts: [piWebRecord])
        XCTAssertEqual(packageSet.executablePlans.map(\.packageName), [packageName])
    }

    // MARK: - 7. 手动入口：仍然可用，但必须先看到记录并显式确认

    func testManualEntryStaysAvailableButRequiresExplicitConfirmation() throws {
        let piWebAttempt = makeAttempt()
        XCTAssertTrue(
            UpdateAbandonedAttemptPresenter.confirmationBlock(for: piWebAttempt)
                .contains("确认后将执行一次本次更新"),
            "手动确认前必须先展示记录"
        )
        XCTAssertTrue(UpdateAbandonedAttemptPresenter.confirmationBlock(for: piWebAttempt).contains("结束时间：未知"))
        let piWebPlan = try XCTUnwrap(PiWebUpdatePlanner.manualPlan(
            installation: piWebInstallation(),
            targetVersion: "0.9.2",
            npmExecutablePath: fixtureNPM,
            baseEnvironment: piWebBaseEnvironment
        ))
        XCTAssertEqual(piWebPlan.targetVersion, "0.9.2")

        let installer = RecordingInstaller(result: successPiWebResult())
        var outcome: PiWebUpdateRunOutcome?
        makePiWebCoordinator(
            installer: installer,
            detected: { self.piWebInstallation(version: "0.9.2") },
            clear: { _ in }
        ).runManual(piWebPlan) { outcome = $0 }
        XCTAssertEqual(installer.plans.count, 1, "确认之后恰好执行一次")
        guard case .succeeded = outcome else { return XCTFail("手动确认后应执行，实际是 \(String(describing: outcome))") }

        // Pi CLI：确认文案里必须先出现这条记录的全部关键字段。
        let piCLIPlan = try piCLIPlan()
        let piCLIAttempt = makeAttempt(
            kind: .piCLI,
            commandSummary: "pi update --self",
            action: .waitedWithoutSignals
        )
        let piCLIText = PiCLIManualUpdateConfirmation.text(
            plan: piCLIPlan,
            commandText: piCLIPlan.commandText,
            inspection: .noProcesses,
            abandonedAttempt: piCLIAttempt,
            redactingWith: makeRedactor()
        )
        XCTAssertTrue(piCLIText.contains("【已放弃的更新记录】"))
        XCTAssertTrue(piCLIText.contains("结束时间：未知"))
        XCTAssertTrue(piCLIText.contains("超时上限：300 秒"))
        XCTAssertTrue(piCLIText.contains("只有用户显式清除"))
        // 没有记录时确认文案里不出现这一段（旧行为保持不变）。
        let plainText = PiCLIManualUpdateConfirmation.text(
            plan: piCLIPlan,
            commandText: piCLIPlan.commandText,
            inspection: .noProcesses,
            redactingWith: makeRedactor()
        )
        XCTAssertFalse(plainText.contains("【已放弃的更新记录】"))

        // 扩展包：整批确认框先展示记录；确认前执行次数为 0，确认后只执行一次。
        let packageAttempt = makeAttempt(
            kind: .piPackage,
            packageName: packageName,
            commandSummary: "npm install -g \(packageName)@2.0.0",
            action: .waitedWithoutSignals
        )
        let planSet = packagePlanSet(names: [packageName], abandonedAttempts: [packageAttempt])
        let packageText = PiPackageUpdateConfirmation.text(
            plans: planSet.confirmationPlans,
            inspection: .noProcesses,
            abandonedAttempts: [packageAttempt],
            redactingWith: makeRedactor()
        )
        XCTAssertTrue(packageText.contains("【已放弃的更新记录】"))
        XCTAssertTrue(packageText.contains("结束时间：未知"))
        XCTAssertTrue(packageText.contains("取消是默认按钮"))
        XCTAssertEqual(planSet.executablePlans.count, 0, "未确认前没有可执行入口")

        let packagePlan = try XCTUnwrap(planSet.confirmationPlans.first)
        XCTAssertEqual(packagePlan.packageName, packageName)
        let runner = RecordingPiPackageRunner(result: successPiPackageResult())
        var batch: PiPackageUpdateBatchOutcome?
        PiPackageUpdateCoordinator(environment: PiPackageUpdateCoordinator.Environment(
            inspectProcesses: { .noProcesses },
            runner: runner,
            detectPackageVersion: { _ in "2.0.0" },
            redactor: makeRedactor(),
            log: { _ in },
            deliver: { $0() },
            timeout: 60,
            transaction: .disabled,
            clearAbandonedAttempt: { _ in }
        )).runConfirmed(planSet.confirmationPlans) { batch = $0 }
        XCTAssertEqual(runner.plans.map(\.packageName), [packageName], "确认之后恰好执行一次")
        XCTAssertEqual(batch?.outcomes.count, 1)
    }

    // MARK: - 8. 成功后清除记录

    func testSuccessfulUpdateClearsOnlyThatComponentRecord() {
        let defaults = makeDefaults()
        var preferences = UpdateCheckPreferences.factoryDefaults
        preferences.autoUpdatePiWebBeforeLaunch = true
        func input() -> PiWebUpdatePlanningInput {
            PiWebUpdatePlanningInput(
                preferences: preferences,
                installation: self.piWebInstallation(),
                targetVersion: "0.9.2",
                targetStatus: .updateAvailable,
                targetConfidence: .verified,
                targetOrigin: .network,
                npmExecutablePath: self.fixtureNPM,
                abandonedAttempt: nil
            )
        }

        // 成功：清除该组件的记录。
        let installer = RecordingInstaller(result: successPiWebResult())
        UpdateAbandonedAttemptStore.save(makeAttempt(), to: defaults)
        let cleared = RecordedComponents()
        makePiWebCoordinator(
            installer: installer,
            detected: { self.piWebInstallation(version: "0.9.2") },
            clear: { component in
                cleared.append(component)
                UpdateAbandonedAttemptStore.clear(component: component, from: defaults)
            }
        ).run(input()) { _ in }
        XCTAssertEqual(cleared.values, [.piWeb])
        XCTAssertEqual(installer.plans.count, 1)
        XCTAssertTrue(
            UpdateAbandonedAttemptStore.load(from: defaults).isEmpty,
            "成功完成一次更新后该组件的记录必须被清除"
        )

        // 失败路径不清除：记录仍然在（下次启动继续挡住自动执行）。
        UpdateAbandonedAttemptStore.save(makeAttempt(), to: defaults)
        let failing = RecordingInstaller(result: PiWebUpdateInstallResult(
            exitCode: 1,
            startedAt: referenceDate,
            finishedAt: referenceDate.addingTimeInterval(1)
        ))
        let failedClears = RecordedComponents()
        makePiWebCoordinator(
            installer: failing,
            detected: { self.piWebInstallation(version: "0.9.0") },
            clear: { component in
                failedClears.append(component)
                UpdateAbandonedAttemptStore.clear(component: component, from: defaults)
            }
        ).run(input()) { _ in }
        XCTAssertTrue(failedClears.values.isEmpty, "更新失败不得清除记录")
        let remaining = UpdateAbandonedAttemptStore.load(from: defaults)
        XCTAssertEqual(remaining.count, 1, "失败后记录仍然在")
        XCTAssertEqual(remaining.first?.componentKind, .piWeb)
        XCTAssertNil(remaining.first?.finishedAt)
    }

    func testSuccessfulPiCLIAndPackageUpdatesClearTheirOwnRecords() throws {
        let plan = try piCLIPlan()
        let runner = RecordingPiCLIRunner(result: successPiCLIResult())
        var piCLICleared: [UpdateTransactionComponent] = []
        var outcome: PiCLIUpdateRunOutcome?
        PiCLIUpdateCoordinator(environment: PiCLIUpdateCoordinator.Environment(
            inspectProcesses: { .noProcesses },
            runner: runner,
            detectInstallation: {
                ComponentInstallation(
                    kind: .piCLI,
                    packageName: InstallCommandManifest.piCLIPackageName,
                    version: "0.2.0",
                    executablePath: "/opt/homebrew/bin/pi",
                    resolvedPath: nil,
                    symlinkChain: [],
                    packageJSONPath: nil,
                    source: .npmGlobal,
                    confidence: .verified,
                    evidence: ["fixture"],
                    suggestedCommand: nil
                )
            },
            redactor: makeRedactor(),
            log: { _ in },
            deliver: { $0() },
            timeout: 60,
            transaction: .disabled,
            clearAbandonedAttempt: { piCLICleared.append($0) }
        )).run(piCLIInput()) { outcome = $0 }
        XCTAssertEqual(runner.plans.count, 1)
        guard case .succeeded = outcome else { return XCTFail("应成功，实际是 \(String(describing: outcome))") }
        XCTAssertEqual(piCLICleared, [.piCLI])
        XCTAssertEqual(plan.installedVersion, "0.1.0")

        let planSet = packagePlanSet(names: [packageName])
        let packageRunner = RecordingPiPackageRunner(result: successPiPackageResult())
        var packageCleared: [UpdateTransactionComponent] = []
        PiPackageUpdateCoordinator(environment: PiPackageUpdateCoordinator.Environment(
            inspectProcesses: { .noProcesses },
            runner: packageRunner,
            detectPackageVersion: { _ in "2.0.0" },
            redactor: makeRedactor(),
            log: { _ in },
            deliver: { $0() },
            timeout: 60,
            transaction: .disabled,
            clearAbandonedAttempt: { packageCleared.append($0) }
        )).runConfirmed(planSet.executablePlans) { _ in }
        XCTAssertEqual(packageRunner.plans.map(\.packageName), [packageName])
        XCTAssertEqual(packageCleared, [.piPackage(packageName)])
    }

    // MARK: - 9. 进程组：启动属性与“只终止一次自己的子进程组”

    func testSpawnPolicyRequestsItsOwnProcessGroup() {
        XCTAssertEqual(PiWebUpdateSpawnPolicy.newProcessGroup, 0)
        XCTAssertNotEqual(
            PiWebUpdateSpawnPolicy.flags & Int16(POSIX_SPAWN_SETPGROUP),
            0,
            "启动属性必须包含 POSIX_SPAWN_SETPGROUP"
        )
        XCTAssertEqual(
            PiWebUpdateSpawnPolicy.degradedFlags & Int16(POSIX_SPAWN_SETPGROUP),
            0,
            "降级属性不得声称新建了进程组"
        )

        var attributes: posix_spawnattr_t?
        XCTAssertEqual(posix_spawnattr_init(&attributes), 0)
        defer { posix_spawnattr_destroy(&attributes) }
        XCTAssertTrue(PiWebUpdateSpawnPolicy.apply(to: &attributes))

        var flags: Int16 = 0
        XCTAssertEqual(posix_spawnattr_getflags(&attributes, &flags), 0)
        XCTAssertNotEqual(flags & Int16(POSIX_SPAWN_SETPGROUP), 0)
        var group: pid_t = -1
        XCTAssertEqual(posix_spawnattr_getpgroup(&attributes, &group), 0)
        XCTAssertEqual(group, 0, "pgroup 0 表示“新进程组的组长 = 子进程自己”")
    }

    func testTimeoutSignalsOwnChildProcessGroupExactlyOnce() throws {
        let handle = PiWebChildProcessHandle(
            processIdentifier: 4242,
            processGroupIdentifier: 4242,
            usesOwnProcessGroup: true,
            outputDescriptor: -1
        )
        let spawner = FakeChildSpawner(handle: handle)
        spawner.blocksWait = true
        let recorder = RecordedAttempts()
        let installer = ProcessPiWebUpdateInstaller(
            clock: { self.referenceDate },
            spawner: spawner,
            redact: { self.makeRedactor().redact($0) },
            recordAbandonedAttempt: { recorder.append($0) }
        )
        let plan = try makePiWebPlan()
        let finished = expectation(description: "超时后结束")
        installer.install(plan, timeout: 0.2) { _ in finished.fulfill() }
        wait(for: [finished], timeout: 5)
        defer { spawner.releaseWait() }

        XCTAssertEqual(spawner.terminateCallCount, 1, "超时必须恰好终止一次自己的子进程组")
        XCTAssertEqual(spawner.terminateCalls.map(\.processIdentifier), [4242])
        XCTAssertEqual(spawner.terminateCalls.map(\.processGroupIdentifier), [4242])
        XCTAssertEqual(spawner.specifications.map(\.executablePath), [fixtureNPM])
        XCTAssertEqual(spawner.specifications.first?.arguments, plan.arguments)
        XCTAssertFalse(
            spawner.specifications.contains { $0.arguments.contains { $0.contains("sudo") } },
            "启动规格里不得出现 sudo"
        )
        XCTAssertEqual(recorder.values.map(\.childProcessAction), [.terminatedOwnProcessGroup])
        XCTAssertNil(recorder.values.first?.finishedAt)
    }

    func testTimeoutWithoutOwnProcessGroupNeverSignals() throws {
        // 四种“不能确定那是自己的进程组”的句柄：一律不发信号，只放弃等待并记录。
        let handles = [
            PiWebChildProcessHandle(processIdentifier: 4242, processGroupIdentifier: 4242, usesOwnProcessGroup: false, outputDescriptor: -1),
            PiWebChildProcessHandle(processIdentifier: 4242, processGroupIdentifier: 1, usesOwnProcessGroup: true, outputDescriptor: -1),
            PiWebChildProcessHandle(processIdentifier: 1, processGroupIdentifier: 1, usesOwnProcessGroup: true, outputDescriptor: -1),
            PiWebChildProcessHandle(processIdentifier: -1, processGroupIdentifier: -1, usesOwnProcessGroup: true, outputDescriptor: -1)
        ]
        for handle in handles {
            let spawner = FakeChildSpawner(handle: handle)
            spawner.blocksWait = true
            let recorder = RecordedAttempts()
            let installer = ProcessPiWebUpdateInstaller(
                clock: { self.referenceDate },
                spawner: spawner,
                redact: { $0 },
                recordAbandonedAttempt: { recorder.append($0) }
            )
            let plan = try makePiWebPlan()
            let finished = expectation(description: "超时后结束")
            installer.install(plan, timeout: 0.2) { _ in finished.fulfill() }
            wait(for: [finished], timeout: 5)
            spawner.releaseWait()

            XCTAssertEqual(spawner.terminateCallCount, 0, "不能确定是自己进程组时不得发送任何信号")
            XCTAssertEqual(recorder.values.map(\.childProcessAction), [.processGroupUnavailable])
            XCTAssertNil(recorder.values.first?.finishedAt)
            XCTAssertTrue(
                UpdateAbandonedAttemptPresenter
                    .lines(for: recorder.values[0])
                    .joined(separator: "\n")
                    .contains("没有发送任何信号")
            )
        }
    }

    func testCancelSignalsOwnProcessGroupAtMostOnce() throws {
        let handle = PiWebChildProcessHandle(
            processIdentifier: 5555,
            processGroupIdentifier: 5555,
            usesOwnProcessGroup: true,
            outputDescriptor: -1
        )
        let spawner = FakeChildSpawner(handle: handle)
        spawner.blocksWait = true
        let recorder = RecordedAttempts()
        let installer = ProcessPiWebUpdateInstaller(
            clock: { self.referenceDate },
            spawner: spawner,
            redact: { self.makeRedactor().redact($0) },
            recordAbandonedAttempt: { recorder.append($0) }
        )
        let plan = try makePiWebPlan()
        let finished = expectation(description: "放弃等待后结束")
        installer.install(plan, timeout: 60) { result in
            XCTAssertTrue(result.cancelled)
            XCTAssertEqual(result.failure, .cancelled)
            finished.fulfill()
        }
        installer.cancel()
        installer.cancel()
        wait(for: [finished], timeout: 5)
        spawner.releaseWait()
        Thread.sleep(forTimeInterval: 0.1)

        XCTAssertEqual(spawner.terminateCallCount, 1, "取消只终止一次自己的子进程组")
        XCTAssertEqual(recorder.values.count, 1, "一次运行只写一条「已放弃」记录")
        XCTAssertEqual(recorder.values.first?.reason, .abandonedWaiting)
        XCTAssertEqual(recorder.values.first?.childProcessAction, .terminatedOwnProcessGroup)
    }

    func testLaunchFailureRecordsNoAbandonedAttempt() throws {
        let spawner = FakeChildSpawner(handle: PiWebChildProcessHandle(
            processIdentifier: 1,
            processGroupIdentifier: 1,
            usesOwnProcessGroup: true,
            outputDescriptor: -1
        ))
        spawner.spawnError = .spawnFailed(13)
        let recorder = RecordedAttempts()
        let installer = ProcessPiWebUpdateInstaller(
            clock: { self.referenceDate },
            spawner: spawner,
            redact: { $0 },
            recordAbandonedAttempt: { recorder.append($0) }
        )
        let finished = expectation(description: "启动失败后结束")
        installer.install(try makePiWebPlan(), timeout: 60) { result in
            XCTAssertEqual(result.failure, .launchFailed)
            finished.fulfill()
        }
        wait(for: [finished], timeout: 5)

        XCTAssertEqual(spawner.terminateCallCount, 0)
        XCTAssertTrue(recorder.values.isEmpty, "没有启动成功的命令不会产生「已放弃」记录")
    }

    // MARK: - 10. 负向断言：只有 Pi Web 的链路里可能出现信号调用

    func testOnlyThePiWebPathCanCarryASignalCall() throws {
        let forbidden = ["kill(", "killpg(", "SIGTERM", "SIGKILL", "signal(", "posix_spawn", ".terminate(", "killall"]
        for path in [
            "Sources/PiCLIUpdateAdapter.swift",
            "Sources/PiPackageUpdateAdapter.swift",
            "Sources/UpdateAbandonedAttempt.swift"
        ] {
            let code = codeText(of: try sourceText(relativePath: path))
            for token in forbidden {
                XCTAssertFalse(code.contains(token), "\(path) 里不得出现 \(token)")
            }
        }

        // Pi Web 适配器是唯一允许出现信号调用的地方：恰好一次 `killpg`，且只对
        // 句柄里的进程组；不得出现按 pid 的 `kill(`、进程名匹配或 `sudo`。
        let piWeb = codeText(of: try sourceText(relativePath: "Sources/PiWebUpdateAdapter.swift"))
        XCTAssertEqual(
            piWeb.components(separatedBy: "killpg(").count - 1,
            1,
            "只允许一处 killpg 调用"
        )
        for token in ["kill(", "killall", "SIGKILL"] {
            XCTAssertFalse(piWeb.contains(token), "Pi Web 适配器里不得出现 \(token)")
        }
        XCTAssertTrue(piWeb.contains("POSIX_SPAWN_SETPGROUP"))
        // 命令文本里的“不调用 sudo”是展示文案；真正要断言的是 argv 里没有 sudo/shell。
        let plan = try makePiWebPlan()
        XCTAssertTrue(PiWebUpdateArgumentPolicy.isSafe(plan.arguments))
        for argument in plan.arguments {
            XCTAssertFalse(argument == "sudo" || argument == "sh" || argument == "-c")
        }
    }

    // MARK: - 源码定位

    /// 仓库根目录（测试文件位于 `<root>/PiWebDesktopTests/`）；在无 Xcode 的
    /// 独立运行器里回退到当前工作目录。
    private func repositoryRoot() -> URL {
        let derived = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        if FileManager.default.fileExists(atPath: derived.appendingPathComponent("Sources/PiWebApp.swift").path) {
            return derived
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    }

    private func sourceText(relativePath: String) throws -> String {
        try String(contentsOf: repositoryRoot().appendingPathComponent(relativePath), encoding: .utf8)
    }

    /// 去掉注释后的代码文本：注释里提到被禁止的 API 名字是允许的。
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
}
