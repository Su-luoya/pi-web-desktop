import Cocoa

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuDelegate {
    private var window: NSWindow!
    private var webViewController: WebViewController!
    private var statusMenuItem: NSMenuItem?
    private var terminationDecisionPending = false
    private var hasInstanceLock = false
    private var eventMonitor: Any?
    private var screenParametersObserver: NSObjectProtocol?
    private var screenFitWorkItem: DispatchWorkItem?
    private var isFullScreenTransition = false
    private var currentState: ServiceState = .checking
    private var preferencesWindowController: PreferencesWindowController?
    private var diagnosticsWindowController: DiagnosticsWindowController?
    /// 依赖门控禁用的服务控件菜单项（启动/停止/重启）。
    private var serviceControlMenuItems: [NSMenuItem] = []
    private var dependencyReport: DependencyReport?
    /// 依赖门控状态；start/stop/restart 的可用性统一由 `ServiceControlState` 映射。
    private var dependencyGate: DiagnosticsGate = .checking
    private var dependencyCheckGeneration = 0
    private var shouldPresentDiagnostics = false
    /// 工作目录校验结果（GitHub #9）。不可用时门控关闭、路由进入诊断页。
    private var workspaceValidation: WorkspaceDirectoryValidation = .usable(path: "")

    // MARK: - 更新检查（GitHub #17）

    /// 版本检查器：只检查、不安装。失败只改变检查结果状态，不影响服务状态。
    private var updateChecker: UpdateChecker?
    private var updateStatusMenuItem: NSMenuItem?
    private var updateCategoryMenuItems: [UpdateCheckCategory: NSMenuItem] = [:]
    private var updateSettingsMenu: NSMenu?
    /// “更新检查偏好设置”窗口（GitHub #18）。
    private var updateSettingsWindowController: UpdateSettingsWindowController?
    /// 每类组件的“忽略版本”（只存版本字符串与时间戳，见 `UpdateIgnoredVersions`）。
    private var ignoredVersions: UpdateIgnoredVersions = .empty
    /// 本次运行已经提示过哪些版本，避免同一个版本反复打扰；退出即丢弃。
    private var notifiedVersions: [UpdateCheckCategory: String] = [:]
    /// 主线程状态：是否有一次检查正在进行（用于菜单文案与重复点击防护）。
    private var updateCheckInProgress = false
    /// 手动检查完成后是否弹提示；自动检查是否提示由策略与忽略版本决定。
    private var pendingManualUpdateCheck = false

    // MARK: - 受限自动更新（GitHub #20）

    /// 最近一次失败的启动前自动更新的持久警告（从 UserDefaults 读入，跨启动保留）。
    private var piWebUpdateWarning: PiWebUpdateWarning?
    /// 启动前更新进行中：抑制同一版本的自动提示框（安装流程会自己给结果）。
    private var preLaunchUpdateInProgress = false
    /// 本次运行已经尝试过启动前自动更新（无论成败）：同一次运行内不再自动重试，
    /// 失败后由用户显式点击“立即更新 Pi Web…”或下次启动再试。
    private var preLaunchUpdateAttemptedInThisRun = false
    /// 告警菜单项与“立即更新…”菜单项。
    private var piWebUpdateWarningMenuItem: NSMenuItem?
    private var piWebUpdateMenuItem: NSMenuItem?
    /// 受限自动更新的编排器（安装器、重检测、启动/健康检查全部注入）。
    private var piWebUpdateCoordinator: PiWebUpdateCoordinator?
    /// 生产安装器：`Process` + 参数数组，不使用 shell、不调用 sudo。
    private let piWebUpdateInstaller = ProcessPiWebUpdateInstaller()
    /// 安装后的版本重检测输入（每次更新前在主线程写入）。
    private var piWebUpdateRedetectionPath: String?

    /// 诊断页/设置窗口的状态时间格式。
    private static let updateTimestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter
    }()

    private let appConfiguration: AppConfiguration
    private let commandRunner: CommandRunning
    private let processInspector: ProcessInspector
    private let serviceManager: ServiceManager
    /// 统一脱敏器（GitHub #10）：日志、诊断导出、错误消息、环境变量/命令行展示
    /// 都使用这一个实例。同一对象而不是“同一份规则”。
    private let logRedactor: LogRedactor
    /// 应用日志写入器（服务子进程输出 + 更新检查状态行共用同一个脱敏器实例）。
    private let logWriter: LogWriter
    /// 工作目录探针（存在/是目录/可写）；测试可注入假探针。
    private let workspaceProbe: WorkspaceDirectoryProbe
    /// 远程访问密码的唯一存储。AppDelegate 只把它注入 ServiceManager、设置界面
    /// 和诊断文本的状态行，绝不把密码写进 UserDefaults、日志或诊断内容。
    private let keychain: KeychainStoring

    private var startURL: URL { serviceManager.configuration.serviceURL }

    private var instanceLockHandle: FileHandle?

    init(
        appConfiguration: AppConfiguration = AppConfiguration.forCurrentProcess(),
        commandRunner: CommandRunning = SystemCommandRunner(),
        keychain: KeychainStoring = KeychainStore(),
        workspaceProbe: WorkspaceDirectoryProbe = .live(),
        logRedactor: LogRedactor = LogRedactor()
    ) {
        self.appConfiguration = appConfiguration
        self.commandRunner = commandRunner
        self.keychain = keychain
        self.workspaceProbe = workspaceProbe
        self.logRedactor = logRedactor
        let logWriter = LogWriter(logFileURL: appConfiguration.logURL, redactor: logRedactor)
        self.logWriter = logWriter
        let processInspector = ProcessInspector(runner: commandRunner)
        self.processInspector = processInspector
        self.serviceManager = ServiceManager(
            configuration: appConfiguration.serviceConfiguration,
            appConfiguration: appConfiguration,
            processInspector: processInspector,
            commandRunner: commandRunner,
            // 远程模式的门控与环境变量都读这一个闭包：读取失败即“无密码”。
            remoteAccessPassword: { RemoteAccessPassword.load(from: keychain) },
            // ServiceManager 的日志与错误消息共用 AppDelegate 的脱敏器实例。
            logWriter: logWriter
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
            timeout: PiWebUpdateCoordinator.defaultTimeout
        ))
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        switch appConfiguration.smokeLaunchMode {
        case .startup:
            runSmokeLaunch()
            return
        case .diagnostics:
            runDiagnosticsSmokeLaunch()
            return
        case .none:
            break
        }
        try? FileManager.default.createDirectory(at: appConfiguration.supportURL, withIntermediateDirectories: true)
        guard acquireSingleInstanceLock() else {
            NSApp.terminate(nil)
            return
        }
        try? "\(ProcessInfo.processInfo.processIdentifier)\n".write(to: appConfiguration.appPIDURL, atomically: true, encoding: .utf8)
        NSApp.mainMenu = nil
        installQuitShortcuts()
        installScreenChangeObserver()
        installMainMenu()
        createWindow()
        installServiceManagerCallbacks()
        serviceManager.setState(.checking)
        webViewController.showLoadingPage(message: "正在检查运行环境…")
        refreshWorkspaceState()
        // 更新检查立即开始：先把应用自身版本发出去；依赖检测完成后补齐
        // Pi / Pi Web / 扩展包版本（见 `startUpdateChecking`）。
        startUpdateChecking(with: UpdateCheckInventory(desktopAppVersion: ApplicationInstallationProbe.current.version))
        runDependencyCheck()
    }

    // MARK: - Smoke launch

    /// `PI_WEB_DESKTOP_SMOKE=1` startup: temporary support directory, no
    /// single-instance lock and no service auto-start. Prints the fixed marker
    /// and exits 0 once the main window exists; any failure exits non-zero
    /// without printing it. Without the variable this path is never taken.
    private func runSmokeLaunch() {
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
    private func runDiagnosticsSmokeLaunch() {
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
        // 应用关闭时不检查：先取消周期计时器，此后的触发一律忽略。
        updateChecker?.stop()
        // 进行中的受限自动安装也必须终止：取消按失败处理，不留孤儿进程。
        piWebUpdateInstaller.cancel()
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

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !serviceManager.isQuitting else { return .terminateNow }
        guard !terminationDecisionPending else { return .terminateLater }

        // 退出决策是纯逻辑（QuitPlan）：三种行为（询问/保持运行/停止服务）都在
        // 这里映射成“弹框 / 退出 / 停止托管服务”。外部服务在任何行为下都不会
        // 被停止。
        let plan = QuitPlan.plan(for: serviceManager.configuration.quitBehavior)
        guard plan.requiresUserConfirmation else {
            applyQuitPlan(plan)
            return .terminateLater
        }

        terminationDecisionPending = true
        let alert = NSAlert()
        alert.messageText = "退出 Pi Web"
        alert.informativeText = "是否在退出应用后继续保持 Pi Web 服务运行？"
        alert.addButton(withTitle: "保持服务运行")
        alert.addButton(withTitle: "退出并停止服务")
        alert.addButton(withTitle: "取消")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            self.terminationDecisionPending = false
            let confirmation: QuitConfirmation
            switch response {
            case .alertFirstButtonReturn: confirmation = .keepServiceRunning
            case .alertSecondButtonReturn: confirmation = .stopService
            default: confirmation = .cancel
            }
            self.applyQuitPlan(QuitPlan.plan(for: confirmation))
        }
        return .terminateLater
    }

    /// 执行退出计划。`.stayOpen`（用户取消）不停止任何服务，也不退出。
    private func applyQuitPlan(_ plan: QuitPlan) {
        switch plan.nextStep {
        case .askUser, .stayOpen:
            return
        case .terminate:
            if plan.stopsManagedService {
                quitAndStop(nil)
            } else {
                quitKeepingService(nil)
            }
        }
    }

    private func acquireSingleInstanceLock() -> Bool {
        let existingPID = (try? String(contentsOf: appConfiguration.appPIDURL, encoding: .utf8))
            .flatMap { ProcessInspector.parsePIDRecord($0) }
        if let existingPID, processInspector.isProcessAlive(existingPID) {
            return false
        }
        if FileManager.default.fileExists(atPath: appConfiguration.instanceLockURL.path) {
            try? FileManager.default.removeItem(at: appConfiguration.instanceLockURL)
        }
        FileManager.default.createFile(atPath: appConfiguration.instanceLockURL.path, contents: nil)
        do {
            instanceLockHandle = try FileHandle(forWritingTo: appConfiguration.instanceLockURL)
            hasInstanceLock = true
            return true
        } catch {
            return false
        }
    }

    private func installQuitShortcuts() {
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard modifiers.contains(.command) else { return event }

            switch event.charactersIgnoringModifiers?.lowercased() {
            case ",":
                self?.showPreferences(nil)
                return nil
            case "r" where modifiers.contains(.shift):
                self?.hardReloadPage(nil)
                return nil
            case "r":
                self?.reloadPage(nil)
                return nil
            case "f" where modifiers.contains(.control):
                self?.toggleFullScreen(nil)
                return nil
            default:
                return event
            }
        }
    }

    private func installScreenChangeObserver() {
        screenParametersObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // 屏幕旋转/分辨率变化时，windowDidChangeScreen 不一定会发送；
            // 等 AppKit 更新 NSScreen.visibleFrame 后再重新布局。
            self?.scheduleWindowFit()
        }
    }

    private func scheduleWindowFit() {
        screenFitWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.screenFitWorkItem = nil
            self.fitWindowToCurrentScreen()
        }
        screenFitWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: workItem)
    }

    // MARK: - Menus

    private func installMainMenu() {
        serviceControlMenuItems.removeAll()
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu(title: "Pi Web Desktop")
        appMenu.addItem(withTitle: "关于 Pi Web Desktop", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "隐藏 Pi Web Desktop", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(withTitle: "隐藏其他应用", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "显示全部", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(withTitle: "设置…", action: #selector(showPreferences(_:)), keyEquivalent: ",")
        appMenu.addItem(makeServiceControlMenuItem(title: "启动服务", action: #selector(startServiceAction(_:))))
        appMenu.addItem(makeServiceControlMenuItem(title: "重启服务", action: #selector(restartServiceAction(_:))))
        appMenu.addItem(makeServiceControlMenuItem(title: "停止服务", action: #selector(stopServiceAction(_:))))
        appMenu.addItem(withTitle: "在浏览器中打开", action: #selector(openInBrowser(_:)), keyEquivalent: "")
        appMenu.addItem(withTitle: "复制本地地址", action: #selector(copyLocalAddress(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "退出 Pi Web Desktop（保持服务运行）", action: #selector(quitKeepingService(_:)), keyEquivalent: "")
        appMenu.addItem(withTitle: "退出 Pi Web Desktop（停止服务）", action: #selector(quitAndStop(_:)), keyEquivalent: "")
        // ⌘Q 走配置的退出行为（默认询问），与设置里的“退出行为”一致；两个
        // 显式菜单项不受配置影响。
        let quitItem = appMenu.addItem(withTitle: "退出 Pi Web Desktop", action: #selector(quitWithConfiguredBehavior(_:)), keyEquivalent: "q")
        quitItem.keyEquivalentModifierMask = [.command]
        appMenuItem.submenu = appMenu

        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)
        let editMenu = NSMenu(title: "编辑")
        editMenu.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "在页面中查找…", action: #selector(showFindBar(_:)), keyEquivalent: "f")
        editMenuItem.submenu = editMenu

        let viewMenuItem = NSMenuItem()
        mainMenu.addItem(viewMenuItem)
        let viewMenu = NSMenu(title: "显示")
        viewMenu.addItem(withTitle: "重新加载", action: #selector(reloadPage(_:)), keyEquivalent: "r")
        let hardReload = viewMenu.addItem(withTitle: "强制重新加载", action: #selector(hardReloadPage(_:)), keyEquivalent: "r")
        hardReload.keyEquivalentModifierMask = [.command, .shift]
        viewMenu.addItem(.separator())
        viewMenu.addItem(withTitle: "放大", action: #selector(zoomIn(_:)), keyEquivalent: "+")
        viewMenu.addItem(withTitle: "缩小", action: #selector(zoomOut(_:)), keyEquivalent: "-")
        viewMenu.addItem(withTitle: "实际大小", action: #selector(resetZoom(_:)), keyEquivalent: "0")
        viewMenu.addItem(.separator())
        let fullScreenItem = viewMenu.addItem(withTitle: "进入全屏幕", action: #selector(toggleFullScreen(_:)), keyEquivalent: "f")
        fullScreenItem.keyEquivalentModifierMask = [.command, .control]
        viewMenuItem.submenu = viewMenu

        let serviceMenuItem = NSMenuItem()
        mainMenu.addItem(serviceMenuItem)
        let serviceMenu = NSMenu(title: "服务")
        statusMenuItem = serviceMenu.addItem(withTitle: "状态：正在检查…", action: nil, keyEquivalent: "")
        statusMenuItem?.isEnabled = false
        serviceMenu.addItem(.separator())
        serviceMenu.addItem(makeServiceControlMenuItem(title: "启动服务", action: #selector(startServiceAction(_:))))
        serviceMenu.addItem(makeServiceControlMenuItem(title: "重启服务", action: #selector(restartServiceAction(_:))))
        serviceMenu.addItem(makeServiceControlMenuItem(title: "停止服务", action: #selector(stopServiceAction(_:))))
        serviceMenu.addItem(withTitle: "设置…", action: #selector(showPreferences(_:)), keyEquivalent: "")
        serviceMenu.addItem(withTitle: "在浏览器中打开", action: #selector(openInBrowser(_:)), keyEquivalent: "")
        serviceMenu.addItem(withTitle: "复制本地地址", action: #selector(copyLocalAddress(_:)), keyEquivalent: "")
        serviceMenu.addItem(withTitle: "打开日志", action: #selector(openLog(_:)), keyEquivalent: "")
        serviceMenu.addItem(withTitle: "打开日志文件夹", action: #selector(openLogsFolder(_:)), keyEquivalent: "")
        serviceMenu.addItem(withTitle: "复制诊断", action: #selector(copyDiagnostics(_:)), keyEquivalent: "")
        serviceMenu.addItem(withTitle: "依赖与环境诊断…", action: #selector(showDiagnosticsAction(_:)), keyEquivalent: "")
        serviceMenu.addItem(.separator())
        serviceMenu.addItem(withTitle: "检查更新…", action: #selector(checkForUpdatesNow(_:)), keyEquivalent: "")
        serviceMenu.addItem(makeUpdateSettingsMenuItem())
        serviceMenuItem.submenu = serviceMenu

        let windowMenuItem = NSMenuItem()
        mainMenu.addItem(windowMenuItem)
        let windowMenu = NSMenu(title: "窗口")
        windowMenu.addItem(withTitle: "最小化", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "缩放", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenu.addItem(withTitle: "全屏幕", action: #selector(toggleFullScreen(_:)), keyEquivalent: "f")
        windowMenu.item(at: 2)?.keyEquivalentModifierMask = [.command, .control]
        windowMenu.addItem(withTitle: "显示 Pi Web", action: #selector(showWindow(_:)), keyEquivalent: "")
        windowMenuItem.submenu = windowMenu
        NSApp.windowsMenu = windowMenu

        NSApp.mainMenu = mainMenu
    }

    /// 依赖门控禁用的服务控件菜单项（启动/停止/重启）；菜单打开时由
    /// `validateMenuItem` 再次确认。两处都读取同一个 `ServiceControlState` 映射。
    private func makeServiceControlMenuItem(title: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        serviceControlMenuItems.append(item)
        return item
    }

    // MARK: - 依赖诊断门控

    /// 工作目录校验（GitHub #9）：默认目录首次使用时创建，自选目录必须已存在
    /// 且可写。结果同时写入 `ServiceManager` 门控（阻止启动）与路由输入。
    @discardableResult
    private func refreshWorkspaceState(
        configuration: ServiceConfiguration? = nil
    ) -> WorkspaceDirectoryValidation {
        let configuration = configuration ?? serviceManager.configuration
        let validation = WorkspaceDirectory.prepare(
            configuredPath: configuration.workspacePath,
            defaultPath: appConfiguration.defaultWorkspaceDirectory.path,
            probe: workspaceProbe
        )
        workspaceValidation = validation
        serviceManager.setWorkspaceAvailability(
            problem: validation.problem,
            path: validation.path,
            usesDefaultLocation: WorkspaceDirectory.usesDefaultLocation(configured: configuration.workspacePath)
        )
        return validation
    }

    /// 工作目录不可用时状态页上的完整正文；目录可用时返回 nil。
    private var workspaceProblemMessage: String? {
        guard workspaceValidation.problem != nil else { return nil }
        return WorkspaceDirectory.statusPageText(
            workspaceValidation,
            defaultPath: appConfiguration.defaultWorkspaceDirectory.path
        )
    }

    /// 工作目录不可用时的单条可读修复提示（诊断窗口用）；目录可用时返回 nil。
    private var workspaceHintMessage: String? {
        guard let problem = workspaceValidation.problem else { return nil }
        return problem.message(
            path: workspaceValidation.path,
            isDefaultLocation: workspaceValidation.path == appConfiguration.defaultWorkspaceDirectory.path
        )
    }

    /// 启动时与“重新检测”共用的环境检查。命令执行会阻塞，因此放到后台；
    /// 结果回到主线程后再决定路由与门控。检查期间服务控件保持禁用。
    private func runDependencyCheck(triggeredByUser: Bool = false) {
        dependencyGate = .checking
        applyServiceControlAvailability()
        // 检查期间即使有异步回调到达，服务启动入口也必须保持关闭。
        serviceManager.isDependencyGateOpen = false
        dependencyCheckGeneration += 1
        let generation = dependencyCheckGeneration
        // 在主线程读配置和注入的 runner，后台只执行只读探测。
        let configuration = serviceManager.configuration
        let checker = DependencyChecker(
            commandRunner: commandRunner,
            configuredPiWebPath: configuration.piWebPath,
            serviceHostname: configuration.hostname,
            servicePort: configuration.port,
            // 组件安装识别（GitHub #16）：只读运行中的应用包信息；unhosted 测试
            // 与 smoke 用默认 `.none`，因此不会读到真实 bundle 路径。
            applicationInstallation: .current
        )
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let report = checker.run()
            DispatchQueue.main.async {
                guard let self, generation == self.dependencyCheckGeneration else { return }
                self.applyDependencyReport(report, triggeredByUser: triggeredByUser)
            }
        }
    }

    /// 显式更新菜单项的启用状态。三个服务控件的门控相同（只有 `.ready` 时可用），
    /// 所以用同一个映射值；停止项也受门控约束（GitHub #7）。
    private func applyServiceControlAvailability() {
        let controls = ServiceControlState(gate: dependencyGate, workspaceIsReady: workspaceValidation.isUsable)
        serviceControlMenuItems.forEach { $0.isEnabled = controls.canStart }
    }

    /// 应用诊断结果：先定门控（只看硬性前置），再定路由（诊断页或主窗口）。
    ///
    /// - 门控为 `.ready` 当且仅当 `canStartService`（必需项齐备且状态均为
    ///   `ok`）；端口占用与 Pi 配置目录缺失只提示，不改变门控。
    /// - 用户主动重新检测得到就绪报告时记录首次设置完成，路由随即进入主窗口。
    /// - `firstLaunchSetupJustCompleted` 为 true 时（用户刚修好前置）主窗口必须
    ///   显式启动服务，见 `ServiceLaunchIntent`。
    /// - 缺少 pi/pi-web 时路由结果是 `.diagnostics`：应用保留窗口，没有退出分支。
    private func applyDependencyReport(
        _ report: DependencyReport,
        triggeredByUser: Bool,
        firstLaunchSetupJustCompleted: Bool = false
    ) {
        dependencyReport = report
        // 本机版本清单（GitHub #17 的检查输入）来自同一份 #16 识别结果。
        startUpdateChecking(with: UpdateCheckInventory(components: report.components))
        // 工作目录是独立的启动前置：每次报告落地前重新校验（首次使用会创建默认
        // 目录），使外部删除目录后重新检测就能得到可读提示。
        refreshWorkspaceState()

        var justCompletedSetup = firstLaunchSetupJustCompleted
        if triggeredByUser,
           DiagnosticsRouting.completesFirstLaunchSetup(report: report),
           workspaceValidation.isUsable,
           !appConfiguration.hasCompletedFirstLaunchSetup {
            appConfiguration.markFirstLaunchSetupCompleted()
            justCompletedSetup = true
        }

        dependencyGate = report.canStartService ? .ready : .blocked
        applyServiceControlAvailability()
        serviceManager.isDependencyGateOpen = report.canStartService

        // 依赖检查（启动时或用户重新检测）是又一个收敛点：远程配置却取不到密码，
        // 而本应用管理的远程进程仍在运行时，立即停止它并关闭远程模式。
        serviceManager.closeRemoteAccessIfCredentialsAreUnavailable()

        let firstLaunchSetupIncomplete = !appConfiguration.hasCompletedFirstLaunchSetup
        let route = DiagnosticsRouting.route(DiagnosticsRouting.Context(
            report: report,
            hasCompletedFirstLaunchSetup: appConfiguration.hasCompletedFirstLaunchSetup,
            workspaceProblem: workspaceValidation.problem
        ))
        let presentDiagnostics = shouldPresentDiagnostics
        shouldPresentDiagnostics = false

        switch route {
        case .mainWindow:
            diagnosticsWindowController?.close()
            diagnosticsWindowController = nil
            // 首次设置刚完成时必须显式启动，正常启动仍尊重 autoStart（GitHub #7 复审）。
            let launchIntent = ServiceLaunchIntent.intent(firstLaunchSetupJustCompleted: justCompletedSetup)
            beginMainWindowLaunch(
                report: report,
                launchIntent: launchIntent,
                firstLaunchSetupIncomplete: firstLaunchSetupIncomplete,
                presentDiagnostics: presentDiagnostics
            )
        case .diagnostics(let reasons):
            // 诊断页不管理服务：停掉健康轮询并把状态置为 stopped，避免健康检查
            // 把状态改回 running、把诊断页覆盖回服务页。前置缺失、“首次设置
            // 未完成”与“工作目录不可用”三条路径都不启动服务。
            serviceManager.stopHealthMonitor()
            serviceManager.setState(.stopped)
            let workspaceReasons = reasons.contains { reason in
                if case .unusableWorkspace = reason { return true }
                return false
            }
            webViewController.showDependencyPage(
                title: firstLaunchSetupIncomplete ? "首次启动环境检查" : "无法启动 Pi Web 服务",
                message: diagnosticsPageText(
                    report: report,
                    firstLaunchSetupIncomplete: firstLaunchSetupIncomplete,
                    workspaceReasons: workspaceReasons
                )
            )
            showDiagnostics(
                report: report,
                firstLaunchSetupIncomplete: firstLaunchSetupIncomplete,
                canContinueToService: report.canStartService && workspaceValidation.isUsable
            )
        }
    }

    /// 诊断状态页正文：依赖报告文本 + （不可用时）工作目录修复提示。
    private func diagnosticsPageText(
        report: DependencyReport,
        firstLaunchSetupIncomplete: Bool,
        workspaceReasons: Bool
    ) -> String {
        // 依赖与首次设置都正常时，页面上只需要讲工作目录，不重复打印一遍
        // “可以启动 Pi Web 服务”的结论。
        var text = report.canStartService && !firstLaunchSetupIncomplete
            ? ""
            : DependencyReportPresenter.statusPageText(for: report, setupIncomplete: firstLaunchSetupIncomplete)
        if workspaceReasons, let workspaceProblemMessage {
            text = text.isEmpty ? workspaceProblemMessage : text + "\n\n" + workspaceProblemMessage
        }
        return text.isEmpty
            ? DependencyReportPresenter.statusPageText(for: report, setupIncomplete: firstLaunchSetupIncomplete)
            : text
    }

    private func showDiagnostics(report: DependencyReport, firstLaunchSetupIncomplete: Bool, canContinueToService: Bool) {
        if let controller = diagnosticsWindowController {
            controller.update(
                report: report,
                firstLaunchSetupIncomplete: firstLaunchSetupIncomplete,
                canContinueToService: canContinueToService,
                workspaceMessage: workspaceHintMessage
            )
            controller.window?.makeKeyAndOrderFront(nil)
        } else {
            let controller = DiagnosticsWindowController(
                report: report,
                firstLaunchSetupIncomplete: firstLaunchSetupIncomplete,
                canContinueToService: canContinueToService,
                workspaceMessage: workspaceHintMessage
            )
            controller.onRecheck = { [weak self] in self?.runDependencyCheck(triggeredByUser: true) }
            controller.onContinue = { [weak self] in self?.completeFirstLaunchSetup() }
            controller.onSelectPiWebPath = { [weak self] path in self?.applySelectedPiWebPath(path) }
            // 与菜单“复制诊断”完全同一条导出路径与同一份文本。
            controller.diagnosticsTextProvider = { [weak self] in self?.diagnosticsExportText() ?? "" }
            // 更新检查状态（GitHub #18）：诊断页只渲染同一份状态快照。
            controller.updateStatusTextProvider = { [weak self] in self?.updateCheckStatusBlockText() ?? "" }
            diagnosticsWindowController = controller
            controller.showWindow(nil)
        }
        if !NSApp.isActive {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    /// 用户选择的 pi-web 路径：校验失败（不可执行或无法确认是 pi-web）时返回可读
    /// 错误且不碰配置；成功时经 `AppConfiguration` 写回 `ServiceConfiguration.piWebPath`，
    /// 随即重新检测。身份证据只来自只读的 `--version` 与 package.json `name`。
    private func applySelectedPiWebPath(_ path: String) -> String? {
        let checker = DependencyChecker(commandRunner: commandRunner)
        let result = PiWebPathSelection.apply(
            selectedPath: path,
            configuration: serviceManager.configuration,
            evidence: { checker.piWebIdentityEvidence(atPath: $0) }
        )
        guard let error = result.error else {
            let configuration = result.configuration
            appConfiguration.save(configuration)
            serviceManager.updateConfiguration(configuration)
            runDependencyCheck(triggeredByUser: true)
            return nil
        }
        return error
    }

    /// 首次设置完成：记录状态后用最近一次报告重新走路由，随即进入主窗口。
    /// 这条路径标记“本次调用刚刚完成设置”，因此主窗口会显式启动服务。
    private func completeFirstLaunchSetup() {
        guard let report = dependencyReport,
              DiagnosticsRouting.completesFirstLaunchSetup(report: report),
              workspaceValidation.isUsable,
              !appConfiguration.hasCompletedFirstLaunchSetup else { return }
        appConfiguration.markFirstLaunchSetupCompleted()
        applyDependencyReport(report, triggeredByUser: false, firstLaunchSetupJustCompleted: true)
    }

    // MARK: - 启动前受限自动更新（GitHub #20）

    /// 主窗口路由的启动尾部：先处理待更新，再启动服务。
    ///
    /// 任何更新失败路径都不会让应用无法启动：WebView 停在带持久告警的诊断状态
    /// 页、诊断窗口保留、服务不启动；也不会静默继续或声称回滚成功。
    private func beginMainWindowLaunch(
        report: DependencyReport,
        launchIntent: ServiceLaunchIntent,
        firstLaunchSetupIncomplete: Bool,
        presentDiagnostics: Bool
    ) {
        serviceManager.setState(.checking)
        webViewController.showLoadingPage(message: "正在检查 Pi Web 服务…")
        let proceed = { [weak self] in
            guard let self else { return }
            if let warning = self.piWebUpdateWarning {
                self.presentPiWebUpdateWarningBanner(warning)
            }
            self.webViewController.showLoadingPage(message: "正在检查 Pi Web 服务…")
            self.serviceManager.startAtLaunch(forceStart: launchIntent.forcesStart)
            if presentDiagnostics {
                self.showDiagnostics(
                    report: report,
                    firstLaunchSetupIncomplete: firstLaunchSetupIncomplete,
                    canContinueToService: report.canStartService && self.workspaceValidation.isUsable
                )
            }
        }
        // 服务正在运行（例如用户重新检测）：不弹确认、不安装，只记录决策行。
        if serviceManager.managedServicePID() != nil {
            logPiWebUpdateDecision(PiWebUpdatePlanner.decide(piWebUpdatePlanningInput(report: report)))
            proceed()
            return
        }
        guard let updateChecker else {
            proceed()
            return
        }
        let installation = report.components.first { $0.kind == .piWeb }
        guard !preLaunchUpdateAttemptedInThisRun,
              PiWebUpdatePlanner.needsTargetVersionBeforeLaunch(
            preferences: updateChecker.preferences,
            installation: installation
        ) else {
            // 设置关闭或来源不满足：记录一次决策行（为何不走启动前自动更新），
            // 然后照常启动服务。
            logPiWebUpdateDecision(PiWebUpdatePlanner.decide(piWebUpdatePlanningInput(report: report)))
            proceed()
            return
        }
        // 先等一次覆盖 Pi Web 的检查结果（仍然尊重每一类的开关），再根据
        // “是否有已验证的可用版本”决定是否安装；检查失败也只会跳过自动更新，
        // 不影响服务启动。
        preLaunchUpdateInProgress = true
        updateChecker.checkNow(
            triggeredBy: .launch,
            inventory: UpdateCheckInventory(components: report.components)
        ) { [weak self] in
            guard let self else { return }
            self.attemptPreLaunchPiWebUpdate(report: report, proceed: proceed)
        }
    }

    /// 根据已完成的检查结果执行或跳过启动前自动更新。
    private func attemptPreLaunchPiWebUpdate(report: DependencyReport, proceed: @escaping () -> Void) {
        let input = piWebUpdatePlanningInput(report: report)
        let decision = PiWebUpdatePlanner.decide(input)
        logPiWebUpdateDecision(decision)
        guard case .automatic(let plan) = decision, let coordinator = piWebUpdateCoordinator else {
            preLaunchUpdateInProgress = false
            proceed()
            return
        }
        piWebUpdateRedetectionPath = serviceManager.configuration.piWebPath
        preLaunchUpdateAttemptedInThisRun = true
        showPiWebUpdateProgressPage(plan: plan)
        coordinator.run(input) { [weak self] outcome in
            guard let self else { return }
            self.preLaunchUpdateInProgress = false
            switch outcome {
            case .succeeded(_, let oldVersion, let newVersion):
                self.clearPiWebUpdateWarning()
                self.logPiWebUpdate(
                    "启动前自动更新完成：\(oldVersion) → \(newVersion)。"
                )
                proceed()
            default:
                self.presentPiWebUpdateFailure(outcome)
            }
        }
    }

    /// 决策输入：全部来自 #16 识别结果、#17/#18 检查结果与当前服务状态。
    /// npm 路径只由检测到的前缀与 PATH 解析，且必须通过可执行位确认。
    private func piWebUpdatePlanningInput(
        report: DependencyReport?,
        serviceIsRunning: Bool? = nil
    ) -> PiWebUpdatePlanningInput {
        let installation = (report ?? dependencyReport)?.components.first { $0.kind == .piWeb }
        let piWebTarget = UpdateCheckTarget(category: .piWeb, packageName: nil)
        let result = updateChecker?.summary.result(for: piWebTarget.id)
        let environment = ProcessInfo.processInfo.environment
        let npmPath = PiWebUpdateNPMResolver(environment: environment).resolve(installation: installation)
        return PiWebUpdatePlanningInput(
            preferences: updateChecker?.preferences ?? appConfiguration.updateCheckPreferences(),
            installation: installation,
            targetVersion: result?.latestVersion,
            targetStatus: result?.status ?? .unknown,
            targetConfidence: result?.confidence ?? .unknown,
            serviceIsRunning: serviceIsRunning ?? (serviceManager.managedServicePID() != nil),
            npmExecutablePath: npmPath,
            baseEnvironment: environment
        )
    }

    private func logPiWebUpdateDecision(_ decision: PiWebUpdateDecision) {
        logPiWebUpdate(decision.logLine(redactingWith: logRedactor))
    }

    private func logPiWebUpdate(_ message: String) {
        _ = logWriter.append(logRedactor.redact(message))
    }

    /// 失败路径：记录持久告警、进入诊断状态、保留可用 UI；不启动服务、不声称回滚。
    private func presentPiWebUpdateFailure(_ outcome: PiWebUpdateRunOutcome) {
        guard let warning = outcome.warning else { return }
        piWebUpdateWarning = warning
        appConfiguration.savePiWebUpdateWarning(warning)
        logPiWebUpdate(warning.text)
        refreshUpdateMenuState()
        diagnosticsWindowController?.refreshUpdateStatus()

        serviceManager.stopHealthMonitor()
        serviceManager.setState(.stopped)
        let report = dependencyReport
        let diagnosticsText = report.map {
            DependencyReportPresenter.statusPageText(
                for: $0,
                setupIncomplete: !appConfiguration.hasCompletedFirstLaunchSetup
            )
        }
        let message = [warning.text, diagnosticsText]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
        webViewController.showDependencyPage(title: "Pi Web 更新未完成", message: message)
        if let report {
            showDiagnostics(
                report: report,
                firstLaunchSetupIncomplete: !appConfiguration.hasCompletedFirstLaunchSetup,
                canContinueToService: false
            )
        }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Pi Web 更新未完成"
        alert.informativeText = warning.text
        alert.addButton(withTitle: "好")
        alert.beginSheetModal(for: window)
    }

    private func presentPiWebUpdateWarningBanner(_ warning: PiWebUpdateWarning) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Pi Web 上次更新未完成"
        alert.informativeText = warning.text
        alert.addButton(withTitle: "好")
        alert.addButton(withTitle: "清除警告")
        alert.beginSheetModal(for: window) { [weak self] response in
            // 只清除这条持久警告；不会改变 Pi Web 的版本，也不会重试安装。
            guard response == .alertSecondButtonReturn else { return }
            self?.clearPiWebUpdateWarning()
        }
    }

    /// 菜单里的持久警告项：展开完整告警文本，并提供“清除警告”。
    @objc private func showPiWebUpdateWarning(_ sender: Any?) {
        guard let warning = piWebUpdateWarning else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = warning.shortText
        alert.informativeText = warning.text
            + "\n\nPi Web 仍保持更新前的版本；可以手动更新，或修好环境后重试。"
        alert.addButton(withTitle: "好")
        alert.addButton(withTitle: "清除警告")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertSecondButtonReturn else { return }
            self?.clearPiWebUpdateWarning()
        }
    }

    private func clearPiWebUpdateWarning() {
        guard piWebUpdateWarning != nil else { return }
        piWebUpdateWarning = nil
        appConfiguration.savePiWebUpdateWarning(nil)
        refreshUpdateMenuState()
        diagnosticsWindowController?.refreshUpdateStatus()
    }

    /// 启动服务并做健康检查（复用既有启动与探测路径）。回调 true 表示服务可用。
    private func startServiceAndCheckHealthForUpdate(completion: @escaping (Bool) -> Void) {
        DispatchQueue.main.async { [weak self] in
            guard let self else {
                completion(false)
                return
            }
            guard self.dependencyGate == .ready else {
                completion(false)
                return
            }
            self.serviceManager.ensureServerIsRunning()
            self.pollServiceHealth(attemptsRemaining: 25, completion: completion)
        }
    }

    /// 有界的健康检查轮询（25 × 0.5 秒）。超时按“健康检查失败”处理，不无限等待。
    private func pollServiceHealth(attemptsRemaining: Int, completion: @escaping (Bool) -> Void) {
        serviceManager.checkServer { [weak self] ready in
            DispatchQueue.main.async {
                guard let self else {
                    completion(ready)
                    return
                }
                if ready {
                    completion(true)
                    return
                }
                guard attemptsRemaining > 0 else {
                    completion(false)
                    return
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                    self?.pollServiceHealth(attemptsRemaining: attemptsRemaining - 1, completion: completion)
                }
            }
        }
    }

    /// 手动“立即更新 Pi Web…”：必须先确认（说明需要停服），确认后先停服务
    /// （走既有所有权验证的停止路径）再安装。运行期间发现的更新不会自动安装。
    @objc private func updatePiWebNow(_ sender: Any?) {
        guard dependencyGate == .ready, let report = dependencyReport else {
            presentPiWebUpdateInfo("环境检查尚未完成", detail: "请等待依赖诊断完成后再试。")
            return
        }
        let input = piWebUpdatePlanningInput(report: report)
        let decision = PiWebUpdatePlanner.decide(input)
        guard case .automatic(let plan) = decision else {
            presentPiWebUpdateInfo("当前不能立即更新 Pi Web", detail: manualUpdateUnavailableText(decision))
            return
        }
        let alert = NSAlert()
        alert.messageText = "立即更新 Pi Web"
        alert.informativeText = plan.confirmationText(redactingWith: logRedactor)
            + "\n\n更新前会先停止本应用启动的 Pi Web 服务（需要短暂停服）；外部启动的服务不会被停止，"
            + "如果服务仍在运行，更新会被取消。应用不会调用 sudo。"
        alert.addButton(withTitle: "停止服务并更新")
        alert.addButton(withTitle: "取消")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.performManualPiWebUpdate(plan: plan)
        }
    }

    private func performManualPiWebUpdate(plan: PiWebUpdateInstallPlan) {
        logPiWebUpdate("手动立即更新 Pi Web：先停止托管服务，再执行安装（只使用参数数组）。")
        serviceManager.stopService { [weak self] in
            guard let self else { return }
            self.serviceManager.checkServer { [weak self] ready in
                DispatchQueue.main.async {
                    guard let self else { return }
                    guard !ready else {
                        self.presentPiWebUpdateInfo(
                            "已取消更新",
                            detail: "Pi Web 服务仍在响应（可能是外部启动的服务）。"
                                + "为避免在服务运行期间替换文件，已取消本次更新；应用不会停止外部服务。"
                        )
                        return
                    }
                    self.runManualPiWebUpdate(plan: plan)
                }
            }
        }
    }

    private func runManualPiWebUpdate(plan: PiWebUpdateInstallPlan) {
        guard let coordinator = piWebUpdateCoordinator else { return }
        piWebUpdateRedetectionPath = serviceManager.configuration.piWebPath
        let input = piWebUpdatePlanningInput(report: dependencyReport, serviceIsRunning: false)
        showPiWebUpdateProgressPage(plan: plan)
        coordinator.run(input) { [weak self] outcome in
            guard let self else { return }
            switch outcome {
            case .succeeded(_, let oldVersion, let newVersion):
                self.clearPiWebUpdateWarning()
                self.logPiWebUpdate("手动更新完成：\(oldVersion) → \(newVersion)。")
                self.presentPiWebUpdateInfo(
                    "Pi Web 已更新",
                    detail: "已更新到 \(newVersion)，服务健康检查通过。"
                )
            default:
                self.presentPiWebUpdateFailure(outcome)
            }
        }
    }

    /// 更新执行页：在真正执行前展示同一个计划（可执行文件路径已把 Home 段换成
    /// `~`、参数数组逐项、当前/目标版本、来源与可信度、环境变量键名），保证用户
    /// 在安装开始前能看到将要执行什么。
    private func showPiWebUpdateProgressPage(plan: PiWebUpdateInstallPlan) {
        var lines = plan.displayLines(redactingWith: logRedactor)
        lines.append("")
        lines.append("正在执行安装；更新期间请不要退出应用（安装有超时限制）。")
        webViewController.showDependencyPage(
            title: "正在更新 Pi Web",
            message: lines.joined(separator: "\n")
        )
    }

    private func presentPiWebUpdateInfo(_ title: String, detail: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.addButton(withTitle: "好")
        alert.beginSheetModal(for: window)
    }

    private func manualUpdateUnavailableText(_ decision: PiWebUpdateDecision) -> String {
        var text = "原因：\(decision.reason.text)。"
        if let command = decision.commandText {
            text += "\n\n可以手动执行以下命令（应用不会代为执行）：\n\(logRedactor.redact(command))"
        } else {
            text += "\n\n该来源没有适用的静态命令，请按来源文档更新。"
        }
        text += "\n\n自动更新只对已验证的 npm 全局安装生效；应用不承诺所有来源都能回滚。"
        return text
    }

    // MARK: - Window and WebView

    private func preferredWindowFrame(for screen: NSScreen?) -> NSRect {
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 920)
        let isPortrait = visible.height > visible.width

        // 竖屏可用宽度本来就有限，使用完整的 visibleFrame，避免窗口
        // 因为默认尺寸、窗口自动保存尺寸或屏幕旋转后留下的旧 frame 变成
        // 一个看起来“没有全屏”的小窗口。
        if isPortrait {
            return visible
        }

        let desiredWidth = min(1440, max(900, visible.width * 0.86))
        let desiredHeight = min(920, max(620, visible.height * 0.82))
        let width = min(desiredWidth, max(560, visible.width))
        let height = min(desiredHeight, max(560, visible.height))
        return NSRect(
            x: visible.midX - width / 2,
            y: visible.midY - height / 2,
            width: width,
            height: height
        )
    }

    private func fitWindowToCurrentScreen() {
        guard let window, let screen = window.screen ?? NSScreen.main else { return }
        // Native full-screen mode owns the window frame. Do not overwrite it
        // while AppKit is entering or already in a full-screen Space.
        guard !isFullScreenTransition, !window.styleMask.contains(.fullScreen) else { return }
        let visible = screen.visibleFrame
        guard visible.width > 0, visible.height > 0 else { return }

        // 竖屏时必须覆盖整个可用桌面区域。原实现只在窗口过宽时缩小，
        // 而且还额外留了 20pt 边距；如果窗口之前已经较小，就永远不会
        // 被放大回去，因此在旋转显示器或恢复自动保存 frame 后会偶发露出桌面。
        if visible.height > visible.width {
            if window.frame != visible {
                window.setFrame(visible, display: true, animate: false)
            }
            return
        }

        var frame = window.frame
        frame.size.width = min(max(frame.size.width, window.minSize.width), visible.width)
        frame.size.height = min(max(frame.size.height, window.minSize.height), visible.height)
        frame.origin.x = min(max(frame.origin.x, visible.minX), visible.maxX - frame.width)
        frame.origin.y = min(max(frame.origin.y, visible.minY), visible.maxY - frame.height)
        if frame != window.frame {
            window.setFrame(frame, display: true, animate: false)
        }
    }

    private func createWindow() {
        webViewController = WebViewController(
            serviceURL: startURL,
            servicePort: serviceManager.configuration.port,
            windowProvider: { [weak self] in self?.window }
        )
        webViewController.onNavigationFailure = { [weak self] failure in
            guard let self, !self.serviceManager.isQuitting else { return }
            self.serviceManager.setState(.stopped)
            switch failure {
            case .loadFailed(let description):
                self.webViewController.showErrorPage(message: "页面加载失败：\(description)")
            case .connectionFailed(let description):
                self.webViewController.showErrorPage(message: "无法连接 Pi Web：\(description)")
            }
        }

        window = NSWindow(
            contentRect: preferredWindowFrame(for: NSScreen.main),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.delegate = self
        window.title = "Pi Web Desktop"
        window.titlebarAppearsTransparent = false
        // Keep the native green button and the standard Control-Command-F
        // shortcut available on a regular foreground application.
        window.collectionBehavior = [.fullScreenPrimary]
        window.minSize = NSSize(width: 560, height: 560)
        // 使用原生标题栏作为稳定的拖拽区域；网页内容不会被透明拖拽层遮挡。
        window.contentView = webViewController.webView
        window.center()
        window.setFrameAutosaveName("PiWebMainWindow")
        window.makeKeyAndOrderFront(nil)
        fitWindowToCurrentScreen()
        if !NSApp.isActive {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }

    @objc private func showWindow(_ sender: Any?) {
        window.makeKeyAndOrderFront(nil)
        if !NSApp.isActive {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func windowDidChangeScreen(_ notification: Notification) {
        scheduleWindowFit()
    }

    @objc private func toggleFullScreen(_ sender: Any?) {
        window.toggleFullScreen(sender)
    }

    func windowWillEnterFullScreen(_ notification: Notification) {
        isFullScreenTransition = true
        screenFitWorkItem?.cancel()
        screenFitWorkItem = nil
    }

    func windowDidEnterFullScreen(_ notification: Notification) {
        isFullScreenTransition = false
    }

    func windowWillExitFullScreen(_ notification: Notification) {
        isFullScreenTransition = true
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        isFullScreenTransition = false
        // Re-apply the portrait layout only after AppKit has finished leaving
        // the full-screen Space and restored the normal window frame.
        scheduleWindowFit()
    }

    // MARK: - Service manager callbacks

    private func installServiceManagerCallbacks() {
        serviceManager.onStateChange = { [weak self] state in
            self?.applyState(state)
        }
        serviceManager.onLoadPage = { [weak self] in
            guard let self else { return }
            self.webViewController.updateService(
                url: self.serviceManager.configuration.serviceURL,
                port: self.serviceManager.configuration.port
            )
            self.webViewController.loadServicePage()
        }
        serviceManager.onPageMessage = { [weak self] message in
            self?.webViewController.showLoadingPage(message: message)
        }
        serviceManager.onStartupFailure = { [weak self] message in
            self?.presentStartupError(message)
        }
        serviceManager.onRemoteAccessClosed = { [weak self] closed in
            self?.persistClosedRemoteAccessConfiguration(closed)
        }
        // 启动入口在启动前发现工作目录不可用（GitHub #9 复审：健康监控运行期间
        // 自选目录被删除）：进入诊断状态并给出可读修复提示，而不是重建目录。
        serviceManager.onWorkspaceProblem = { [weak self] _, _ in
            // 从启动入口里回来，延到下一个主线程周期再重路由，避开重入。
            DispatchQueue.main.async { self?.presentWorkspaceDiagnostics() }
        }
    }

    /// 工作目录在某个启动入口被判定为不可用时重新路由到诊断状态。
    ///
    /// 目录已经被恢复（例如用户在提示后重新创建）时不进入诊断，回到正常路由：
    /// `applyDependencyReport` 会拿最新的工作目录状态重新决定主窗口/诊断页。
    private func presentWorkspaceDiagnostics() {
        guard !serviceManager.isQuitting else { return }
        // 用 AppDelegate 自己的探针重新校验，保证页面、诊断窗口与门控三处同源。
        refreshWorkspaceState()
        guard let report = dependencyReport else { return }
        applyDependencyReport(report, triggeredByUser: false)
    }

    /// 远程访问被 `ServiceManager` 收敛（密码被删除或读取失败、已停止托管进程）
    /// 后只持久化回落后的 loopback 配置，不自动重启：用户先看到“已停止并回到
    /// loopback”的可读提示，再由自己决定是否启动，敏感状态变化不做静默重启。
    private func persistClosedRemoteAccessConfiguration(_ closed: ServiceConfiguration) {
        appConfiguration.save(closed)
        serviceManager.updateConfiguration(closed)
    }

    private func applyState(_ state: ServiceState) {
        currentState = state
        // The status menu keeps the pre-split base text; the ownership suffix is
        // reserved for the diagnostics copy.
        statusMenuItem?.title = "状态：\(state.displayText)"
    }

    /// Alert shown when the managed service could not start. ServiceManager owns
    /// the state change and the "启动失败" page; the buttons are UI wiring here.
    private func presentStartupError(_ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Pi Web 启动失败"
        alert.informativeText = message
        alert.addButton(withTitle: "重试")
        alert.addButton(withTitle: "打开日志")
        alert.addButton(withTitle: "退出")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            switch response {
            case .alertFirstButtonReturn: self.serviceManager.ensureServerIsRunning()
            case .alertSecondButtonReturn: self.openLog(nil)
            default: self.quitApp(nil)
            }
        }
    }

    @objc private func showPreferences(_ sender: Any?) {
        let controller = PreferencesWindowController(
            configuration: serviceManager.configuration,
            keychain: keychain,
            defaultWorkspaceDirectory: appConfiguration.defaultWorkspaceDirectory.path,
            workspaceProbe: workspaceProbe
        )
        controller.onSave = { [weak self] newConfiguration in
            self?.applyPreferencesConfiguration(newConfiguration, credentialsChanged: false)
        }
        controller.onRemoteAccessCredentialsChanged = { [weak self] newConfiguration in
            self?.applyPreferencesConfiguration(newConfiguration, credentialsChanged: true)
        }
        preferencesWindowController = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        if !NSApp.isActive {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    /// 设置窗口保存后的统一入口。
    ///
    /// `credentialsChanged` 表示 Keychain 中的密码刚被设置或删除：远程模式下
    /// 正在运行的托管服务必须重启，新的 `PI_WEB_PASSWORD`（或没有它）才会进入
    /// 子进程环境。删除密码已经把 hostname 收回 loopback，因此会走普通的重启
    /// 路径。
    private func applyPreferencesConfiguration(_ newConfiguration: ServiceConfiguration, credentialsChanged: Bool) {
        let previous = serviceManager.configuration
        appConfiguration.save(newConfiguration)
        let changed = previous.runtimeSignature != newConfiguration.runtimeSignature
        let needsRestartForCredentials = credentialsChanged && !RemoteAccessPolicy.isLoopbackHostname(newConfiguration.hostname)
        let managed = (changed || needsRestartForCredentials) && serviceManager.managedServicePID() != nil
        // 工作目录门控与菜单可用性读最新配置，但配置要等旧服务停止后才交给
        // ServiceManager（否则停止校验会因端口/参数变化把旧进程误判为外部服务）。
        refreshWorkspaceState(configuration: newConfiguration)
        applyServiceControlAvailability()

        if managed {
            // 先停止旧参数启动的服务，再切换配置，避免旧端口和新端口同时留下实例。
            serviceManager.stopService { [weak self] in
                guard let self else { return }
                self.serviceManager.updateConfiguration(newConfiguration)
                self.serviceManager.reloadAfterConfigurationChange()
            }
        } else {
            serviceManager.updateConfiguration(newConfiguration)
            if changed || needsRestartForCredentials {
                serviceManager.reloadAfterConfigurationChange()
            } else {
                // Re-emit the current state so the status menu title refreshes.
                serviceManager.setState(serviceManager.currentState)
            }
        }
    }


    // MARK: - Actions

    @objc private func startServiceAction(_ sender: Any?) {
        guard dependencyGate == .ready else { return }
        if !appConfiguration.hasCompletedFirstLaunchSetup {
            // 在首次启动诊断页主动启动服务等同于“开始使用 Pi Web”：
            // 记录首次设置完成并走正常主窗口路径（startAtLaunch 会启动服务）。
            completeFirstLaunchSetup()
            return
        }
        serviceManager.startService()
    }

    @objc private func restartServiceAction(_ sender: Any?) {
        guard dependencyGate == .ready else { return }
        if serviceManager.managedServicePID() != nil {
            serviceManager.restartManagedService()
        } else {
            // 外部服务只读：确认后的“重启”只会在端口空闲时启动一个可验证的托管进程；
            // 如果外部服务仍在响应，应用只是继续使用它，不会向它发送信号。
            presentExternalServiceWarning(action: "重启") { [weak self] in
                self?.serviceManager.ensureServerIsRunning()
            }
        }
    }

    @objc private func stopServiceAction(_ sender: Any?) {
        if serviceManager.managedServicePID() != nil {
            serviceManager.stopService()
        } else {
            // 外部服务只读：保留原有警告文案，但确认后 stopService() 找不到可验证的
            // 所有权记录，不会向任何进程发送 TERM/KILL，也不会把状态改成“已停止”。
            presentExternalServiceWarning(action: "停止") { [weak self] in
                self?.serviceManager.stopService()
            }
        }
    }

    /// Warning shown before a stop/restart action that involves a service the
    /// app cannot prove it started. The copy is intentionally unchanged, but
    /// `proceed` may only update state or start a managed process: an external
    /// service never receives a signal.
    private func presentExternalServiceWarning(action: String, proceed: @escaping () -> Void) {
        serviceManager.checkServer { [weak self] ready in
            DispatchQueue.main.async {
                guard let self else { return }
                if !ready {
                    if action == "重启" { self.serviceManager.startManagedService() }
                    else { self.serviceManager.setState(.stopped) }
                    return
                }
                let alert = NSAlert()
                alert.messageText = "这是外部启动的 Pi Web 服务"
                alert.informativeText = "该服务不是由本应用启动的。确定要\(action)它吗？"
                alert.addButton(withTitle: action)
                alert.addButton(withTitle: "取消")
                alert.alertStyle = .warning
                alert.beginSheetModal(for: self.window) { response in
                    if response == .alertFirstButtonReturn { proceed() }
                }
            }
        }
    }

    @objc private func showDiagnosticsAction(_ sender: Any?) {
        if let report = dependencyReport {
            showDiagnostics(
                report: report,
                firstLaunchSetupIncomplete: !appConfiguration.hasCompletedFirstLaunchSetup,
                canContinueToService: report.canStartService && workspaceValidation.isUsable
            )
        } else {
            // 首次检查还没返回：检查结束后无论如何都展示一次结果。
            shouldPresentDiagnostics = true
        }
    }

    @objc private func openInBrowser(_ sender: Any?) { NSWorkspace.shared.open(startURL) }
    @objc private func copyLocalAddress(_ sender: Any?) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(startURL.absoluteString, forType: .string) }
    @objc private func openLog(_ sender: Any?) {
        // 日志父目录可能还不存在（从未启动过服务，或关闭了自动启动）：先补齐目录，
        // 失败时给出可读提示，不静默失败也不崩溃（GitHub #9 复审）。
        if let error = appConfiguration.prepareLogFileForOpening(redactor: logRedactor) {
            presentLogOpenFailure(error)
            return
        }
        NSWorkspace.shared.open(appConfiguration.logURL)
    }

    /// “打开日志文件夹”只确保目录存在，不创建日志文件。
    @objc private func openLogsFolder(_ sender: Any?) {
        if let error = appConfiguration.prepareLogsDirectoryForOpening(redactor: logRedactor) {
            presentLogOpenFailure(error)
            return
        }
        NSWorkspace.shared.open(appConfiguration.logsDirectoryURL)
    }

    /// “打开日志”失败时的可读提示（只用于用户主动点开日志的场景）。
    private func presentLogOpenFailure(_ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "无法打开日志"
        alert.informativeText = message
        alert.addButton(withTitle: "好")
        alert.beginSheetModal(for: window) { _ in }
    }

    // 版本信息只有一个来源：bundle 的 Info.plist（由 Configuration/AppIdentity.xcconfig 生成）。
    // Swift 侧不保存第二套版本常量；读取失败时明确标注为开发构建。
    private var appVersionDescription: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String)?.nilIfEmpty
            ?? "开发构建（Info.plist 缺少 CFBundleShortVersionString）"
    }

    private var appBuildDescription: String {
        (Bundle.main.infoDictionary?["CFBundleVersion"] as? String)?.nilIfEmpty
            ?? "开发构建（Info.plist 缺少 CFBundleVersion）"
    }

    /// 菜单“复制诊断”与诊断窗口共用的导出文本（GitHub #10）。所有字段——包括
    /// 启动环境与 `ps` 命令行——统一交给 `logRedactor` 脱敏。
    private func diagnosticsExportText() -> String {
        let piWebPath = serviceManager.resolvePiWebPath() ?? "未找到"
        let piWebVersion = shell([piWebPath, "--version"])?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "未知"
        let nodeFinding = dependencyReport?.finding(for: .node)
        let nodeVersion = nodeFinding?.version
            ?? shell(["/usr/bin/env", "node", "--version"])?.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? "未知"
        let piWebFinding = dependencyReport?.finding(for: .piWeb)
        let piCLIFinding = dependencyReport?.finding(for: .piCLI)
        let managedPID = serviceManager.managedServicePID()

        // 启动环境只展示应用显式设置的子进程变量；远程密码只以占位符进入展示路径，
        // 真实值不经过诊断代码。脱敏器仍会再检查一遍。
        let hasRemotePassword = RemoteAccessPassword.isSet(in: keychain)
        let launchEnvironment = ServiceLaunchSpecification.environmentDescription(
            ServiceLaunchSpecification.make(
                configuration: serviceManager.configuration,
                piWebPath: piWebPath,
                appConfiguration: appConfiguration,
                baseEnvironment: [:],
                remoteAccessPassword: hasRemotePassword ? LogRedactor.marker : nil
            ).environment
        )

        return DiagnosticsCollector.text(
            for: DiagnosticsInput(
                appVersion: appVersionDescription,
                appBuild: appBuildDescription,
                piWebVersion: piWebVersion,
                piWebVersionConfidence: piWebFinding?.confidence.rawValue ?? "unknown",
                piWebPath: piWebFinding?.path ?? piWebPath,
                piWebPathConfidence: piWebFinding?.confidence.rawValue ?? "unknown",
                piCLIVersion: piCLIFinding?.version ?? "未知",
                piCLIVersionConfidence: piCLIFinding?.confidence.rawValue ?? "unknown",
                nodeVersion: nodeVersion,
                nodeVersionConfidence: nodeFinding?.confidence.rawValue ?? "unknown",
                serviceAddress: startURL.absoluteString,
                port: String(serviceManager.configuration.port),
                status: statusDescription(),
                management: managedPID.map { DiagnosticsManagement.managed(pid: String($0)) } ?? .external,
                listenerPID: processInspector.listenerPIDDescription(port: serviceManager.configuration.port),
                listenerProcess: processInspector.listenerProcessDescription(port: serviceManager.configuration.port),
                managedPID: managedPID.map(String.init) ?? "无（外部服务或未运行）",
                workspaceDirectory: appConfiguration.workspaceDirectory(for: serviceManager.configuration).path,
                configurationDirectory: "~/.pi/agent",
                launchCommand: ([piWebPath] + ServiceLaunchSpecification.arguments(configuration: serviceManager.configuration))
                    .joined(separator: " "),
                launchEnvironment: launchEnvironment,
                logPath: appConfiguration.logURL.path,
                logWriteStatus: serviceManager.logWriter.writeStatusDescription,
                remoteAccessPasswordStatus: RemoteAccessPassword.statusText(
                    isSet: RemoteAccessPassword.isSet(in: keychain)
                ),
                // #16 的组件安装识别结果（已脱敏）直接进入导出文本。
                componentInstallations: dependencyReport?.components ?? []
            ),
            redactor: logRedactor
        )
    }

    /// 复制前先弹脱敏提醒（GitHub #10）：文本已按规则脱敏，但公开粘贴前仍需自查。
    @objc private func copyDiagnostics(_ sender: Any?) {
        DiagnosticsClipboard.copyAfterConfirmation(diagnosticsExportText(), presentingIn: window)
    }

    private func statusDescription() -> String {
        ServiceState.statusText(for: currentState, managedPID: serviceManager.managedServicePID())
    }

    @objc private func reloadPage(_ sender: Any?) { webViewController.reload() }
    @objc private func hardReloadPage(_ sender: Any?) { webViewController.reloadFromOrigin() }
    @objc private func zoomIn(_ sender: Any?) { webViewController.zoomIn() }
    @objc private func zoomOut(_ sender: Any?) { webViewController.zoomOut() }
    @objc private func resetZoom(_ sender: Any?) { webViewController.resetZoom() }

    @objc private func showFindBar(_ sender: Any?) { webViewController.showFindBar(in: window) }

    @objc private func quitKeepingService(_ sender: Any?) {
        guard !serviceManager.isQuitting else { return }
        serviceManager.keepRunningOnQuit()
        // 不调用 stopService，也不删除 service-owner.json，让 pi-web 继续独立运行。
        NSApp.terminate(nil)
    }

    /// ⌘Q：按设置里的“退出行为”退出（默认询问）。两个显式菜单项不受它影响。
    @objc private func quitWithConfiguredBehavior(_ sender: Any?) {
        NSApp.terminate(nil)
    }

    @objc private func quitApp(_ sender: Any?) {
        quitAndStop(sender)
    }

    @objc private func quitAndStop(_ sender: Any?) {
        guard !serviceManager.isQuitting else { return }
        // 只停止通过所有权校验的托管进程组；外部服务在任何退出行为下都不发信号。
        serviceManager.stopManagedServiceOnQuit {
            NSApp.terminate(nil)
        }
    }

    // MARK: - 更新检查（GitHub #17）

    /// 更新检查的生命周期入口：第一次调用启动（立即检查一次并安排周期复查），
    /// 之后的调用只更新本机版本清单。检查只访问白名单内的上游，不安装任何东西。
    private func startUpdateChecking(with inventory: UpdateCheckInventory) {
        guard let updateChecker else { return }
        var inventory = inventory
        if inventory.desktopAppVersion == nil {
            inventory.desktopAppVersion = ApplicationInstallationProbe.current.version
        }
        if updateChecker.isStarted {
            updateChecker.updateInventory(inventory)
        } else {
            updateChecker.start(inventory: inventory)
        }
    }

    /// “服务 → 检查更新…”：忽略 TTL 立即检查，完成后弹出提示。仍然尊重每一类
    /// 的策略（关闭的分类不会因为手动点击而发起请求）。
    @objc private func checkForUpdatesNow(_ sender: Any?) {
        guard let updateChecker else { return }
        pendingManualUpdateCheck = true
        updateCheckInProgress = true
        refreshUpdateMenuState()
        updateChecker.checkNow(triggeredBy: .manual)
    }

    /// 菜单快捷开关：打开 = 该分类的默认策略，关闭 = 关闭。完整策略（每周 /
    /// 询问后更新）在“更新检查偏好设置…”里选择。
    @objc private func toggleUpdateCategory(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let category = UpdateCheckCategory(rawValue: rawValue),
              let updateChecker else { return }
        var preferences = updateChecker.preferences
        preferences.setEnabled(sender.state != .on, for: category)
        applyUpdatePreferences(preferences)
    }

    /// 策略变更的统一入口：写 UserDefaults、让调度器重建计时器、刷新界面。
    private func applyUpdatePreferences(_ preferences: UpdateCheckPreferences) {
        appConfiguration.save(preferences)
        updateChecker?.preferences = preferences
        refreshUpdateMenuState()
        syncUpdateSettingsWindow()
    }

    /// “服务 → 更新检查偏好设置…”：策略、每类状态、忽略版本与 alpha.3 预留位。
    @objc private func showUpdatePreferences(_ sender: Any?) {
        let controller = updateSettingsWindowController ?? UpdateSettingsWindowController()
        controller.onPreferencesChanged = { [weak self] preferences in
            self?.applyUpdatePreferences(preferences)
        }
        controller.onIgnoreCurrentVersion = { [weak self] category in
            self?.ignoreCurrentVersion(of: category) ?? false
        }
        controller.onShowExplanation = { [weak self] in
            self?.showUpdateCheckExplanation(nil)
        }
        updateSettingsWindowController = controller
        syncUpdateSettingsWindow()
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        if !NSApp.isActive {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    /// 把当前设置、每类状态与可忽略版本推给设置窗口（窗口未打开时是空操作）。
    private func syncUpdateSettingsWindow() {
        guard let controller = updateSettingsWindowController,
              let updateChecker else { return }
        controller.update(
            preferences: updateChecker.preferences,
            statuses: statusSnapshot(for: updateChecker),
            ignorableVersions: ignorableVersionCandidates()
        )
    }

    /// 每类组件的状态快照。检查器发布过汇总时用它的（在主线程发布，线程安全）；
    /// 否则用当前设置现算一份“尚未检查”的状态。
    private func statusSnapshot(for updateChecker: UpdateChecker) -> [UpdateCategoryStatus] {
        if !updateChecker.summary.categoryStatuses.isEmpty {
            return updateChecker.summary.categoryStatuses
        }
        return UpdateCategoryStatusBuilder.statuses(
            preferences: updateChecker.preferences,
            intervals: .standard,
            cache: .empty,
            ignoredVersions: ignoredVersions
        )
    }

    /// 当前可以被“忽略”的版本：可更新、有上游版本、且尚未被忽略。
    private func ignorableVersionCandidates() -> [UpdateCheckCategory: String] {
        guard let updateChecker else { return [:] }
        var candidates: [UpdateCheckCategory: String] = [:]
        for status in statusSnapshot(for: updateChecker) where status.status == .updateAvailable {
            guard let latest = status.latestVersion, status.ignoredVersion != latest else { continue }
            candidates[status.category] = latest
        }
        return candidates
    }

    /// 记录“忽略某个版本”：只写版本字符串与时间戳，不锁定版本也不降级。
    @discardableResult
    private func ignoreCurrentVersion(of category: UpdateCheckCategory) -> Bool {
        guard let version = ignorableVersionCandidates()[category] else { return false }
        ignoredVersions.ignore(version, for: category, at: Date())
        appConfiguration.save(ignoredVersions)
        updateChecker?.ignoredVersions = ignoredVersions
        notifiedVersions[category] = version
        refreshUpdateMenuState()
        syncUpdateSettingsWindow()
        diagnosticsWindowController?.refreshUpdateStatus()
        return true
    }

    @objc private func showUpdateCheckExplanation(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = "关于更新检查"
        alert.informativeText = UpdateCheckDisclosure.text(
            cachePath: logRedactor.redact(appConfiguration.paths.updateCheckCacheURL.path)
        )
        alert.addButton(withTitle: "好")
        alert.beginSheetModal(for: window)
    }

    /// “更新检查设置”子菜单：状态行 + 四类快捷开关 + 偏好设置与说明。菜单打开
    /// 时由 `menuNeedsUpdate` 刷新。
    private func makeUpdateSettingsMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "更新检查设置", action: nil, keyEquivalent: "")
        let menu = NSMenu(title: "更新检查设置")
        menu.delegate = self
        menu.autoenablesItems = false
        let status = NSMenuItem(title: updateCheckStatusText(), action: nil, keyEquivalent: "")
        status.isEnabled = false
        updateStatusMenuItem = status
        menu.addItem(status)
        // 持久告警项：有告警时常显并可点开（无告警时隐藏）。
        let warningItem = NSMenuItem(
            title: "",
            action: #selector(showPiWebUpdateWarning(_:)),
            keyEquivalent: ""
        )
        warningItem.target = self
        warningItem.isHidden = true
        piWebUpdateWarningMenuItem = warningItem
        menu.addItem(warningItem)
        menu.addItem(.separator())
        for category in UpdateCheckCategory.allCases {
            let toggle = NSMenuItem(
                title: category.displayName,
                action: #selector(toggleUpdateCategory(_:)),
                keyEquivalent: ""
            )
            toggle.target = self
            toggle.representedObject = category.rawValue
            toggle.state = (updateChecker?.preferences.isEnabled(category) ?? true) ? .on : .off
            updateCategoryMenuItems[category] = toggle
            menu.addItem(toggle)
        }
        menu.addItem(.separator())
        let preferencesItem = NSMenuItem(
            title: "更新检查偏好设置…",
            action: #selector(showUpdatePreferences(_:)),
            keyEquivalent: ""
        )
        preferencesItem.target = self
        menu.addItem(preferencesItem)
        // 手动“立即更新”：运行期间发现的更新不会自动安装，只能在这里显式确认后执行。
        let manualUpdateItem = NSMenuItem(
            title: "立即更新 Pi Web…",
            action: #selector(updatePiWebNow(_:)),
            keyEquivalent: ""
        )
        manualUpdateItem.target = self
        piWebUpdateMenuItem = manualUpdateItem
        menu.addItem(manualUpdateItem)
        menu.addItem(withTitle: "更新检查说明…", action: #selector(showUpdateCheckExplanation(_:)), keyEquivalent: "")
        item.submenu = menu
        updateSettingsMenu = menu
        return item
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === updateSettingsMenu else { return }
        refreshUpdateMenuState()
    }

    private func refreshUpdateMenuState() {
        updateStatusMenuItem?.title = updateCheckStatusText()
        if let piWebUpdateWarningMenuItem {
            piWebUpdateWarningMenuItem.title = piWebUpdateWarning?.shortText ?? ""
            piWebUpdateWarningMenuItem.isHidden = piWebUpdateWarning == nil
        }
        piWebUpdateMenuItem?.isEnabled = dependencyGate == .ready
        let preferences = updateChecker?.preferences ?? .factoryDefaults
        for (category, item) in updateCategoryMenuItems {
            item.state = preferences.isEnabled(category) ? .on : .off
            // 菜单里同时显示当前策略，避免把快捷开关误当成完整设置。
            item.title = "\(category.displayName)：\(preferences.policy(for: category).title)"
        }
    }

    private func updateCheckStatusText() -> String {
        guard let updateChecker else { return "更新检查：不可用" }
        if updateCheckInProgress { return "更新检查：正在检查…" }
        return updateChecker.summary.statusLine
    }

    /// 诊断页里的更新检查状态块（已脱敏：只有策略、时间、结果与版本）。
    private func updateCheckStatusBlockText() -> String {
        guard let updateChecker else { return "" }
        var lines = UpdateStatusPresenter.lines(
            statuses: statusSnapshot(for: updateChecker),
            preferences: updateChecker.preferences,
            format: { Self.updateTimestampFormatter.string(from: $0) }
        )
        if let warning = piWebUpdateWarning {
            lines.append("")
            lines.append(warning.text)
        }
        return lines.joined(separator: "\n")
    }

    /// 检查结果落地（主线程）：刷新菜单与窗口；手动检查弹完整结果，自动检查按
    /// 策略与忽略版本决定是否提示。
    private func handleUpdateCheckResults(_ summary: UpdateCheckSummary) {
        updateCheckInProgress = false
        refreshUpdateMenuState()
        syncUpdateSettingsWindow()
        diagnosticsWindowController?.refreshUpdateStatus()
        guard pendingManualUpdateCheck else {
            notifyAboutAutomaticUpdates(summary)
            return
        }
        pendingManualUpdateCheck = false
        presentUpdateCheckResults(summary)
    }

    /// 自动检查（启动 / 周期）的通知：尊重策略与忽略版本，同一个版本在一次
    /// 运行里最多提示一次。提示内容是固定文案 + 组件名 + 版本，不含路径或凭据。
    private func notifyAboutAutomaticUpdates(_ summary: UpdateCheckSummary) {
        // 启动前更新进行中时不弹同版本的“可用更新”提示：安装流程会给出结果。
        guard let updateChecker, !preLaunchUpdateInProgress else { return }
        let entries = UpdateNotificationPlanner.plan(
            results: summary.results,
            preferences: updateChecker.preferences,
            ignoredVersions: ignoredVersions,
            alreadyNotified: notifiedVersions
        )
        guard !entries.isEmpty else { return }
        for entry in entries {
            notifiedVersions[entry.category] = entry.latestVersion
        }
        // 运行期间发现 Pi Web 更新时，如果启动前自动更新已开启，只会安排到下次
        // 启动安装（本次运行不安装）。
        var deferred: Set<UpdateCheckCategory> = []
        if updateChecker.preferences.autoUpdatePiWebBeforeLaunch,
           entries.contains(where: { $0.category == .piWeb }) {
            deferred.insert(.piWeb)
        }
        presentUpdateNotifications(entries, autoInstallDeferredToNextLaunch: deferred)
    }

    /// 多个分类共用一个提示框：除了“好”，每个条目一个“忽略 <版本>”按钮。
    /// 提示框不执行任何安装，按钮只记录忽略版本。
    private func presentUpdateNotifications(
        _ entries: [UpdateNotificationEntry],
        autoInstallDeferredToNextLaunch: Set<UpdateCheckCategory> = []
    ) {
        let alert = NSAlert()
        alert.messageText = UpdateNotificationText.title(for: entries)
        alert.informativeText = UpdateNotificationText.body(
            for: entries,
            autoInstallDeferredToNextLaunch: autoInstallDeferredToNextLaunch
        )
        alert.addButton(withTitle: "好")
        for entry in entries {
            alert.addButton(withTitle: "忽略 \(entry.latestVersion)")
        }
        alert.beginSheetModal(for: window) { [weak self] response in
            // 第一个按钮是“好”，其后的每个按钮对应一个条目。
            let index = response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue - 1
            guard index >= 0, entries.indices.contains(index) else { return }
            _ = self?.ignoreCurrentVersion(of: entries[index].category)
        }
    }

    /// 提示全文来自 `UpdateCheckSummary.detailText`；这里只定标题。
    private func presentUpdateCheckResults(_ summary: UpdateCheckSummary) {
        let alert = NSAlert()
        if summary.allDisabled {
            alert.messageText = "更新检查已全部关闭"
        } else if summary.updateAvailableCount > 0 {
            alert.messageText = "发现 \(summary.updateAvailableCount) 项可用更新"
        } else if summary.unknownCount > 0 {
            alert.messageText = "更新检查未全部完成"
        } else {
            alert.messageText = "全部已是最新"
        }
        alert.informativeText = summary.detailText
        alert.addButton(withTitle: "好")
        alert.beginSheetModal(for: window)
    }

    // MARK: - Error and utility

    @discardableResult private func shell(_ arguments: [String]) -> String? {
        commandRunner.run(arguments)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        let controls = ServiceControlState(gate: dependencyGate, workspaceIsReady: workspaceValidation.isUsable)
        switch menuItem.action {
        case #selector(startServiceAction(_:)):
            return controls.canStart && serviceManager.managedServicePID() == nil
        case #selector(stopServiceAction(_:)): return controls.canStop
        case #selector(restartServiceAction(_:)): return controls.canRestart
        case #selector(toggleFullScreen(_:)):
            menuItem.title = window.styleMask.contains(.fullScreen) ? "退出全屏幕" : "进入全屏幕"
            return true
        default: return true
        }
    }
}
