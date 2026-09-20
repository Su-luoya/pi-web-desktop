/// Pi Web update orchestration, warnings and re-detection.

import Darwin
import Foundation

/// 启动前更新与手动更新的顺序编排：决策 → 安装 → 重新检测版本 → 启动 + 健康检查。
///
/// 全部副作用都注入（安装器、版本重检测、启动/健康检查、日志、投递队列、时钟），
/// 因此 unhosted 测试可以用同步替身断言每一步，不执行真实 npm、不访问网络、
/// 不启动真实服务。
final class PiWebUpdateCoordinator {
    struct Environment {
        /// 安装器（生产：`ProcessPiWebUpdateInstaller`；测试：记录替身）。
        var installer: PiWebUpdateInstalling
        /// 重新检测 Pi Web 版本（复用 #16 识别器）。
        var detectInstallation: () -> ComponentInstallation?
        /// 启动服务并做健康检查（复用既有启动/健康检查路径）。回调 true 表示
        /// 服务可用。
        var startServiceAndCheckHealth: (@escaping (Bool) -> Void) -> Void
        /// 统一脱敏器（与日志/诊断共用同一个实例）。
        var redactor: LogRedactor
        /// 日志入口；每条消息写入前都必须经过 `redactor`。
        var log: (String) -> Void
        /// 结果投递队列（生产：主队列；测试：立即执行）。
        var deliver: (@escaping () -> Void) -> Void
        /// 安装超时（秒）。超时按失败处理。
        var timeout: TimeInterval
        /// 共享更新事务（GitHub #23）：文件系统探针、统一历史与降级应用。
        /// 默认不注入探针、不记历史、不应用降级，也不改变已有行为。
        var transaction: UpdateTransactionEnvironment
        /// 该组件成功完成一次更新后清除它的「已放弃」记录（GitHub #62）。
        /// 默认什么都不做（旧调用点保持不变）。
        var clearAbandonedAttempt: (UpdateTransactionComponent) -> Void

        init(
            installer: PiWebUpdateInstalling,
            detectInstallation: @escaping () -> ComponentInstallation?,
            startServiceAndCheckHealth: @escaping (@escaping (Bool) -> Void) -> Void,
            redactor: LogRedactor,
            log: @escaping (String) -> Void,
            deliver: @escaping (@escaping () -> Void) -> Void,
            timeout: TimeInterval = PiWebUpdateCoordinator.defaultTimeout,
            transaction: UpdateTransactionEnvironment = .disabled,
            clearAbandonedAttempt: @escaping (UpdateTransactionComponent) -> Void = { _ in }
        ) {
            self.installer = installer
            self.detectInstallation = detectInstallation
            self.startServiceAndCheckHealth = startServiceAndCheckHealth
            self.redactor = redactor
            self.log = log
            self.deliver = deliver
            self.timeout = timeout
            self.transaction = transaction
            self.clearAbandonedAttempt = clearAbandonedAttempt
        }
    }

    /// 默认安装超时：5 分钟。有界，应用启动不会因为安装无上限地卡住。
    static let defaultTimeout: TimeInterval = 300

    /// 整轮更新事务是否在进行中：安装、重新检测版本、启动服务与健康检查都算
    /// （W3B F2：安装子进程一结束就放行，事务尾段的几秒到几十秒里还能再叠加一次
    /// 安装）。标志由协调器自己持有，组件之间互不影响（W3B F3）。
    private let transactionLock = NSLock()
    private var transactionInFlight = false

    /// 事务级「更新进行中」：只在 `runInstall` 的事务期间为真。
    var isRunning: Bool {
        transactionLock.lock()
        defer { transactionLock.unlock() }
        return transactionInFlight
    }

    /// 是否有一次更新正在进行（供 UI 门控：手动入口与菜单项）。既覆盖整轮事务
    /// （安装 + 重检测 + 服务启动 + 健康检查，W3B F2），也覆盖安装器自己的
    /// 「已放弃等待、子进程退出未确认」窗口。
    var isUpdateInProgress: Bool { isRunning || environment.installer.isRunning }

    private func beginTransaction() {
        transactionLock.lock()
        transactionInFlight = true
        transactionLock.unlock()
    }

    private func endTransaction() {
        transactionLock.lock()
        transactionInFlight = false
        transactionLock.unlock()
    }

    private let environment: Environment

    init(environment: Environment) {
        self.environment = environment
    }

