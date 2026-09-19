import Cocoa

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
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

    private let appConfiguration: AppConfiguration
    private let commandRunner: CommandRunning
    private let processInspector: ProcessInspector
    private let serviceManager: ServiceManager
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
        workspaceProbe: WorkspaceDirectoryProbe = .live()
    ) {
        self.appConfiguration = appConfiguration
        self.commandRunner = commandRunner
        self.keychain = keychain
        self.workspaceProbe = workspaceProbe
        let processInspector = ProcessInspector(runner: commandRunner)
        self.processInspector = processInspector
        self.serviceManager = ServiceManager(
            configuration: appConfiguration.serviceConfiguration,
            appConfiguration: appConfiguration,
            processInspector: processInspector,
            commandRunner: commandRunner,
            // 远程模式的门控与环境变量都读这一个闭包：读取失败即“无密码”。
            remoteAccessPassword: { RemoteAccessPassword.load(from: keychain) }
        )
        super.init()
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
        serviceMenu.addItem(withTitle: "复制诊断信息", action: #selector(copyDiagnostics(_:)), keyEquivalent: "")
        serviceMenu.addItem(withTitle: "依赖与环境诊断…", action: #selector(showDiagnosticsAction(_:)), keyEquivalent: "")
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
            servicePort: configuration.port
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
            serviceManager.setState(.checking)
            webViewController.showLoadingPage(message: "正在检查 Pi Web 服务…")
            // 首次设置刚完成时必须显式启动，正常启动仍尊重 autoStart（GitHub #7 复审）。
            let launchIntent = ServiceLaunchIntent.intent(firstLaunchSetupJustCompleted: justCompletedSetup)
            serviceManager.startAtLaunch(forceStart: launchIntent.forcesStart)
            if presentDiagnostics {
                showDiagnostics(
                    report: report,
                    firstLaunchSetupIncomplete: firstLaunchSetupIncomplete,
                    canContinueToService: report.canStartService && workspaceValidation.isUsable
                )
            }
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
        if let error = appConfiguration.prepareLogFileForOpening() {
            presentLogOpenFailure(error)
            return
        }
        NSWorkspace.shared.open(appConfiguration.logURL)
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
        let info = Bundle.main.infoDictionary
        guard let shortVersion = (info?["CFBundleShortVersionString"] as? String)?.nilIfEmpty,
              let buildVersion = (info?["CFBundleVersion"] as? String)?.nilIfEmpty else {
            return "开发构建（Info.plist 缺少 CFBundleShortVersionString 或 CFBundleVersion）"
        }
        return "\(shortVersion) (\(buildVersion))"
    }

    @objc private func copyDiagnostics(_ sender: Any?) {
        let piWebPath = serviceManager.resolvePiWebPath() ?? "未找到"
        let piWebVersion = shell([piWebPath, "--version"])?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "未知"
        let nodeVersion = shell(["/usr/bin/env", "node", "--version"])?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "未知"
        let diagnostics = DiagnosticsCollector.text(for: DiagnosticsInput(
            appVersion: appVersionDescription,
            piWebVersion: piWebVersion,
            nodeVersion: nodeVersion,
            serviceAddress: startURL.absoluteString,
            status: statusDescription(),
            listenerPID: processInspector.listenerPIDDescription(port: serviceManager.configuration.port),
            listenerProcess: processInspector.listenerProcessDescription(port: serviceManager.configuration.port),
            managedPID: serviceManager.managedServicePID().map(String.init) ?? "无（外部服务或未运行）",
            piWebPath: piWebPath,
            configurationDirectory: "~/.pi/agent",
            logPath: appConfiguration.logURL.path,
            remoteAccessPasswordStatus: RemoteAccessPassword.statusText(
                isSet: RemoteAccessPassword.isSet(in: keychain)
            )
        ))
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(diagnostics, forType: .string)
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
