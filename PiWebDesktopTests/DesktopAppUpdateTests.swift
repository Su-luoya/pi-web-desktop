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
        let expectedAppPath = URL(fileURLWithPath: "/Applications/Pi-Web-Desktop.app", isDirectory: true)
        let insidePath = URL(fileURLWithPath: "/Applications/Tools/Pi-Web-Desktop.app", isDirectory: true)
        XCTAssertTrue(DesktopAppUpdateInstaller.canReplaceInstalledApp(expectedAppPath))
        XCTAssertFalse(DesktopAppUpdateInstaller.canReplaceInstalledApp(insidePath))
        XCTAssertFalse(DesktopAppUpdateInstaller.canReplaceInstalledApp(URL(fileURLWithPath: "/Applications/Pi-Web-Desktop.app/Contents/../Pi-Web-Desktop.app")))
        XCTAssertFalse(DesktopAppUpdateInstaller.canReplaceInstalledApp(URL(fileURLWithPath: "/Applications/Pi-Web-Desktop.app/Contents/../../Other/Pi-Web-Desktop.app")))
        XCTAssertFalse(DesktopAppUpdateInstaller.canReplaceInstalledApp(URL(fileURLWithPath: "/Applications/Pi-Web-Desktop.app-copy")))
        XCTAssertFalse(DesktopAppUpdateInstaller.canReplaceInstalledApp(URL(fileURLWithPath: "/Applications/Utilities/Pi-Web-Desktop.app")))
        XCTAssertFalse(DesktopAppUpdateInstaller.canReplaceInstalledApp(URL(fileURLWithPath: "/tmp/Pi-Web-Desktop.app")))

        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let applications = temporary.appendingPathComponent("Applications", isDirectory: true)
        let bundle = applications.appendingPathComponent("Pi-Web-Desktop.app", isDirectory: true)
        let external = temporary.appendingPathComponent("external.app", isDirectory: true)
        try! FileManager.default.createDirectory(at: bundle.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        try! FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        try! FileManager.default.createSymbolicLink(at: bundle.appendingPathComponent("Contents/link.app"), withDestinationURL: external)
        XCTAssertFalse(DesktopAppUpdateInstaller.canReplaceInstalledApp(bundle.appendingPathComponent("Contents/link.app")))
        XCTAssertFalse(DesktopAppUpdateInstaller.canReplaceInstalledApp(external))
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
