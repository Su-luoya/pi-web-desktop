/// Manual update checks (Pi Web, Pi CLI, extension packages) started from the UI.

import Cocoa

extension AppDelegate {
    // MARK: - 桌面 App 自动更新

    /// 允许本次网络往返确认过的结果（含条件请求命中 304 的重验证结果）进入下载
    /// 流程；准入条件与理由见 `DesktopAppUpdateInstallPolicy`。
    @objc func updateDesktopAppNow(_ sender: Any?) {
        // 入口闸控（outD-2）：整轮占位（含确认框、取发布页、下载、替换）。重复点击
        // 不得静默丢弃，必须给出可见原因；先判忙，消息才是「已在进行中」而不是
        // 误导性的「结果未核实」。
        guard !DesktopAppUpdateEntryPolicy.isBusy(
            activity: desktopAppUpdateRound.activity,
            installerPresent: desktopAppUpdateInstaller != nil
        ) else {
            presentDesktopUpdateFailure(.updateAlreadyInProgress)
            return
        }
        let result = updateChecker?.summary.result(for: UpdateCheckCategory.desktopApp.rawValue)
        let runningVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        guard let target = DesktopAppUpdateInstallPolicy.installTarget(
                  for: result, runningVersion: runningVersion
              ) else {
            presentDesktopUpdateFailure(.unconfirmedUpdate)
            return
        }
        // 确认框本身也占住入口：否则确认框还开着时再点菜单会再弹一个，两个「更新」
        // 都确认就会并行跑两轮下载。
        guard desktopAppUpdateRound.beginConfirming(releaseTag: target.releaseTag) else {
            presentDesktopUpdateFailure(.updateAlreadyInProgress)
            return
        }
        let alert = NSAlert()
        alert.messageText = "更新桌面应用"
        alert.informativeText = "检测到桌面应用新版本 \(target.version)。下载并安装后应用会退出并重新启动。"
            + "当前版本未经过 Apple Developer 签名与 notarization，请确认 GitHub 发布来源。"
        alert.addButton(withTitle: "更新")
        alert.addButton(withTitle: "取消")
        alert.alertStyle = .warning
        refreshUpdateMenuState()
        presentAlert(alert) { [weak self] response in
            guard let self else { return }
            guard response == .alertFirstButtonReturn else {
                // 用户取消：阶段位必须复位（否则入口永久置灰、菜单永久显示「等待确认」）。
                self.finishDesktopAppUpdateRound(releaseTag: target.releaseTag)
                self.finishDesktopAppUpdateProgress(.skipped(reason: "用户取消了更新"))
                return
            }
            // 进度窗口（GitHub #219）：从这里开始才有真正要等的工作。
            self.beginDesktopAppUpdateProgress(version: target.version)
            self.downloadAndInstallDesktopApp(version: target.version, releaseTag: target.releaseTag)        }
    }

    /// 从「等待确认」推进到「重新核对发布页」：只允许推进自己那一轮（同一 tag），
    /// 其他任何情况的重复开始一律拒绝并给出可见原因。
    private func beginDesktopAppUpdateActivity(releaseTag: String) -> Bool {
        guard desktopAppUpdateRound.beginResolving(releaseTag: releaseTag) else {
            presentDesktopUpdateFailure(.updateAlreadyInProgress)
            return false
        }
        refreshUpdateMenuState()
        return true
    }

    /// 一轮更新结束（成功/失败/被拒）：复位阶段位并刷新菜单，否则入口会永久置灰。
    /// 只复位自己那一轮：已经开始新一轮时，旧一轮的回调不得清掉它的阶段位。
    private func finishDesktopAppUpdateRound(releaseTag: String?) {
        guard desktopAppUpdateRound.finish(releaseTag: releaseTag) else { return }
        refreshUpdateMenuState()
    }

