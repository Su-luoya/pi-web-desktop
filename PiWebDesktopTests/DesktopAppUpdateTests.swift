import XCTest

final class DesktopAppUpdateTests: XCTestCase {
    func testDesktopAppDownloadResourceTimeoutAllowsLargeArchives() {
        XCTAssertGreaterThan(DesktopAppUpdateInstaller.downloadResourceTimeout, UpdateChecker.requestTimeout)
    }

    func testSelectsOnlyPinnedGitHubZipAndValidChecksum() {
        let archiveName = "Pi-Web-Desktop-2.5.0+build.42.zip"
        let archiveURL = URL(string: "https://github.com/Su-luoya/pi-web-desktop/releases/download/v2.5.0/Pi-Web-Desktop-2.5.0%2Bbuild.42.zip")!
        let checksumURL = URL(string: "https://github.com/Su-luoya/pi-web-desktop/releases/download/v2.5.0/Pi-Web-Desktop-2.5.0%2Bbuild.42.zip.sha256")!
        let checksum = String(repeating: "A", count: 64)
        let asset = DesktopAppReleaseAssetSelector.select(
            version: "2.5.0",
            assets: [(name: archiveName, url: archiveURL)],
            checksum: checksum,
            releaseTag: "v2.5.0"
        )
        XCTAssertEqual(asset?.downloadURL, archiveURL)
        XCTAssertEqual(asset?.sha256, checksum.lowercased())
        XCTAssertEqual(asset?.releaseTag, "v2.5.0")
        XCTAssertEqual(asset?.assetName, archiveName)
        XCTAssertTrue(DesktopAppReleaseAssetSelector.allowsDownloadURL(archiveURL, assetName: archiveName, releaseTag: "v2.5.0"))
        XCTAssertTrue(DesktopAppReleaseAssetSelector.allowsChecksumDownloadURL(checksumURL, assetName: "\(archiveName).sha256", releaseTag: "v2.5.0"))
        XCTAssertTrue(DesktopAppReleaseAssetSelector.isReleaseTag("v2.5.0"))
        XCTAssertFalse(DesktopAppReleaseAssetSelector.isReleaseTag("v2/5.0"))
        XCTAssertTrue(DesktopAppReleaseAssetSelector.isArchiveName(archiveName, version: "2.5.0"))
        XCTAssertFalse(DesktopAppReleaseAssetSelector.isArchiveName("Pi-Web-Desktop-2.5.0+build.zip", version: "2.5.0"))
        XCTAssertTrue(DesktopAppReleaseAssetSelector.allowsAssetRedirect(URL(string: "https://release-assets.githubusercontent.com/download/asset.zip?sig=opaque")!))
        XCTAssertFalse(DesktopAppReleaseAssetSelector.allowsAssetRedirect(URL(string: "https://attacker.example/Pi-Web-Desktop.zip")!))
        XCTAssertTrue(DesktopAppReleaseAssetSelector.allowsChecksumRedirect(URL(string: "https://release-assets.githubusercontent.com/download/asset.sha256?sig=opaque")!))
        XCTAssertFalse(DesktopAppReleaseAssetSelector.allowsChecksumRedirect(URL(string: "https://release-assets.githubusercontent.com/download/asset.zip?sig=opaque")!))
        XCTAssertFalse(DesktopAppReleaseAssetSelector.allowsDownloadURL(
            URL(string: "https://github.com/Su-luoya/pi-web-desktop/releases/download/v2.5.0/other.zip")!,
            assetName: archiveName,
            releaseTag: "v2.5.0"
        ))
    }

