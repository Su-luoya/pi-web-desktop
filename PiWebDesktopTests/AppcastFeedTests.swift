/// 自建 appcast 的解析与信任边界。
///
/// 这份 JSON 由发布 workflow 写进 `appcast` 分支，是桌面更新检查与安装的主端点
/// （GitHub API 只在它不可达时回落）。因此这里的断言分两类：结构解析（坏数据
/// 必须返回 nil 让调用方回落）与信任边界（内容不能把下载引到别的主机）。

import XCTest

final class AppcastFeedTests: XCTestCase {
    private let tag = "v0.2.0-alpha.3"
    private let zipURL = "https://github.com/Su-luoya/pi-web-desktop/releases/download/v0.2.0-alpha.3/Pi-Web-Desktop-0.2.0-alpha.3+build.3.zip"
    private let sha256 = String(repeating: "a1b2", count: 16)

    private func feedBody(
        tag: String? = nil,
        version: String? = nil,
        zip: String? = nil,
        sha256: String? = nil,
        schema: String = "1"
    ) -> String {
        let resolvedTag = tag ?? self.tag
        let resolvedZip = zip ?? """
        {"name":"Pi-Web-Desktop-0.2.0-alpha.3+build.3.zip","url":"\(zipURL)","sha256":"\(sha256 ?? self.sha256)"}
        """
        let resolvedVersion = version ?? "0.2.0-alpha.3"
        return """
        {"schema":\(schema),"releases":[
          {"tag":"\(resolvedTag)","version":"\(resolvedVersion)","zip":\(resolvedZip)}
        ]}
        """
    }

    // MARK: - 结构解析

    func testParsesReleaseWithZipAndChecksum() {
        let releases = AppcastFeed.releases(from: Data(feedBody().utf8))
        XCTAssertEqual(releases?.count, 1)
        let release = releases?.first
        XCTAssertEqual(release?.tag, tag)
        XCTAssertEqual(release?.version, "0.2.0-alpha.3")
        XCTAssertEqual(release?.zip.name, "Pi-Web-Desktop-0.2.0-alpha.3+build.3.zip")
        XCTAssertEqual(release?.zip.url.absoluteString, zipURL)
        XCTAssertEqual(release?.zip.sha256, sha256)
    }

    func testReleaseLookupIsByExactTag() {
        let data = Data(feedBody().utf8)
        XCTAssertEqual(AppcastFeed.release(tag: tag, in: data)?.tag, tag)
        // 安装路径只认用户确认过的版本，不做「最新即最佳」的推断。
        XCTAssertNil(AppcastFeed.release(tag: "v0.2.0-alpha.4", in: data))
    }

    func testTagsAreAvailableEvenWhenZipIsIncomplete() {
        // 检查路径只需要版本号：某条 zip 字段写坏不该让这个版本从更新列表里消失。
        let body = """
        {"schema":1,"releases":[
          {"tag":"v0.2.0-alpha.3","version":"0.2.0-alpha.3"},
          {"tag":"v0.2.0-alpha.4","version":"0.2.0-alpha.4"}
        ]}
        """
        let data = Data(body.utf8)
        XCTAssertEqual(AppcastFeed.tags(from: data), ["v0.2.0-alpha.3", "v0.2.0-alpha.4"])
        XCTAssertEqual(AppcastFeed.releases(from: data)?.count, 0)
    }

    func testRejectsUnknownSchemaAndMalformedDocuments() {
        XCTAssertNil(AppcastFeed.releases(from: Data(feedBody(schema: "99").utf8)))
        XCTAssertNil(AppcastFeed.tags(from: Data(feedBody(schema: "99").utf8)))
        XCTAssertNil(AppcastFeed.releases(from: Data("not json".utf8)))
        XCTAssertNil(AppcastFeed.tags(from: Data("[]".utf8)))
        XCTAssertNil(AppcastFeed.releases(from: Data("{\"schema\":1}".utf8)))
    }

    func testDropsEntriesMissingRequiredFields() {
        let body = """
        {"schema":1,"releases":[
          {"version":"0.2.0-alpha.3","zip":{"name":"a.zip","url":"\(zipURL)","sha256":"\(sha256)"}},
          {"tag":"v0.2.0-alpha.3","zip":{"name":"a.zip","url":"\(zipURL)","sha256":"\(sha256)"}}
        ]}
        """
        // 第一条缺 tag、第二条缺 version：都不够格作为安装依据。
        XCTAssertEqual(AppcastFeed.releases(from: Data(body.utf8))?.count, 0)
    }

    // MARK: - 信任边界

    func testFeedURLIsPinnedToTheRepositoryFeedBranch() {
        XCTAssertEqual(
            AppcastFeed.url?.absoluteString,
            "https://raw.githubusercontent.com/Su-luoya/pi-web-desktop/appcast/appcast.json"
        )
    }

    func testOnlyTheFeedHostIsAcceptedAsFinalURL() {
        XCTAssertTrue(AppcastFeed.allows(finalURL: URL(string: "https://raw.githubusercontent.com/Su-luoya/pi-web-desktop/appcast/appcast.json")!))
        // 重定向到别的主机（含 http 降级）一律不采信。
        XCTAssertFalse(AppcastFeed.allows(finalURL: URL(string: "https://evil.example/appcast.json")!))
        XCTAssertFalse(AppcastFeed.allows(finalURL: URL(string: "http://raw.githubusercontent.com/appcast.json")!))
    }

    /// feed 里的 zip 地址仍然要过一遍发布资产选择器：内容不能把下载引到
    /// 别的域名，也不能用非 64 位十六进制的「校验值」。
    func testZipURLFromFeedStillGoesThroughReleaseAssetSelector() {
        let accepted = DesktopAppReleaseAssetSelector.select(
            version: "0.2.0-alpha.3",
            assets: [(name: "Pi-Web-Desktop-0.2.0-alpha.3+build.3.zip", url: URL(string: zipURL)!)],
            checksum: sha256,
            releaseTag: tag
        )
        XCTAssertEqual(accepted?.downloadURL.absoluteString, zipURL)
        XCTAssertEqual(accepted?.sha256, sha256)

        let foreignHost = DesktopAppReleaseAssetSelector.select(
            version: "0.2.0-alpha.3",
            assets: [(name: "Pi-Web-Desktop-0.2.0-alpha.3+build.3.zip", url: URL(string: "https://evil.example/x.zip")!)],
            checksum: sha256,
            releaseTag: tag
        )
        XCTAssertNil(foreignHost)

        let malformedChecksum = DesktopAppReleaseAssetSelector.select(
            version: "0.2.0-alpha.3",
            assets: [(name: "Pi-Web-Desktop-0.2.0-alpha.3+build.3.zip", url: URL(string: zipURL)!)],
            checksum: "not-a-sha256",
            releaseTag: tag
        )
        XCTAssertNil(malformedChecksum)
    }
}
