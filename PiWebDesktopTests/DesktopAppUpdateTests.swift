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
}