    /// 这一轮已占位后失败：必须同时复位阶段位并给出可见原因。
    ///
    /// 把两件事绑在一个入口，是因为它们漏一个就是故障：只弹提示会留下永远停在忙碌
    /// 态的菜单项（只能重启应用才能再试，alpha.17 修的正是这个）；只复位不提示则是
    /// 静默失败。调用方一律走这里，而不是先 `present…` 再指望自己记得 `finish…`。
    /// 调用方负责确保已在主线程（`desktopAppUpdateRound` 是主线程独占的状态）。
    private func failDesktopAppUpdateRound(
        _ failure: DesktopAppUpdateFailure,
        releaseTag: String?,
        detail: String? = nil
    ) {
        finishDesktopAppUpdateRound(releaseTag: releaseTag)
        // 失败必须留痕：这条路径过去一行日志都不写，用户截图报错时日志里查不到
        // 任何线索（GitHub #225 的排查成本就是这么来的）。
        let tag = releaseTag.map { "（\($0)）" } ?? ""
        _ = logWriter.append(logRedactor.redact(
            "桌面应用更新失败\(tag)：\(failure.text)" + (detail.map { " 原因：\($0)" } ?? "")
        ))
        // 进度窗口（GitHub #219）：失败必须停在这一步可见，所以用同一句原因收尾。
        finishDesktopAppUpdateProgress(.failed(reason: failure.text))
        presentDesktopUpdateFailure(failure)
    }

    /// 安装入口：先问更新通道（appcast），通道不可用再回落 GitHub API。
    ///
    /// 通道优先的理由是配额：GitHub 未认证 API 每小时 60 次、按出口 IP 共享，
    /// 用完就让整个更新失败（GitHub #225）。appcast 走 CDN，不占配额。
    private func downloadAndInstallDesktopApp(version: String, releaseTag: String) {
        guard beginDesktopAppUpdateActivity(releaseTag: releaseTag) else { return }
        guard DesktopAppReleaseAssetSelector.isReleaseTag(releaseTag) else {
            failDesktopAppUpdateRound(.invalidAssetURL, releaseTag: releaseTag)
            return
        }
        fetchDesktopAppReleaseAssetsFromAppcast(version: version, releaseTag: releaseTag) { [weak self] asset in
            guard let self else { return }
            if let asset {
                self.beginDesktopAppUpdateDownload(
                    asset: asset, releaseTag: releaseTag, source: "已从更新通道取得资产信息"
                )
                return
            }
            self.fetchDesktopAppReleaseAssetsFromGitHubAPI(version: version, releaseTag: releaseTag)
        }
    }

