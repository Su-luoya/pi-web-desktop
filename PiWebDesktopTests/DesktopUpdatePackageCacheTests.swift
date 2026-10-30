import XCTest

/// 预下载缓存（GitHub #230）：检查发现新版本后先在后台下好，点“更新”时不再等下载。
final class DesktopUpdatePackageCacheTests: XCTestCase {
    private var root: URL!
    private var fileManager: FileManager!

    override func setUpWithError() throws {
        try super.setUpWithError()
        fileManager = .default
        root = fileManager.temporaryDirectory.appendingPathComponent("cache-test-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fileManager.removeItem(at: root)
        try super.tearDownWithError()
    }

    private func cache() -> DesktopUpdatePackageCache {
        DesktopUpdatePackageCache(directory: root.appendingPathComponent("cache", isDirectory: true))
    }

    private func asset(
        version: String = "0.1.0-alpha.27",
        tag: String = "v0.1.0-alpha.27",
        name: String = "Pi-Web-Desktop-0.1.0-alpha.27+build.5.zip",
        sha256: String? = String(repeating: "a", count: 64)
    ) -> DesktopAppReleaseAsset {
        DesktopAppReleaseAsset(
            version: version,
            downloadURL: URL(string: "https://github.com/Su-luoya/pi-web-desktop/releases/download/\(tag)/\(name)")!,
            sha256: sha256,
            releaseTag: tag,
            assetName: name
        )
    }

    private func downloadedFile(contents: String = "zip-bytes") throws -> URL {
        let url = root.appendingPathComponent("download-\(UUID().uuidString).zip")
        try Data(contents.utf8).write(to: url)
        return url
    }

    func testStoresPackageAndReturnsItForTheSameVersionAndTag() throws {
        let cache = cache()
        let stored = try cache.store(archiveAt: try downloadedFile(), asset: asset())

        XCTAssertEqual(stored.version, "0.1.0-alpha.27")
        XCTAssertEqual(stored.releaseTag, "v0.1.0-alpha.27")
        XCTAssertTrue(fileManager.fileExists(atPath: stored.archiveURL.path))

        let hit = cache.package(matching: "0.1.0-alpha.27", releaseTag: "v0.1.0-alpha.27")
        XCTAssertEqual(hit?.archiveURL, stored.archiveURL)
        XCTAssertEqual(hit?.sha256, String(repeating: "a", count: 64))
    }

    func testMissesForAnotherVersionOrTag() throws {
        let cache = cache()
        _ = try cache.store(archiveAt: try downloadedFile(), asset: asset())

        XCTAssertNil(cache.package(matching: "0.1.0-alpha.26", releaseTag: "v0.1.0-alpha.27"))
        XCTAssertNil(cache.package(matching: "0.1.0-alpha.27", releaseTag: "v0.1.0-alpha.26"))
    }

    func testKeepsOnlyTheLatestArchive() throws {
        let cache = cache()
        _ = try cache.store(archiveAt: try downloadedFile(contents: "old"), asset: asset())
        let latest = try cache.store(
            archiveAt: try downloadedFile(contents: "new"),
            asset: asset(
                version: "0.1.0-alpha.28",
                tag: "v0.1.0-alpha.28",
                name: "Pi-Web-Desktop-0.1.0-alpha.28+build.6.zip"
            )
        )

        let entries = try fileManager.contentsOfDirectory(atPath: root.appendingPathComponent("cache").path)
        XCTAssertEqual(Set(entries), Set([latest.archiveName, "package.json"]))
        XCTAssertNil(cache.package(matching: "0.1.0-alpha.27", releaseTag: "v0.1.0-alpha.27"))
        XCTAssertNotNil(cache.package(matching: "0.1.0-alpha.28", releaseTag: "v0.1.0-alpha.28"))
    }

    func testRefusesAssetWithoutPinnedFields() throws {
        let cache = cache()
        XCTAssertThrowsError(try cache.store(archiveAt: try downloadedFile(), asset: asset(sha256: nil)))
        XCTAssertThrowsError(
            try cache.store(
                archiveAt: try downloadedFile(),
                asset: DesktopAppReleaseAsset(
                    version: "0.1.0-alpha.27",
                    downloadURL: URL(string: "https://example.com/x.zip")!,
                    sha256: String(repeating: "a", count: 64),
                    releaseTag: nil,
                    assetName: nil
                )
            )
        )
    }

    /// 缓存目录是用户可写的：写进去之后再被改掉，安装时必须重新下载而不是装坏包。
    func testCachedArchiveIsRejectedWhenBytesNoLongerMatch() throws {
        let cache = cache()
        let stored = try cache.store(archiveAt: try downloadedFile(), asset: asset())
        let expected = String(repeating: "a", count: 64)

        XCTAssertEqual(
            DesktopAppUpdateInstaller.cachedArchive(
                for: asset(), expectedHash: expected, packageCache: cache,
                verify: { _ in expected }
            ),
            stored.archiveURL
        )
        XCTAssertNil(
            DesktopAppUpdateInstaller.cachedArchive(
                for: asset(), expectedHash: expected, packageCache: cache,
                verify: { _ in String(repeating: "b", count: 64) }
            )
        )
        XCTAssertNil(
            DesktopAppUpdateInstaller.cachedArchive(
                for: asset(), expectedHash: expected, packageCache: cache,
                verify: { _ in nil }
            )
        )
    }

    func testRemovesEverythingOnDemand() throws {
        let cache = cache()
        _ = try cache.store(archiveAt: try downloadedFile(), asset: asset())
        cache.removeAll()
        XCTAssertNil(cache.package(matching: "0.1.0-alpha.27", releaseTag: "v0.1.0-alpha.27"))
    }

    /// 预下载只接受钉在 releases/download/<tag>/ 下的地址；不合规直接放弃，不发请求。
    func testPrefetchRejectsUnpinnedAssetWithoutDownloading() {
        let installer = DesktopAppUpdateInstaller(
            applicationURL: root.appendingPathComponent("Pi-Web-Desktop.app", isDirectory: true),
            packageCache: cache()
        )
        let bogus = DesktopAppReleaseAsset(
            version: "0.1.0-alpha.27",
            downloadURL: URL(string: "https://example.com/Pi-Web-Desktop-0.1.0-alpha.27.zip")!,
            sha256: String(repeating: "a", count: 64),
            releaseTag: "v0.1.0-alpha.27",
            assetName: "Pi-Web-Desktop-0.1.0-alpha.27+build.5.zip"
        )
        let done = expectation(description: "prefetch")
        installer.prefetch(asset: bogus) { stored in
            XCTAssertFalse(stored)
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
    }
}
