/// Main menu construction and the menu/toolbar actions it exposes.

import Cocoa

extension AppDelegate {
    // MARK: - Menus

    func installMainMenu() {
        serviceControlMenuItems.removeAll()
        phoneAccessMenus.removeAll()
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
        let appPhoneAccessItem = NSMenuItem(title: "复制手机访问链接", action: nil, keyEquivalent: "")
        appPhoneAccessItem.submenu = makePhoneAccessMenu()
        appMenu.addItem(appPhoneAccessItem)
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
        let recentWorkspacesItem = NSMenuItem(title: "最近工作目录", action: nil, keyEquivalent: "")
        let recentWorkspacesMenu = NSMenu(title: "最近工作目录")
        recentWorkspacesMenu.delegate = self
        recentWorkspacesItem.submenu = recentWorkspacesMenu
        self.recentWorkspacesMenu = recentWorkspacesMenu
        serviceMenu.addItem(recentWorkspacesItem)
        serviceMenu.addItem(withTitle: "在 Finder 中打开当前工作目录", action: #selector(openCurrentWorkspace(_:)), keyEquivalent: "")
        serviceMenu.addItem(withTitle: "在浏览器中打开", action: #selector(openInBrowser(_:)), keyEquivalent: "")
        serviceMenu.addItem(withTitle: "复制本地地址", action: #selector(copyLocalAddress(_:)), keyEquivalent: "")
        let servicePhoneAccessItem = NSMenuItem(title: "复制手机访问链接", action: nil, keyEquivalent: "")
        servicePhoneAccessItem.submenu = makePhoneAccessMenu()
        serviceMenu.addItem(servicePhoneAccessItem)
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

    func menuWillOpen(_ menu: NSMenu) {
        if menu === recentWorkspacesMenu {
            rebuildRecentWorkspacesMenu()
        } else if phoneAccessMenus.contains(where: { $0 === menu }) {
            rebuildPhoneAccessMenu(menu)
        }
    }

    /// 依赖门控禁用的服务控件菜单项（启动/停止/重启）；菜单打开时由
    /// `validateMenuItem` 再次确认。两处都读取同一个 `ServiceControlState` 映射。
    private func makeServiceControlMenuItem(title: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        serviceControlMenuItems.append(item)
        return item
    }


    // MARK: - Actions

    /// Finder 拖放、`open -a` 与菜单选择共用同一套校验和确认流程。
    func requestWorkspaceSwitch(to url: URL) {
        let currentPath = appConfiguration.workspaceDirectory(for: serviceManager.configuration).path
        switch WorkspaceSwitchDecision.decide(
            requestedPath: url.path,
            currentPath: currentPath,
            probe: workspaceProbe
        ) {
        case .unchanged:
            recordWorkspace(path: currentPath)
        case .reject(let validation):
            presentWorkspaceSwitchFailure(validation)
        case .confirm(let path):
            let managed = serviceManager.managedServicePID() != nil
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "切换工作目录？"
            alert.informativeText = managed
                ? "将工作目录切换到：\n\(path)\n\n当前服务由应用管理并正在运行，确认后将重启服务。"
                : "将工作目录切换到：\n\(path)"
            alert.addButton(withTitle: managed ? "切换并重启" : "切换")
            alert.addButton(withTitle: "取消")
            presentWorkspaceAlert(alert) { [weak self] response in
                guard response == .alertFirstButtonReturn else { return }
                self?.applyWorkspaceSwitch(path: path)
            }
        }
    }

    private func presentWorkspaceAlert(_ alert: NSAlert, completion: @escaping (NSApplication.ModalResponse) -> Void) {
        if let window, window.isVisible {
            alert.beginSheetModal(for: window, completionHandler: completion)
        } else {
            completion(alert.runModal())
        }
    }

    private func presentWorkspaceSwitchFailure(_ validation: WorkspaceDirectoryValidation) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "无法切换工作目录"
        alert.informativeText = validation.problem?.message(path: validation.path, isDefaultLocation: false)
            ?? "请选择一个已存在且可写的文件夹。"
        alert.addButton(withTitle: "好")
        presentWorkspaceAlert(alert) { _ in }
    }

    private func applyWorkspaceSwitch(path: String) {
        var configuration = serviceManager.configuration
        configuration.workspacePath = path
        applyPreferencesConfiguration(configuration, credentialsChanged: false)
    }

    func recordCurrentWorkspace() {
        recordWorkspace(path: appConfiguration.workspaceDirectory(for: serviceManager.configuration).path)
    }

    func recordWorkspace(path: String) {
        _ = appConfiguration.recentWorkspaceStore.record(path: path)
        rebuildRecentWorkspacesMenu()
    }

    func rebuildRecentWorkspacesMenu() {
        guard let menu = recentWorkspacesMenu else { return }
        menu.removeAllItems()
        let currentPath = RecentWorkspaceStore.normalizedPath(
            appConfiguration.workspaceDirectory(for: serviceManager.configuration).path
        )
        let paths = appConfiguration.recentWorkspaceStore.load()
        if paths.isEmpty {
            let empty = NSMenuItem(title: "无最近工作目录", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        } else {
            for path in paths {
                let item = NSMenuItem(title: path, action: #selector(selectRecentWorkspace(_:)), keyEquivalent: "")
                item.representedObject = path
                item.state = path == currentPath ? .on : .off
                menu.addItem(item)
            }
        }
        menu.addItem(.separator())
        let clear = NSMenuItem(title: "清除历史记录", action: #selector(clearRecentWorkspaces(_:)), keyEquivalent: "")
        clear.isEnabled = !paths.isEmpty
        menu.addItem(clear)
    }

    @objc private func selectRecentWorkspace(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        requestWorkspaceSwitch(to: URL(fileURLWithPath: path, isDirectory: true))
    }

    @objc private func clearRecentWorkspaces(_ sender: Any?) {
        appConfiguration.recentWorkspaceStore.clear()
        rebuildRecentWorkspacesMenu()
    }

    @objc private func openCurrentWorkspace(_ sender: Any?) {
        let directory = appConfiguration.workspaceDirectory(for: serviceManager.configuration)
        let validation = WorkspaceDirectory.validate(path: directory.path, probe: workspaceProbe)
        guard validation.isUsable else {
            presentWorkspaceSwitchFailure(validation)
            return
        }
        NSWorkspace.shared.open(directory)
    }

    @objc func startServiceAction(_ sender: Any?) {
        guard dependencyGate == .ready else { return }
        if !appConfiguration.hasCompletedFirstLaunchSetup {
            // 在首次启动诊断页主动启动服务等同于“开始使用 Pi Web”：
            // 记录首次设置完成并走正常主窗口路径（startAtLaunch 会启动服务）。
            completeFirstLaunchSetup()
            return
        }
        serviceManager.startService()
    }

    @objc func restartServiceAction(_ sender: Any?) {
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

    @objc func stopServiceAction(_ sender: Any?) {
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

    // MARK: - 复制手机访问链接（GitHub #150）

    /// 「复制手机访问链接」候选子菜单：与 `recentWorkspacesMenu` 同一写法（delegate +
    /// 打开时重建）。候选地址只出现在菜单项里，不写日志与诊断导出。
    private func makePhoneAccessMenu() -> NSMenu {
        let menu = NSMenu(title: "复制手机访问链接")
        menu.delegate = self
        phoneAccessMenus.append(menu)
        return menu
    }

    /// 菜单打开时按当前网络地址重建候选项；无可用地址时只留一条禁用的说明项。
    func rebuildPhoneAccessMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        for entry in PhoneAccessMenuBuilder.entries(for: networkAddressProvider.ipv4Addresses()) {
            let item = NSMenuItem(
                title: entry.title,
                action: entry.address == nil ? nil : #selector(copyPhoneAccessLink(_:)),
                keyEquivalent: ""
            )
            item.representedObject = entry.address.map { ServiceAddressBox($0) }
            item.isEnabled = entry.isEnabled
            menu.addItem(item)
        }
    }

    /// 候选动作：判定是纯函数（`ServiceAddressDecision`），交互层只做呈现。
    ///
    /// - 已经是当前监听地址：直接复制链接，不改配置；
    /// - 没有可用密码：用共用文案引导到「设置… → 远程访问」，不静默改配置、
    ///   不启动远程监听；
    /// - 其他情况：先确认（会切换监听地址并重启，当前会话中断），确认后按
    ///   设置窗口同一保存语义保存配置并重启，成功后才复制链接。
    @objc private func copyPhoneAccessLink(_ sender: NSMenuItem) {
        guard let address = (sender.representedObject as? ServiceAddressBox)?.address else { return }
        let configuration = serviceManager.configuration
        let hasPassword = RemoteAccessPassword.load(from: keychain) != nil
        switch ServiceAddressDecision.decide(
            currentHostname: configuration.hostname,
            selected: address,
            hasPassword: hasPassword
        ) {
        case .copyOnly:
            copyPhoneAccessLink(for: address, port: configuration.port)
        case .needsPassword:
            presentPhoneAccessPasswordRequired()
        case .needsConfirmation:
            confirmPhoneAccessSwitch(to: address)
        }
    }

    /// 复制链接：用选中地址与当前端口新构造 URL，不改 `startURL` 语义。
    private func copyPhoneAccessLink(for address: ServiceAddress, port: Int) {
        guard let url = ServiceAddressLink.url(forIPv4: address.ipv4, port: port) else {
            presentPhoneAccessFailure("无法生成访问链接：地址 \(address.ipv4) 或端口 \(port) 无效。")
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
    }

    /// 没有密码时的引导：只提示下一步，不写配置、不切监听地址。
    private func presentPhoneAccessPasswordRequired() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "需要先设置访问密码"
        alert.informativeText = "\(RemoteAccessPolicy.missingPasswordMessage)\n\n监听地址保持不变。"
        alert.addButton(withTitle: "打开设置…")
        alert.addButton(withTitle: "取消")
        presentPhoneAccessAlert(alert) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.showPreferences(nil)
        }
    }

    /// 切换监听地址前的确认：说明会重启服务、当前会话中断。
    private func confirmPhoneAccessSwitch(to address: ServiceAddress) {
        let configuration = serviceManager.configuration
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "切换到 \(address.title)？"
        alert.informativeText = "复制链接会把服务监听地址从 \(configuration.hostname) 切换到 \(address.ipv4)，并重启服务；当前会话会中断。"
        alert.addButton(withTitle: "切换并复制链接")
        alert.addButton(withTitle: "取消")
        presentPhoneAccessAlert(alert) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.switchPhoneAccessListening(to: address)
        }
    }

    /// 确认后的切换：与设置窗口同一条保存路径（`RemoteAccessSetup.apply` 校验
    /// hostname 并沿用 Keychain 里已有的密码）；配置未保存时不复制链接，也不启动
    /// 远程监听。配置生效且重启路径结束（`applyPreferencesConfiguration` 的
    /// completion）后才复制链接。
    private func switchPhoneAccessListening(to address: ServiceAddress) {
        var requested = serviceManager.configuration
        requested.hostname = address.ipv4
        let outcome = RemoteAccessSetup.apply(requested: requested, newPassword: nil, keychain: keychain)
        guard let newConfiguration = outcome.configuration else {
            presentPhoneAccessFailure(outcome.error ?? "设置未保存。")
            return
        }
        applyPreferencesConfiguration(newConfiguration, credentialsChanged: false) { [weak self] in
            self?.copyPhoneAccessLink(for: address, port: newConfiguration.port)
        }
    }

    private func presentPhoneAccessFailure(_ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "无法复制手机访问链接"
        alert.informativeText = message
        alert.addButton(withTitle: "好")
        presentPhoneAccessAlert(alert) { _ in }
    }

    private func presentPhoneAccessAlert(_ alert: NSAlert, completion: @escaping (NSApplication.ModalResponse) -> Void) {
        if let window, window.isVisible {
            alert.beginSheetModal(for: window, completionHandler: completion)
        } else {
            completion(alert.runModal())
        }
    }
    @objc func openLog(_ sender: Any?) {
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

    /// 导出用的主线程快照：只读取已经在内存里的状态（配置、依赖报告、Keychain
    /// 结论、进程记录），**不执行任何子进程**。子进程探测交给
    /// `diagnosticsProbeCollector` 在后台串行队列上做（W4 M3）。
    private struct DiagnosticsExportSnapshot {
        var piWebPath: String
        var piWebFinding: DependencyFinding?
        var piCLIFinding: DependencyFinding?
        var nodeFinding: DependencyFinding?
        var managedPID: pid_t?
        var port: Int
        var serviceAddress: String
        var status: String
        var workspaceDirectory: String
        var launchCommand: String
        var launchEnvironment: String
        var logPath: String
        var logWriteStatus: String
        var remoteAccessPasswordStatus: String
        var componentInstallations: [ComponentInstallation]
    }

    /// 在主线程捕获一次导出快照；不发起任何子进程，也不阻塞。
    private func diagnosticsExportSnapshot() -> DiagnosticsExportSnapshot {
        let piWebPath = serviceManager.resolvePiWebPath() ?? "未找到"
        // 启动环境只展示应用显式设置的子进程变量；远程密码只以占位符进入展示路径，
        // 真实值不经过诊断代码。脱敏器仍会再检查一遍。
        let hasRemotePassword = RemoteAccessPassword.isSet(in: keychain)
        let launchEnvironment = ServiceLaunchSpecification.environmentDescription(
            ServiceLaunchSpecification.make(
                configuration: serviceManager.configuration,
                piWebPath: piWebPath,
                appConfiguration: appConfiguration,
                baseEnvironment: [:],
                remoteAccessPassword: hasRemotePassword ? LogRedactor.marker : nil,
                // 展示的启动环境与真实启动用同一个 PATH 构建器（GitHub #89）。
                toolPathProvider: toolPathProvider
            ).environment
        )
        return DiagnosticsExportSnapshot(
            piWebPath: piWebPath,
            piWebFinding: dependencyReport?.finding(for: .piWeb),
            piCLIFinding: dependencyReport?.finding(for: .piCLI),
            nodeFinding: dependencyReport?.finding(for: .node),
            managedPID: serviceManager.managedServicePID(),
            port: serviceManager.configuration.port,
            serviceAddress: startURL.absoluteString,
            status: statusDescription(),
            workspaceDirectory: appConfiguration.workspaceDirectory(for: serviceManager.configuration).path,
            launchCommand: ([piWebPath] + ServiceLaunchSpecification.arguments(configuration: serviceManager.configuration))
                .joined(separator: " "),
            launchEnvironment: launchEnvironment,
            logPath: appConfiguration.logURL.path,
            logWriteStatus: serviceManager.logWriter.writeStatusDescription,
            remoteAccessPasswordStatus: RemoteAccessPassword.statusText(isSet: hasRemotePassword),
            // #16 的组件安装识别结果（已脱敏）直接进入导出文本。
            componentInstallations: dependencyReport?.components ?? []
        )
    }

    /// 组装导出文本：纯文本工作，不执行命令、不读磁盘（W4 M3）。
    ///
    /// 探测缺失（超时/失败）统一标注成 `DiagnosticsProbeText.failure`；仅当实时
    /// 探测没值时，才回退到依赖报告里的缓存版本（否则报告里的旧版本会盖掉
    /// “这次没读到”的事实）。外部监听进程命令行已经由探测器按更新路径的同一套
    /// 遮罩处理过，这里再交给 `LogRedactor` 做整段兜底。
    private func diagnosticsExportText(snapshot: DiagnosticsExportSnapshot, probes: DiagnosticsProbeResult) -> String {
        let piWebVersion = probes.piWebVersion ?? snapshot.piWebFinding?.version
        let nodeVersion = probes.nodeVersion ?? snapshot.nodeFinding?.version
        return DiagnosticsCollector.text(
            for: DiagnosticsInput(
                appVersion: appVersionDescription,
                appBuild: appBuildDescription,
                piWebVersion: DiagnosticsCollector.probeValue(piWebVersion),
                piWebVersionConfidence: snapshot.piWebFinding?.confidence.rawValue ?? "unknown",
                piWebPath: snapshot.piWebFinding?.path ?? snapshot.piWebPath,
                piWebPathConfidence: snapshot.piWebFinding?.confidence.rawValue ?? "unknown",
                piCLIVersion: snapshot.piCLIFinding?.version ?? "未知",
                piCLIVersionConfidence: snapshot.piCLIFinding?.confidence.rawValue ?? "unknown",
                nodeVersion: DiagnosticsCollector.probeValue(nodeVersion),
                nodeVersionConfidence: snapshot.nodeFinding?.confidence.rawValue ?? "unknown",
                serviceAddress: snapshot.serviceAddress,
                port: String(snapshot.port),
                status: snapshot.status,
                management: snapshot.managedPID.map { DiagnosticsManagement.managed(pid: String($0)) } ?? .external,
                listenerPID: DiagnosticsCollector.probeValue(probes.listenerPID),
                listenerProcess: DiagnosticsCollector.probeValue(probes.listenerProcess),
                managedPID: snapshot.managedPID.map(String.init) ?? "无（外部服务或未运行）",
                workspaceDirectory: snapshot.workspaceDirectory,
                configurationDirectory: "~/.pi/agent",
                launchCommand: snapshot.launchCommand,
                launchEnvironment: snapshot.launchEnvironment,
                logPath: snapshot.logPath,
                logWriteStatus: snapshot.logWriteStatus,
                remoteAccessPasswordStatus: snapshot.remoteAccessPasswordStatus,
                componentInstallations: snapshot.componentInstallations
            ),
            redactor: logRedactor
        )
    }

    /// 菜单“复制诊断”入口：与诊断窗口的按钮完全同一条路径。
    @objc func copyDiagnostics(_ sender: Any?) {
        beginDiagnosticsExport(presentingIn: window)
    }

    /// 诊断导出（GitHub #10 / W4 M3）：先在主线程弹脱敏提醒，用户确认后才到后台
    /// 串行队列执行子进程探测（每个调用有超时），采集完成再回主线程组装文本并写入
    /// 剪贴板。等待期间主线程不被子进程阻塞；取消则不跑任何子进程。
    func beginDiagnosticsExport(presentingIn window: NSWindow?) {
        guard !diagnosticsExportInProgress else { return }
        diagnosticsExportInProgress = true
        DiagnosticsClipboard.confirmExport(presentingIn: window) { [weak self] approved in
            guard let self else { return }
            guard approved else {
                self.diagnosticsExportInProgress = false
                return
            }
            // 确认后才取快照：用户在提醒框上停留期间的状态变化不会让导出内容失真。
            let snapshot = self.diagnosticsExportSnapshot()
            self.diagnosticsProbeCollector.collect(piWebPath: snapshot.piWebPath, port: snapshot.port) { [weak self] probes in
                guard let self else { return }
                let text = self.diagnosticsExportText(snapshot: snapshot, probes: probes)
                // 组装完回主线程写入剪贴板（不在后台线程碰 AppKit 之外的 UI 约定）。
                DispatchQueue.main.async {
                    self.diagnosticsExportInProgress = false
                    DiagnosticsClipboard.copy(text)
                }
            }
        }
    }

    private func statusDescription() -> String {
        ServiceState.statusText(for: currentState, managedPID: serviceManager.managedServicePID())
    }

    @objc func reloadPage(_ sender: Any?) { webViewController.reload() }
    @objc func hardReloadPage(_ sender: Any?) { webViewController.reloadFromOrigin() }
    @objc private func zoomIn(_ sender: Any?) { webViewController.zoomIn() }
    @objc private func zoomOut(_ sender: Any?) { webViewController.zoomOut() }
    @objc private func resetZoom(_ sender: Any?) { webViewController.resetZoom() }

    @objc private func showFindBar(_ sender: Any?) { webViewController.showFindBar(in: window) }

    /// 显式菜单项“退出 Pi Web Desktop（保持服务运行）”：不受设置的退出行为影响。
    /// 不调用 stopService，也不删除 service-owner.json，让 pi-web 继续独立运行。
    @objc private func quitKeepingService(_ sender: Any?) {
        handleQuitEvent(.keepServiceRunningQuitRequested(service: currentQuitServiceState(), now: Date()))
    }

    /// ⌘Q 与菜单“退出 Pi Web Desktop”：按设置里的“退出行为”退出（默认询问）。
    /// 两个显式菜单项不受它影响。
    @objc private func quitWithConfiguredBehavior(_ sender: Any?) {
        handleQuitEvent(.configuredQuitRequested(
            behavior: serviceManager.configuration.quitBehavior,
            service: currentQuitServiceState(),
            now: Date()
        ))
    }

    /// “启动失败”提示里的“退出”按钮：与显式“退出并停止服务”一致。
    @objc func quitApp(_ sender: Any?) {
        quitAndStop(sender)
    }

    /// 显式菜单项“退出 Pi Web Desktop（停止服务）”：不受设置影响；只停止通过
    /// 所有权校验的托管进程组，外部服务在任何退出行为下都不发信号。
    @objc private func quitAndStop(_ sender: Any?) {
        handleQuitEvent(.stopServiceQuitRequested(service: currentQuitServiceState(), now: Date()))
    }
}
