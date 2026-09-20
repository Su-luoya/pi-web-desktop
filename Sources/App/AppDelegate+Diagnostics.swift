/// Dependency diagnostics gate shown before the workspace loads.

import Cocoa

extension AppDelegate {
    // MARK: - 依赖诊断门控

    /// 工作目录校验（GitHub #9）：默认目录首次使用时创建，自选目录必须已存在
    /// 且可写。结果同时写入 `ServiceManager` 门控（阻止启动）与路由输入。
    @discardableResult
    func refreshWorkspaceState(
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

    /// 启动时与“重新检测”共用的环境检查。命令探针是同步阻塞调用（现在有超时
    /// 上限，超时按不可用处理并写进诊断项的“原因”），因此整份检查走
    /// `CommandProbeDispatch`：后台执行、结果回到主队列再决定路由与门控。
    /// 检查期间服务控件保持禁用。
    func runDependencyCheck(triggeredByUser: Bool = false) {
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
            applicationInstallation: .current,
            // 与启动环境、更新子进程共用同一个工具 PATH（GitHub #89）。
            toolPathProvider: toolPathProvider
        )
        CommandProbeDispatch.runOffMain(work: { checker.run() }) { [weak self] report in
            guard let self, generation == self.dependencyCheckGeneration else { return }
            self.applyDependencyReport(report, triggeredByUser: triggeredByUser)
        }
    }

    /// 命令探测失败原因进日志（GitHub #89）：只写已脱敏的报告字段，文本里只有
    /// 工具名与静态说明，不含 Home 路径、凭据或 URL。没有原因时不写任何东西。
    private func logDependencyDiagnoses(_ report: DependencyReport) {
        for finding in report.findings {
            guard let diagnosis = finding.detail, !diagnosis.isEmpty else { continue }
            _ = logWriter.append(logRedactor.redact(
                "依赖诊断：\(DependencyReportPresenter.title(for: finding.kind)) \(diagnosis)"
            ))
        }
    }

    /// 显式更新菜单项的启用状态。三个服务控件的门控相同（只有 `.ready` 时可用），
    /// 所以用同一个映射值；停止项也受门控约束（GitHub #7）。
    func applyServiceControlAvailability() {
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
    func applyDependencyReport(
        _ report: DependencyReport,
        triggeredByUser: Bool,
        firstLaunchSetupJustCompleted: Bool = false
    ) {
        dependencyReport = report
        // 命令探测失败的原因（GitHub #89）进日志：不再只留一个 `.unknown`。
        logDependencyDiagnoses(report)
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

    func showDiagnostics(report: DependencyReport, firstLaunchSetupIncomplete: Bool, canContinueToService: Bool) {
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
            controller.onSelectPiWebPath = { [weak self] path in
                self?.applySelectedPiWebPath(path)
                return nil
            }
            controller.onUpdatePiCLI = { [weak self] in self?.updatePiCLINow(nil) }
            // 与菜单“复制诊断”完全同一条导出路径（W4 M3：提醒 → 后台采集 → 复制）。
            controller.onExportDiagnostics = { [weak self] in
                guard let self else { return }
                self.beginDiagnosticsExport(presentingIn: self.diagnosticsWindowController?.window)
            }
            // 更新检查状态（GitHub #18）：诊断页只渲染同一份状态快照。
            controller.updateStatusTextProvider = { [weak self] in self?.updateCheckStatusBlockText() ?? "" }
            diagnosticsWindowController = controller
            controller.showWindow(nil)
        }
        // 诊断页每次都刷新一次 Pi 进程检查（只读枚举；smoke 启动不枚举）。
        if !appConfiguration.isSmokeLaunch {
            refreshPiProcessInspection()
            diagnosticsWindowController?.refreshUpdateStatus()
        }
        if !NSApp.isActive {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    /// 用户选择的 pi-web 路径：校验失败（不可执行或无法确认是 pi-web）时显示可读
    /// 错误且不碰配置；成功时经 `AppConfiguration` 写回 `ServiceConfiguration.piWebPath`，
    /// 随即重新检测。身份证据只来自只读的 `--version` 与 package.json `name`。
    ///
    /// 校验会执行 `--version`（同步阻塞、有超时上限），因此不在主线程做：
    /// 后台队列校验，主队列写配置与提示（与依赖检查同一条线程约定）。
    /// 参数探测失败时保留原配置，提示的可读文案与原同步实现一致。
    /// 校验用的 `DependencyChecker` 与其它探测共用同一个 `toolPathProvider`
    /// （GitHub #89）：`pi-web` 同样是 `#!/usr/bin/env node` 脚本，没有合并后的
    /// 工具 PATH 时 `--version` 会以 127 退出。
    private func applySelectedPiWebPath(_ path: String) {
        let configuration = serviceManager.configuration
        let checker = DependencyChecker(commandRunner: commandRunner, toolPathProvider: toolPathProvider)
        CommandProbeDispatch.runOffMain(work: {
            PiWebPathSelection.apply(
                selectedPath: path,
                configuration: configuration,
                evidence: { checker.piWebIdentityEvidence(atPath: $0) }
            )
        }) { [weak self] result in
            guard let self else { return }
            guard let error = result.error else {
                let updated = result.configuration
                self.appConfiguration.save(updated)
                self.serviceManager.updateConfiguration(updated)
                self.runDependencyCheck(triggeredByUser: true)
                return
            }
            self.presentPiWebPathSelectionError(error)
        }
    }

    /// 异步路径校验失败时的可读提示（配置保持原样）。
    private func presentPiWebPathSelectionError(_ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "无法使用所选的 pi-web 路径"
        alert.informativeText = message
        alert.addButton(withTitle: "好")
        alert.beginSheetModal(for: window)
    }

    /// 首次设置完成：记录状态后用最近一次报告重新走路由，随即进入主窗口。
    /// 这条路径标记“本次调用刚刚完成设置”，因此主窗口会显式启动服务。
    func completeFirstLaunchSetup() {
        guard let report = dependencyReport,
              DiagnosticsRouting.completesFirstLaunchSetup(report: report),
              workspaceValidation.isUsable,
              !appConfiguration.hasCompletedFirstLaunchSetup else { return }
        appConfiguration.markFirstLaunchSetupCompleted()
        applyDependencyReport(report, triggeredByUser: false, firstLaunchSetupJustCompleted: true)
    }
}
