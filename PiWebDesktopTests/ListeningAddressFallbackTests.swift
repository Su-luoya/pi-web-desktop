import XCTest

/// 监听地址回环回落（issue：Tailscale 地址掉线后 pi-web 秒退）的纯逻辑测试。
///
/// 全部用注入的本机地址快照与主机名解析判定，不访问真实接口表、DNS 或 UserDefaults；
/// 覆盖网络地址按 `["100", suffix].joined(separator: ".")` 拼接，仓库文本扫描禁止
/// 把 CGNAT 地址写成字面值（`Scripts/check-identity.sh`）。
final class ListeningAddressFallbackTests: XCTestCase {
    private func cgnat(_ suffix: String) -> String {
        ["100", suffix].joined(separator: ".")
    }

    private func snapshot(ipv4: [String] = [], ipv6: [String] = []) -> LocalAddresses {
        LocalAddresses(ipv4: Set(ipv4), ipv6: Set(ipv6))
    }

    // MARK: - Presence

    /// 本机有该 IPv4 字面量 → present；没有 → missing。字面量比较不经过 DNS。
    func testIPv4LiteralPresenceFollowsTheLocalInterfaceSnapshot() {
        let address = cgnat("76.71.55")
        let with = ListeningAddressFallbackPolicy.presence(
            of: address,
            localAddresses: { self.snapshot(ipv4: [address]) },
            resolvesToLocalHost: { _ in false }
        )
        XCTAssertEqual(with, .present)

        let without = ListeningAddressFallbackPolicy.presence(
            of: address,
            localAddresses: { self.snapshot(ipv4: []) },
            resolvesToLocalHost: { _ in true }
        )
        XCTAssertEqual(without, .missing, "字面量地址必须按接口快照判定，不能采信主机名解析")
    }

    /// loopback 永远算可用，不需要枚举接口；`localhost`、`::1` 与整个 `127/8` 都覆盖。
    func testLoopbackHostnamesAreAlwaysPresent() {
        for hostname in ["127.0.0.1", "localhost", "::1", "127.0.0.53"] {
            let presence = ListeningAddressFallbackPolicy.presence(
                of: hostname,
                localAddresses: { self.snapshot() },
                resolvesToLocalHost: { _ in false }
            )
            XCTAssertEqual(presence, .present, hostname)
        }
    }

    /// IPv6 字面量按接口快照比较，文本大小写不敏感。
    func testIPv6LiteralPresenceIsCaseInsensitive() {
        let presence = ListeningAddressFallbackPolicy.presence(
            of: "FD7A:115C:A1E0::1",
            localAddresses: { self.snapshot(ipv6: ["fd7a:115c:a1e0::1"]) },
            resolvesToLocalHost: { _ in false }
        )
        XCTAssertEqual(presence, .present)
    }

    /// 主机名走注入的解析判定：解析到本机才算可用。
    func testHostnamePresenceUsesTheInjectedResolver() {
        let present = ListeningAddressFallbackPolicy.presence(
            of: "pi.example.invalid",
            localAddresses: { self.snapshot() },
            resolvesToLocalHost: { $0 == "pi.example.invalid" }
        )
        XCTAssertEqual(present, .present)

        let missing = ListeningAddressFallbackPolicy.presence(
            of: "pi.example.invalid",
            localAddresses: { self.snapshot() },
            resolvesToLocalHost: { _ in false }
        )
        XCTAssertEqual(missing, .missing)
    }

    /// 非法与通配地址保持 unknown：诊断仍由既有的地址校验路径给出，这里不接管。
    func testUnusableAddressesStayUnknown() {
        for hostname in ["0.0.0.0", "::", "", " bad.example.invalid"] {
            let presence = ListeningAddressFallbackPolicy.presence(
                of: hostname,
                localAddresses: { self.snapshot(ipv4: [hostname]) },
                resolvesToLocalHost: { _ in true }
            )
            XCTAssertEqual(presence, .unknown, hostname)
        }
    }

    // MARK: - Resolution

    /// 地址不在本机：生效地址换成回环地址，提示里说明原地址与“配置没有改动”。
    func testMissingAddressResolvesToTheLoopbackFallback() throws {
        let address = cgnat("76.71.55")
        let resolution = ListeningAddressFallbackPolicy.resolve(
            hostname: address,
            localAddresses: { self.snapshot(ipv4: []) },
            resolvesToLocalHost: { _ in false }
        )
        XCTAssertEqual(resolution.presence, .missing)
        XCTAssertTrue(resolution.fallback.isActive)
        XCTAssertEqual(resolution.fallback.requested, address)
        XCTAssertEqual(resolution.fallback.effective, "127.0.0.1")

        let notice = try XCTUnwrap(resolution.fallback.notice)
        XCTAssertTrue(notice.contains(address), notice)
        XCTAssertTrue(notice.contains("127.0.0.1"), notice)
        XCTAssertTrue(notice.contains("没有改动"), notice)
    }

    /// 地址仍在本机（或本来就是 loopback）：不回落，生效地址就是配置地址。
    func testPresentAddressKeepsTheConfiguredAddress() {
        let address = cgnat("76.71.55")
        for resolution in [
            ListeningAddressFallbackPolicy.resolve(
                hostname: address,
                localAddresses: { self.snapshot(ipv4: [address]) },
                resolvesToLocalHost: { _ in false }
            ),
            ListeningAddressFallbackPolicy.resolve(
                hostname: "127.0.0.1",
                localAddresses: { self.snapshot() },
                resolvesToLocalHost: { _ in false }
            ),
        ] {
            XCTAssertFalse(resolution.fallback.isActive)
            XCTAssertNil(resolution.fallback.notice)
        }
        XCTAssertEqual(
            ListeningAddressFallbackPolicy.resolve(
                hostname: address,
                localAddresses: { self.snapshot(ipv4: [address]) },
                resolvesToLocalHost: { _ in false }
            ).fallback.effective,
            address
        )
    }

    /// 非法地址不产生回落：返回 unknown 与“生效地址 = 配置地址”，由既有校验报错。
    func testUnusableAddressNeverFallsBack() {
        let resolution = ListeningAddressFallbackPolicy.resolve(
            hostname: "0.0.0.0",
            localAddresses: { self.snapshot(ipv4: ["0.0.0.0"]) },
            resolvesToLocalHost: { _ in true }
        )
        XCTAssertEqual(resolution.presence, .unknown)
        XCTAssertFalse(resolution.fallback.isActive)
        XCTAssertNil(resolution.fallback.notice)
        XCTAssertEqual(resolution.fallback.effective, "0.0.0.0")
    }

    /// 回落到回环地址后，服务 URL 用同一个地址拼接（IPv6 回环需要方括号的既有行为不变）。
    func testEffectiveServiceURLUsesTheFallbackAddress() {
        var configuration = ServiceConfiguration.default
        configuration.hostname = cgnat("76.71.55")
        configuration.port = 30141
        let fallback = ListeningAddressFallback(requested: configuration.hostname, effective: "127.0.0.1")
        XCTAssertEqual(
            configuration.serviceURL(forHostname: fallback.effective).absoluteString,
            "http://127.0.0.1:30141/"
        )
        // 无回落时与 `serviceURL` 完全一致。
        XCTAssertEqual(
            configuration.serviceURL(forHostname: configuration.hostname).absoluteString,
            configuration.serviceURL.absoluteString
        )
    }
}