    /// 执行一次受限自动更新。`input.serviceIsRunning` 为 true 时只会得到
    /// `.skipped(.serviceRunning)`，不会调用安装器。
    func run(_ input: PiWebUpdatePlanningInput, completion: @escaping (PiWebUpdateRunOutcome) -> Void) {
        let decision = PiWebUpdatePlanner.decide(input)
        environment.log(decision.logLine(redactingWith: environment.redactor))
        switch decision {
        case .manualOnly(let commandText, let reason):
            environment.deliver { completion(.skipped(reason: reason, commandText: commandText)) }
        case .unavailable(let reason):
            environment.deliver { completion(.skipped(reason: reason, commandText: nil)) }
        case .automatic(let plan):
            runInstall(plan: plan, installation: input.installation, completion: completion)
        }
    }

    /// 手动路径：用户已经在确认框里看到计划、「已放弃」记录（如果有）与风险说明
    /// 并显式确认，因此这里不再做自动判定，直接执行安装；执行结果同样重新检测
    /// 版本并进入同一份更新历史。
    func runManual(
        _ plan: PiWebUpdateInstallPlan,
        completion: @escaping (PiWebUpdateRunOutcome) -> Void
    ) {
        environment.log(environment.redactor.redact(
            "Pi Web 手动更新：已确认执行\n"
                + plan.displayLines(redactingWith: environment.redactor).joined(separator: "\n")
        ))
        runInstall(plan: plan, installation: nil, completion: completion)
    }

