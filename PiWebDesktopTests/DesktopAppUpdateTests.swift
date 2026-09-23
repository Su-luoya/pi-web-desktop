import XCTest

final class DesktopAppUpdateTests: XCTestCase {
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

    func testRejectsNonGitHubZipAndMalformedChecksum() {
        XCTAssertNil(DesktopAppReleaseAssetSelector.select(
            version: "2.5.0",
            assets: [(name: "Pi-Web-Desktop-2.5.0.zip", url: URL(string: "https://evil.example/update.zip")!)],
            checksum: String(repeating: "a", count: 64)
        ))
        XCTAssertNil(DesktopAppReleaseAssetSelector.normalizedChecksum("not-a-sha256"))
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
}
