import Cocoa

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuDelegate {
    /// 多窗口登记表（GitHub #168）：窗口 ↔ WebView 控制器的唯一对应关系来源，
    /// 同时维护启动主窗口（primary）标识与最近使用顺序。
    /// 它只做登记/查找/最近使用排序，不触碰服务生命周期（开窗、关窗都不会启动、
    /// 停止或重启服务）。
    var windowRegistry = AppWindowRegistry<NSWindow, WebViewController>()
    /// 最近使用的窗口（`mainWindow`）与它的 WebView 控制器。
    ///
    /// 这两个名字保留给既有调用点（启动路由、诊断页、更新页、菜单动作）：多窗口下
    /// 它们表示**最近使用**的窗口，状态页与菜单动作因此总是落在用户刚操作过的窗口
    /// 上，而不是固定第一个窗口；窗口全部关闭时为 nil。它们**不是**启动主窗口
    /// （primary）：Dock 恢复、关闭语义与 `showMainWindow()` 只认
    /// `windowRegistry.primaryWindow`。
    var window: NSWindow! { windowRegistry.mainWindow }
    var webViewController: WebViewController! { windowRegistry.mainController }
    var statusMenuItem: NSMenuItem?
    /// 退出状态机（GitHub #72）：决策、超时兜底与副作用顺序都是纯逻辑，见
    /// `Sources/QuitCoordinator.swift`。
    var quitCoordinator = QuitCoordinator()
    /// 等待用户退出决策的兜底计时器：决策完成或取消后立即失效。
    var quitDecisionTimer: Timer?
    var hasInstanceLock = false
    var eventMonitor: Any?
    var screenParametersObserver: NSObjectProtocol?
    var screenFitWorkItem: DispatchWorkItem?
    var isFullScreenTransition = false
    var currentState: ServiceState = .checking
    /// 设置窗口单例（W4 M2）：同一时刻最多一个设置窗口，重复打开复用同一个
    /// 控制器并用当前生效配置刷新控件（`ReusableControllerStore`）。
    let preferencesWindowStore = ReusableControllerStore<PreferencesWindowController>()
    var diagnosticsWindowController: DiagnosticsWindowController?
    /// 诊断导出的后台探测器（W4 M3）：子进程调用在专用串行队列上执行，每个
    /// 调用有超时；导出完成后回主线程组装文本并复制。
    let diagnosticsProbeCollector = DiagnosticsProbeCollector()
    /// 导出进行中（提醒框已弹出或后台采集未结束）：忽略重复触发，菜单项置灰。
    var diagnosticsExportInProgress = false
    /// 依赖门控禁用的服务控件菜单项（启动/停止/重启）。
    var serviceControlMenuItems: [NSMenuItem] = []
    var dependencyReport: DependencyReport?
    /// 依赖门控状态；start/stop/restart 的可用性统一由 `ServiceControlState` 映射。
    var dependencyGate: DiagnosticsGate = .checking
    var dependencyCheckGeneration = 0
    var shouldPresentDiagnostics = false
    /// 工作目录校验结果（GitHub #9）。不可用时门控关闭、路由进入诊断页。
    var workspaceValidation: WorkspaceDirectoryValidation = .usable(path: "")
    /// “服务”菜单中的最近工作目录；菜单每次打开时从持久存储重建。
    var recentWorkspacesMenu: NSMenu?
    /// “复制手机访问链接”候选子菜单（应用菜单与服务菜单各一个）；菜单每次打开时
    /// 按当前网络地址重建（GitHub #150）。
    var phoneAccessMenus: [NSMenu] = []
    /// 网络地址探测：默认枚举本机接口；测试注入替身，不访问真实网络。
    let networkAddressProvider: NetworkAddressProviding = SystemNetworkAddressProvider()

    // MARK: - 系统代理告警（GitHub #157）

    /// 系统代理未排除 VPN 网段时的运行时提示：条件成立时出现在“服务”菜单里，
    /// 条件消失（切回 loopback 或用户加了例外）即清除。不写 UserDefaults：
    /// 每次启动重新检测即可得到同样的结论。
    var systemProxyWarning: SystemProxyWarning?
    /// “服务”菜单里的代理告警项（无告警时隐藏）。
    var systemProxyWarningMenuItem: NSMenuItem?
    /// 只读的系统代理检测 + 提示状态机；绝不修改用户的系统代理设置。
    let systemProxyWarningMonitor: SystemProxyWarningCoordinator

    // MARK: - 更新检查（GitHub #17）

    /// 版本检查器：只检查、不安装。失败只改变检查结果状态，不影响服务状态。
    var updateChecker: UpdateChecker?
    var updateStatusMenuItem: NSMenuItem?
    var updateCategoryMenuItems: [UpdateCheckCategory: NSMenuItem] = [:]
    var updateSettingsMenu: NSMenu?
    /// “更新检查偏好设置”窗口（GitHub #18）。
    var updateSettingsWindowController: UpdateSettingsWindowController?
    /// 当前正在执行的桌面 App 安装器；必须由 AppDelegate 持有到下载/替换流程结束。
    var desktopAppUpdateInstaller: DesktopAppUpdateInstalling?
    /// 更新菜单里的「下载并安装桌面应用更新…」入口；只在检测到已核实的可用新版本时显示。
    var desktopAppUpdateMenuItem: NSMenuItem?
    /// 每类组件的“忽略版本”（只存版本字符串与时间戳，见 `UpdateIgnoredVersions`）。
    var ignoredVersions: UpdateIgnoredVersions = .empty
    /// 本次运行已经提示过哪些版本，避免同一个版本反复打扰；退出即丢弃。
    var notifiedVersions: [UpdateCheckCategory: String] = [:]
    /// 主线程状态：是否有一次检查正在进行（用于菜单文案与重复点击防护）。
    var updateCheckInProgress = false
    /// 手动检查完成后是否弹提示；自动检查是否提示由策略与忽略版本决定。
    var pendingManualUpdateCheck = false

    // MARK: - 受限自动更新（GitHub #20）

    /// 最近一次失败的启动前自动更新的持久警告（从 UserDefaults 读入，跨启动保留）。
    var piWebUpdateWarning: PiWebUpdateWarning?
    /// 启动前更新进行中：抑制同一版本的自动提示框（安装流程会自己给结果）。
    var preLaunchUpdateInProgress = false
    /// 本次运行已经尝试过启动前自动更新（无论成败）：同一次运行内不再自动重试，
    /// 失败后由用户显式点击“立即更新 Pi Web…”或下次启动再试。
    var preLaunchUpdateAttemptedInThisRun = false
    /// 告警菜单项与“立即更新…”菜单项。
    var piWebUpdateWarningMenuItem: NSMenuItem?
    var piWebUpdateMenuItem: NSMenuItem?
    /// 受限自动更新的编排器（安装器、重检测、启动/健康检查全部注入）。
    var piWebUpdateCoordinator: PiWebUpdateCoordinator?
    /// 生产安装器：`posix_spawn` + 参数数组 + 新独立进程组，不使用 shell、不调用
    /// sudo；超时只终止**本次启动的** npm 子进程组（至多一次），绝不触碰 Pi 进程。
    private let piWebUpdateInstaller: ProcessPiWebUpdateInstaller
    /// 安装后的版本重检测输入（每次更新前在主线程写入）。
    var piWebUpdateRedetectionPath: String?

    // MARK: - Pi CLI 更新与运行进程保护（GitHub #21）

    /// Pi CLI 进程检查器：只读 libproc 枚举（`proc_listpids` / `proc_pidinfo` /
    /// `proc_pidpath` / `sysctl`），不向任何进程发送信号。init 里换成与日志/
    /// 诊断共用的同一个 `LogRedactor`。
    var piProcessInspector = PiProcessInspector()
    /// Pi CLI 更新命令执行器：`Process` + 参数数组（`update --self`），不使用
    /// shell、不调用 sudo、不发送信号；超时只放弃等待（见 `PiCLIUpdateCoordinator`）。
    let piCLIUpdateRunner: ProcessPiCLIUpdateCommand
    /// Pi CLI 更新编排器（进程检查、命令执行、版本重检测、日志、投递队列注入）。
    var piCLIUpdateCoordinator: PiCLIUpdateCoordinator?
    /// 最近一次 Pi 进程检查结果；nil = 本次运行还没有检查过（smoke 启动不检查）。
    var piProcessInspection: PiProcessInspection?
    /// 最近一次自动更新决策（诊断/设置页展示用）。
    var piCLIUpdateDecision: PiCLIUpdateDecision?
    /// 最近一次失败的 Pi CLI 更新的持久警告（跨启动保留）。
    var piCLIUpdateWarning: PiCLIUpdateWarning?
    /// 本次运行是否已经执行过自动更新（无论成败，最多一次；推迟不算执行）。
    var piCLIUpdateAttemptedInThisRun = false
    /// 自动更新进行中。
    var piCLIUpdateInProgress = false
    /// 重新检测 Pi 版本的输入路径（每次更新前写入）。
    var piCLIUpdateRedetectionPath: String?
    /// 菜单里的持久告警项与手动更新入口项。
    var piCLIUpdateWarningMenuItem: NSMenuItem?
    var piCLIUpdateMenuItem: NSMenuItem?

    // MARK: - Pi 扩展包更新（GitHub #22）

    /// 扩展包更新命令执行器：`Process` + 参数数组（`update npm:<包名>`），不使用
    /// shell、不调用 sudo、不发送信号；超时只放弃等待（见 `PiPackageUpdateCoordinator`）。
    private let piPackageUpdateRunner: PiPackageUpdateRunning
    /// 扩展包更新编排器（进程检查、命令执行、版本重检测、日志、投递队列注入）。
    var piPackageUpdateCoordinator: PiPackageUpdateCoordinator?
    /// 最近一次规划结果（诊断/设置页展示用）。
    var piPackageUpdatePlanSet: PiPackageUpdatePlanSet?
    /// 最近一次失败的扩展包更新的持久警告（跨启动保留）。
    var piPackageUpdateWarning: PiPackageUpdateWarning?
    /// 扩展包更新进行中。
    var piPackageUpdateInProgress = false
    /// 菜单里的持久告警项与扩展包更新入口项。
    var piPackageUpdateWarningMenuItem: NSMenuItem?
    var piPackageUpdateMenuItem: NSMenuItem?
    /// 菜单里的「已放弃」记录项（GitHub #62）。
    var abandonedAttemptsMenuItem: NSMenuItem?

    /// 诊断页/设置窗口的状态时间格式。
    static let updateTimestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter
    }()

    let appConfiguration: AppConfiguration
    let commandRunner: CommandRunning
    /// 应用级工具 PATH（GitHub #89）：依赖探测、组件识别、更新子进程与服务启动
    /// 共用同一个实例，因此 PATH 只有一份来源（应用 PATH + 登录 shell + 已知
    /// 目录 + node 目录 + npm prefix/bin）。应用从 Finder 启动时 PATH 最小，
    /// `#!/usr/bin/env node` 脚本靠它才能找到 node。
    let toolPathProvider: ToolPathProvider
    let processInspector: ProcessInspector
    let serviceManager: ServiceManager
    /// 统一脱敏器（GitHub #10）：日志、诊断导出、错误消息、环境变量/命令行展示
    /// 都使用这一个实例。同一对象而不是“同一份规则”。
    let logRedactor: LogRedactor
    /// 应用日志写入器（服务子进程输出 + 更新检查状态行共用同一个脱敏器实例）。
    let logWriter: LogWriter
    /// 工作目录探针（存在/是目录/可写）；测试可注入假探针。
    let workspaceProbe: WorkspaceDirectoryProbe
    /// 远程访问密码的唯一存储。AppDelegate 只把它注入 ServiceManager、设置界面
    /// 和诊断文本的状态行，绝不把密码写进 UserDefaults、日志或诊断内容。
    let keychain: KeychainStoring

    var startURL: URL { serviceManager.configuration.serviceURL }

    var instanceLockHandle: FileHandle?

    init(
        appConfiguration: AppConfiguration = AppConfiguration.forCurrentProcess(),
        commandRunner: CommandRunning = SystemCommandRunner(),
        keychain: KeychainStoring = KeychainStore(),
        workspaceProbe: WorkspaceDirectoryProbe = .live(),
        logRedactor: LogRedactor = LogRedactor()
    ) {
        self.appConfiguration = appConfiguration
        self.keychain = keychain
        self.workspaceProbe = workspaceProbe
        self.logRedactor = logRedactor
        // 先用「继承应用环境」的 runner 解析工具 PATH（登录 shell 查询、node、
        // npm prefix），再把解析结果交给主 runner：探测与工具调用因此共用同一份
        // PATH。注入 runner 时（smoke / 测试）解析仍然只走注入的 runner。
        let toolPathProvider = ToolPathProvider(
            environment: ProcessInfo.processInfo.environment,
            homeDirectory: NSHomeDirectory(),
            commandRunner: commandRunner
        )
        self.toolPathProvider = toolPathProvider
        let toolCommandRunner = ToolEnvironmentCommandRunner(
            base: commandRunner,
            environment: toolPathProvider.probeEnvironment()
        )
        self.commandRunner = toolCommandRunner
        let logWriter = LogWriter(logFileURL: appConfiguration.logURL, redactor: logRedactor)
        self.logWriter = logWriter
        let processInspector = ProcessInspector(runner: toolCommandRunner)
        self.processInspector = processInspector
        self.serviceManager = ServiceManager(
            configuration: appConfiguration.serviceConfiguration,
            appConfiguration: appConfiguration,
            processInspector: processInspector,
            commandRunner: toolCommandRunner,
            // 远程模式的门控与环境变量都读这一个闭包：读取失败即“无密码”。
            remoteAccessPassword: { RemoteAccessPassword.load(from: keychain) },
            // ServiceManager 的日志与错误消息共用 AppDelegate 的脱敏器实例。
            logWriter: logWriter,
            // 服务启动环境与依赖探测共用同一个 PATH 构建器（GitHub #89）。
            toolPathProvider: toolPathProvider
        )
        // 系统代理告警（GitHub #157）：只读系统代理配置，日志与提示文案只写网段，
        // 不写用户真实地址，也不修改用户设置。
        self.systemProxyWarningMonitor = SystemProxyWarningCoordinator(
            log: { [logWriter] message in _ = logWriter.append(message) }
        )
        // 更新检查设置（GitHub #18）：策略与忽略版本都存在同一个注入的
        // UserDefaults domain 里；旧版布尔键经迁移函数回退，诊断行进日志。
        let updateLog: (String) -> Void = { [logWriter] message in _ = logWriter.append(message) }
        let updatePreferences = appConfiguration.updateCheckPreferences(diagnostics: updateLog)
        self.ignoredVersions = appConfiguration.updateCheckIgnoredVersions(diagnostics: updateLog)
        let updateChecker = UpdateChecker(
            httpClient: URLSessionUpdateHTTPClient(),
            cacheStore: UpdateCheckCacheFileStore(fileURL: appConfiguration.paths.updateCheckCacheURL),
            scheduler: DispatchUpdateCheckScheduler(),
            identity: .current,
            preferences: updatePreferences,
            ignoredVersions: ignoredVersions,
            log: { [logWriter] message in _ = logWriter.append(message) }
        )
        self.updateChecker = updateChecker
        // 三个更新执行器共用同一个「已放弃」记录写入器（GitHub #62）：超时或放弃
        // 等待时写一条可持久化记录，命令摘要经同一个脱敏器实例处理，绝不写入
        // Home 绝对路径或凭据；Pi CLI / 扩展包路径不会向任何进程发信号。
        let recordAbandonedAttempt: (UpdateAbandonedAttempt) -> Void = { attempt in
            appConfiguration.saveAbandonedAttempt(attempt)
        }
        self.piWebUpdateInstaller = ProcessPiWebUpdateInstaller(
            redact: { text in logRedactor.redact(text) },
            recordAbandonedAttempt: recordAbandonedAttempt
        )
        self.piCLIUpdateRunner = ProcessPiCLIUpdateCommand(
            // 更新子进程的 PATH 也来自同一个构建器（GitHub #89）；白名单在
            // `PiCLIUpdateEnvironment` 里保持不变。
            baseEnvironment: toolPathProvider.probeEnvironment(),
            redact: { text in logRedactor.redact(text) },
            recordAbandonedAttempt: recordAbandonedAttempt
        )
        self.piPackageUpdateRunner = ProcessPiPackageUpdateCommand(
            baseEnvironment: toolPathProvider.probeEnvironment(),
            redact: { text in logRedactor.redact(text) },
            recordAbandonedAttempt: recordAbandonedAttempt
        )
        super.init()
        updateChecker.onResultsChanged = { [weak self] summary in
            self?.handleUpdateCheckResults(summary)
        }
        // 受限自动更新（GitHub #20）：日志与其它写入共用同一个 LogWriter/LogRedactor；
        // 版本重检测复用 #16 识别器；服务启动与健康检查复用 ServiceManager 路径。
        self.piWebUpdateWarning = appConfiguration.piWebUpdateWarning()
        self.piWebUpdateCoordinator = PiWebUpdateCoordinator(environment: PiWebUpdateCoordinator.Environment(
            installer: piWebUpdateInstaller,
            detectInstallation: { [weak self] in
                guard let self else { return nil }
                return PiWebUpdateRedetection.detect(
                    piWebPath: self.piWebUpdateRedetectionPath,
                    commandRunner: self.commandRunner
                )
            },
            startServiceAndCheckHealth: { [weak self] completion in
                self?.startServiceAndCheckHealthForUpdate(completion: completion)
            },
            redactor: logRedactor,
            log: { [logWriter] message in _ = logWriter.append(message) },
            deliver: { work in DispatchQueue.main.async(execute: work) },
            timeout: PiWebUpdateCoordinator.defaultTimeout,
            transaction: UpdateTransactionEnvironment(
                probe: .live,
                recordHistory: { [weak self] entry in self?.appConfiguration.recordUpdateHistory(entry) },
                applyDegradation: { [weak self] plan in self?.applyPiWebUpdateDegradation(plan) },
                now: Date.init
            ),
            clearAbandonedAttempt: { [weak self] component in self?.clearAbandonedAttempt(component) }
        ))
        // Pi CLI 更新与运行进程保护（GitHub #21）：进程检查复用同一个脱敏器；
        // 执行器不发送任何信号（超时只放弃等待）；版本重检测复用 #16 识别器。
        self.piProcessInspector = PiProcessInspector(redactor: logRedactor)
        self.piCLIUpdateWarning = appConfiguration.piCLIUpdateWarning()
        self.piCLIUpdateCoordinator = PiCLIUpdateCoordinator(environment: PiCLIUpdateCoordinator.Environment(
            inspectProcesses: { [weak self] in
                self?.refreshPiProcessInspection() ?? .unknown(.enumerationFailed)
            },
            runner: piCLIUpdateRunner,
            detectInstallation: { [weak self] in
                guard let self else { return nil }
                return PiCLIUpdateRedetection.detect(
                    piPath: self.piCLIUpdateRedetectionPath,
                    commandRunner: self.commandRunner
                )
            },
            redactor: logRedactor,
            log: { [logWriter] message in _ = logWriter.append(message) },
            deliver: { work in DispatchQueue.main.async(execute: work) },
            timeout: PiCLIUpdateCoordinator.defaultTimeout,
            transaction: UpdateTransactionEnvironment(
                probe: .live,
                recordHistory: { [weak self] entry in self?.appConfiguration.recordUpdateHistory(entry) },
                applyDegradation: { [weak self] plan in self?.applyPiCLIUpdateDegradation(plan) },
                now: Date.init
            ),
            clearAbandonedAttempt: { [weak self] component in self?.clearAbandonedAttempt(component) }
        ))
        // Pi 扩展包更新（GitHub #22）：策略只有关闭 / 检查并通知 / 询问后更新，
        // 绝不无人值守更新；执行前复查 Pi 进程，执行后重新检测该包版本。
        self.piPackageUpdateWarning = appConfiguration.piPackageUpdateWarning()
        self.piPackageUpdateCoordinator = PiPackageUpdateCoordinator(environment: PiPackageUpdateCoordinator.Environment(
            inspectProcesses: { [weak self] in
                self?.refreshPiProcessInspection() ?? .unknown(.enumerationFailed)
            },
            runner: piPackageUpdateRunner,
            detectPackageVersion: { [weak self] packageName in
                guard let self else { return nil }
                let piPath = self.dependencyReport?.components.first { $0.kind == .piCLI }?.executablePath
                return PiPackageUpdateRedetection.versionProvider(
                    piPath: piPath,
                    commandRunner: self.commandRunner
                )(packageName)
            },
            redactor: logRedactor,
            log: { [logWriter] message in _ = logWriter.append(message) },
            deliver: { work in DispatchQueue.main.async(execute: work) },
            timeout: PiPackageUpdateCoordinator.defaultTimeout,
            transaction: UpdateTransactionEnvironment(
                probe: .live,
                recordHistory: { [weak self] entry in self?.appConfiguration.recordUpdateHistory(entry) },
                applyDegradation: { plan in
                    // 扩展包没有可重新指向的可执行文件：只把降级结果写进日志与历史。
                    _ = plan
                },
                now: Date.init
            ),
            clearAbandonedAttempt: { [weak self] component in self?.clearAbandonedAttempt(component) }
        ))
    }

    // MARK: - Smoke launch

    /// `PI_WEB_DESKTOP_SMOKE=1` startup: temporary support directory, no
    /// single-instance lock and no service auto-start. Prints the fixed marker
    /// and exits 0 once the main window exists; any failure exits non-zero
    /// without printing it. Without the variable this path is never taken.
    func runSmokeLaunch() {
        do {
            try FileManager.default.createDirectory(at: appConfiguration.supportURL, withIntermediateDirectories: true)
        } catch {
            failSmokeLaunch("cannot create \(appConfiguration.supportURL.path): \(error.localizedDescription)")
        }
        installMainMenu()
        createWindow()
        guard window != nil, webViewController != nil else {
            failSmokeLaunch("main window was not created")
        }
        let supportURL = appConfiguration.supportURL
        DispatchQueue.main.async {
            FileHandle.standardOutput.write(Data((AppConfiguration.smokeReadyMarker + "\n").utf8))
            try? FileManager.default.removeItem(at: supportURL)
            exit(0)
        }
    }

    private func failSmokeLaunch(_ message: String) -> Never {
        FileHandle.standardError.write(Data("smoke launch failed: \(message)\n".utf8))
        exit(1)
    }

    /// `PI_WEB_DESKTOP_SMOKE=diagnostics` diagnostics smoke: temporary support
    /// directory, no single-instance lock, no service auto-start and no real
    /// probes. It uses the deterministic `DiagnosticsSmokeFixture` report, runs
    /// the real first-launch routing decision, renders the diagnostics status
    /// page into the WebView and creates the diagnostics window, then prints the
    /// fixed marker and exits 0. Any failure exits non-zero without printing it.
    /// Without the variable this path is never taken.
    func runDiagnosticsSmokeLaunch() {
        do {
            try FileManager.default.createDirectory(at: appConfiguration.supportURL, withIntermediateDirectories: true)
        } catch {
            failSmokeLaunch("cannot create \(appConfiguration.supportURL.path): \(error.localizedDescription)")
        }
        installMainMenu()
        createWindow()
        guard window != nil, webViewController != nil else {
            failSmokeLaunch("main window was not created")
        }

        let report = DiagnosticsSmokeFixture.report()
        let route = DiagnosticsRouting.route(DiagnosticsRouting.Context(report: report, hasCompletedFirstLaunchSetup: false))
        guard case .diagnostics = route else {
            failSmokeLaunch("the deterministic diagnostics report did not route to the diagnostics page")
        }

        webViewController.showDependencyPage(
            title: "首次启动环境检查",
            message: DependencyReportPresenter.statusPageText(for: report, setupIncomplete: true)
        )
        showDiagnostics(report: report, firstLaunchSetupIncomplete: true, canContinueToService: report.canStartService)

        let supportURL = appConfiguration.supportURL
        let summary = "smoke: diagnostics items=\(report.findings.count) blockers=\(report.blockingFindings.count)\n"
        DispatchQueue.main.async {
            FileHandle.standardOutput.write(Data((summary + AppConfiguration.smokeDiagnosticsReadyMarker + "\n").utf8))
            try? FileManager.default.removeItem(at: supportURL)
            exit(0)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        desktopAppUpdateInstaller = nil
        // 退出已开始：兜底计时器不再需要。
        quitDecisionTimer?.invalidate()
        quitDecisionTimer = nil
        // 应用关闭时不检查：先取消周期计时器，此后的触发一律忽略。
        updateChecker?.stop()
        // 进行中的受限自动安装也必须终止：取消按失败处理，不留孤儿进程。
        piWebUpdateInstaller.cancel()
        // 依赖探针（`--version` / `command -v` / `ps` / `lsof`）不再等待：取消只会
        // 终止本次启动的子进程，不按名字或进程组发信号。
        commandRunner.cancelRunningProbe()
        // Pi CLI 更新命令只放弃等待：本应用不向任何进程发送信号。
        piCLIUpdateRunner.abandon()
        serviceManager.stopHealthMonitor()
        try? FileManager.default.removeItem(at: appConfiguration.appPIDURL)
        serviceManager.closeLog()
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
            self.eventMonitor = nil
        }
        if let screenParametersObserver {
            NotificationCenter.default.removeObserver(screenParametersObserver)
            self.screenParametersObserver = nil
        }
        screenFitWorkItem?.cancel()
        screenFitWorkItem = nil
        if hasInstanceLock { instanceLockHandle = nil }
    }

    /// 工作目录不可用时状态页上的完整正文；目录可用时返回 nil。
    var workspaceProblemMessage: String? {
        guard workspaceValidation.problem != nil else { return nil }
        return WorkspaceDirectory.statusPageText(
            workspaceValidation,
            defaultPath: appConfiguration.defaultWorkspaceDirectory.path
        )
    }

    /// 工作目录不可用时的单条可读修复提示（诊断窗口用）；目录可用时返回 nil。
    var workspaceHintMessage: String? {
        guard let problem = workspaceValidation.problem else { return nil }
        return problem.message(
            path: workspaceValidation.path,
            isDefaultLocation: workspaceValidation.path == appConfiguration.defaultWorkspaceDirectory.path
        )
    }

    // 版本信息只有一个来源：bundle 的 Info.plist（由 Configuration/AppIdentity.xcconfig 生成）。
    // Swift 侧不保存第二套版本常量；读取失败时明确标注为开发构建。
    var appVersionDescription: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String)?.nilIfEmpty
            ?? "开发构建（Info.plist 缺少 CFBundleShortVersionString）"
    }

    var appBuildDescription: String {
        (Bundle.main.infoDictionary?["CFBundleVersion"] as? String)?.nilIfEmpty
            ?? "开发构建（Info.plist 缺少 CFBundleVersion）"
    }

    /// Pi Web 的更新入口状态（W3B F3）：只看 Pi Web 自己，不看另一个组件；
    /// 「事务进行中」与「已放弃等待但退出未确认」分开：后者要给出重启恢复路径。
    var piWebUpdateEntryState: UpdateEntryState {
        UpdateEntryState.component(
            transactionInProgress: piWebUpdateCoordinator?.isRunning == true,
            childInFlight: piWebUpdateInstaller.isRunning,
            abandonedChildrenUnconfirmed: piWebUpdateInstaller.abandonedChildrenUnconfirmed
        )
    }

    /// Pi CLI 的更新入口状态（W3B F3）：只看 Pi CLI 自己，不看另一个组件。
    var piCLIUpdateEntryState: UpdateEntryState {
        UpdateEntryState.component(
            transactionInProgress: piCLIUpdateCoordinator?.isRunning == true,
            childInFlight: piCLIUpdateRunner.isRunning,
            abandonedChildrenUnconfirmed: piCLIUpdateRunner.abandonedChildrenUnconfirmed
        )
    }

    /// Pi 扩展包的更新入口状态（GitHub #107）：与 Pi Web / Pi CLI 同一套判据，
    /// 数据来自扩展包自己的执行器（`isRunning` / `abandonedChildrenUnconfirmed`，
    /// 都是非阻塞读状态）与编排中标记。
    var piPackageUpdateEntryState: UpdateEntryState {
        UpdateEntryState.component(
            transactionInProgress: piPackageUpdateInProgress,
            childInFlight: piPackageUpdateRunner.isRunning,
            abandonedChildrenUnconfirmed: piPackageUpdateRunner.abandonedChildrenUnconfirmed
        )
    }

    // MARK: - Error and utility

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        let controls = ServiceControlState(gate: dependencyGate, workspaceIsReady: workspaceValidation.isUsable)
        switch menuItem.action {
        case #selector(startServiceAction(_:)):
            return controls.canStart && serviceManager.managedServicePID() == nil
        case #selector(stopServiceAction(_:)): return controls.canStop
        case #selector(restartServiceAction(_:)): return controls.canRestart
        // 诊断导出进行中（提醒框已弹出或后台采集未结束）：忽略重复触发。
        case #selector(copyDiagnostics(_:)): return !diagnosticsExportInProgress
        case #selector(toggleFullScreen(_:)):
            // 多窗口（GitHub #168）：标题跟随将被切换的那个窗口（已登记的 key 窗口），
            // 没有时回落到最近使用的窗口（`mainWindow`）。
            menuItem.title = activeWindow?.styleMask.contains(.fullScreen) == true ? "退出全屏幕" : "进入全屏幕"
            return true
        default: return true
        }
    }
}