    private func runInstall(
        plan: PiWebUpdateInstallPlan,
        installation: ComponentInstallation?,
        completion originalCompletion: @escaping (PiWebUpdateRunOutcome) -> Void
    ) {
        // 同一时间只允许一次更新事务（W2A A-2/A-4 + W3B F2）：不只安装子进程在跑
        // 时算，安装之后的重新检测/服务启动/健康检查还在跑时同样按「跳过」返回，
        // 给出可见文案，而不是排队等第二次回调。
        guard !isUpdateInProgress else {
            environment.log("Pi Web 更新跳过：\(PiWebUpdateRefusal.updateAlreadyInProgress.text)")
            environment.deliver {
                originalCompletion(.skipped(reason: .updateAlreadyInProgress, commandText: nil))
            }
            return
        }
        // 事务级门控（W3B F2）：从第二次触发直到结果真正投递给调用方为止，
        // 整个事务（安装 + 重检测 + 服务启动 + 健康检查）都算「更新进行中」。
        // 包装一次完成回调，事务里的每个结束分支都会先解除门控再投递。
        beginTransaction()
        let completion: (PiWebUpdateRunOutcome) -> Void = { [weak self] outcome in
            self?.endTransaction()
            originalCompletion(outcome)
        }
        // 共享事务（GitHub #23）：准备阶段记录更新前指纹，安装/验证/提交/降级
        // 四个阶段的结果都进入同一份更新历史。
        let component = UpdateTransactionComponent.piWeb
        let advice = UpdateManualAdviceBuilder.advice(component: component, source: plan.source)
        var journal = UpdateTransactionJournal(
            configuration: UpdateTransactionJournal.Configuration(
                component: component,
                source: plan.source,
                previousVersion: plan.installedVersion,
                targetVersion: plan.targetVersion,
                fingerprint: UpdateArtifactFingerprint.capture(
                    installation: installation,
                    probe: environment.transaction.probe
                )
            ),
            now: environment.transaction.now
        )
        journal.recordPreflight()
        environment.installer.install(plan, timeout: environment.timeout) { [weak self] result in
            guard let self else { return }
            // 与安装器的门控竞争失败：这一次没有启动子进程，不写失败历史。
            if result.failure == .alreadyRunning {
                self.logOutcome("Pi Web 更新跳过（\(PiWebUpdateRefusal.updateAlreadyInProgress.text)）。")
                self.environment.deliver {
                    completion(.skipped(reason: .updateAlreadyInProgress, commandText: nil))
                }
                return
            }
            // F5（GitHub #121）：取消请求落在收尾窗口内时不写「已取消」，也不截断结果；
            // 但这句要记下来，免得「取消被忽略」看起来像「成功了」的静默结果。
            if result.cancelRequestedDuringFinish {
                self.logOutcome(
                    "Pi Web 取消请求落在收尾窗口内：安装进程已经退出，只是还在等管道读到 EOF，"
                        + "没有信号可发；结果按真实退出码处理。"
                )
            }
            if let failure = result.failure {
                let degradation = UpdateDegradationPlanner.installFailure(
                    component: component,
                    source: plan.source,
                    fingerprint: journal.configuration.fingerprint,
                    targetVersion: plan.targetVersion,
                    failureReason: failure.text
                )
                journal.recordInstallFailed(failure.text)
                journal.recordCommitNotAttempted(reason: "安装阶段失败，未启用新版本")
                journal.recordDegradation(degradation)
                self.recordTransaction(
                    journal,
                    degradation: degradation,
                    advice: advice,
                    resultingVersion: nil
                )
                self.logOutcome(
                    "Pi Web 更新失败（\(failure.text)）：退出码 \(result.exitCode.map(String.init) ?? "无")，"
                    + "当前版本 \(plan.installedVersion)，目标版本 \(plan.targetVersion)。本次没有执行任何回滚动作。"
                    + (result.childProcessAction.map { "本次实际动作：\($0.text)。" } ?? "")
                )
                if let tail = result.outputTail, !tail.isEmpty {
                    self.logOutputTail(tail)
                }
                // F6（GitHub #121）：outcome 会跨类型边界交给 UI，构造前先脱敏，
                // 不把未脱敏的输出尾巴留在结果里（日志路径本来就是脱敏的）。
                let outcomeTail = result.outputTail.map { self.environment.redactor.redact($0) }
                let outcome = PiWebUpdateRunOutcome.installFailed(
                    plan: plan,
                    failure: failure,
                    oldVersion: plan.installedVersion,
                    targetVersion: plan.targetVersion,
                    outputTail: outcomeTail
                )
                self.environment.deliver { completion(outcome) }
                return
            }

            journal.recordInstallSucceeded()
            let detected = self.environment.detectInstallation()
            let detectedVersion = detected?.version
            let verificationInput = UpdateVerificationInput(
                component: .piWeb,
                packageName: component.expectedPackageName,
                previousVersion: plan.installedVersion,
                targetVersion: plan.targetVersion,
                detectedVersion: detectedVersion,
                detectedPackageName: detected?.packageName,
                detectedExecutablePath: detected?.executablePath,
                detectedResolvedPath: detected?.resolvedPath,
                detectedPackageJSONPath: detected?.packageJSONPath,
                fingerprint: journal.configuration.fingerprint
            )
            let report = UpdateVerifier.verify(
                verificationInput,
                probe: self.environment.transaction.probe
            )
            guard journal.recordVerification(report, detectedVersion: detectedVersion) else {
                let degradation = UpdateDegradationPlanner.verificationFailure(
                    component: component,
                    source: plan.source,
                    fingerprint: journal.configuration.fingerprint,
                    newVersion: detectedVersion,
                    newResolvedPath: detected?.resolvedPath ?? detected?.executablePath,
                    failureReason: report.failureReason ?? "验证未通过",
                    probe: self.environment.transaction.probe
                )
                journal.recordCommitNotAttempted(reason: "验证阶段失败，未启用新版本")
                journal.recordDegradation(degradation)
                self.environment.transaction.applyDegradation(degradation)
                self.recordTransaction(
                    journal,
                    degradation: degradation,
                    advice: advice,
                    resultingVersion: detectedVersion
                )
                self.logOutcome(
                    "Pi Web 更新未通过版本验证：安装命令退出码 0，但重新检测到的版本是 "
                    + "\(detectedVersion ?? "未知")，目标版本 \(plan.targetVersion)。"
                    + UpdateWarningText.oldVersionClaimText(detectedVersion: detectedVersion)
                    + "应用不会自动回滚，也不声称更新成功。"
                )
                let outcome = PiWebUpdateRunOutcome.versionUnchanged(
                    plan: plan,
                    detectedVersion: detectedVersion,
                    oldVersion: plan.installedVersion,
                    targetVersion: plan.targetVersion
                )
                self.environment.deliver { completion(outcome) }
                return
            }

            let newVersion = detectedVersion ?? plan.targetVersion
            self.environment.startServiceAndCheckHealth { [weak self] ready in
                guard let self else { return }
                let finalReport = UpdateVerifier.report(
                    report,
                    healthCheck: ready
                        ? .passed
                        : .failed(reason: "既有健康检查路径报告服务不可用")
                )
                if ready {
                    // 成功历史也必须用健康检查后的最终报告覆盖 verify 阶段；否则会把
                    // 已实际通过的检查持久化成“尚未启动服务”。
                    journal.recordVerification(finalReport, detectedVersion: newVersion)
                    journal.recordDegradationNotNeeded()
                    journal.recordCommit(version: newVersion)
                    self.recordTransaction(
                        journal,
                        degradation: nil,
                        advice: advice,
                        resultingVersion: newVersion
                    )
                    // 该组件成功完成了一次更新：清除它的「已放弃」记录（GitHub #62）。
                    self.environment.clearAbandonedAttempt(component)
                    self.logOutcome(
                        "Pi Web 更新完成：\(plan.installedVersion) → \(newVersion)，服务健康检查通过。"
                    )
                    let outcome = PiWebUpdateRunOutcome.succeeded(
                        plan: plan,
                        oldVersion: plan.installedVersion,
                        newVersion: newVersion
                    )
                    self.environment.deliver { completion(outcome) }
                } else {
                    // 健康检查失败也属于验证失败：用最终报告原地更新 verify 阶段。
                    journal.recordVerification(finalReport, detectedVersion: newVersion)
                    let degradation = UpdateDegradationPlanner.verificationFailure(
                        component: component,
                        source: plan.source,
                        fingerprint: journal.configuration.fingerprint,
                        newVersion: newVersion,
                        newResolvedPath: detected?.resolvedPath ?? detected?.executablePath,
                        failureReason: finalReport.failureReason ?? "服务健康检查失败",
                        probe: self.environment.transaction.probe
                    )
                    journal.recordDegradation(degradation)
                    self.environment.transaction.applyDegradation(degradation)
                    self.recordTransaction(
                        journal,
                        degradation: degradation,
                        advice: advice,
                        resultingVersion: newVersion
                    )
                    self.logOutcome(
                        "Pi Web 更新后健康检查失败：\(plan.installedVersion) → \(newVersion)。"
                        + "应用停在诊断状态，不会自动回滚，也不声称更新成功。"
                    )
                    let outcome = PiWebUpdateRunOutcome.healthCheckFailed(
                        plan: plan,
                        oldVersion: plan.installedVersion,
                        newVersion: newVersion
                    )
                    self.environment.deliver { completion(outcome) }
                }
            }
        }
    }

