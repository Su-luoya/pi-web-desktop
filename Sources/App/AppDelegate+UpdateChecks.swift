/// Manual update checks (Pi Web, Pi CLI, extension packages) started from the UI.

import Cocoa

extension AppDelegate {
    // MARK: - 桌面 App 自动更新

    /// 只允许本次刚从 GitHub API 验证过的 Release 进入下载流程；缓存结果不会安装。
    @objc func updateDesktopAppNow(_ sender: Any?) {
        guard desktopAppUpdateInstaller == nil else { return }
        guard let result = updateChecker?.summary.result(for: UpdateCheckCategory.desktopApp.rawValue),
              result.status == .updateAvailable,
              result.origin == .network,
              result.freshness == .fresh,
              result.confidence == .verified,
              let version = result.latestVersion,
              let releaseTag = result.upstreamTag else {
            presentDesktopUpdateFailure(.missingAsset)
            return
        }
        let alert = NSAlert()
        alert.messageText = "更新桌面应用"
        alert.informativeText = "检测到桌面应用新版本 \(version)。下载并安装后应用会退出并重新启动。"
            + "当前版本未经过 Apple Developer 签名与 notarization，请确认 GitHub 发布来源。"
        alert.addButton(withTitle: "更新")
        alert.addButton(withTitle: "取消")
        alert.alertStyle = .warning
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.downloadAndInstallDesktopApp(version: version, releaseTag: releaseTag)
        }
    }

    private func downloadAndInstallDesktopApp(version: String, releaseTag: String) {
        let tagCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        guard DesktopAppReleaseAssetSelector.isReleaseTag(releaseTag),
              let encodedTag = releaseTag.addingPercentEncoding(withAllowedCharacters: tagCharacters),
              let releaseURL = URL(string: "https://api.github.com/repos/\(UpdateCheckUpstream.desktopRepository)/releases/tags/\(encodedTag)"),
              let components = URLComponents(url: releaseURL, resolvingAgainstBaseURL: false),
              components.scheme == "https",
              components.host == UpdateCheckUpstream.githubHost,
              components.path == "/repos/\(UpdateCheckUpstream.desktopRepository)/releases/tags/\(encodedTag)",
              components.query == nil,
              components.fragment == nil else {
            presentDesktopUpdateFailure(.invalidAssetURL)
            return
        }

        var request = URLRequest(url: releaseURL)
        request.httpMethod = "GET"
        request.timeoutInterval = UpdateChecker.requestTimeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(UpdateCheckIdentity.current.userAgent, forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let data, error == nil,
                  response?.url == releaseURL,
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = json["tag_name"] as? String,
                  tag == releaseTag,
                  let assets = json["assets"] as? [[String: Any]] else {
                DispatchQueue.main.async { self?.presentDesktopUpdateFailure(.downloadFailed) }
                return
            }
            let parsedAssets = assets.compactMap { asset -> (name: String, url: URL)? in
                guard let name = asset["name"] as? String,
                      let text = asset["browser_download_url"] as? String,
                      let url = URL(string: text) else { return nil }
                return (name, url)
            }
            guard let archive = parsedAssets.first(where: {
                      DesktopAppReleaseAssetSelector.isArchiveName($0.name, version: version)
                  }),
                  let checksumAsset = parsedAssets.first(where: { $0.name == "\(archive.name).sha256" }),
                  DesktopAppReleaseAssetSelector.allowsDownloadURL(
                      archive.url, assetName: archive.name, releaseTag: releaseTag
                  ),
                  DesktopAppReleaseAssetSelector.allowsChecksumDownloadURL(
                      checksumAsset.url, assetName: checksumAsset.name, releaseTag: releaseTag
                  ) else {
                DispatchQueue.main.async { self?.presentDesktopUpdateFailure(.missingAsset) }
                return
            }

            var checksumRequest = URLRequest(url: checksumAsset.url)
            checksumRequest.httpMethod = "GET"
            checksumRequest.timeoutInterval = UpdateChecker.requestTimeout
            checksumRequest.setValue("text/plain", forHTTPHeaderField: "Accept")
            checksumRequest.setValue(UpdateCheckIdentity.current.userAgent, forHTTPHeaderField: "User-Agent")
            let checksumSession = URLSession(
                configuration: .ephemeral,
                delegate: ChecksumRedirectDelegate(),
                delegateQueue: nil
            )
            checksumSession.dataTask(with: checksumRequest) { [weak self] checksumData, checksumResponse, checksumError in
                guard let checksumData, checksumError == nil,
                      (checksumResponse as? HTTPURLResponse)?.statusCode == 200,
                      let finalURL = checksumResponse?.url,
                      DesktopAppReleaseAssetSelector.allowsChecksumRedirect(finalURL),
                      let checksum = String(data: checksumData, encoding: .utf8),
                      let verifiedAsset = DesktopAppReleaseAssetSelector.select(
                          version: version,
                          assets: [(name: archive.name, url: archive.url)],
                          checksum: checksum,
                          releaseTag: releaseTag
                      ) else {
                    checksumSession.finishTasksAndInvalidate()
                    DispatchQueue.main.async { self?.presentDesktopUpdateFailure(.checksumUnavailable) }
                    return
                }
                checksumSession.finishTasksAndInvalidate()
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.desktopAppUpdateInstaller == nil else { return }
                    let installer = DesktopAppUpdateInstaller()
                    self.desktopAppUpdateInstaller = installer
                    installer.install(asset: verifiedAsset) { [weak self, weak installer] result in
                        if self?.desktopAppUpdateInstaller === installer {
                            self?.desktopAppUpdateInstaller = nil
                        }
                        if case .failed(let failure) = result {
                            self?.presentDesktopUpdateFailure(failure)
                        }
                    }
                }
            }.resume()
        }.resume()
    }

    private func presentDesktopUpdateFailure(_ failure: DesktopAppUpdateFailure) {
        let alert = NSAlert()
        alert.messageText = "桌面应用更新未完成"
        alert.informativeText = failure.text
        alert.addButton(withTitle: "好")
        alert.beginSheetModal(for: window)
    }

    // MARK: - 更新检查（GitHub #17）

    /// 更新检查的生命周期入口：第一次调用启动（立即检查一次并安排周期复查），
    /// 之后的调用只更新本机版本清单。检查只访问白名单内的上游，不安装任何东西。
    func startUpdateChecking(with inventory: UpdateCheckInventory) {
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
    @objc func checkForUpdatesNow(_ sender: Any?) {
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
    func syncUpdateSettingsWindow() {
        guard let controller = updateSettingsWindowController,
              let updateChecker else { return }
        controller.update(
            preferences: updateChecker.preferences,
            statuses: statusSnapshot(for: updateChecker),
            ignorableVersions: ignorableVersionCandidates(),
            piCLIStatus: piCLIStatusBlockText(),
            piPackageStatus: piPackageStatusBlockText(),
            abandonedStatus: updateAbandonedStatusBlockText()
        )
    }

    /// 诊断页/设置页的「已放弃」记录块（GitHub #62）：组件、开始时间、超时上限、
    /// 结束时间未知与本次实际动作。命令摘要已经过脱敏。
    func updateAbandonedStatusBlockText() -> String {
        guard !appConfiguration.isSmokeLaunch else { return "" }
        return UpdateAbandonedAttemptPresenter.block(
            for: appConfiguration.abandonedAttempts(),
            format: { Self.updateTimestampFormatter.string(from: $0) }
        ) ?? ""
    }

    /// 每类组件的状态快照。检查器发布过汇总时用它的（在主线程发布，线程安全）；
    /// 否则用当前设置现算一份“尚未检查”的状态。
    func statusSnapshot(for updateChecker: UpdateChecker) -> [UpdateCategoryStatus] {
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
    func makeUpdateSettingsMenuItem() -> NSMenuItem {
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
        // Pi CLI 更新的持久告警项（GitHub #21）。
        let piCLIWarningItem = NSMenuItem(
            title: "",
            action: #selector(showPiCLIUpdateWarning(_:)),
            keyEquivalent: ""
        )
        piCLIWarningItem.target = self
        piCLIWarningItem.isHidden = true
        piCLIUpdateWarningMenuItem = piCLIWarningItem
        menu.addItem(piCLIWarningItem)
        // Pi 扩展包更新的持久告警项（GitHub #22）。
        let piPackageWarningItem = NSMenuItem(
            title: "",
            action: #selector(showPiPackageUpdateWarning(_:)),
            keyEquivalent: ""
        )
        piPackageWarningItem.target = self
        piPackageWarningItem.isHidden = true
        piPackageUpdateWarningMenuItem = piPackageWarningItem
        menu.addItem(piPackageWarningItem)
        // 桌面 App 自更新入口：默认隐藏，只有检测到“本次网络检查 + 已核实”的新版本时才显示。
        // 下载、校验与替换进程都由 `updateDesktopAppNow(_:)` 负责；这里只是一个入口。
        let desktopUpdateItem = NSMenuItem(
            title: "下载并安装桌面应用更新…",
            action: #selector(updateDesktopAppNow(_:)),
            keyEquivalent: ""
        )
        desktopUpdateItem.target = self
        desktopUpdateItem.isHidden = true
        desktopUpdateItem.isEnabled = false
        desktopAppUpdateMenuItem = desktopUpdateItem
        menu.addItem(desktopUpdateItem)
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
        // 手动“立即更新 Pi CLI…”：只调用官方 pi update --self，执行前显示计划、
        // 运行中的 Pi 进程与风险说明并要求确认（GitHub #21）。
        let manualPiCLIItem = NSMenuItem(
            title: "立即更新 Pi CLI…",
            action: #selector(updatePiCLINow(_:)),
            keyEquivalent: ""
        )
        manualPiCLIItem.target = self
        piCLIUpdateMenuItem = manualPiCLIItem
        menu.addItem(manualPiCLIItem)
        // 扩展包更新入口（GitHub #22）：策略为“检查并通知”时只展示文本与可复制
        // 命令，策略为“询问后更新”才会弹确认框（取消是默认按钮）；关闭策略不检查
        // 不通知不执行，也不做无人值守更新。
        let piPackageItem = NSMenuItem(
            title: "查看 Pi 扩展包更新…",
            action: #selector(showPiPackageUpdates(_:)),
            keyEquivalent: ""
        )
        piPackageItem.target = self
        piPackageUpdateMenuItem = piPackageItem
        menu.addItem(piPackageItem)
        // 「已放弃」记录（GitHub #62）：超时/放弃等待之后可能仍在运行的命令。这里
        // 只展示记录并提供显式清除；清除不改动任何安装，也不结束任何进程。
        let abandonedItem = NSMenuItem(
            title: "已放弃的更新记录…",
            action: #selector(showAbandonedUpdateAttempts(_:)),
            keyEquivalent: ""
        )
        abandonedItem.target = self
        abandonedAttemptsMenuItem = abandonedItem
        menu.addItem(abandonedItem)
        menu.addItem(withTitle: "更新检查说明…", action: #selector(showUpdateCheckExplanation(_:)), keyEquivalent: "")
        item.submenu = menu
        updateSettingsMenu = menu
        return item
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === updateSettingsMenu else { return }
        refreshUpdateMenuState()
    }

    func refreshUpdateMenuState() {
        updateStatusMenuItem?.title = updateCheckStatusText()
        if let piWebUpdateWarningMenuItem {
            piWebUpdateWarningMenuItem.title = piWebUpdateWarning?.shortText ?? ""
            piWebUpdateWarningMenuItem.isHidden = piWebUpdateWarning == nil
        }
        // 更新进行中时对应入口不可用（W2A A-4 + W3B F2/F3）：菜单项与入口同一条
        // 判据，但按组件分开——一个组件的卡住的子进程不会禁用另一个组件的入口；
        // 被禁用时标题里带可见原因（不静默置灰），「退出未确认」窗口给出重启恢复。
        let webEntry = piWebUpdateEntryState
        piWebUpdateMenuItem?.title = "立即更新 Pi Web…" + (webEntry.menuTitleSuffix ?? "")
        piWebUpdateMenuItem?.isEnabled = dependencyGate == .ready && !webEntry.isBlocked
        if let piCLIUpdateWarningMenuItem {
            piCLIUpdateWarningMenuItem.title = piCLIUpdateWarning?.shortText ?? ""
            piCLIUpdateWarningMenuItem.isHidden = piCLIUpdateWarning == nil
        }
        let cliEntry = piCLIUpdateEntryState
        piCLIUpdateMenuItem?.title = "立即更新 Pi CLI…" + (cliEntry.menuTitleSuffix ?? "")
        piCLIUpdateMenuItem?.isEnabled = dependencyGate == .ready && !cliEntry.isBlocked
        if let piPackageUpdateWarningMenuItem {
            piPackageUpdateWarningMenuItem.title = piPackageUpdateWarning?.shortText ?? ""
            piPackageUpdateWarningMenuItem.isHidden = piPackageUpdateWarning == nil
        }
        // 桌面 App 自更新入口：只有「本次网络检查 + 已核实 + 有可用版本」才显示；安装器
        // 运行期间置灰，避免同一时刻进入两次下载/替换流程。
        let desktopResult = updateChecker?.summary.result(for: UpdateCheckCategory.desktopApp.rawValue)
        let desktopInstallable = desktopResult?.status == .updateAvailable
        desktopAppUpdateMenuItem?.isHidden = !desktopInstallable
        desktopAppUpdateMenuItem?.isEnabled = desktopInstallable && desktopAppUpdateInstaller == nil
        // 扩展包入口与上面两个组件同一套闸控（GitHub #107）：忙或上一次命令已放弃等待、
        // 退出未确认时，菜单项直接带可见原因置灰，而不是让用户点下去才被拒。
        let packageEntry = piPackageUpdateEntryState
        piPackageUpdateMenuItem?.title = "查看 Pi 扩展包更新…" + (packageEntry.menuTitleSuffix ?? "")
        piPackageUpdateMenuItem?.isEnabled = dependencyGate == .ready && !packageEntry.isBlocked
        // 「已放弃」记录项：只有真的有记录时才可用并显示条数（GitHub #62）。
        if let abandonedAttemptsMenuItem {
            let attempts = appConfiguration.abandonedAttempts()
            abandonedAttemptsMenuItem.title = attempts.isEmpty
                ? "已放弃的更新记录（无）"
                : "已放弃的更新记录（\(attempts.count) 条）"
            abandonedAttemptsMenuItem.isEnabled = !attempts.isEmpty
        }
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
    func updateCheckStatusBlockText() -> String {
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
        let piCLIStatus = piCLIStatusBlockText()
        if !piCLIStatus.isEmpty {
            lines.append("")
            lines.append(piCLIStatus)
        }
        let piPackageStatus = piPackageStatusBlockText()
        if !piPackageStatus.isEmpty {
            lines.append("")
            lines.append(piPackageStatus)
        }
        // 统一更新历史（GitHub #23）：展示最近一次更新的完成阶段、阶段结果与
        // 建议动作（含静态手动命令文本，仅展示不执行）。
        lines.append("")
        lines.append(contentsOf: UpdateHistoryPresenter.lines(for: appConfiguration.updateHistory().first))
        // 「已放弃」记录（GitHub #62）：超时/放弃等待之后可能仍在运行的命令。
        let abandonedStatus = updateAbandonedStatusBlockText()
        if !abandonedStatus.isEmpty {
            lines.append("")
            lines.append(abandonedStatus)
        }
        return lines.joined(separator: "\n")
    }

    /// 检查结果落地（主线程）：刷新菜单与窗口；手动检查弹完整结果，自动检查按
    /// 策略与忽略版本决定是否提示。
    func handleUpdateCheckResults(_ summary: UpdateCheckSummary) {
        updateCheckInProgress = false
        refreshUpdateMenuState()
        syncUpdateSettingsWindow()
        diagnosticsWindowController?.refreshUpdateStatus()
        // Pi CLI 的受限自动更新（GitHub #21）：只在拿到本次检查结果后判定一次。
        attemptPiCLIAutomaticUpdateIfNeeded()
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
}

/// Checksummed assets use a dedicated session so the redirect policy cannot be toggled
/// while an unrelated archive download is in flight.
private final class ChecksumRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(
            DesktopAppReleaseAssetSelector.allowsChecksumRedirect(request.url) ? request : nil
        )
    }
}