    func testAllowsOnlyTheInstalledApplicationsBundle() {
        // 形状校验不依赖运行机状态：父目录必须是 Applications，名字必须精确
        XCTAssertFalse(DesktopAppUpdateInstaller.canReplaceInstalledApp(URL(fileURLWithPath: "/Applications/Tools/Pi-Web-Desktop.app", isDirectory: true)))
        XCTAssertFalse(DesktopAppUpdateInstaller.canReplaceInstalledApp(URL(fileURLWithPath: "/Applications/Pi-Web-Desktop.app/Contents/../Pi-Web-Desktop.app")))
        XCTAssertFalse(DesktopAppUpdateInstaller.canReplaceInstalledApp(URL(fileURLWithPath: "/Applications/Pi-Web-Desktop.app-copy")))
        XCTAssertFalse(DesktopAppUpdateInstaller.canReplaceInstalledApp(URL(fileURLWithPath: "/Applications/Utilities/Pi-Web-Desktop.app")))
        XCTAssertFalse(DesktopAppUpdateInstaller.canReplaceInstalledApp(URL(fileURLWithPath: "/tmp/Pi-Web-Desktop.app")))

        // 真实 bundle 的三类判定用注入的根目录验证，不要求运行机装了 App
        let fileManager = FileManager.default
        let temporary = fileManager.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? fileManager.removeItem(at: temporary) }
        let external = temporary.appendingPathComponent("external.app", isDirectory: true)
        try! fileManager.createDirectory(at: external.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        try! Data().write(to: external.appendingPathComponent("Contents/Info.plist"))
        func applicationsRoot(_ name: String, withInfoPlist: Bool) -> URL {
            let root = temporary.appendingPathComponent(name, isDirectory: true)
            let contents = root.appendingPathComponent("Pi-Web-Desktop.app/Contents", isDirectory: true)
            try! fileManager.createDirectory(at: contents, withIntermediateDirectories: true)
            if withInfoPlist { try! Data().write(to: contents.appendingPathComponent("Info.plist")) }
            return root
        }
        let applications = applicationsRoot("Applications", withInfoPlist: true)
        let installed = applications.appendingPathComponent("Pi-Web-Desktop.app", isDirectory: true)
        XCTAssertTrue(DesktopAppUpdateInstaller.canReplaceInstalledApp(installed, applicationsRoot: applications))
        XCTAssertTrue(DesktopAppUpdateInstaller.canReplaceInstalledApp(URL(fileURLWithPath: installed.path + "/"), applicationsRoot: applications))
        XCTAssertFalse(DesktopAppUpdateInstaller.canReplaceInstalledApp(applications.appendingPathComponent("Pi-Web-Desktop.app/Contents/../Pi-Web-Desktop.app"), applicationsRoot: applications))
        XCTAssertFalse(DesktopAppUpdateInstaller.canReplaceInstalledApp(applications.appendingPathComponent("Tools/Pi-Web-Desktop.app", isDirectory: true), applicationsRoot: applications))

        let withoutInfoPlist = applicationsRoot("NoInfo", withInfoPlist: false)
        XCTAssertFalse(DesktopAppUpdateInstaller.canReplaceInstalledApp(withoutInfoPlist.appendingPathComponent("Pi-Web-Desktop.app", isDirectory: true), applicationsRoot: withoutInfoPlist))

        let symlinked = temporary.appendingPathComponent("Symlinked", isDirectory: true)
        try! fileManager.createDirectory(at: symlinked, withIntermediateDirectories: true)
        try! fileManager.createSymbolicLink(at: symlinked.appendingPathComponent("Pi-Web-Desktop.app", isDirectory: true), withDestinationURL: external)
        XCTAssertFalse(DesktopAppUpdateInstaller.canReplaceInstalledApp(symlinked.appendingPathComponent("Pi-Web-Desktop.app", isDirectory: true), applicationsRoot: symlinked))
    }

    /// 更新包自带的最低系统高于本机时不得安装。
    /// 版本值取与项目自身无关的数字，并显式注入 `running`：不依赖运行机的系统版本。
    func testRejectsCandidateRequiringNewerSystem() {
        let fileManager = FileManager.default
        let temporary = fileManager.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? fileManager.removeItem(at: temporary) }

        func bundle(named name: String, minimumSystem: String?) -> URL {
            let app = temporary.appendingPathComponent("\(name).app", isDirectory: true)
            let contents = app.appendingPathComponent("Contents", isDirectory: true)
            try! fileManager.createDirectory(at: contents, withIntermediateDirectories: true)
            var plist: [String: Any] = ["CFBundleIdentifier": "io.github.su-luoya.pi-web-desktop"]
            if let minimumSystem { plist["LSMinimumSystemVersion"] = minimumSystem }
            let data = try! PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            try! data.write(to: contents.appendingPathComponent("Info.plist"))
            return app
        }