    /// 记录统一更新历史（GitHub #23）：阶段结果、从/到版本、降级结果与手动建议。
    /// 历史字段全部是固定枚举、已校验版本与静态清单文本，不含路径。
    private func recordTransaction(
        _ journal: UpdateTransactionJournal,
        degradation: UpdateDegradationPlan?,
        advice: UpdateManualAdvice,
        resultingVersion: String?
    ) {
        let entry = journal.historyEntry(
            degradation: degradation,
            advice: advice,
            resultingVersion: resultingVersion
        )
        environment.transaction.recordHistory(entry)
        logOutcome("更新历史：\(UpdateHistoryPresenter.lines(for: entry).joined(separator: " "))")
    }

    /// 重新检测的版本是否达到目标版本（相等或更高都算达到）。
    static func versionReached(detected: String?, target: String) -> Bool {
        UpdateVerifier.versionReached(detected: detected, old: target, target: target)
    }

    private func logOutcome(_ message: String) {
        environment.log(environment.redactor.redact(message))
    }

    private func logOutputTail(_ tail: String) {
        let redacted = environment.redactor.redact(tail)
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !redacted.isEmpty else { return }
        environment.log("Pi Web 安装输出片段（已脱敏）：\(redacted)")
    }
}

// MARK: - 持久警告

/// 一次失败的受限自动更新的持久记录。
///
/// 只保存类别、旧/新/目标版本、固定原因文案与时间：不含路径、环境变量值、
/// 凭据或子进程输出。警告在界面与诊断文本里持续显示，直到下一次成功更新。
struct PiWebUpdateWarning: Equatable {
    enum Kind: String, Equatable {
        case installFailed
        case versionUnchanged
        case healthCheckFailed
    }

    var kind: Kind
    var oldVersion: String?
    var newVersion: String?
    var targetVersion: String?
    var reason: String
    var recordedAt: Date

    init(
        kind: Kind,
        oldVersion: String? = nil,
        newVersion: String? = nil,
        targetVersion: String? = nil,
        reason: String,
        recordedAt: Date = Date()
    ) {
        self.kind = kind
        self.oldVersion = oldVersion
        self.newVersion = newVersion
        self.targetVersion = targetVersion
        self.reason = reason
        self.recordedAt = recordedAt
    }

    /// 用户可见的持久警告：明确说明旧版本语义保持不变、没有回滚成功这回事。
    var text: String {
        var parts: [String] = []
        parts.append("Pi Web 启动前自动更新未完成：\(reason)。")
        parts.append("当前版本：\(oldVersion ?? "未知")；目标版本：\(targetVersion ?? "未知")"
            + (newVersion.map { "；重新检测到的版本：\($0)" } ?? "") + "。")
        parts.append("旧版本语义保持不变：应用不会自动回滚已替换的文件，也不声称更新成功。"
            + "请查看日志与诊断结果后手动处理。")
        return parts.joined(separator: " ")
    }

