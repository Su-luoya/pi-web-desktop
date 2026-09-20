import Foundation
import XCTest

// GitHub #20 的 unhosted 测试。
//
// 假安装器脚本只在 `$TMPDIR` 下创建（带 shebang 的可执行文件、内容由测试写入），
// 绝不执行真实 `npm`、绝不访问网络。编排器、版本重检测与启动/健康检查都用同步
// 替身，因此断言确定、无需 sleep（唯一的真实子进程用例是 `Process` 安装器本身，
// 它执行的也只是临时目录里的假脚本）。
//
// 不写真实 Home、Application Support 或 `~/.pi`；唯一写 UserDefaults 的用例使用
// suiteName 隔离的 domain，测试结束即删除。

final class PiWebUpdateAdapterTests: XCTestCase {

    private let referenceDate = Date(timeIntervalSince1970: 1_700_000_000)
    private let fixtureHome = "/tmp/pi-web-update-tests-home"
    private let fixtureNPM = "/opt/homebrew/bin/npm"
    private let baseEnvironment = ["PATH": "/usr/bin:/bin", "HOME": "/tmp/pi-web-update-tests-home"]

    // MARK: - 替身

    private final class LogSink {
        private(set) var messages: [String] = []

        func append(_ message: String) {
            messages.append(message)
        }

        var text: String { messages.joined(separator: "\n") }
    }

    private final class RecordingInstaller: PiWebUpdateInstalling {
        private(set) var plans: [PiWebUpdateInstallPlan] = []
        private(set) var timeouts: [TimeInterval] = []
        private(set) var cancelCount = 0
        var isRunning = false
        var result: (PiWebUpdateInstallPlan) -> PiWebUpdateInstallResult = { _ in
            PiWebUpdateInstallResult(
                exitCode: 0,
                startedAt: Date(timeIntervalSince1970: 1_700_000_000),
                finishedAt: Date(timeIntervalSince1970: 1_700_000_001)
            )
        }

        func install(
            _ plan: PiWebUpdateInstallPlan,
            timeout: TimeInterval,
            completion: @escaping (PiWebUpdateInstallResult) -> Void
        ) {
            plans.append(plan)
            timeouts.append(timeout)
            completion(result(plan))
        }

        func cancel() {
            cancelCount += 1
        }
    }

    private final class ResultBox {
        var value: PiWebUpdateInstallResult?
    }

    private final class CoordinatorWorld {
        let installer = RecordingInstaller()
        let log = LogSink()
        let homeDirectory: String
        var detectedInstallation: ComponentInstallation?
        private(set) var detectionCount = 0
        var healthResults: [Bool] = []
        private(set) var startCallCount = 0
        private(set) var healthCheckCallCount = 0
        /// W3B F2：为 true 时健康检查不立即回调（模拟“安装已结束、事务还在尾段”），
        /// 由测试显式放行。
        var parksHealthCheck = false
        private var parkedHealthCompletion: ((Bool) -> Void)?

        func releaseParkedHealthCheck(_ ready: Bool = true) {
            let completion = parkedHealthCompletion
            parkedHealthCompletion = nil
            completion?(ready)
        }

        init(homeDirectory: String) {
            self.homeDirectory = homeDirectory
        }

        func makeCoordinator(
            timeout: TimeInterval = 60,
            transaction: UpdateTransactionEnvironment = .disabled
        ) -> PiWebUpdateCoordinator {
            PiWebUpdateCoordinator(environment: PiWebUpdateCoordinator.Environment(
                installer: installer,
                detectInstallation: {
                    self.detectionCount += 1
                    return self.detectedInstallation
                },
                startServiceAndCheckHealth: { completion in
                    self.startCallCount += 1
                    self.healthCheckCallCount += 1
                    if self.parksHealthCheck {
                        self.parkedHealthCompletion = completion
                        return
                    }
                    let ready = self.healthResults.isEmpty ? true : self.healthResults.removeFirst()
                    completion(ready)
                },
                redactor: LogRedactor(homeDirectory: self.homeDirectory),
                log: { message in self.log.append(message) },
                deliver: { work in work() },
                timeout: timeout,
                transaction: transaction
            ))
        }
    }

    // MARK: - 夹具

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pi-web-update-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// 写一个可执行的假安装器脚本（只写内容，不执行真实 npm）。
    private func makeScript(in directory: URL, name: String = "npm", body: String) throws -> String {
        let url = directory.appendingPathComponent(name)
        try ("#!/bin/sh\n" + body + "\n").write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url.path
    }

