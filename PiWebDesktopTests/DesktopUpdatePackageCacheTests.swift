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
        version: String = "1.2.3",
        tag: String = "v1.2.3",
        name: String = "Pi-Web-Desktop-1.2.3+build.5.zip",
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

        XCTAssertEqual(stored.version, "1.2.3")
        XCTAssertEqual(stored.releaseTag, "v1.2.3")
        XCTAssertTrue(fileManager.fileExists(atPath: stored.archiveURL.path))

        let hit = cache.package(matching: "1.2.3", releaseTag: "v1.2.3")
        XCTAssertEqual(hit?.archiveURL, stored.archiveURL)
        XCTAssertEqual(hit?.sha256, String(repeating: "a", count: 64))
    }

    func testMissesForAnotherVersionOrTag() throws {
        let cache = cache()
        _ = try cache.store(archiveAt: try downloadedFile(), asset: asset())

        XCTAssertNil(cache.package(matching: "1.2.2", releaseTag: "v1.2.3"))
        XCTAssertNil(cache.package(matching: "1.2.3", releaseTag: "v1.2.2"))
    }

    func testKeepsOnlyTheLatestArchive() throws {
        let cache = cache()
        _ = try cache.store(archiveAt: try downloadedFile(contents: "old"), asset: asset())
        let latest = try cache.store(
            archiveAt: try downloadedFile(contents: "new"),
            asset: asset(
                version: "1.2.4",
                tag: "v1.2.4",
                name: "Pi-Web-Desktop-1.2.4+build.6.zip"
            )
        )

        let entries = try fileManager.contentsOfDirectory(atPath: root.appendingPathComponent("cache").path)
        XCTAssertEqual(Set(entries), Set([latest.archiveName, "package.json"]))
        XCTAssertNil(cache.package(matching: "1.2.3", releaseTag: "v1.2.3"))
        XCTAssertNotNil(cache.package(matching: "1.2.4", releaseTag: "v1.2.4"))
    }

    func testRefusesAssetWithoutPinnedFields() throws {
        let cache = cache()
        XCTAssertThrowsError(try cache.store(archiveAt: try downloadedFile(), asset: asset(sha256: nil)))
        XCTAssertThrowsError(
            try cache.store(
                archiveAt: try downloadedFile(),
                asset: DesktopAppReleaseAsset(
                    version: "1.2.3",
                    downloadURL: URL(string: "https://example.com/x.zip")!,
                    sha256: String(repeating: "a", count: 64),
                    releaseTag: nil,
                    assetName: nil
                )
            )
        )
    }

    func testRejectsMetadataPointingOutsideCache() throws {
        let cache = cache()
        let stored = try cache.store(archiveAt: try downloadedFile(), asset: asset())
        let outside = root.appendingPathComponent(stored.archiveName)
        try fileManager.moveItem(at: stored.archiveURL, to: outside)
        let metadata = DesktopUpdatePackageCache.Metadata(
            version: stored.version, releaseTag: stored.releaseTag,
            archiveName: "../" + stored.archiveName, sha256: stored.sha256,
            downloadedAt: stored.downloadedAt
        )
        try JSONEncoder().encode(metadata).write(to: root.appendingPathComponent("cache/package.json"))

        XCTAssertNil(cache.package(matching: stored.version, releaseTag: stored.releaseTag))
        XCTAssertTrue(fileManager.fileExists(atPath: outside.path))
    }

    func testRejectsArchiveSymlinkAndDirectory() throws {
        let cache = cache()
        let stored = try cache.store(archiveAt: try downloadedFile(), asset: asset())
        let outside = root.appendingPathComponent(stored.archiveName)
        try fileManager.moveItem(at: stored.archiveURL, to: outside)
        try fileManager.createSymbolicLink(at: stored.archiveURL, withDestinationURL: outside)
        XCTAssertNil(cache.package(matching: stored.version, releaseTag: stored.releaseTag))

        try fileManager.removeItem(at: stored.archiveURL)
        try fileManager.createDirectory(at: stored.archiveURL, withIntermediateDirectories: false)
        XCTAssertNil(cache.package(matching: stored.version, releaseTag: stored.releaseTag))
    }

    func testRejectsUnsafeArchiveNameBeforeChangingFiles() throws {
        let cache = cache()
        let stored = try cache.store(archiveAt: try downloadedFile(contents: "old"), asset: asset())
        let outside = root.appendingPathComponent(stored.archiveName)
        try Data("keep".utf8).write(to: outside)
        let download = try downloadedFile()
        XCTAssertThrowsError(try cache.store(archiveAt: download, asset: asset(name: "../" + stored.archiveName)))
        XCTAssertEqual(try String(contentsOf: outside, encoding: .utf8), "keep")
        XCTAssertTrue(fileManager.fileExists(atPath: download.path))
        XCTAssertNotNil(cache.package(matching: stored.version, releaseTag: stored.releaseTag))
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
        XCTAssertNil(cache.package(matching: "1.2.3", releaseTag: "v1.2.3"))
    }

    /// 预下载只接受钉在 releases/download/<tag>/ 下的地址；不合规直接放弃，不发请求。
    func testPrefetchRejectsUnpinnedAssetWithoutDownloading() {
        let installer = DesktopAppUpdateInstaller(
            applicationURL: root.appendingPathComponent("Pi-Web-Desktop.app", isDirectory: true),
            packageCache: cache()
        )
        let bogus = DesktopAppReleaseAsset(
            version: "1.2.3",
            downloadURL: URL(string: "https://example.com/Pi-Web-Desktop-1.2.3.zip")!,
            sha256: String(repeating: "a", count: 64),
            releaseTag: "v1.2.3",
            assetName: "Pi-Web-Desktop-1.2.3+build.5.zip"
        )
        let done = expectation(description: "prefetch")
        installer.prefetch(asset: bogus) { stored in
            XCTAssertFalse(stored)
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
    }
}
