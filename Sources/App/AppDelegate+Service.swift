/// Service manager callbacks: state changes, failures and restart handling.

import Cocoa

extension AppDelegate {
    // MARK: - Service manager callbacks

    func installServiceManagerCallbacks() {
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

    /// “设置…”入口：单例窗口（W4 M2）。
    ///
    /// 同一时刻最多一个设置窗口：第一次请求创建控制器，之后每次请求复用同一个
    /// 控制器/窗口。窗口已经打开时只置前（不拿已保存值覆盖用户正在编辑的内容）；
    /// 取消/关闭后再打开时，先用当前生效配置刷新控件——上一次取消后残留的输入、
    /// 外部改动与刚输入的新密码都不会留在窗口里。旧实现每次都新建控制器并覆盖
    /// 引用，旧窗口（`isReleasedWhenClosed = false` 且不 close）会留在屏幕上，
    /// 用打开时的配置快照写回，出现“两个都能写配置的窗口、后写覆盖前写”。
    @objc func showPreferences(_ sender: Any?) {
        let controller = preferencesWindowStore.reuse { makePreferencesWindowController() }
        if controller.window?.isVisible != true {
            controller.update(configuration: serviceManager.configuration)
        }
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        if !NSApp.isActive {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    /// 创建设置窗口控制器。只在单例存储为空时调用；回调接线只做一次。
    private func makePreferencesWindowController() -> PreferencesWindowController {
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
        return controller
    }

    /// 设置窗口保存后的统一入口。
    ///
    /// `credentialsChanged` 表示 Keychain 中的密码刚被设置或删除：远程模式下
    /// 正在运行的托管服务必须重启，新的 `PI_WEB_PASSWORD`（或没有它）才会进入
    /// 子进程环境。删除密码已经把 hostname 收回 loopback，因此会走普通的重启
    /// 路径。
    ///
    /// `completion` 在配置生效（需要重启时，重启路径已经走完）后回到主线程调用；
    /// 默认 nil 让既有调用方不受影响。GitHub #150 的“切换监听地址后复制链接”
    /// 靠它保证复制发生在配置落盘与重启路径之后。
    ///
    /// 重叠切换（GitHub #135 F1）：被更新的配置请求取代时，这次调用的
    /// `completion` 不会被调用——写入与重启由取代它的请求完成。过期回调只负责
    /// 停止/清理（`stopService` 已经做完），不得把捕获的旧配置写回去。
    func applyPreferencesConfiguration(
        _ newConfiguration: ServiceConfiguration,
        credentialsChanged: Bool,
        completion: (() -> Void)? = nil
    ) {
        // GitHub #135 F1：在改动任何状态之前领取本次请求的配置代次。之后任何更新的
        // 配置请求或直接写入都会让它失效，用于让迟到的停止回调不再写配置。
        let configurationGeneration = serviceManager.beginConfigurationChange()
        let previous = serviceManager.configuration
        appConfiguration.save(newConfiguration)
        let changed = previous.runtimeSignature != newConfiguration.runtimeSignature
        let workspaceChanged = previous.workspacePath != newConfiguration.workspacePath
        let needsRestartForCredentials = credentialsChanged && !RemoteAccessPolicy.isLoopbackHostname(newConfiguration.hostname)
        let managed = (changed || needsRestartForCredentials) && serviceManager.managedServicePID() != nil
        // 工作目录门控与菜单可用性读最新配置，但配置要等旧服务停止后才交给
        // ServiceManager（否则停止校验会因端口/参数变化把旧进程误判为外部服务）。
        refreshWorkspaceState(configuration: newConfiguration)
        if workspaceChanged {
            recordWorkspace(path: appConfiguration.workspaceDirectory(for: newConfiguration).path)
        }
        applyServiceControlAvailability()

        if managed {
            // 先停止旧参数启动的服务，再切换配置，避免旧端口和新端口同时留下实例。
            serviceManager.stopService { [weak self] in
                guard let self else { return }
                // GitHub #135 F1：这个回调可能在用户又切换了一次工作目录之后才回来。
                // 只有仍是最新请求的那一次才写配置并重启；过期请求到此为止（停止与
                // 状态收敛已由 stopService 完成），否则会把配置写回旧目录，菜单勾选
                // 与实际服务目录随之后退。
                guard self.serviceManager.updateConfiguration(
                    newConfiguration,
                    ifGenerationMatches: configurationGeneration
                ) else { return }
                self.serviceManager.reloadAfterConfigurationChange()
                completion?()
            }
        } else {
            serviceManager.updateConfiguration(newConfiguration)
            if changed || needsRestartForCredentials {
                serviceManager.reloadAfterConfigurationChange()
            } else {
                // Re-emit the current state so the status menu title refreshes.
                serviceManager.setState(serviceManager.currentState)
            }
            completion?()
        }
    }
}