        let older = OperatingSystemVersion(majorVersion: 2, minorVersion: 4, patchVersion: 0)
        // 候选要求 2.5，本机是 2.4：拒绝。
        XCTAssertFalse(DesktopAppUpdateInstaller.requiresNoNewerSystem(bundle(named: "TooNew", minimumSystem: "2.5.0"), running: older))
        // 候选要求 2.4 / 2.3：放行。
        XCTAssertTrue(DesktopAppUpdateInstaller.requiresNoNewerSystem(bundle(named: "Equal", minimumSystem: "2.4.0"), running: older))
        XCTAssertTrue(DesktopAppUpdateInstaller.requiresNoNewerSystem(bundle(named: "Older", minimumSystem: "2.3.0"), running: older))
        // 缺这个键视为放行：本轮之前的包都没有被当作门槛使用过。
        XCTAssertTrue(DesktopAppUpdateInstaller.requiresNoNewerSystem(bundle(named: "Missing", minimumSystem: nil), running: older))
        // 无法解析的声明按「缺键」处理（放行）：真正的闸门是 isValidBundle 与 sha256。
        XCTAssertTrue(DesktopAppUpdateInstaller.requiresNoNewerSystem(bundle(named: "Garbage", minimumSystem: "not-a-version"), running: older))
    }

    /// 校验值比对的真实行为：下载到的字节与 GitHub 公布的 SHA-256 不一致时必须判不等，
    /// 相等时必须判相等。alpha.18 的发布验证里试过用改 Release 资产的方式在真机上
    /// 构造这个失败，结果被 CDN 缓存挡住（详见 Docs/alpha-release-checklist.md），
    /// 所以这条路径的保证只能落在测试上。
    func testSha256DetectsMismatchedDownloadBytes() throws {
        let fileManager = FileManager.default
        let file = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fileManager.removeItem(at: file) }
        try Data("hello pi web desktop".utf8).write(to: file)

        let actual = try DesktopAppUpdateInstaller.sha256(of: file)
        XCTAssertEqual(actual, "6f72aa83223c5151e74d92a27b61b4403017e5591e655937e7d3104f50f37d56")
        XCTAssertEqual(actual.count, 64)

        // 全 0 的“公布值”必须与真实摘要不符，且两者都能被 normalizedChecksum 接受。
        let published = String(repeating: "0", count: 64)
        XCTAssertEqual(DesktopAppReleaseAssetSelector.normalizedChecksum(published), published)
        XCTAssertNotEqual(actual, DesktopAppReleaseAssetSelector.normalizedChecksum(published))

        // 改一个字节就必须换一个摘要，否则比对本身失效。
        try Data("hello pi web desktop!".utf8).write(to: file)
        XCTAssertNotEqual(try DesktopAppUpdateInstaller.sha256(of: file), actual)

        // 失败文案是用户唯一能看到的信号，不能改。
        XCTAssertEqual(DesktopAppUpdateFailure.checksumMismatch.text, "更新包校验失败，已停止安装。")
    }

    func testRejectsNonGitHubZipAndMalformedChecksum() {
        XCTAssertNil(DesktopAppReleaseAssetSelector.select(
            version: "2.5.0",
            assets: [(name: "Pi-Web-Desktop-2.5.0.zip", url: URL(string: "https://evil.example/update.zip")!)],
            checksum: String(repeating: "a", count: 64)
        ))
        XCTAssertNil(DesktopAppReleaseAssetSelector.normalizedChecksum("not-a-sha256"))
    }

    /// GitHub 的未认证 API 限流（403 + `x-ratelimit-remaining: 0`）必须与真正的
    /// 下载失败分开：前者等一会儿就能好，后者不能。否则用户只看到「更新包下载
    /// 失败」，既不知道原因也不知道该不该重试（GitHub #225）。
    func testReleasePageFailureSeparatesRateLimitFromDownloadFailure() {
        XCTAssertEqual(
            DesktopAppUpdateFailure.releasePageFailure(status: 403, rateLimitRemaining: "0"),
            .rateLimited
        )
        XCTAssertEqual(
            DesktopAppUpdateFailure.releasePageFailure(status: 429, rateLimitRemaining: nil),
            .rateLimited
        )
        // 真正的禁止访问（剩余额度不为 0）与 5xx / 无响应仍按下载失败处理。
        XCTAssertEqual(
            DesktopAppUpdateFailure.releasePageFailure(status: 403, rateLimitRemaining: "12"),
            .downloadFailed
        )
        XCTAssertEqual(
            DesktopAppUpdateFailure.releasePageFailure(status: 500, rateLimitRemaining: nil),
            .downloadFailed
        )
        XCTAssertEqual(
            DesktopAppUpdateFailure.releasePageFailure(status: nil, rateLimitRemaining: nil),
            .downloadFailed
        )
        // 文案必须给出可执行的下一步，不能只说「失败」。
        XCTAssertTrue(DesktopAppUpdateFailure.rateLimited.text.contains("60"))
        XCTAssertTrue(DesktopAppUpdateFailure.rateLimited.text.contains("重试"))
    }

    /// 人工更新流程的准入：网络往返成功就够（含 304 重验证的缓存版本值），但要有
    /// 可联网复核的 tag，且目标版本必须比正在运行的版本新。（版本字符串用与项目自身
    /// 无关的值：check-identity.sh 禁止本机 MARKETING_VERSION 出现在源码里。）
    func testInstallPolicyAcceptsRevalidatedCacheOnlyForANewerTarget() {
        func check(
            status: UpdateCheckStatus = .updateAvailable,
            latest: String? = "1.2.4",
            tag: String? = "v1.2.4",
            confidence: DetectionConfidence = .verified,
            freshness: UpdateResultFreshness = .fresh,
            origin: UpdateCheckOrigin = .cachedFallback
        ) -> UpdateCheckResult {
            UpdateCheckResult(
                target: UpdateCheckTarget(category: .desktopApp, packageName: nil),
                status: status,
                installedVersion: "1.2.3",
                latestVersion: latest,
                upstreamTag: tag,
                confidence: confidence,
                freshness: freshness,
                failure: nil,
                httpStatusCode: origin == .cachedFallback ? 304 : 200,
                checkedAt: nil,
                lastSuccessAt: nil,
                origin: origin
            )
        }
        let running = "1.2.3"

        // 304：本次网络往返成功、版本值来自缓存文件 —— 人工流程允许
        XCTAssertEqual(
            DesktopAppUpdateInstallPolicy.installTarget(for: check(), runningVersion: running),
            DesktopAppUpdateInstallTarget(version: "1.2.4", releaseTag: "v1.2.4")
        )
        // 本次网络结果（200）照旧通过
        XCTAssertNotNil(DesktopAppUpdateInstallPolicy.installTarget(
            for: check(origin: .network), runningVersion: running
        ))
        // 网络失败沿用的缓存结论不是本轮确认过的，不能进安装流程
        XCTAssertNil(DesktopAppUpdateInstallPolicy.installTarget(
            for: check(freshness: .cached), runningVersion: running
        ))
        // 上游结构未验证的结论不能进安装流程
        XCTAssertNil(DesktopAppUpdateInstallPolicy.installTarget(
            for: check(confidence: .unknown), runningVersion: running
        ))
        // 没有 tag 就没有可联网复核的发布
        XCTAssertNil(DesktopAppUpdateInstallPolicy.installTarget(
            for: check(tag: nil), runningVersion: running
        ))
        // 改写缓存让目标版本不比当前版本新：拒绝降级与平级重装
        XCTAssertNil(DesktopAppUpdateInstallPolicy.installTarget(
            for: check(latest: "1.2.2", tag: "v1.2.2"), runningVersion: running
        ))
        XCTAssertNil(DesktopAppUpdateInstallPolicy.installTarget(
            for: check(), runningVersion: "1.2.4"
        ))
        // 本机版本读不到、或根本没有结论时都不安装
        XCTAssertNil(DesktopAppUpdateInstallPolicy.installTarget(for: check(), runningVersion: nil))
        XCTAssertNil(DesktopAppUpdateInstallPolicy.installTarget(for: nil, runningVersion: running))
    }

    /// 真实签名直链把资产名放在查询串里，路径是 `…/github-production-release-asset/<id>/<uuid>`
    /// ——只看 url.pathExtension 会把 GitHub 自己的重定向判成非法（GitHub #177）。
    func testRedirectValidationAcceptsGitHubSignedAssetURLs() {
        let asset = "Pi-Web-Desktop-1.2.4+build.7.zip"
        let signedZip = URL(string: "https://release-assets.githubusercontent.com/github-production-release-asset/1/2"
            + "?sp=r&rscd=attachment%3B+filename%3D\(asset)&response-content-disposition=attachment%3B%20filename%3D\(asset)&sig=opaque")!
        let signedChecksum = URL(string: "https://release-assets.githubusercontent.com/github-production-release-asset/1/2"
            + "?sp=r&rscd=attachment%3B+filename%3D\(asset).sha256&response-content-disposition=attachment%3B%20filename%3D\(asset).sha256&sig=opaque")!

        XCTAssertTrue(DesktopAppReleaseAssetSelector.allowsAssetRedirect(signedZip))
        XCTAssertTrue(DesktopAppReleaseAssetSelector.allowsChecksumRedirect(signedChecksum))
        XCTAssertEqual(DesktopAppReleaseAssetSelector.signedFileName(in: signedZip), asset)
        // 资产类型必须对得上，不能把校验值当安装包、也不能反过来
        XCTAssertFalse(DesktopAppReleaseAssetSelector.allowsChecksumRedirect(signedZip))
        XCTAssertFalse(DesktopAppReleaseAssetSelector.allowsAssetRedirect(signedChecksum))
        // 签名直链里声明的文件名后缀不对（例如被换成别的类型）、或主机不在白名单
        XCTAssertFalse(DesktopAppReleaseAssetSelector.allowsAssetRedirect(URL(string:
            "https://release-assets.githubusercontent.com/a/b?response-content-disposition=attachment%3B%20filename%3Dsetup.dmg")!))
        XCTAssertFalse(DesktopAppReleaseAssetSelector.allowsAssetRedirect(URL(string:
            "https://attacker.example/a/b?response-content-disposition=attachment%3B%20filename%3D\(asset)")!))
        // 既没有可读的 filename、路径又没有扩展名：保持拒绝
        XCTAssertFalse(DesktopAppReleaseAssetSelector.allowsAssetRedirect(URL(string:
            "https://release-assets.githubusercontent.com/github-production-release-asset/1/2?sig=opaque")!))
        XCTAssertNil(DesktopAppReleaseAssetSelector.signedFileName(in: URL(string:
            "https://release-assets.githubusercontent.com/a/b?sig=opaque")!))
    }

    // MARK: - 入口闸控与轮次归属（outD-2）

    /// 旧实现只用 `desktopAppUpdateInstaller == nil` 当闸控，安装器对象要到「发布页 +
    /// 资产 + .sha256 全都核对完」才创建，整个下载窗口期菜单仍可点，重复点击会再
    /// 下一遍整包。这里锁住：确认框、联网核对、安装三个阶段都算「在跑」。
    func testEntryStaysBlockedThroughTheWholeUpdateRound() {
        var round = DesktopAppUpdateRound()
        XCTAssertFalse(round.isBusy)
        XCTAssertTrue(DesktopAppUpdateEntryPolicy.isEntryEnabled(
            installable: true, activity: round.activity, installerPresent: false
        ))

        XCTAssertTrue(round.beginConfirming(releaseTag: "v2.5.0"))
        XCTAssertTrue(round.isBusy)
        XCTAssertFalse(DesktopAppUpdateEntryPolicy.isEntryEnabled(
            installable: true, activity: round.activity, installerPresent: false
        ))

        XCTAssertTrue(round.beginResolving(releaseTag: "v2.5.0"))
        XCTAssertTrue(round.isBusy)
        XCTAssertFalse(DesktopAppUpdateEntryPolicy.isEntryEnabled(
            installable: true, activity: round.activity, installerPresent: false
        ))

        // 「刚刚核对完校验值」那段：安装器还没创建，旧实现的闸控在这一瞬间是开的。
        if case .resolvingRelease = round.activity {} else { XCTFail("应在联网核对阶段") }
        XCTAssertFalse(DesktopAppUpdateEntryPolicy.isEntryEnabled(
            installable: true, activity: round.activity, installerPresent: false
        ))

        XCTAssertTrue(round.markInstalling(releaseTag: "v2.5.0"))
        XCTAssertEqual(round.activity, .installing)
        XCTAssertFalse(DesktopAppUpdateEntryPolicy.isEntryEnabled(
            installable: true, activity: round.activity, installerPresent: false
        ))

        XCTAssertTrue(round.finish(releaseTag: "v2.5.0"))
        XCTAssertFalse(round.isBusy)
        XCTAssertNil(round.releaseTag)
        XCTAssertTrue(DesktopAppUpdateEntryPolicy.isEntryEnabled(
            installable: true, activity: round.activity, installerPresent: false
        ))
    }

    /// 确认框本身也占位：否则确认框还开着时再点一次菜单会再弹一个，两个「更新」都
    /// 确认就并行跑两轮下载。
    func testSecondConfirmDialogIsRejectedWhileOneIsOpen() {
        var round = DesktopAppUpdateRound()
        XCTAssertTrue(round.beginConfirming(releaseTag: "v2.5.0"))
        XCTAssertFalse(round.beginConfirming(releaseTag: "v2.5.0"))
        XCTAssertFalse(round.beginConfirming(releaseTag: "v2.6.0"))
        XCTAssertEqual(round.releaseTag, "v2.5.0")
    }

    /// 用户取消确认框、或某个网络请求失败：阶段位必须复位，否则入口永久置灰。
    func testCancellingOrFailingARoundReleasesTheEntry() {
        var round = DesktopAppUpdateRound()
        XCTAssertTrue(round.beginConfirming(releaseTag: "v2.5.0"))
        XCTAssertTrue(round.finish(releaseTag: "v2.5.0"))
        XCTAssertFalse(round.isBusy)
        XCTAssertTrue(DesktopAppUpdateEntryPolicy.isEntryEnabled(
            installable: true, activity: round.activity, installerPresent: false
        ))
        // 空闲时再结束一次不应算作变化（调用方据此避免无谓刷新）
        XCTAssertFalse(round.finish(releaseTag: nil))
    }

    /// 晚到的旧回调不得复位新一轮：否则新一轮在下载中途入口会重新变成可点。
    func testLateCallbackFromAnEarlierRoundCannotReleaseTheNewRound() {
        var round = DesktopAppUpdateRound()
        XCTAssertTrue(round.beginConfirming(releaseTag: "v2.5.0"))
        XCTAssertTrue(round.beginResolving(releaseTag: "v2.5.0"))
        XCTAssertTrue(round.finish(releaseTag: "v2.5.0"))

        XCTAssertTrue(round.beginConfirming(releaseTag: "v2.6.0"))
        XCTAssertTrue(round.beginResolving(releaseTag: "v2.6.0"))
        // 上一轮的网络回调迟到
        XCTAssertFalse(round.finish(releaseTag: "v2.5.0"))
        XCTAssertTrue(round.isBusy)
        XCTAssertEqual(round.releaseTag, "v2.6.0")
    }

    /// 只能按自己那一轮推进：tag 不匹配时既不能开始联网核对、也不能开安装器。
    func testRoundOnlyAdvancesForItsOwnReleaseTag() {
        var round = DesktopAppUpdateRound()
        XCTAssertTrue(round.beginConfirming(releaseTag: "v2.5.0"))
        XCTAssertFalse(round.beginResolving(releaseTag: "v2.6.0"))
        XCTAssertEqual(round.activity, .confirming)
        XCTAssertTrue(round.beginResolving(releaseTag: "v2.5.0"))
        XCTAssertFalse(round.markInstalling(releaseTag: "v2.6.0"))
        XCTAssertEqual(round.activity, .resolvingRelease)
        XCTAssertTrue(round.markInstalling(releaseTag: "v2.5.0"))
        // 已在安装阶段，重复标记不算推进
        XCTAssertFalse(round.markInstalling(releaseTag: "v2.5.0"))
    }

    /// 菜单项：忙时置灰但标题里带可见原因（不静默置灰）；安装器对象单独存在也算忙。
    func testMenuEntryShowsWhyItIsDisabled() {
        XCTAssertNil(DesktopAppUpdateEntryPolicy.menuTitleSuffix(activity: .idle, installerPresent: false))
        XCTAssertEqual(DesktopAppUpdateEntryPolicy.menuTitleSuffix(activity: .confirming, installerPresent: false),
                       "（等待确认）")
        XCTAssertEqual(DesktopAppUpdateEntryPolicy.menuTitleSuffix(activity: .resolvingRelease, installerPresent: false),
                       "（正在下载）")
        XCTAssertEqual(DesktopAppUpdateEntryPolicy.menuTitleSuffix(activity: .installing, installerPresent: false),
                       "（正在安装）")
        // 安装器对象存在但阶段位已复位（回调晚到的那种）：仍按安装中挡住并解释原因。
        XCTAssertEqual(DesktopAppUpdateEntryPolicy.menuTitleSuffix(activity: .idle, installerPresent: true),
                       "（正在安装）")
        XCTAssertTrue(DesktopAppUpdateEntryPolicy.isBusy(activity: .idle, installerPresent: true))
        // 不可安装时一律关（哪怕空闲）
        XCTAssertFalse(DesktopAppUpdateEntryPolicy.isEntryEnabled(
            installable: false, activity: .idle, installerPresent: false
        ))
    }
}