    /// GitHub API 回落路径（更新通道不可用时的原路径）。
    private func fetchDesktopAppReleaseAssetsFromGitHubAPI(version: String, releaseTag: String) {
        let tagCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        guard let encodedTag = releaseTag.addingPercentEncoding(withAllowedCharacters: tagCharacters),
              let releaseURL = URL(string: "https://api.github.com/repos/\(UpdateCheckUpstream.desktopRepository)/releases/tags/\(encodedTag)"),
              let components = URLComponents(url: releaseURL, resolvingAgainstBaseURL: false),
              components.scheme == "https",
              components.host == UpdateCheckUpstream.githubHost,
              components.path == "/repos/\(UpdateCheckUpstream.desktopRepository)/releases/tags/\(encodedTag)",
              components.query == nil,
              components.fragment == nil else {
            failDesktopAppUpdateRound(.invalidAssetURL, releaseTag: releaseTag)
            return
        }

        var request = URLRequest(url: releaseURL)
        request.httpMethod = "GET"
        request.timeoutInterval = UpdateChecker.requestTimeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(UpdateCheckIdentity.current.userAgent, forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            let http = response as? HTTPURLResponse
            let status = http?.statusCode
            let remaining = http?.value(forHTTPHeaderField: "x-ratelimit-remaining")
            guard let data, error == nil,
                  response?.url == releaseURL,
                  status == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = json["tag_name"] as? String,
                  tag == releaseTag,
                  let assets = json["assets"] as? [[String: Any]] else {
                // 发布页请求失败与「整包下载失败」不是一回事：GitHub 的未认证 API
                // 每小时只给 60 次，用完返回 403 + `x-ratelimit-remaining: 0`。
                // 旧实现一律报「更新包下载失败」，用户既不知道原因，也不知道
                // 等一会儿就能好（GitHub #225）。
                let failure = error == nil
                    ? DesktopAppUpdateFailure.releasePageFailure(
                        status: status, rateLimitRemaining: remaining)
                    : .downloadFailed
                let detail = "发布页请求失败（HTTP \(status.map(String.init) ?? "无响应")"
                    + "\(remaining.map { "，限流剩余 \($0)" } ?? "")"
                    + "\(error.map { "，\($0.localizedDescription)" } ?? "")"
                DispatchQueue.main.async {
                    self?.failDesktopAppUpdateRound(failure, releaseTag: releaseTag, detail: detail)
                }
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
                DispatchQueue.main.async {
                    self?.failDesktopAppUpdateRound(.missingAsset, releaseTag: releaseTag)
                }
                return
            }

            var checksumRequest = URLRequest(url: checksumAsset.url)
            // 进度窗口（GitHub #219）：发布页与资产列表都核对完了，进入下载阶段。
            DispatchQueue.main.async { [weak self] in
                self?.setDesktopAppUpdateProgressStep(0, .succeeded, detail: "已核对发布页与资产列表")
                self?.setDesktopAppUpdateProgressStep(1, .running, detail: "正在下载更新包与校验和…")
            }
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
                    // 必须同时结束这一轮：`beginDesktopAppUpdateActivity` 已经把
                    // `desktopAppUpdateRound.activity` 置成忙碌，而菜单入口的闸控
                    // （`DesktopAppUpdateEntryPolicy.isBusy`）只看 activity 与安装器
                    // 是否在场。少了结束这一步，校验和下载失败后整轮永远停在忙碌态，
                    // 菜单项永久置灰，只能重启应用才能再试。
                    DispatchQueue.main.async {
                        self?.failDesktopAppUpdateRound(.checksumUnavailable, releaseTag: releaseTag)
                    }
                    return
                }
                checksumSession.finishTasksAndInvalidate()
                self?.beginDesktopAppUpdateDownload(
                    asset: verifiedAsset,
                    releaseTag: releaseTag,
                    source: "已核对发布页与资产列表"
                )
            }.resume()
        }.resume()
    }

    /// 更新通道（appcast）优先。回调 nil 表示「通道不可用」，由调用方回落
    /// GitHub API —— feed 是加速器，不是新的单点依赖。
    private func fetchDesktopAppReleaseAssetsFromAppcast(
        version: String,
        releaseTag: String,
        completion: @escaping (DesktopAppReleaseAsset?) -> Void
    ) {
        guard let feedURL = AppcastFeed.url else {
            completion(nil)
            return
        }
        var request = URLRequest(url: feedURL)
        request.httpMethod = "GET"
        request.timeoutInterval = UpdateChecker.requestTimeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(UpdateCheckIdentity.current.userAgent, forHTTPHeaderField: "User-Agent")
        let session = URLSession(
            configuration: .ephemeral,
            delegate: AppcastRedirectDelegate(),
            delegateQueue: nil
        )
        session.dataTask(with: request) { data, response, error in
            session.finishTasksAndInvalidate()
            guard let data, error == nil,
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let finalURL = response?.url, AppcastFeed.allows(finalURL: finalURL),
                  let release = AppcastFeed.release(tag: releaseTag, in: data),
                  release.version == version,
                  let asset = DesktopAppReleaseAssetSelector.select(
                      version: version,
                      assets: [(name: release.zip.name, url: release.zip.url)],
                      checksum: release.zip.sha256,
                      releaseTag: releaseTag
                  ) else {
                // 任何一处不合规都退回 GitHub API：feed 坏了不该让更新失败。
                completion(nil)
                return
            }
            completion(asset)
        }.resume()
    }

    /// 两条通道的共同出口：资产与校验值都到手后，创建安装器接管下载与替换。
    private func beginDesktopAppUpdateDownload(
        asset: DesktopAppReleaseAsset,
        releaseTag: String,
        source: String
    ) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            // 进度窗口（GitHub #219）：资产与校验值都核对完了，进入安装阶段。
            self.setDesktopAppUpdateProgressStep(0, .succeeded, detail: source)
            // 预下载命中时第 1 步直接算完成：用户看到的是“已预下载”而不是一段
            // 其实不会发生的下载。
            let prefetched = DesktopUpdatePackageCache.shared
                .package(matching: asset.version, releaseTag: releaseTag) != nil
            self.setDesktopAppUpdateProgressStep(
                1,
                prefetched ? .succeeded : .running,
                detail: prefetched ? "更新包已预下载，直接校验" : "正在下载更新包与校验和…"
            )
            self.setDesktopAppUpdateProgressStep(2, .running, detail: "正在校验安装包（SHA-256）…")
            guard self.desktopAppUpdateInstaller == nil else {
                // 安装器已存在（入口闸控已挡住第二轮，这里只是兜底）：这轮
                // 到此结束，不创建第二个安装器。
                self.finishDesktopAppUpdateRound(releaseTag: releaseTag)
                return
            }
            guard self.desktopAppUpdateRound.markInstalling(releaseTag: releaseTag) else {
                // 这一轮已被取消或已被新一轮顶掉：不要再开一个安装器。
                self.finishDesktopAppUpdateRound(releaseTag: releaseTag)
                return
            }
            let installer = DesktopAppUpdateInstaller()
            self.desktopAppUpdateInstaller = installer
            self.refreshUpdateMenuState()
            installer.install(asset: asset) { [weak self, weak installer] result in
                if self?.desktopAppUpdateInstaller === installer {
                    self?.desktopAppUpdateInstaller = nil
                }
                // 安装器交付结果即整轮结束：成功时应用即将被替换，失败时入口
                // 必须重新可用（否则菜单永久置灰）。
                switch result {
                case .updated:
                    self?.setDesktopAppUpdateProgressStep(2, .succeeded, detail: "校验和匹配")
                    self?.setDesktopAppUpdateProgressStep(3, .succeeded, detail: "已替换应用，即将重新启动")
                    self?.finishDesktopAppUpdateRound(releaseTag: releaseTag)
                    self?.finishDesktopAppUpdateProgress(.succeeded(version: asset.version))
                case .failed(let failure):
                    // 失败停在真正失败的那一步，而不是笼统地“跳过”。
                    self?.failRunningDesktopAppUpdateStep(detail: failure.text)
                    self?.failDesktopAppUpdateRound(failure, releaseTag: releaseTag)
                }
            }
        }
    }

    private func presentDesktopUpdateFailure(_ failure: DesktopAppUpdateFailure) {
        let alert = NSAlert()
        alert.messageText = "桌面应用更新未完成"
        alert.informativeText = failure.text
        alert.addButton(withTitle: "好")
        presentAlert(alert)
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

    /// “更新 → 更新检查偏好设置…”：策略、每类状态、忽略版本与 alpha.3 预留位。
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
            NSApp.activate()
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
        // M9（更新事务审计）：notifiedVersions 改按 target（分类+包名）记录；
        // 忽略入口只有分类，这里把该分类下命中该版本的全部 target 都标记为已提示，
        // 保证同样不再弹窗。
        if let updateChecker {
            for result in updateChecker.summary.results
            where result.target.category == category && result.latestVersion == version {
                notifiedVersions[result.target] = version
            }
        }
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
        presentAlert(alert)
    }

    /// 把更新相关的可点项追加进顶层“更新”菜单。
    ///
    /// 这些项原来藏在“更新 → …”两级子菜单下：告警、四类开关、
    /// 三个立即更新入口与两个对话框混在一屏，用户既找不到也读不完。现在按
    /// “先看告警，再做动作，最后改策略”分三段，每段之间用分隔线断开。
    ///
    /// - Parameter menu: 顶层“更新”菜单，状态行已由调用方加好。
    func appendUpdateMenuItems(to menu: NSMenu) {
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
        // 进度窗口（GitHub #219）：重新打开当前（或最近一次）更新的实时进度；
        // 窗口也只在更新开始/失败时自动出现，这里给用户一个手动入口。
        let progressItem = NSMenuItem(
            title: "显示更新进度…",
            action: #selector(showUpdateProgress(_:)),
            keyEquivalent: ""
        )
        progressItem.target = self
        updateProgressMenuItem = progressItem
        menu.addItem(progressItem)
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
        menu.addItem(.separator())
        menu.addItem(withTitle: "更新检查说明…", action: #selector(showUpdateCheckExplanation(_:)), keyEquivalent: "")
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        if phoneAccessMenus.contains(where: { $0 === menu }) {
            rebuildPhoneAccessMenu(menu)
        } else if remoteAccessMenus.contains(where: { $0 === menu }) {
            rebuildRemoteAccessMenu(menu)
        } else if menu === updateMenu {
            refreshUpdateMenuState()
        }
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
        // 桌面 App 自更新入口：只有「本次网络检查 + 已核实 + 有可用版本」才显示；整轮
        // 更新（等待确认、下载、校验、替换）期间置灰并带可见原因：旧实现只看安装器
        // 对象，下载窗口期看不出「进行中」，用户能再点一次再下一遍整包（outD-2）。
        let desktopResult = updateChecker?.summary.result(for: UpdateCheckCategory.desktopApp.rawValue)
        let desktopInstallable = desktopResult?.status == .updateAvailable
        desktopAppUpdateMenuItem?.isHidden = !desktopInstallable
        desktopAppUpdateMenuItem?.title = "下载并安装桌面应用更新…"
            + (DesktopAppUpdateEntryPolicy.menuTitleSuffix(
                activity: desktopAppUpdateRound.activity,
                installerPresent: desktopAppUpdateInstaller != nil
            ) ?? "")
        desktopAppUpdateMenuItem?.isEnabled = DesktopAppUpdateEntryPolicy.isEntryEnabled(
            installable: desktopInstallable,
            activity: desktopAppUpdateRound.activity,
            installerPresent: desktopAppUpdateInstaller != nil
        )
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

    func updateCheckStatusText() -> String {
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
        prefetchDesktopUpdateIfAvailable(summary)
        // Pi CLI 的受限自动更新（GitHub #21）：只在拿到本次检查结果后判定一次。
        // 推迟路径依赖这次判定再调一次检查，因此必须排在下面的
        // `pendingManualUpdateCheck` 分支之前。
        attemptPiCLIAutomaticUpdateIfNeeded()
        guard pendingManualUpdateCheck else {
            notifyAboutAutomaticUpdates(summary)
            return
        }
        pendingManualUpdateCheck = false
        presentUpdateCheckResults(summary)
    }

    /// 检查发现桌面应用有新版本时，后台先把包下好（只用无配额的 appcast 通道）。
    ///
    /// 只下不装：安装入口仍然只在用户点击时出现。命中后点“更新”只剩解压与替换，
    /// 不再等一次 1.6MB 下载（GitHub #219 的进度窗口里下载通常是最长的一段）。
    /// 失败不重试也不提示：下一轮检查会再试一次。
    private func prefetchDesktopUpdateIfAvailable(_ summary: UpdateCheckSummary) {
        guard let updateChecker,
              updateChecker.preferences.isEnabled(.desktopApp),
              desktopAppUpdateInstaller == nil,
              desktopAppPrefetcher == nil,
              let result = summary.results.first(where: { $0.target.category == .desktopApp }),
              result.status == .updateAvailable,
              let version = result.latestVersion,
              let releaseTag = result.upstreamTag,
              DesktopAppReleaseAssetSelector.isReleaseTag(releaseTag),
              prefetchedDesktopUpdateVersion != version else { return }
        fetchDesktopAppReleaseAssetsFromAppcast(version: version, releaseTag: releaseTag) { [weak self] asset in
            guard let self, let asset else { return }
            DispatchQueue.main.async {
                guard self.desktopAppUpdateInstaller == nil, self.desktopAppPrefetcher == nil else { return }
                let prefetcher = DesktopAppUpdateInstaller()
                self.desktopAppPrefetcher = prefetcher
                prefetcher.prefetch(asset: asset) { [weak self, weak prefetcher] stored in
                    guard let self else { return }
                    if self.desktopAppPrefetcher === prefetcher { self.desktopAppPrefetcher = nil }
                    if stored { self.prefetchedDesktopUpdateVersion = version }
                }
            }
        }
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
            notifiedVersions[entry.target] = entry.latestVersion
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
        presentAlert(alert) { [weak self] response in
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
        presentAlert(alert)
    }
}

/// Checksummed assets use a dedicated session so the redirect policy cannot be toggled
/// while an unrelated archive download is in flight.
/// appcast 重定向闸控：只跟随到 feed 主机（与校验和下载同一策略）。
private final class AppcastRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let url = request.url, AppcastFeed.allows(finalURL: url) else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}

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