    /// 菜单/状态行用的单行摘要。
    var shortText: String {
        "Pi Web 更新告警：\(reason)（当前 \(oldVersion ?? "未知") → 目标 \(targetVersion ?? "未知")）"
    }
}

/// 持久警告的 UserDefaults 存取（只经 `AppConfiguration` 调用）。
///
/// 键与其它更新检查设置分开：保存策略不会清掉警告，保存警告也不会改动策略。
/// 读到的值必须通过类型与版本校验，否则整条记录视为无效（返回 nil）。
enum PiWebUpdateWarningStore {
    static func load(from defaults: UserDefaults) -> PiWebUpdateWarning? {
        guard let kindText = defaults.string(forKey: UpdateSettingKeys.piWebUpdateWarningKind),
              let kind = PiWebUpdateWarning.Kind(rawValue: kindText) else { return nil }
        guard let reason = defaults.string(forKey: UpdateSettingKeys.piWebUpdateWarningReason),
              !reason.isEmpty else { return nil }
        let recordedAt = UpdateIgnoredVersions.timestamp(
            defaults.object(forKey: UpdateSettingKeys.piWebUpdateWarningRecordedAt)
        ) ?? Date(timeIntervalSince1970: 0)
        return PiWebUpdateWarning(
            kind: kind,
            oldVersion: version(defaults, UpdateSettingKeys.piWebUpdateWarningOldVersion),
            newVersion: version(defaults, UpdateSettingKeys.piWebUpdateWarningNewVersion),
            targetVersion: version(defaults, UpdateSettingKeys.piWebUpdateWarningTargetVersion),
            reason: reason,
            recordedAt: recordedAt
        )
    }

    static func save(_ warning: PiWebUpdateWarning?, to defaults: UserDefaults) {
        guard let warning else {
            for key in UpdateSettingKeys.allPiWebUpdateWarningKeys {
                defaults.removeObject(forKey: key)
            }
            return
        }
        defaults.set(warning.kind.rawValue, forKey: UpdateSettingKeys.piWebUpdateWarningKind)
        defaults.set(warning.reason, forKey: UpdateSettingKeys.piWebUpdateWarningReason)
        defaults.set(warning.recordedAt.timeIntervalSince1970, forKey: UpdateSettingKeys.piWebUpdateWarningRecordedAt)
        setVersion(warning.oldVersion, key: UpdateSettingKeys.piWebUpdateWarningOldVersion, defaults: defaults)
        setVersion(warning.newVersion, key: UpdateSettingKeys.piWebUpdateWarningNewVersion, defaults: defaults)
        setVersion(warning.targetVersion, key: UpdateSettingKeys.piWebUpdateWarningTargetVersion, defaults: defaults)
    }

    /// 只接受可解析为语义化版本的字符串；否则写入 nil（删除键）。
    static func setVersion(_ version: String?, key: String, defaults: UserDefaults) {
        guard let version, SemanticVersion(version) != nil else {
            defaults.removeObject(forKey: key)
            return
        }
        defaults.set(version, forKey: key)
    }

    static func version(_ defaults: UserDefaults, _ key: String) -> String? {
        guard let text = defaults.string(forKey: key), SemanticVersion(text) != nil else { return nil }
        return text
    }
}

// MARK: - 重检测辅助

/// 安装后与手动更新前的聚焦版本重检测：复用 #16 识别器，只识别 Pi Web 一个
/// 组件，不重新跑整个依赖诊断。
enum PiWebUpdateRedetection {
    static func request(piWebPath: String?) -> ComponentInstallationDetector.ComponentDetectionRequest {
        var candidates: [String] = []
        if let piWebPath, !piWebPath.isEmpty {
            candidates.append(piWebPath)
        }
        candidates.append(contentsOf: [
            "/opt/homebrew/bin/pi-web",
            "/usr/local/bin/pi-web"
        ])
        return ComponentInstallationDetector.ComponentDetectionRequest(
            kind: .piWeb,
            packageName: InstallCommandManifest.piWebPackageName,
            executableNames: ["pi-web"],
            candidates: candidates,
            knownVersion: nil,
            runsVersionCommand: true,
            isApplicationBundle: false,
            probesShellPath: true
        )
    }

    static func detect(
        piWebPath: String?,
        commandRunner: CommandRunning,
        fileSystem: DependencyFileSystemProbing = SystemDependencyFileSystemProbe(),
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: String? = nil
    ) -> ComponentInstallation {
        let detector = ComponentInstallationDetector(
            commandRunner: commandRunner,
            fileSystem: fileSystem,
            environment: environment,
            homeDirectory: homeDirectory
        )
        return detector.detect(request(piWebPath: piWebPath))
    }
}