    private func installation(
        kind: ComponentKind = .piWeb,
        packageName: String? = InstallCommandManifest.piWebPackageName,
        version: String? = "0.9.0",
        executablePath: String? = "/opt/homebrew/bin/pi-web",
        resolvedPath: String? = "/opt/homebrew/lib/node_modules/@agegr/pi-web/bin/pi-web.js",
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
            suggestedCommand: InstallCommandManifest.updateGuidance(for: kind, source: source)?.command
        )
    }

    /// `targetOrigin` 的默认值是 `.network`：既有用例描述的是“本次运行刚从白名单
    /// 主机取得结果”的场景。缓存回退场景由专门用例显式传入（GitHub #59）。
    private func input(
        installation: ComponentInstallation?,
        targetVersion: String? = "0.9.2",
        targetStatus: UpdateCheckStatus = .updateAvailable,
        targetConfidence: DetectionConfidence = .verified,
        targetOrigin: UpdateCheckOrigin = .network,
        targetCacheWrittenAt: Date? = nil,
        serviceIsRunning: Bool = false,
        npmExecutablePath: String? = "/opt/homebrew/bin/npm",
        autoUpdate: Bool = true,
        baseEnvironment: [String: String]? = nil
    ) -> PiWebUpdatePlanningInput {
        var preferences = UpdateCheckPreferences.factoryDefaults
        preferences.autoUpdatePiWebBeforeLaunch = autoUpdate
        return PiWebUpdatePlanningInput(
            preferences: preferences,
            installation: installation,
            targetVersion: targetVersion,
            targetStatus: targetStatus,
            targetConfidence: targetConfidence,
            targetOrigin: targetOrigin,
            targetCacheWrittenAt: targetCacheWrittenAt,
            serviceIsRunning: serviceIsRunning,
            npmExecutablePath: npmExecutablePath,
            baseEnvironment: baseEnvironment ?? self.baseEnvironment
        )
    }

    private func makePlan(
        installedVersion: String = "0.9.0",
        targetVersion: String = "0.9.2",
        npmExecutablePath: String? = nil,
        baseEnvironment: [String: String]? = nil
    ) throws -> PiWebUpdateInstallPlan {
        try XCTUnwrap(PiWebUpdateInstallPlan.make(
            packageName: InstallCommandManifest.piWebPackageName,
            installedVersion: installedVersion,
            targetVersion: targetVersion,
            npmExecutablePath: npmExecutablePath ?? fixtureNPM,
            baseEnvironment: baseEnvironment ?? self.baseEnvironment,
            source: .npmGlobal,
            confidence: .verified
        ))
    }

    private func successResult() -> PiWebUpdateInstallResult {
        PiWebUpdateInstallResult(
            exitCode: 0,
            startedAt: referenceDate,
            finishedAt: referenceDate.addingTimeInterval(1)
        )
    }

    // MARK: - 1. 设置关闭 → 不调用安装器

    func testSettingDisabledNeverInvokesInstaller() throws {
        let world = CoordinatorWorld(homeDirectory: fixtureHome)
        let request = input(installation: installation(), autoUpdate: false)
        let decision = PiWebUpdatePlanner.decide(request)

        guard case .manualOnly(let commandText, let reason) = decision else {
            return XCTFail("设置关闭时必须只展示命令，实际是 \(decision)")
        }
        XCTAssertEqual(reason, .settingDisabled)
        XCTAssertEqual(commandText, InstallCommandManifest.updateNPMPiWeb.command)
        XCTAssertFalse(decision.isAutomatic)

        var outcome: PiWebUpdateRunOutcome?
        world.makeCoordinator().run(request) { outcome = $0 }
        XCTAssertEqual(outcome, .skipped(reason: .settingDisabled, commandText: commandText))
        XCTAssertTrue(world.installer.plans.isEmpty, "设置关闭时安装调用次数必须为 0")
        XCTAssertEqual(world.detectionCount, 0)
        XCTAssertEqual(world.startCallCount, 0)
    }

    // MARK: - 2. 非 npmGlobal / 未验证来源 → 只产出命令文本

    func testNonNPMOrUnverifiedSourcesNeverInstallAutomatically() throws {
        let cases: [(name: String, installation: ComponentInstallation)] = [
            ("pnpm", installation(source: .pnpmGlobal, confidence: .verified)),
            ("homebrew", installation(source: .homebrew, confidence: .verified)),
            ("nvm", installation(source: .nvm, confidence: .verified)),
            ("mise", installation(source: .mise, confidence: .verified)),
            ("git", installation(source: .gitCheckout, confidence: .verified)),
            ("local", installation(source: .localPath, confidence: .inferred)),
            ("unknown", installation(source: .unknown, confidence: .unknown)),
            ("npm-inferred", installation(source: .npmGlobal, confidence: .inferred))
        ]
        for testCase in cases {
            let world = CoordinatorWorld(homeDirectory: fixtureHome)
            let request = input(installation: testCase.installation)
            let decision = PiWebUpdatePlanner.decide(request)
            XCTAssertFalse(decision.isAutomatic, "\(testCase.name) 不允许自动安装")
            XCTAssertEqual(decision.reason, .sourceNotVerifiedNPMGlobal(
                source: testCase.installation.source,
                confidence: testCase.installation.confidence
            ))
            // 命令文本只来自 #16 的静态清单：npm/pnpm 有命令，其余来源为 nil。
            XCTAssertEqual(decision.commandText, testCase.installation.suggestedCommand)

            var outcome: PiWebUpdateRunOutcome?
            world.makeCoordinator().run(request) { outcome = $0 }
            guard case .skipped(let reason, let commandText) = outcome else {
                return XCTFail("\(testCase.name) 应当只跳过，实际是 \(String(describing: outcome))")
            }
            XCTAssertEqual(reason, decision.reason)
            XCTAssertEqual(commandText, decision.commandText)
            XCTAssertTrue(world.installer.plans.isEmpty, "\(testCase.name) 安装调用次数必须为 0")
            XCTAssertEqual(world.startCallCount, 0)
        }
    }

    func testPromiseThatOnlyVerifiedNPMGlobalSourcesCanInstall() throws {
        // pnpm 是包管理器来源，但不允许自动安装。
        var pnpmInput = input(installation: installation(source: .pnpmGlobal))
        pnpmInput.preferences.autoUpdatePiWebBeforeLaunch = true
        XCTAssertFalse(PiWebUpdatePlanner.decide(pnpmInput).isAutomatic)
        XCTAssertFalse(PiWebUpdatePlanner.needsTargetVersionBeforeLaunch(
            preferences: pnpmInput.preferences,
            installation: pnpmInput.installation
        ))
        // npm 全局但可信度不是 verified，同样不允许。
        XCTAssertFalse(PiWebUpdatePlanner.decide(input(installation: installation(confidence: .inferred))).isAutomatic)
        XCTAssertFalse(PiWebUpdatePlanner.decide(input(installation: installation(source: .gitCheckout))).isAutomatic)
        XCTAssertTrue(PiWebUpdatePlanner.needsTargetVersionBeforeLaunch(
            preferences: input(installation: installation()).preferences,
            installation: installation()
        ))
    }

    // MARK: - 3. verified npmGlobal + 设置开 → 参数数组安装

    func testVerifiedNPMGlobalBuildsArgumentArrayWithoutShellOrSudo() throws {
        let request = input(installation: installation())
        let decision = PiWebUpdatePlanner.decide(request)
        guard case .automatic(let plan) = decision else {
            return XCTFail("应允许自动安装，实际是 \(decision)")
        }
        XCTAssertEqual(plan.npmExecutablePath, fixtureNPM)
        XCTAssertEqual(plan.arguments, ["install", "-g", "@agegr/pi-web@0.9.2"])
        XCTAssertEqual(plan.packageName, InstallCommandManifest.piWebPackageName)
        XCTAssertEqual(plan.installedVersion, "0.9.0")
        XCTAssertEqual(plan.targetVersion, "0.9.2")
        XCTAssertEqual(plan.source, .npmGlobal)
        XCTAssertEqual(plan.confidence, .verified)
        XCTAssertFalse(plan.arguments.contains("sudo"))
        for argument in plan.arguments {
            XCTAssertTrue(PiWebUpdateArgumentPolicy.isSafe(argument: argument), "参数必须是字面量：\(argument)")
        }

        // 编排器把同一个计划交给安装器，并传入注入的超时。
        let world = CoordinatorWorld(homeDirectory: fixtureHome)
        world.detectedInstallation = installation(version: "0.9.2")
        world.healthResults = [true]
        var outcome: PiWebUpdateRunOutcome?
        world.makeCoordinator(timeout: 42).run(request) { outcome = $0 }
        XCTAssertEqual(world.installer.plans, [plan])
        XCTAssertEqual(world.installer.timeouts, [42])
        XCTAssertEqual(outcome, .succeeded(plan: plan, oldVersion: "0.9.0", newVersion: "0.9.2"))
        XCTAssertEqual(world.startCallCount, 1)
    }

    // MARK: - 3b. 来源硬前置：缓存回退不驱动自动安装（GitHub #59）

    /// 只有缓存结果、没有本次网络结果：即使其余前置条件全部满足，也只给手动
    /// 入口，安装调用次数为 0；拒绝原因写入日志且包含“缓存”与缓存写入时间。
    func testCacheFallbackOriginOnlyOffersManualCommand() throws {
        let world = CoordinatorWorld(homeDirectory: fixtureHome)
        let cachedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let request = input(
            installation: installation(),
            targetOrigin: .cachedFallback,
            targetCacheWrittenAt: cachedAt
        )
        let decision = PiWebUpdatePlanner.decide(request)

        guard case .manualOnly(let commandText, let reason) = decision else {
            return XCTFail("缓存回退不应允许自动安装，实际是 \(decision)")
        }
        XCTAssertEqual(reason, .targetNotFromNetwork(origin: .cachedFallback, cacheWrittenAt: cachedAt))
        XCTAssertFalse(decision.isAutomatic)
        XCTAssertEqual(commandText, InstallCommandManifest.updateNPMPiWeb.command)

        var outcome: PiWebUpdateRunOutcome?
        world.makeCoordinator().run(request) { outcome = $0 }
        guard case .skipped(let skippedReason, let skippedCommand) = outcome else {
            return XCTFail("缓存回退应只跳过，实际是 \(String(describing: outcome))")
        }
        XCTAssertEqual(skippedReason, reason)
        XCTAssertEqual(skippedCommand, commandText)
        XCTAssertTrue(world.installer.plans.isEmpty, "缓存回退时安装调用次数必须为 0")
        XCTAssertEqual(world.startCallCount, 0)
        XCTAssertEqual(world.detectionCount, 0)

        // 可读的拒绝原因写入日志：包含“缓存”与缓存写入时间，不含误导措辞。
        let expectedCommand = try XCTUnwrap(InstallCommandManifest.updateNPMPiWeb.command)
        let log = world.log.text
        XCTAssertTrue(log.contains("本机缓存"))
        XCTAssertTrue(log.contains(UpdateCheckTimestamp.text(cachedAt)))
        XCTAssertFalse(log.contains("已验证"))
        XCTAssertFalse(log.contains("官方"))
        XCTAssertTrue(log.contains(expectedCommand))
    }

    /// 缓存缺失（`.unavailable`）同样不自动安装。
    func testUnavailableOriginOnlyOffersManualCommand() {
        let request = input(installation: installation(), targetOrigin: .unavailable)
        let decision = PiWebUpdatePlanner.decide(request)

        XCTAssertEqual(
            decision,
            .manualOnly(
                commandText: InstallCommandManifest.updateNPMPiWeb.command,
                reason: .targetNotFromNetwork(origin: .unavailable, cacheWrittenAt: nil)
            )
        )
        XCTAssertFalse(decision.isAutomatic)
    }

    /// 规划输入的默认来源是最安全的一档：漏传来源时不会退化成“允许自动安装”。
    func testPlanningInputDefaultsToNoAutomaticInstallOrigin() {
        var preferences = UpdateCheckPreferences.factoryDefaults
        preferences.autoUpdatePiWebBeforeLaunch = true
        let bare = PiWebUpdatePlanningInput(preferences: preferences, installation: installation())

        XCTAssertEqual(bare.targetOrigin, .unavailable)
        XCTAssertFalse(bare.targetOrigin.isEligibleForAutomaticInstall)
        XCTAssertFalse(PiWebUpdatePlanner.decide(bare).isAutomatic)
    }

    func testArgumentPolicyRejectsShellMetacharactersAndSudo() {
        XCTAssertTrue(PiWebUpdateArgumentPolicy.isSafe(["install", "-g", "@agegr/pi-web@0.9.2"]))
        XCTAssertFalse(PiWebUpdateArgumentPolicy.isSafe(["sudo", "install"]))
        XCTAssertFalse(PiWebUpdateArgumentPolicy.isSafe(["install", "-g", "@agegr/pi-web@0.9.2; touch pwned"]))
        XCTAssertFalse(PiWebUpdateArgumentPolicy.isSafe(["install", "-g", "$(whoami)"]))
        XCTAssertFalse(PiWebUpdateArgumentPolicy.isSafe(["install", "-g", "`whoami`"]))
        XCTAssertFalse(PiWebUpdateArgumentPolicy.isSafe(["sh", "-c", "npm install"]))
        XCTAssertFalse(PiWebUpdateArgumentPolicy.isSafe(["install -g"]))
        XCTAssertFalse(PiWebUpdateArgumentPolicy.isSafe([]))
    }

    func testPlanRejectsHostilePackageNameAndTargetVersion() {
        XCTAssertNil(PiWebUpdateInstallPlan.make(
            packageName: "@agegr/pi-web; touch pwned",
            installedVersion: "0.9.0",
            targetVersion: "0.9.2",
            npmExecutablePath: fixtureNPM,
            baseEnvironment: baseEnvironment,
            source: .npmGlobal,
            confidence: .verified
        ))
        XCTAssertNil(PiWebUpdateInstallPlan.make(
            packageName: "@agegr/pi-web",
            installedVersion: "0.9.0",
            targetVersion: "0.9.2; touch pwned",
            npmExecutablePath: fixtureNPM,
            baseEnvironment: baseEnvironment,
            source: .npmGlobal,
            confidence: .verified
        ))
        // 包名必须是 Pi Web 的静态包名，不能是任意 npm 包。
        XCTAssertNil(PiWebUpdateInstallPlan.make(
            packageName: "left-pad",
            installedVersion: "0.9.0",
            targetVersion: "0.9.2",
            npmExecutablePath: fixtureNPM,
            baseEnvironment: baseEnvironment,
            source: .npmGlobal,
            confidence: .verified
        ))
        XCTAssertEqual(PiWebUpdatePlanner.decide(input(installation: installation(packageName: "left-pad"))).reason, .invalidPackageName)
        XCTAssertEqual(PiWebUpdatePlanner.decide(input(installation: installation(packageName: nil))).reason, .invalidPackageName)
        XCTAssertEqual(PiWebUpdatePlanner.decide(input(installation: installation(), targetVersion: "not-a-version")).reason, .invalidTargetVersion)
        XCTAssertEqual(PiWebUpdatePlanner.decide(input(installation: installation(), targetVersion: nil)).reason, .noTargetVersion)
        XCTAssertEqual(PiWebUpdatePlanner.decide(input(installation: installation(version: "0.9.2"))).reason, .noNewerTargetVersion)
        XCTAssertEqual(PiWebUpdatePlanner.decide(input(installation: installation(), targetConfidence: .inferred)).reason, .targetNotVerified)
        XCTAssertEqual(PiWebUpdatePlanner.decide(input(installation: installation(), targetStatus: .upToDate)).reason, .noTargetVersion)
        XCTAssertEqual(PiWebUpdatePlanner.decide(input(installation: installation(), npmExecutablePath: nil)).reason, .npmExecutableUnresolved)
        XCTAssertEqual(PiWebUpdatePlanner.decide(input(installation: nil, autoUpdate: true)).reason, .missingInstallation)
    }

    func testEnvironmentWhitelistDropsCredentialsAndNodeOptions() throws {
        let plan = try makePlan(baseEnvironment: [
            "PATH": "/usr/bin:/bin",
            "HOME": fixtureHome,
            "LANG": "en_US.UTF-8",
            "TMPDIR": "/tmp/pi-web-update-tests",
            "PI_WEB_PASSWORD": "super-secret-value",  // scan-secrets: allow(reason=test fixture environment)
            "AWS_SECRET_ACCESS_KEY": "aws-secret",
            "NODE_OPTIONS": "--require /tmp/evil.js",
            "NODE_PATH": "/tmp/evil-modules",
            "npm_config_registry": "https://example.invalid",
            "HTTP_PROXY": "http://user:pass@example.invalid:8080"
        ])
        XCTAssertEqual(Set(plan.environment.keys), ["PATH", "HOME", "LANG", "TMPDIR"])
        XCTAssertNil(plan.environment["PI_WEB_PASSWORD"])
        XCTAssertNil(plan.environment["AWS_SECRET_ACCESS_KEY"])
        XCTAssertNil(plan.environment["NODE_OPTIONS"])
        XCTAssertNil(plan.environment["NODE_PATH"])
        XCTAssertNil(plan.environment["npm_config_registry"])
        XCTAssertNil(plan.environment["HTTP_PROXY"])
        // npm 所在目录被放到 PATH 最前（shebang 需要解析 node）。
        XCTAssertEqual(plan.environment["PATH"]?.hasPrefix("/opt/homebrew/bin:"), true)
        // 展示文本只列键名，不含任何值。
        let lines = plan.displayLines(redactingWith: LogRedactor(homeDirectory: fixtureHome)).joined(separator: "\n")
        XCTAssertTrue(lines.contains("HOME"))
        XCTAssertFalse(lines.contains("super-secret-value"))
        XCTAssertFalse(lines.contains("aws-secret"))
        XCTAssertFalse(lines.contains("--require"))
    }

    // MARK: - 3b. npm 生命周期脚本策略（GitHub #60，对应 alpha.3 安全审查 A-2）

    /// argv 精确等于普通 `npm install -g`：刻意不传 `--ignore-scripts`，因此上游包声明的
    /// 安装期脚本按 npm 默认语义执行。结论与证据在 `PiWebUpdateLifecycleScriptPolicy` 里，
    /// 那是一次**静态评估**（只读检查上游 `package.json`、`bin/prepare-terminal.js` 与依赖
    /// `node-pty` 自己的安装脚本），没有真的执行过安装。
    func testAutomaticInstallArgumentsNeverPassIgnoreScripts() throws {
        let plan = try makePlan()
        XCTAssertEqual(plan.arguments, ["install", "-g", "@agegr/pi-web@0.9.2"])
        XCTAssertEqual(plan.arguments.count, 3)
        XCTAssertFalse(plan.arguments.contains("--ignore-scripts"))
        XCTAssertFalse(plan.arguments.contains { $0.hasPrefix("--ignore-scripts") })
        // 决策本身是可断言的事实：应用不替用户决定 npm 脚本策略。
        XCTAssertFalse(PiWebUpdateLifecycleScriptPolicy.passesIgnoreScripts)
        XCTAssertTrue(PiWebUpdateLifecycleScriptPolicy.rationale.contains("--ignore-scripts"))
        XCTAssertTrue(PiWebUpdateLifecycleScriptPolicy.rationale.contains("npm"))
        // 日志/诊断/确认框必须给出可复现的 argv，并带上这条生命周期脚本说明。
        let text = plan.displayLines(redactingWith: LogRedactor(homeDirectory: fixtureHome)).joined(separator: "\n")
        XCTAssertTrue(text.contains("参数数组：\"install\", \"-g\", \"@agegr/pi-web@0.9.2\""))
        XCTAssertTrue(text.contains(PiWebUpdateLifecycleScriptPolicy.rationale))
    }

    /// 子进程环境白名单不注入 `npm_config_ignore_scripts`：脚本策略由用户的 npm 配置与上游包
    /// 决定，应用既不传开关也不改写 npm 配置（既有行为：所有 `npm_config_*` 一律不传递）。
    func testChildEnvironmentNeverCarriesIgnoreScriptsOverride() throws {
        let plan = try makePlan(baseEnvironment: [
            "PATH": "/usr/bin:/bin",
            "HOME": fixtureHome,
            "npm_config_ignore_scripts": "true",
            "NPM_CONFIG_IGNORE_SCRIPTS": "true",
            "npm_config_registry": "https://example.invalid"
        ])
        XCTAssertEqual(Set(plan.environment.keys), ["PATH", "HOME"])
        XCTAssertNil(plan.environment["npm_config_ignore_scripts"])
        XCTAssertNil(plan.environment["NPM_CONFIG_IGNORE_SCRIPTS"])
        XCTAssertNil(plan.environment["npm_config_registry"])
        XCTAssertFalse(PiWebUpdateEnvironment.allowedKeys.contains { $0.lowercased().hasPrefix("npm_config_") })
        XCTAssertFalse(plan.environment.keys.contains { $0.lowercased().hasPrefix("npm_config_") })
    }

    // MARK: - 4. 安装成功但版本未变化 → 版本验证失败

    func testInstallerSuccessWithUnchangedVersionFailsVerification() throws {
        let world = CoordinatorWorld(homeDirectory: fixtureHome)
        let plan = try makePlan()
        let request = input(installation: installation())
        // 假安装器成功退出，但重新检测仍是旧版本。
        world.detectedInstallation = installation(version: "0.9.0")
        var outcome: PiWebUpdateRunOutcome?
        world.makeCoordinator().run(request) { outcome = $0 }

        XCTAssertEqual(outcome, .versionUnchanged(
            plan: plan,
            detectedVersion: "0.9.0",
            oldVersion: "0.9.0",
            targetVersion: "0.9.2"
        ))
        XCTAssertEqual(world.installer.plans.count, 1)
        XCTAssertEqual(world.detectionCount, 1)
        XCTAssertEqual(world.startCallCount, 0, "版本验证失败时不得启动服务")
        let warning = try XCTUnwrap(outcome?.warning)
        XCTAssertEqual(warning.kind, .versionUnchanged)
        XCTAssertEqual(warning.oldVersion, "0.9.0")
        XCTAssertEqual(warning.targetVersion, "0.9.2")
        XCTAssertTrue(warning.text.contains("不会自动回滚"))
        XCTAssertTrue(warning.text.contains("0.9.2"))
        XCTAssertTrue(world.log.text.contains("不会自动回滚"))
    }

    /// 重新检测不到任何版本（识别器无法确认）同样按版本验证失败处理。
    func testUnverifiableRedetectionFailsVerification() throws {
        let world = CoordinatorWorld(homeDirectory: fixtureHome)
        world.detectedInstallation = nil
        var outcome: PiWebUpdateRunOutcome?
        world.makeCoordinator().run(input(installation: installation())) { outcome = $0 }
        XCTAssertEqual(outcome?.warning?.kind, .versionUnchanged)
        XCTAssertEqual(world.startCallCount, 0)
    }

    func testSuccessfulUpdateHistoryRecordsPassedHealthCheck() throws {
        let world = CoordinatorWorld(homeDirectory: fixtureHome)
        world.detectedInstallation = installation(version: "0.9.2")
        world.healthResults = [true]
        var history: [UpdateHistoryEntry] = []
        let transaction = UpdateTransactionEnvironment(
            probe: .disabled,
            recordHistory: { history.append($0) },
            applyDegradation: { _ in },
            now: { self.referenceDate }
        )

        var outcome: PiWebUpdateRunOutcome?
        world.makeCoordinator(transaction: transaction)
            .run(input(installation: installation())) { outcome = $0 }

        XCTAssertTrue(try XCTUnwrap(outcome).isSucceeded)
        let entry = try XCTUnwrap(history.first)
        let verification = try XCTUnwrap(entry.phases.first { $0.phase == .verify })
        XCTAssertEqual(verification.status, .succeeded)
        XCTAssertTrue(verification.reason.contains("健康检查（既有路径）报告服务可用"))
        XCTAssertFalse(verification.reason.contains("尚未启动服务"))
        XCTAssertFalse(verification.reason.contains("健康检查未运行"))
    }

    // MARK: - 5. 版本变化但健康检查失败 → 降级 + 持久警告

    func testHealthCheckFailureAfterSuccessfulUpdateKeepsOldVersionRecorded() throws {
        let world = CoordinatorWorld(homeDirectory: fixtureHome)
        let plan = try makePlan()
        world.detectedInstallation = installation(version: "0.9.2")
        world.healthResults = [false]
        var outcome: PiWebUpdateRunOutcome?
        world.makeCoordinator().run(input(installation: installation())) { outcome = $0 }

        XCTAssertEqual(outcome, .healthCheckFailed(
            plan: plan,
            oldVersion: "0.9.0",
            newVersion: "0.9.2"
        ))
        XCTAssertEqual(world.startCallCount, 1)
        XCTAssertEqual(world.healthCheckCallCount, 1)
        let warning = try XCTUnwrap(outcome?.warning)
        XCTAssertEqual(warning.kind, .healthCheckFailed)
        XCTAssertEqual(warning.oldVersion, "0.9.0")
        XCTAssertEqual(warning.newVersion, "0.9.2")
        XCTAssertTrue(warning.text.contains("0.9.0"))
        XCTAssertTrue(warning.text.contains("健康检查失败"))
        XCTAssertTrue(warning.text.contains("不会自动回滚"))
        XCTAssertTrue(world.log.text.contains("健康检查失败"))
    }

    // MARK: - 6. 安装器失败：超时 / 非零退出 → 失败处理，不崩溃

    func testInstallerFailuresAreReportedWithoutCrashing() throws {
        let cases: [(name: String, result: PiWebUpdateInstallResult, expected: PiWebUpdateInstallFailure)] = [
            ("timeout", PiWebUpdateInstallResult(
                exitCode: nil,
                timedOut: true,
                startedAt: referenceDate,
                finishedAt: referenceDate.addingTimeInterval(1)
            ), .timedOut),
            ("non-zero", PiWebUpdateInstallResult(
                exitCode: 3,
                startedAt: referenceDate,
                finishedAt: referenceDate.addingTimeInterval(1)
            ), .nonZeroExit),
            ("cancelled", PiWebUpdateInstallResult(
                exitCode: nil,
                cancelled: true,
                startedAt: referenceDate,
                finishedAt: referenceDate.addingTimeInterval(1)
            ), .cancelled),
            ("launch-failed", PiWebUpdateInstallResult(
                exitCode: nil,
                launchFailed: true,
                startedAt: referenceDate,
                finishedAt: referenceDate.addingTimeInterval(1)
            ), .launchFailed)
        ]
        for testCase in cases {
            let world = CoordinatorWorld(homeDirectory: fixtureHome)
            let plan = try makePlan()
            world.installer.result = { _ in testCase.result }
            var outcome: PiWebUpdateRunOutcome?
            world.makeCoordinator().run(input(installation: installation())) { outcome = $0 }

            XCTAssertEqual(outcome, .installFailed(
                plan: plan,
                failure: testCase.expected,
                oldVersion: "0.9.0",
                targetVersion: "0.9.2",
                outputTail: nil
            ), "\(testCase.name) 必须按失败处理")
            let warning = try XCTUnwrap(outcome?.warning)
            XCTAssertTrue(warning.text.contains(testCase.expected.text), "\(testCase.name) 警告应含原因")
            XCTAssertEqual(world.detectionCount, 0, "\(testCase.name) 不应进入版本验证")
            XCTAssertEqual(world.startCallCount, 0, "\(testCase.name) 不应启动服务")
            XCTAssertTrue(world.log.text.contains("旧版本保持不变"), "\(testCase.name) 日志应写明旧版本语义")
        }
    }

    // MARK: - 7. 服务运行中发现的更新 → 只安排到下次启动

    func testUpdateDiscoveredWhileServiceRunsIsDeferredToNextLaunch() throws {
        let world = CoordinatorWorld(homeDirectory: fixtureHome)
        let request = input(installation: installation(), serviceIsRunning: true)
        let decision = PiWebUpdatePlanner.decide(request)
        XCTAssertEqual(decision.reason, .serviceRunning)
        XCTAssertFalse(decision.isAutomatic)
        XCTAssertEqual(decision.commandText, InstallCommandManifest.updateNPMPiWeb.command)

        var outcome: PiWebUpdateRunOutcome?
        world.makeCoordinator().run(request) { outcome = $0 }
        XCTAssertEqual(outcome, .skipped(reason: .serviceRunning, commandText: decision.commandText))
        XCTAssertTrue(world.installer.plans.isEmpty, "服务运行期间安装调用次数必须为 0")
        XCTAssertEqual(world.detectionCount, 0)
        XCTAssertEqual(world.startCallCount, 0)
    }

    /// 通知文案：设置打开时明确说明只安排到下次启动。
    func testNotificationTextMentionsDeferredAutoInstall() {
        let result = UpdateCheckResult(
            target: UpdateCheckTarget(category: .piWeb, packageName: nil),
            status: .updateAvailable,
            installedVersion: "0.9.0",
            latestVersion: "0.9.2",
            confidence: .verified,
            freshness: .fresh,
            failure: nil,
            httpStatusCode: 200,
            checkedAt: referenceDate,
            lastSuccessAt: referenceDate
        )
        var preferences = UpdateCheckPreferences.factoryDefaults
        preferences.autoUpdatePiWebBeforeLaunch = true
        let entries = UpdateNotificationPlanner.plan(
            results: [result],
            preferences: preferences,
            ignoredVersions: .empty,
            alreadyNotified: [:]
        )
        let text = UpdateNotificationText.body(for: entries, autoInstallDeferredToNextLaunch: [.piWeb])
        XCTAssertTrue(text.contains("只安排到下次启动"))
        XCTAssertTrue(text.contains("0.9.2"))
        for forbidden in ["~", "password", "token", "secret", "Bearer"] {
            XCTAssertFalse(text.contains(forbidden), "提示内容不应包含 \(forbidden)")
        }
    }

    // MARK: - 8. 脱敏断言

    func testLogsAndDiagnosticsNeverContainHomePathsSecretsOrEnvValues() throws {
        let home = "/tmp/pi-web-update-redaction-home"
        let world = CoordinatorWorld(homeDirectory: home)
        let secret = "svc-token-abc123"
        let plan = try makePlan(
            npmExecutablePath: home + "/bin/npm",
            baseEnvironment: ["PATH": "/usr/bin:/bin", "HOME": home, "PI_WEB_PASSWORD": secret]
        )
        world.installer.result = { _ in
            PiWebUpdateInstallResult(
                exitCode: 7,
                startedAt: Date(timeIntervalSince1970: 1_700_000_000),
                finishedAt: Date(timeIntervalSince1970: 1_700_000_001),
                outputTail: "npm ERR! path \(home)/lib/node_modules token=\(secret)"
            )
        }
        var outcome: PiWebUpdateRunOutcome?
        world.makeCoordinator().run(input(installation: installation(), baseEnvironment: ["PATH": "/usr/bin:/bin", "HOME": home, "PI_WEB_PASSWORD": secret])) { outcome = $0 }

        let warning = try XCTUnwrap(outcome?.warning)
        let redactor = LogRedactor(homeDirectory: home)
        let diagnosticText = redactor.redact(plan.displayLines(redactingWith: redactor).joined(separator: "\n"))
            + "\n" + warning.text
            + "\n" + world.log.text

        XCTAssertTrue(diagnosticText.contains("~/bin/npm"), "Home 路径必须显示为 ~")
        // 真实 Home 前缀用拼接方式写出，避免在仓库文本里出现绝对路径字面量。
        let realHomePrefix = "/" + "Users" + "/"
        XCTAssertFalse(diagnosticText.contains(realHomePrefix))
        for forbidden in [home, secret, "PI_WEB_PASSWORD=" + secret, "--require"] {
            XCTAssertFalse(diagnosticText.contains(forbidden), "脱敏后的文本不应包含 \(forbidden)")
        }
        XCTAssertTrue(diagnosticText.contains(LogRedactor.marker), "输出片段里的凭据必须被替换")
        // 环境变量只记录键名；计划里也不含凭据值。
        XCTAssertNil(plan.environment["PI_WEB_PASSWORD"])
        XCTAssertTrue(world.log.text.contains("环境变量键"))
        XCTAssertFalse(world.log.text.contains(secret))
    }

    func testPlanDisplayShowsExecutableArgumentsVersionsSourceAndConfidence() throws {
        let redactor = LogRedactor(homeDirectory: fixtureHome)
        let plan = try makePlan(npmExecutablePath: fixtureHome + "/bin/npm")
        let text = plan.displayLines(redactingWith: redactor).joined(separator: "\n")
        XCTAssertTrue(text.contains("~/bin/npm"))
        XCTAssertTrue(text.contains("\"install\""))
        XCTAssertTrue(text.contains("\"-g\""))
        XCTAssertTrue(text.contains("\"@agegr/pi-web@0.9.2\""))
        XCTAssertTrue(text.contains("当前版本：0.9.0"))
        XCTAssertTrue(text.contains("目标版本：0.9.2"))
        XCTAssertTrue(text.contains("npm 全局"))
        XCTAssertTrue(text.contains("已验证"))
    }

    // MARK: - npm 解析

    func testNPMResolverPrefersDetectedPrefixAndRequiresExecutableBit() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let prefix = directory.appendingPathComponent("npm-prefix", isDirectory: true)
        let bin = prefix.appendingPathComponent("bin", isDirectory: true)
        let packageBin = prefix.appendingPathComponent("lib/node_modules/@agegr/pi-web/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: packageBin, withIntermediateDirectories: true)

        let resolver = PiWebUpdateNPMResolver(
            fileSystem: SystemDependencyFileSystemProbe(),
            environment: ["PATH": "/usr/bin:/bin"]
        )
        let detected = installation(
            executablePath: bin.appendingPathComponent("pi-web").path,
            resolvedPath: packageBin.appendingPathComponent("pi-web.js").path
        )
        XCTAssertNil(resolver.resolve(installation: detected), "没有可执行位确认的 npm 时不得猜测")

        let npm = bin.appendingPathComponent("npm")
        try "#!/bin/sh\n".write(to: npm, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: npm.path)
        XCTAssertEqual(resolver.resolve(installation: detected), npm.path)
    }

    func testNPMResolverFallsBackToPATH() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let pathBin = directory.appendingPathComponent("path-bin", isDirectory: true)
        try FileManager.default.createDirectory(at: pathBin, withIntermediateDirectories: true)
        let npm = pathBin.appendingPathComponent("npm")
        try "#!/bin/sh\n".write(to: npm, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: npm.path)

        let resolver = PiWebUpdateNPMResolver(
            fileSystem: SystemDependencyFileSystemProbe(),
            environment: ["PATH": pathBin.path]
        )
        XCTAssertEqual(resolver.resolve(installation: nil), npm.path)
        XCTAssertTrue(resolver.candidates(installation: nil).count == 1)
    }

    func testRelativePATHEntryIsFilteredAndReportedPrecisely() {
        let environment = ["PATH": "/usr/bin:relative-bin::/bin", "HOME": fixtureHome]
        let resolver = PiWebUpdateNPMResolver(
            fileSystem: SystemDependencyFileSystemProbe(),
            environment: environment
        )
        XCTAssertEqual(
            resolver.candidates(installation: nil),
            ["/usr/bin/npm", "/bin/npm"],
            "PATH 的相对项与空项不得被解释为当前工作目录下的候选"
        )

        let decision = PiWebUpdatePlanner.decide(input(
            installation: installation(),
            npmExecutablePath: nil,
            baseEnvironment: environment
        ))
        guard case .unavailable(let reason) = decision else {
            return XCTFail("相对 PATH 项且无法解析 npm 时必须明确拒绝，实际是 \(decision)")
        }
        XCTAssertEqual(reason, .unsafeExecutablePath)
        XCTAssertTrue(reason.text.contains("PATH 中的相对项"))
        XCTAssertFalse(reason.text.contains("参数安全校验失败"))
    }

    // MARK: - Process 安装器（只执行临时目录里的假脚本）

    func testProcessInstallerPassesExactArgumentArray() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("argv.txt")
        let script = try makeScript(in: directory, body: """
        printf '%s\\n' "$#" > '\(output.path)'
        for arg in "$@"; do printf '%s\\n' "$arg" >> '\(output.path)'; done
        """)
        let plan = try makePlan(npmExecutablePath: script, baseEnvironment: ["PATH": "/usr/bin:/bin", "HOME": directory.path])

        let box = ResultBox()
        let finished = expectation(description: "installer finished")
        let installer = ProcessPiWebUpdateInstaller()
        installer.install(plan, timeout: 30) { result in
            box.value = result
            finished.fulfill()
        }
        wait(for: [finished], timeout: 30)
        withExtendedLifetime(installer) {}

        XCTAssertEqual(box.value?.failure, nil)
        XCTAssertEqual(box.value?.exitCode, 0)
        XCTAssertNil(box.value?.childProcessAction, "正常结束时没有“已放弃”状态")
        let lines = try String(contentsOf: output, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { !$0.isEmpty }
        XCTAssertEqual(lines, ["3", "install", "-g", "@agegr/pi-web@0.9.2"])
    }

    func testProcessInstallerReportsNonZeroExit() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = try makeScript(in: directory, body: "exit 3")
        let plan = try makePlan(npmExecutablePath: script, baseEnvironment: ["PATH": "/usr/bin:/bin", "HOME": directory.path])

        let box = ResultBox()
        let finished = expectation(description: "installer finished")
        let installer = ProcessPiWebUpdateInstaller()
        installer.install(plan, timeout: 30) { result in
            box.value = result
            finished.fulfill()
        }
        wait(for: [finished], timeout: 30)
        withExtendedLifetime(installer) {}

        XCTAssertEqual(box.value?.exitCode, 3)
        XCTAssertEqual(box.value?.failure, .nonZeroExit)
    }

    func testProcessInstallerTimesOutWithoutBlockingUnbounded() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = try makeScript(in: directory, body: "sleep 5")
        let plan = try makePlan(npmExecutablePath: script, baseEnvironment: ["PATH": "/usr/bin:/bin", "HOME": directory.path])

        let box = ResultBox()
        let finished = expectation(description: "installer timed out")
        let installer = ProcessPiWebUpdateInstaller()
        installer.install(plan, timeout: 0.3) { result in
            box.value = result
            finished.fulfill()
        }
        wait(for: [finished], timeout: 10)
        withExtendedLifetime(installer) {}

        XCTAssertEqual(box.value?.failure, .timedOut)
        XCTAssertEqual(box.value?.timedOut, true)
        XCTAssertLessThan(box.value?.duration ?? .infinity, 5, "超时必须按注入的值提前结束")
        // GitHub #62：超时只终止本次启动的子进程组（真实 posix_spawn + 独立进程组），
        // 并把这件事如实写进结果（不声称派生进程已经结束）。
        XCTAssertEqual(box.value?.childProcessAction, .terminatedOwnProcessGroup)
    }

    func testProcessInstallerReportsLaunchFailureForMissingExecutable() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let plan = try makePlan(
            npmExecutablePath: directory.appendingPathComponent("does-not-exist").path,
            baseEnvironment: ["PATH": "/usr/bin:/bin", "HOME": directory.path]
        )
        let box = ResultBox()
        let finished = expectation(description: "installer failed to launch")
        let installer = ProcessPiWebUpdateInstaller()
        installer.install(plan, timeout: 30) { result in
            box.value = result
            finished.fulfill()
        }
        wait(for: [finished], timeout: 10)
        withExtendedLifetime(installer) {}
        XCTAssertEqual(box.value?.failure, .launchFailed)
    }

    func testProcessInstallerEnvironmentIsWhitelistedForTheChildProcess() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("env.txt")
        let script = try makeScript(in: directory, body: """
        /usr/bin/env > '\(output.path)'
        """)
        let plan = try makePlan(
            npmExecutablePath: script,
            baseEnvironment: [
                "PATH": "/usr/bin:/bin",
                "HOME": directory.path,
                "PI_WEB_PASSWORD": "super-secret-value",  // scan-secrets: allow(reason=test fixture environment)
                "NODE_OPTIONS": "--require /tmp/evil.js",
                "npm_config_registry": "https://example.invalid"
            ]
        )
        let finished = expectation(description: "installer finished")
        let installer = ProcessPiWebUpdateInstaller()
        installer.install(plan, timeout: 30) { _ in
            finished.fulfill()
        }
        wait(for: [finished], timeout: 30)
        withExtendedLifetime(installer) {}

        let environmentText = try String(contentsOf: output, encoding: .utf8)
        XCTAssertTrue(environmentText.contains("HOME="))
        for forbidden in ["PI_WEB_PASSWORD", "NODE_OPTIONS", "npm_config_registry", "super-secret-value", "--require"] {
            XCTAssertFalse(environmentText.contains(forbidden), "子进程环境不应包含 \(forbidden)")
        }
    }

    // MARK: - W2A 回归（A-1/A-2/A-3/A-5/A-6/A-7）

    func testProcessInstallerSupportsSequentialInstalls() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = try makeScript(in: directory, body: "exit 0")
        let plan = try makePlan(npmExecutablePath: script, baseEnvironment: ["PATH": "/usr/bin:/bin", "HOME": directory.path])

        let installer = ProcessPiWebUpdateInstaller()
        let first = ResultBox()
        let firstFinished = expectation(description: "第一次安装结束")
        installer.install(plan, timeout: 30) { result in
            first.value = result
            firstFinished.fulfill()
        }
        wait(for: [firstFinished], timeout: 30)
        XCTAssertEqual(first.value?.failure, nil)
        XCTAssertFalse(installer.isRunning)

        // 同一个安装器必须能再跑一次：对象级“终态”会把第二次调用静默丢弃（W2A A-1）。
        let second = ResultBox()
        let secondFinished = expectation(description: "第二次安装结束")
        installer.install(plan, timeout: 30) { result in
            second.value = result
            secondFinished.fulfill()
        }
        wait(for: [secondFinished], timeout: 30)
        withExtendedLifetime(installer) {}

        XCTAssertEqual(second.value?.failure, nil, "第二次安装必须真的执行并回调（W2A A-1）")
        XCTAssertEqual(second.value?.alreadyRunning, false)
        XCTAssertFalse(installer.isRunning)
    }

    func testProcessInstallerRejectsOverlappingInstallWithoutStartingSecondChild() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let marker = directory.appendingPathComponent("spawns.txt")
        let script = try makeScript(in: directory, body: """
        printf 'spawn\n' >> '\(marker.path)'
        sleep 1
        """)
        let plan = try makePlan(npmExecutablePath: script, baseEnvironment: ["PATH": "/usr/bin:/bin", "HOME": directory.path])

        let installer = ProcessPiWebUpdateInstaller()
        let firstFinished = expectation(description: "第一次安装结束")
        installer.install(plan, timeout: 30) { _ in firstFinished.fulfill() }

        let rejection = ResultBox()
        let rejected = expectation(description: "重叠调用被明确拒绝")
        installer.install(plan, timeout: 30) { result in
            rejection.value = result
            rejected.fulfill()
        }
        wait(for: [rejected, firstFinished], timeout: 30)
        withExtendedLifetime(installer) {}

        XCTAssertEqual(rejection.value?.failure, .alreadyRunning, "重叠 install 必须明确失败，不能静默丢弃")
        XCTAssertEqual(rejection.value?.alreadyRunning, true)
        let spawns = try String(contentsOf: marker, encoding: .utf8)
            .split(separator: "\n")
            .filter { !$0.isEmpty }
        XCTAssertEqual(spawns.count, 1, "重叠 install 不能启动第二个子进程（W2A A-2）")
    }

    func testProcessInstallerAbandoningWaitDoesNotCloseChildStdout() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let marker = directory.appendingPathComponent("late.txt")
        // 先写 stdout、再写 marker：如果放弃等待时读端被关闭，echo 会死于 SIGPIPE，
        // marker 就不会出现（W2A A-3）。trap 掉 TERM，模拟“超时后仍活着的子进程”。
        let script = try makeScript(in: directory, body: """
        trap '' TERM
        sleep 2
        echo late-output
        printf 'late' >> '\(marker.path)'
        """)
        let plan = try makePlan(npmExecutablePath: script, baseEnvironment: ["PATH": "/usr/bin:/bin", "HOME": directory.path])

        let box = ResultBox()
        let finished = expectation(description: "installer timed out")
        let installer = ProcessPiWebUpdateInstaller()
        installer.install(plan, timeout: 0.3) { result in
            box.value = result
            finished.fulfill()
        }
        wait(for: [finished], timeout: 10)

        // 放弃等待 ≠ 子进程已经退出：在退出确认之前必须仍视为「进行中」，否则下一次
        // 点击会真的再启动一个 npm（W2A A-2）。子进程此时还在 sleep（trap 掉了 TERM）。
        XCTAssertTrue(installer.isRunning, "放弃等待后、退出确认前仍须视为进行中（W2A A-2）")
        let rejected = expectation(description: "第二次 install 在退出确认前被拒绝")
        let rejectedBox = ResultBox()
        installer.install(plan, timeout: 30) { result in
            rejectedBox.value = result
            rejected.fulfill()
        }
        wait(for: [rejected], timeout: 10)
        XCTAssertEqual(rejectedBox.value?.failure, .alreadyRunning, "放弃等待期间不得启动第二次安装（W2A A-2）")

        var waited = 0.0
        while !FileManager.default.fileExists(atPath: marker.path), waited < 8 {
            Thread.sleep(forTimeInterval: 0.1)
            waited += 0.1
        }
        withExtendedLifetime(installer) {}
        XCTAssertEqual(box.value?.failure, .timedOut)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: marker.path),
            "放弃等待后子进程必须还能写 stdout（读端不能被关闭，W2A A-3）"
        )
    }

    func testInstallerCompletionDoesNotOccupyTheInstallerQueue() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = try makeScript(in: directory, body: "exit 0")
        let plan = try makePlan(npmExecutablePath: script, baseEnvironment: ["PATH": "/usr/bin:/bin", "HOME": directory.path])

        let installer = ProcessPiWebUpdateInstaller()
        let entered = expectation(description: "回调已开始")
        let finished = expectation(description: "installer finished")
        installer.install(plan, timeout: 30) { _ in
            entered.fulfill()
            Thread.sleep(forTimeInterval: 1)
            finished.fulfill()
        }
        wait(for: [entered], timeout: 30)

        // 回调（含内部的重新检测等长耗时工作）不能占住 installer 的串行队列：
        // 应用退出时的 cancel()/isRunning 必须能排到它前面（W2A A-5）。
        let started = Date()
        _ = installer.isRunning
        installer.cancel()
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertLessThan(elapsed, 0.5, "回调执行期间 installer 队列必须仍可访问（W2A A-5）")

        wait(for: [finished], timeout: 30)
        withExtendedLifetime(installer) {}
    }

    func testProcessInstallerPreservesUTF8SplitAcrossChunks() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = try makeScript(in: directory, body: """
        printf '\\344\\270'
        sleep 0.3
        printf '\\255-tail'
        """)
        let plan = try makePlan(
            npmExecutablePath: script,
            baseEnvironment: ["PATH": "/usr/bin:/bin", "HOME": directory.path]
        )

        let box = ResultBox()
        let finished = expectation(description: "installer preserves split UTF-8")
        let installer = ProcessPiWebUpdateInstaller()
        installer.install(plan, timeout: 30) { result in
            box.value = result
            finished.fulfill()
        }
        wait(for: [finished], timeout: 30)
        withExtendedLifetime(installer) {}

        XCTAssertEqual(box.value?.failure, nil)
        XCTAssertEqual(box.value?.outputTail, "中-tail")
        XCTAssertFalse(box.value?.outputTail?.contains("�") ?? true)
    }

    func testProcessInstallerKeepsTailWrittenAfterParentExit() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = try makeScript(in: directory, body: """
        (sleep 0.2; printf 'after-exit') &
        exit 0
        """)
        let plan = try makePlan(
            npmExecutablePath: script,
            baseEnvironment: ["PATH": "/usr/bin:/bin", "HOME": directory.path]
        )

        let box = ResultBox()
        let finished = expectation(description: "installer drains output after exit")
        let installer = ProcessPiWebUpdateInstaller(pipeDrainGrace: 2)
        installer.install(plan, timeout: 30) { result in
            box.value = result
            finished.fulfill()
        }
        wait(for: [finished], timeout: 30)
        withExtendedLifetime(installer) {}

        XCTAssertEqual(box.value?.exitCode, 0)
        XCTAssertEqual(box.value?.outputTail, "after-exit")
    }

    func testProcessInstallerAbandonDuringDrainGraceKeepsSuccessfulExit() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let marker = directory.appendingPathComponent("parent-exited")
        let script = try makeScript(in: directory, body: """
        sleep 5 &
        printf 'done' > '\(marker.path)'
        exit 0
        """)
        let plan = try makePlan(
            npmExecutablePath: script,
            baseEnvironment: ["PATH": "/usr/bin:/bin", "HOME": directory.path]
        )
        var abandoned: [UpdateAbandonedAttempt] = []
        let installer = ProcessPiWebUpdateInstaller(
            recordAbandonedAttempt: { abandoned.append($0) },
            pipeDrainGrace: 5
        )
        let box = ResultBox()
        let finished = expectation(description: "drain grace preserves exit")
        installer.install(plan, timeout: 30) { result in
            box.value = result
            finished.fulfill()
        }

        let deadline = Date().addingTimeInterval(20)
        while !FileManager.default.fileExists(atPath: marker.path), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        installer.cancel()
        wait(for: [finished], timeout: 20)
        withExtendedLifetime(installer) {}

        XCTAssertEqual(box.value?.exitCode, 0)
        XCTAssertFalse(box.value?.cancelled ?? true)
        XCTAssertNil(box.value?.failure)
        XCTAssertTrue(abandoned.isEmpty, "排水窗口里的 cancel 不得写失实的「已放弃」记录")
    }

    func testProcessInstallerKeepsNonUTF8OutputChunk() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        // 0xFF/0xFE 不是合法 UTF-8：修复前整块被丢弃，outputTail 为空（W2A A-6）。
        let script = try makeScript(in: directory, body: """
        printf '\\377\\376'
        sleep 0.5
        """)
        let plan = try makePlan(npmExecutablePath: script, baseEnvironment: ["PATH": "/usr/bin:/bin", "HOME": directory.path])

        let box = ResultBox()
        let finished = expectation(description: "installer finished")
        let installer = ProcessPiWebUpdateInstaller()
        installer.install(plan, timeout: 30) { result in
            box.value = result
            finished.fulfill()
        }
        wait(for: [finished], timeout: 30)
        withExtendedLifetime(installer) {}

        XCTAssertNotNil(box.value?.outputTail, "非 UTF-8 分块必须 lossy 保留，而不是整块丢弃（W2A A-6）")
    }

    func testPlanRejectsNPMExecutablePathThatIsNotAbsolute() {
        XCTAssertNil(
            PiWebUpdateInstallPlan.make(
                packageName: InstallCommandManifest.piWebPackageName,
                installedVersion: "0.9.0",
                targetVersion: "0.9.2",
                npmExecutablePath: "npm",
                baseEnvironment: baseEnvironment,
                source: .npmGlobal,
                confidence: .verified
            ),
            "相对路径的 npm 不能通过计划构造（W2A A-7）"
        )
    }

    func testCoordinatorSkipsManualInstallWhenInstallAlreadyRunning() throws {
        let world = CoordinatorWorld(homeDirectory: fixtureHome)
        world.installer.isRunning = true
        let coordinator = world.makeCoordinator()
        let plan = try makePlan()
        var outcome: PiWebUpdateRunOutcome?
        coordinator.runManual(plan) { outcome = $0 }
        XCTAssertEqual(outcome, .skipped(reason: .updateAlreadyInProgress, commandText: nil))
        XCTAssertTrue(world.installer.plans.isEmpty, "已有安装在跑时不能再调用安装器（W2A A-4）")
    }

    // MARK: - W3B F2/F3：事务级门控与组件隔离

    /// 安装子进程已经结束、事务还在尾段（重新检测版本 / 启动服务 / 健康检查）时，
    /// 手动入口必须被拒绝且不调用安装器；尾段走完后必须能再次更新（W3B F2）。
    func testCoordinatorRejectsManualInstallDuringTransactionTail() throws {
        let world = CoordinatorWorld(homeDirectory: fixtureHome)
        world.detectedInstallation = installation(version: "0.9.2")
        world.parksHealthCheck = true
        let coordinator = world.makeCoordinator()
        let plan = try makePlan()

        var firstOutcome: PiWebUpdateRunOutcome?
        coordinator.runManual(plan) { firstOutcome = $0 }
        XCTAssertEqual(world.installer.plans.count, 1)
        XCTAssertNil(firstOutcome, "事务尾段还没走完，结果尚未投递")
        XCTAssertTrue(coordinator.isRunning, "事务尾段仍须算「更新进行中」（W3B F2）")
        XCTAssertTrue(coordinator.isUpdateInProgress)

        // 尾段里的第二次手动入口：必须被拒绝，且不能再调用安装器。
        var rejectedOutcome: PiWebUpdateRunOutcome?
        coordinator.runManual(plan) { rejectedOutcome = $0 }
        XCTAssertEqual(
            rejectedOutcome,
            .skipped(reason: .updateAlreadyInProgress, commandText: nil),
            "事务尾段里的第二次手动更新必须被拒绝（W3B F2）"
        )
        XCTAssertEqual(world.installer.plans.count, 1, "被拒绝的那一次不能调用安装器")

        world.releaseParkedHealthCheck(true)
        XCTAssertEqual(firstOutcome, .succeeded(plan: plan, oldVersion: "0.9.0", newVersion: "0.9.2"))
        XCTAssertFalse(coordinator.isUpdateInProgress, "尾段结束后事务门控必须解除")

        // 事务结束之后必须能再次更新：门控不能变成一发式状态。
        world.parksHealthCheck = false
        world.healthResults = [true]
        var secondOutcome: PiWebUpdateRunOutcome?
        coordinator.runManual(plan) { secondOutcome = $0 }
        XCTAssertEqual(secondOutcome, .succeeded(plan: plan, oldVersion: "0.9.0", newVersion: "0.9.2"))
        XCTAssertEqual(world.installer.plans.count, 2)
    }

    /// W3B F3：被挡住时必须有可见原因；「子进程退出未确认」窗口必须给出重启恢复路径；
    /// 入口闸控只由本组件自己的状态合成，构建时看不到另一个组件。
    func testUpdateEntryStateExposesReasonAndRecoveryPath() {
        XCTAssertFalse(UpdateEntryState.free.isBlocked)
        XCTAssertNil(UpdateEntryState.free.menuTitleSuffix)

        let installing = UpdateEntryState.component(
            transactionInProgress: false, childInFlight: true, abandonedChildrenUnconfirmed: false
        )
        XCTAssertTrue(installing.isBlocked)
        XCTAssertEqual(installing.menuTitleSuffix, "（正在更新）", "位住时必须给出可见原因（W3B F3 (b)）")

        let tail = UpdateEntryState.component(
            transactionInProgress: true, childInFlight: false, abandonedChildrenUnconfirmed: false
        )
        XCTAssertTrue(tail.isBlocked, "事务尾段（没有子进程在飞）也必须挡住入口（W3B F2）")

        let awaiting = UpdateEntryState.component(
            transactionInProgress: false, childInFlight: true, abandonedChildrenUnconfirmed: true
        )
        XCTAssertTrue(awaiting.isBlocked)
        XCTAssertEqual(awaiting.menuTitleSuffix, "（上一次更新未确认退出，重启应用可恢复）")
        XCTAssertTrue(
            awaiting.rejectionDetail.contains("重启应用即可恢复"),
            "卡住的子进程窗口必须给出可恢复路径（W3B F3 (c)）"
        )

        // 组件隔离（W3B F3 (a)）：Pi Web 的子进程永不退出时，Pi CLI 的状态仍然
        // 只由 Pi CLI 自己的输入合成，不会被跨组件输入影响。
        let webStuck = UpdateEntryState.component(
            transactionInProgress: false, childInFlight: true, abandonedChildrenUnconfirmed: false
        )
        let cliIdle = UpdateEntryState.component(
            transactionInProgress: false, childInFlight: false, abandonedChildrenUnconfirmed: false
        )
        XCTAssertTrue(webStuck.isBlocked)
        XCTAssertFalse(cliIdle.isBlocked, "Pi Web 卡住不得挡住 Pi CLI 入口（W3B F3 (a)）")
    }

    // MARK: - 持久警告存储

    func testWarningStoreRoundTripsAndRejectsInvalidValues() {
        let suiteName = "pi-web-desktop-pi-web-update-warning-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let warning = PiWebUpdateWarning(
            kind: .installFailed,
            oldVersion: "0.9.0",
            newVersion: "0.9.0",
            targetVersion: "0.9.2",
            reason: "安装超时",
            recordedAt: referenceDate
        )
        PiWebUpdateWarningStore.save(warning, to: defaults)
        XCTAssertEqual(PiWebUpdateWarningStore.load(from: defaults), warning)

        let domain = defaults.persistentDomain(forName: suiteName) ?? [:]
        XCTAssertEqual(Set(domain.keys), Set(UpdateSettingKeys.allPiWebUpdateWarningKeys))
        for (key, value) in domain {
            let text = String(describing: value)
            XCTAssertFalse(text.contains("/"), "键 \(key) 不应包含路径")
            XCTAssertFalse(text.contains("~"), "键 \(key) 不应包含 Home 路径")
            for secret in ["password", "token", "secret", "Bearer"] {
                XCTAssertFalse(text.lowercased().contains(secret.lowercased()), "键 \(key) 不应包含凭据形状")
            }
        }

        // 版本字段无效时只丢弃该字段，不整条作废。
        defaults.set("not-a-version", forKey: UpdateSettingKeys.piWebUpdateWarningOldVersion)
        XCTAssertNil(PiWebUpdateWarningStore.load(from: defaults)?.oldVersion)

        // 类别无效时整条记录不可信。
        defaults.set("nonsense", forKey: UpdateSettingKeys.piWebUpdateWarningKind)
        XCTAssertNil(PiWebUpdateWarningStore.load(from: defaults))

        PiWebUpdateWarningStore.save(nil, to: defaults)
        XCTAssertNil(PiWebUpdateWarningStore.load(from: defaults))
        XCTAssertTrue((defaults.persistentDomain(forName: suiteName) ?? [:]).isEmpty)
    }

    func testAppConfigurationRoundTripsPiWebUpdateWarning() {
        let suiteName = "pi-web-desktop-pi-web-update-appconfig-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let configuration = AppConfiguration(
            supportURL: FileManager.default.temporaryDirectory.appendingPathComponent("pi-web-update-tests-support", isDirectory: true),
            logsRootURL: FileManager.default.temporaryDirectory.appendingPathComponent("pi-web-update-tests-logs", isDirectory: true),
            defaults: defaults
        )

        XCTAssertNil(configuration.piWebUpdateWarning())
        let warning = PiWebUpdateWarning(
            kind: .versionUnchanged,
            oldVersion: "0.9.0",
            newVersion: "0.9.0",
            targetVersion: "0.9.2",
            reason: "版本未达到目标",
            recordedAt: referenceDate
        )
        configuration.savePiWebUpdateWarning(warning)
        XCTAssertEqual(configuration.piWebUpdateWarning(), warning)
        configuration.savePiWebUpdateWarning(nil)
        XCTAssertNil(configuration.piWebUpdateWarning())
    }

    // MARK: - 设置位生效后的边界

    func testAutomationBoundaryExplainsRestrictedScope() {
        XCTAssertTrue(UpdateCheckPreferences.autoUpdateBeforeLaunchIsEffective)
        XCTAssertTrue(UpdateAutomationBoundary.autoUpdateIsEffective)
        let explanation = UpdateAutomationBoundary.restrictedExplanation
        for fragment in ["npm 全局", "不调用 sudo", "只显示命令", "回滚"] {
            XCTAssertTrue(explanation.contains(fragment), "边界说明应包含 \(fragment)")
        }
        XCTAssertFalse(explanation.contains("尚未生效"))
    }
}
