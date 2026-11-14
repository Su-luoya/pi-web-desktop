/// Manual update checks (Pi Web, Pi CLI, extension packages) started from the UI.

import Cocoa

extension AppDelegate {
    // MARK: - 桌面 App 自动更新

    /// 允许本次网络往返确认过的结果（含条件请求命中 304 的重验证结果）进入下载
    /// 流程；准入条件与理由见 `DesktopAppUpdateInstallPolicy`。
    /// 统一更新流程里的桌面应用一步：确认已经在统一对话框里做过，这里直接进
    /// 下载与替换。成功会退出并重启应用，所以这一步由流程排在最后。
    func startDesktopAppUpdate(target: DesktopAppUpdateInstallTarget) {
        guard !DesktopAppUpdateEntryPolicy.isBusy(
            activity: desktopAppUpdateRound.activity,
            installerPresent: desktopAppUpdateInstaller != nil
        ) else {
            abortUpdateFlow("桌面应用未更新：上一轮下载还在进行")
            return
        }
        guard desktopAppUpdateRound.beginConfirming(releaseTag: target.releaseTag) else {
            abortUpdateFlow("桌面应用未更新：上一轮更新还在进行")
            return
        }
        refreshUpdateMenuState()
        beginDesktopAppUpdateProgress(version: target.version)
        downloadAndInstallDesktopApp(version: target.version, releaseTag: target.releaseTag)
    }

