import XCTest

/// 端口回落判定与 `ServiceManager` 接线。
final class ListeningPortFallbackTests: XCTestCase {

    // MARK: - 纯判定

    func testAvailablePortKeepsConfiguration() {
        let resolution = ListeningPortFallbackPolicy.resolve(
            hostname: "127.0.0.1",
            port: 30141,
            isAvailable: { _, _ in true }
        )
        XCTAssertEqual(resolution, .none(30141))
        XCTAssertFalse(resolution.isActive)
        XCTAssertNil(resolution.notice)
    }

    func testOccupiedPortScansUpwardForTheNextFreePort() {
        let occupied: Set<Int> = [30141, 30142]
        let resolution = ListeningPortFallbackPolicy.resolve(
            hostname: "127.0.0.1",
            port: 30141,
            isAvailable: { _, candidate in !occupied.contains(candidate) }
        )
        XCTAssertEqual(resolution.requested, 30141)
        XCTAssertEqual(resolution.effective, 30143)
        XCTAssertTrue(resolution.isActive)
        XCTAssertNotNil(resolution.notice)
    }

    /// 无法判定（主机名、权限错误）时绝不挪端口：挪了就等于把「不知道」当成「被占用」。
    func testUnknownAvailabilityNeverFallsBack() {
        let resolution = ListeningPortFallbackPolicy.resolve(
            hostname: "127.0.0.1",
            port: 30141,
            isAvailable: { _, _ in nil }
        )
        XCTAssertEqual(resolution, .none(30141))
    }

    /// 扫完一段全被占用：沿用配置端口，让失败原因保持可见。
    func testFullyOccupiedRangeKeepsConfiguration() {
        let resolution = ListeningPortFallbackPolicy.resolve(
            hostname: "127.0.0.1",
            port: 30141,
            isAvailable: { _, _ in false }
        )
        XCTAssertEqual(resolution, .none(30141))
    }

    /// 端口接近上限时扫描不能越界，也不能因为 `port + 1 > 65535` 而崩溃。
    func testScanDoesNotOverflowNearThePortCeiling() {
        let resolution = ListeningPortFallbackPolicy.resolve(
            hostname: "127.0.0.1",
            port: 65535,
            isAvailable: { _, _ in false }
        )
        XCTAssertEqual(resolution, .none(65535))
    }

    /// 非法端口不参与回落：配置路径已经会拒绝它们。
    func testOutOfRangePortNeverFallsBack() {
        let resolution = ListeningPortFallbackPolicy.resolve(
            hostname: "127.0.0.1",
            port: 70000,
            isAvailable: { _, _ in false }
        )
        XCTAssertEqual(resolution, .none(70000))
    }

    /// 提示文案要说明「配置没被改动」，否则用户会以为设置被改了。
    func testNoticeExplainsConfigurationIsUntouched() {
        let fallback = ListeningPortFallback(requested: 30141, effective: 30143)
        let notice = try? XCTUnwrap(fallback.notice)
        XCTAssertTrue(notice?.contains("30143") == true)
        XCTAssertTrue(notice?.contains("没有改动") == true)
    }
}