    /// 从「等待确认」推进到「重新核对发布页」：只允许推进自己那一轮（同一 tag），
    /// 其他任何情况的重复开始一律拒绝并给出可见原因。
    private func beginDesktopAppUpdateActivity(releaseTag: String) -> Bool {
        guard desktopAppUpdateRound.beginResolving(releaseTag: releaseTag) else {
            presentDesktopUpdateFailure(.updateAlreadyInProgress)
            // 这一轮没推进：统一流程不能停在“等一个不会到达的结果”上。
            abortUpdateFlow("桌面应用未更新：上一轮更新还在进行", presentAlert: false)
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
        // 统一流程里桌面应用是最后一步：失败就在这里收尾，否则流程会永远停在
        // “等一个不会到达的 completion”。
        abortUpdateFlow("桌面应用更新失败：\(failure.text)", presentAlert: false)
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

        let request = Self.updateRequest(url: releaseURL, accept: "application/json")
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
                // 先固化强引用，再把结果丢回主线程（不在并发闭包里读 weak 捕获变量）。
                guard let self else { return }
                DispatchQueue.main.async {
                    self.failDesktopAppUpdateRound(failure, releaseTag: releaseTag, detail: detail)
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
                guard let self else { return }
                DispatchQueue.main.async {
                    self.failDesktopAppUpdateRound(.missingAsset, releaseTag: releaseTag)
                }
                return
            }

            let checksumRequest = Self.updateRequest(url: checksumAsset.url, accept: "text/plain")
            // 进度窗口（GitHub #219）：发布页与资产列表都核对完了，进入下载阶段。
            DispatchQueue.main.async { [weak self] in
                self?.setDesktopAppUpdateProgressStep(0, .succeeded, detail: "已核对发布页与资产列表")
                self?.setDesktopAppUpdateProgressStep(1, .running, detail: "正在下载更新包与校验和…")
            }
            let checksumSession = URLSession(
                configuration: .ephemeral,
                delegate: AllowlistRedirectDelegate(
                    allows: DesktopAppReleaseAssetSelector.allowsChecksumRedirect
                ),
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
                    guard let self else { return }
                    DispatchQueue.main.async {
                        self.failDesktopAppUpdateRound(.checksumUnavailable, releaseTag: releaseTag)
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
        // `completion` 只被转交给 URLSession 的完成回调执行一次，属于所有权转移；
        // URLSession 的回调参数是 `@Sendable`，直接捕获非 Sendable 的闭包会告警。
        nonisolated(unsafe) let deliver = completion
        guard let feedURL = AppcastFeed.url else {
            completion(nil)
            return
        }
        let request = Self.updateRequest(url: feedURL, accept: "application/json")
        let session = URLSession(
            configuration: .ephemeral,
            delegate: AllowlistRedirectDelegate(
                allows: { $0.map { AppcastFeed.allows(finalURL: $0) } ?? false }
            ),
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
                deliver(nil)
                return
            }
            deliver(asset)
        }.resume()
    }

    /// 更新路径的统一请求构造：固定方法、超时、UA 与 Accept。
    ///
    /// 三条通道（GitHub API、校验和、appcast）以前各自写一份，漏一处就会让某条
    /// 通道带着不同的请求头/超时出去；收在一处后 `User-Agent` 与超时只有一份来源。
    private nonisolated static func updateRequest(url: URL, accept: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = UpdateChecker.requestTimeout
        request.setValue(accept, forHTTPHeaderField: "Accept")
        request.setValue(UpdateCheckIdentity.current.userAgent, forHTTPHeaderField: "User-Agent")
        return request
    }

    /// 两条通道的共同出口：资产与校验值都到手后，创建安装器接管下载与替换。
    private nonisolated func beginDesktopAppUpdateDownload(
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
                self.abortUpdateFlow("桌面应用未更新：已有安装器在跑")
                return
            }
            guard self.desktopAppUpdateRound.markInstalling(releaseTag: releaseTag) else {
                // 这一轮已被取消或已被新一轮顶掉：不要再开一个安装器。
                self.finishDesktopAppUpdateRound(releaseTag: releaseTag)
                self.abortUpdateFlow("桌面应用未更新：这一轮已被取消")
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

    /// “更新 → 检查更新…”：忽略 TTL 立即检查，结果回来后展示可执行的统一确认框
    /// （见 `presentUpdateFlow(manual:)`）。关闭的分类不会因为手动点击而发起请求。
    @objc func checkForUpdatesNow(_ sender: Any?) {
        guard let updateChecker else { return }
        pendingManualUpdateCheck = true
        updateCheckInProgress = true
        refreshUpdateMenuState()
        updateChecker.checkNow(triggeredBy: .manual)
    }

    /// 策略变更的统一入口：写 UserDefaults、让调度器重建计时器、刷新界面。
    private func applyUpdatePreferences(_ preferences: UpdateCheckPreferences) {
        appConfiguration.save(preferences)
        updateChecker?.preferences = preferences
        refreshUpdateMenuState()
        syncUpdateSettingsWindow()
    }

    /// “更新 → 更新设置…”：策略、每类状态、忽略版本与 alpha.3 预留位。
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
            piCLIStatus: piCLIStatusBlockText(compact: true),
            piPackageStatus: piPackageStatusBlockText(compact: true),
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

    /// “更新”菜单的子项：检查、设置、记录。四类组件共用同一条流程，因此不再
    /// 需要每个组件一个入口、也不再需要把策略开关塞进菜单。
    func appendUpdateMenuItems(to menu: NSMenu) {
        let checkItem = NSMenuItem(
            title: "检查更新…",
            action: #selector(checkForUpdatesNow(_:)),
            keyEquivalent: ""
        )
        checkItem.target = self
        updateCheckMenuItem = checkItem
        menu.addItem(checkItem)
        let preferencesItem = NSMenuItem(
            title: "更新设置…",
            action: #selector(showUpdatePreferences(_:)),
            keyEquivalent: ""
        )
        preferencesItem.target = self
        menu.addItem(preferencesItem)
        let historyItem = NSMenuItem(
            title: "更新记录…",
            action: #selector(showUpdateHistory(_:)),
            keyEquivalent: ""
        )
        historyItem.target = self
        menu.addItem(historyItem)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        if remoteAccessMenus.contains(where: { $0 === menu }) {
            rebuildRemoteAccessMenu(menu)
        } else if menu === updateMenu {
            refreshUpdateMenuState()
        }
    }

    func refreshUpdateMenuState() {
        updateStatusMenuItem?.title = updateCheckStatusText()
        // 检查中或更新进行中都不允许再开一轮：否则会并行跑两条安装命令。
        updateCheckMenuItem?.isEnabled = !updateCheckInProgress && updateFlowRun == nil
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

    /// 检查结果落地（主线程）：刷新菜单与窗口，然后交给统一流程。
    ///
    /// 手动检查一律给出可执行的对话框；自动检查只执行用户已经打开“自动更新”的
    /// 组件——过去那条“发现 N 项可用更新”的空提醒就是在这里弹出来的。
    func handleUpdateCheckResults(_ summary: UpdateCheckSummary) {
        updateCheckInProgress = false
        refreshUpdateMenuState()
        syncUpdateSettingsWindow()
        diagnosticsWindowController?.refreshUpdateStatus()
        prefetchDesktopUpdateIfAvailable(summary)
        let manual = pendingManualUpdateCheck
        pendingManualUpdateCheck = false
        presentUpdateFlow(manual: manual)
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
            DispatchQueue.main.async { [self] in
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

}

/// Checksummed assets use a dedicated session so the redirect policy cannot be toggled
/// while an unrelated archive download is in flight.
///
/// 重定向闸控：只有目标 URL 通过调用方给的判定才跟随。校验和下载与 appcast 用的
/// 是同一条策略实现（差别只在判定函数），因此不会出现两份几乎相同的委托各自漂移。
/// `@unchecked Sendable`：`URLSessionTaskDelegate` 在 SDK 里要求 `Sendable`，而本类
/// 持有的 `allows` 是闭包（函数类型本身不是 `Sendable`）。闭包是不可变的 `let`，且
/// 只做一次纯判定（不碰任何共享可变状态），所以并发调用它本身是安全的。
private final class AllowlistRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    /// 判定目标 URL 是否允许跟随；`URL?` 入参是因为 `URLRequest.url` 本身可空，
    /// 拿不到 URL 时必须拒绝而不是放行。
    private let allows: (URL?) -> Bool

    init(allows: @escaping (URL?) -> Bool) {
        self.allows = allows
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(allows(request.url) ? request : nil)
    }
}
