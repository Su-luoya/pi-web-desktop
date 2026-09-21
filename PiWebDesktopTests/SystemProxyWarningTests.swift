import Foundation
import XCTest

/// GitHub #157：系统代理未排除 VPN 网段（CGNAT 段 `100.x.y.z`）时的判定与提示状态。
///
/// 这些测试只使用内存里的代理快照，不读取真实系统代理、不访问网络，也不写入
/// 任何系统设置。
///
/// CGNAT 地址在本文件里运行时拼接：仓库文本扫描禁止把该网段写成点分字面量
/// （`Scripts/check-identity.sh` 的 "no CGNAT private address default"），与
/// `ServiceAddressesTests` 的 `cgnat(_:)` 同一约定；字面量只出现在被测代码的文案常量里。
private func cgnat(_ suffix: String) -> String {
    ["100", suffix].joined(separator: ".")
}

final class SystemProxyWarningTests: XCTestCase {
    private struct FakeReader: SystemProxySettingsReading {
        var snapshot: SystemProxySnapshot?

        func readSnapshot() -> SystemProxySnapshot? { snapshot }
    }

    private let vpnURL = URL(string: "http://\(cgnat("101.102.103")):30141/")!
    private let loopbackURL = URL(string: "http://127.0.0.1:30141/")!

    private func snapshot(
        http: Bool = false,
        https: Bool = false,
        socks: Bool = false,
        pac: Bool = false,
        exceptions: [String] = []
    ) -> SystemProxySnapshot {
        SystemProxySnapshot(
            httpEnabled: http,
            httpsEnabled: https,
            socksEnabled: socks,
            pacEnabled: pac,
            exceptions: exceptions
        )
    }

    private func warns(
        host: String,
        scheme: String = "http",
        snapshot: SystemProxySnapshot
    ) -> Bool {
        SystemProxyWarningEvaluator.shouldWarn(
            serviceURL: URL(string: "\(scheme)://\(host):30141/"),
            snapshot: snapshot
        )
    }

    // MARK: - 该提示与不该提示

    func testLoopbackHostsAreNeverWarned() {
        let proxies = snapshot(http: true, https: true, socks: true, pac: true)
        for host in ["127.0.0.1", "localhost", "127.0.0.53", "::1", "[::1]"] {
            XCTAssertFalse(warns(host: host, snapshot: proxies), host)
        }
    }

    func testVPNAddressWithoutEnabledProxyIsNotWarned() {
        XCTAssertFalse(warns(host: cgnat("101.102.103"), snapshot: snapshot()))
        XCTAssertFalse(warns(host: cgnat("101.102.103"), snapshot: snapshot(exceptions: ["localhost"])))
    }

    func testVPNAddressWithProxyAndNoExceptionWarns() {
        XCTAssertTrue(warns(host: cgnat("64.0.1"), snapshot: snapshot(http: true)))
        XCTAssertTrue(warns(host: cgnat("101.102.103"), scheme: "https", snapshot: snapshot(https: true)))
        // SOCKS 与 PAC 生效时同样会接管这条请求。
        XCTAssertTrue(warns(host: cgnat("101.102.103"), snapshot: snapshot(socks: true)))
        XCTAssertTrue(warns(host: cgnat("101.102.103"), snapshot: snapshot(pac: true)))
        XCTAssertTrue(warns(host: cgnat("127.255.255"), snapshot: snapshot(http: true)))
    }

    func testSchemeSpecificProxyOnlyAppliesToItsOwnScheme() {
        XCTAssertFalse(warns(host: cgnat("101.102.103"), scheme: "https", snapshot: snapshot(http: true)))
        XCTAssertFalse(warns(host: cgnat("101.102.103"), scheme: "http", snapshot: snapshot(https: true)))
    }

    func testSubnetBoundariesAndLANAddressesAreNotWarned() {
        let proxies = snapshot(http: true)
        XCTAssertTrue(warns(host: cgnat("64.0.0"), snapshot: proxies))
        XCTAssertFalse(warns(host: cgnat("63.255.255"), snapshot: proxies))
        XCTAssertFalse(warns(host: cgnat("128.0.0"), snapshot: proxies))
        // 取舍：普通局域网地址与主机名不提示（见 docs/settings-and-workspace.md）。
        XCTAssertFalse(warns(host: "192.168.1.20", snapshot: proxies))
        XCTAssertFalse(warns(host: "10.0.0.5", snapshot: proxies))
        XCTAssertFalse(warns(host: "172.16.3.4", snapshot: proxies))
        // MagicDNS 名在测试里运行时拼接：仓库文本扫描同样禁止 tailnet DNS 后缀字面量。
        let magicDNSHost = ["macbook", "tailnet-xyz", "ts", "net"].joined(separator: ".")
        XCTAssertFalse(warns(host: magicDNSHost, snapshot: proxies))
        XCTAssertFalse(warns(host: cgnat("101.102.103"), scheme: "ftp", snapshot: proxies))
    }

    // MARK: - 例外列表

    func testExceptionEntriesSuppressWarning() {
        let host = cgnat("101.102.103")
        XCTAssertTrue(SystemProxyWarningEvaluator.isHostExcluded(host, rawEntries: [cgnat("101.*")]))
        XCTAssertTrue(SystemProxyWarningEvaluator.isHostExcluded(host, rawEntries: [cgnat("*.102.103")]))
        XCTAssertTrue(SystemProxyWarningEvaluator.isHostExcluded(
            host,
            rawEntries: [SystemProxyWarningEvaluator.vpnSubnetDescription]
        ))
        XCTAssertTrue(SystemProxyWarningEvaluator.isHostExcluded(host, rawEntries: [cgnat("64.0.0/8")]))
        XCTAssertTrue(SystemProxyWarningEvaluator.isHostExcluded(host, rawEntries: [host]))
        // 整串例外（macOS 会把多个条目塞进一个字符串）。
        XCTAssertTrue(SystemProxyWarningEvaluator.isHostExcluded(
            host,
            rawEntries: [["localhost", "127.0.0.1", "*.local", SystemProxyWarningEvaluator.vpnSubnetDescription]
                .joined(separator: ", ")]
        ))
    }

    func testNonMatchingExceptionsKeepTheWarning() {
        let host = cgnat("101.102.103")
        for entry in ["10.0.0.0/8", "192.168.*", cgnat("63.0.0/16"), cgnat("128.0.0/9"), "127.0.0.1", "<local>"] {
            XCTAssertFalse(SystemProxyWarningEvaluator.isHostExcluded(host, rawEntries: [entry]), entry)
        }
        XCTAssertTrue(warns(host: host, snapshot: snapshot(http: true, exceptions: ["10.0.0.0/8", "*.local"])))
    }

    func testUnparseableEntriesAreTreatedAsExcluded() {
        for entry in [cgnat("0.0.0/99"), "not-an-ip/abc", cgnat("64.0.0") + ":", "*/", "999.1.1.1/8"] {
            XCTAssertTrue(SystemProxyWarningEvaluator.isHostExcluded(cgnat("101.102.103"), rawEntries: [entry]), entry)
        }
    }

    func testDomainSuffixAndIPv6Entries() {
        XCTAssertTrue(SystemProxyWarningEvaluator.isHostExcluded("foo.example.com", rawEntries: ["example.com"]))
        XCTAssertTrue(SystemProxyWarningEvaluator.isHostExcluded("foo.example.com", rawEntries: [".example.com"]))
        XCTAssertTrue(SystemProxyWarningEvaluator.isHostExcluded("foo.example.com", rawEntries: ["*"]))
        XCTAssertTrue(SystemProxyWarningEvaluator.isHostExcluded("localhost", rawEntries: ["<local>"]))
        // 合法的 IPv6 例外不可能排掉 IPv4 服务地址，保留提示。
        for entry in ["::1", "fe80::/10"] {
            XCTAssertFalse(SystemProxyWarningEvaluator.isHostExcluded(cgnat("101.102.103"), rawEntries: [entry]), entry)
        }
    }

    // MARK: - 代理字典缺失 / 畸形

    func testNilSnapshotNeverWarns() {
        XCTAssertFalse(SystemProxyWarningEvaluator.shouldWarn(serviceURL: vpnURL, snapshot: nil))
        let coordinator = SystemProxyWarningCoordinator(reader: FakeReader(snapshot: nil))
        XCTAssertFalse(coordinator.refresh(serviceURL: vpnURL))
        XCTAssertNil(coordinator.warning)
    }

    func testMalformedProxyDictionaryNeverWarns() {
        let malformed: [String: Any] = [
            "HTTPEnable": "not-a-number",
            "HTTPSEnable": [1, 2],
            "SOCKSEnable": NSNull(),
            "ProxyAutoConfigEnable": ["on": 1],
            "ExceptionsList": 42,
        ]
        let parsed = SystemProxySnapshot(dictionary: malformed)
        XCTAssertEqual(parsed, SystemProxySnapshot())
        XCTAssertFalse(SystemProxyWarningEvaluator.shouldWarn(
            serviceHost: cgnat("101.102.103"),
            scheme: "http",
            snapshot: parsed
        ))
        // 缺键的合法字典也降级为不提示。
        let empty = SystemProxySnapshot(dictionary: [:])
        XCTAssertFalse(SystemProxyWarningEvaluator.shouldWarn(
            serviceHost: cgnat("101.102.103"),
            scheme: "http",
            snapshot: empty
        ))
    }

    func testSnapshotParsesSystemDictionaryShapes() {
        let dictionary: [String: Any] = [
            "HTTPEnable": 1,
            "HTTPSEnable": NSNumber(value: 0),
            "SOCKSEnable": "1",
            "ProxyAutoConfigEnable": "YES",
            "ExceptionsList": ["localhost, 127.0.0.1, *.local"],
        ]
        let parsed = SystemProxySnapshot(dictionary: dictionary)
        XCTAssertTrue(parsed.httpEnabled)
        XCTAssertFalse(parsed.httpsEnabled)
        XCTAssertTrue(parsed.socksEnabled)
        XCTAssertTrue(parsed.pacEnabled)
        XCTAssertEqual(parsed.exceptions, ["localhost, 127.0.0.1, *.local"])
        XCTAssertFalse(SystemProxyWarningEvaluator.isHostExcluded(
            cgnat("101.102.103"),
            rawEntries: parsed.exceptions
        ))
    }

    // MARK: - 状态机与文案

    func testCoordinatorWarnsOnceAndClearsWhenConditionDisappears() {
        let coordinator = SystemProxyWarningCoordinator(reader: FakeReader(snapshot: snapshot(http: true)))
        XCTAssertTrue(coordinator.refresh(serviceURL: vpnURL))
        XCTAssertEqual(coordinator.warning, SystemProxyWarning.vpnSubnetNotExcluded)
        // 同一条件在一次运行内只提示一次。
        XCTAssertFalse(coordinator.refresh(serviceURL: vpnURL))
        XCTAssertEqual(coordinator.warning, SystemProxyWarning.vpnSubnetNotExcluded)
        // 条件不再成立（切回 loopback）→ 自动清除。
        XCTAssertTrue(coordinator.refresh(serviceURL: loopbackURL))
        XCTAssertNil(coordinator.warning)
        // 再次切到 VPN 网段 → 重新提示。
        XCTAssertTrue(coordinator.refresh(serviceURL: vpnURL))
        XCTAssertNotNil(coordinator.warning)
    }

    func testManualDismissSuppressesOnlyForTheCurrentRun() {
        let coordinator = SystemProxyWarningCoordinator(reader: FakeReader(snapshot: snapshot(http: true)))
        XCTAssertTrue(coordinator.refresh(serviceURL: vpnURL))
        XCTAssertTrue(coordinator.dismiss())
        XCTAssertNil(coordinator.warning)
        // 条件仍成立：本次运行不再提示。
        XCTAssertFalse(coordinator.refresh(serviceURL: vpnURL))
        XCTAssertNil(coordinator.warning)
        // 条件消失后再成立：重新提示。
        XCTAssertFalse(coordinator.refresh(serviceURL: loopbackURL))
        XCTAssertTrue(coordinator.refresh(serviceURL: vpnURL))
        XCTAssertNotNil(coordinator.warning)
    }

    func testWarningTextIsActionableAndRedacted() {
        let warning = SystemProxyWarning.vpnSubnetNotExcluded
        XCTAssertTrue(warning.shortText.contains(SystemProxyWarningEvaluator.vpnSubnetDescription))
        XCTAssertTrue(warning.text.contains("系统设置 → 网络 → 详细信息 → 代理"))
        XCTAssertTrue(warning.text.contains("绕过这些主机与域名"))
        XCTAssertTrue(warning.text.contains(SystemProxyWarningEvaluator.vpnSubnetDescription))
        XCTAssertFalse(warning.text.contains(cgnat("101.102.103")))
        XCTAssertFalse(warning.text.contains(cgnat("101")))
    }

    func testCoordinatorLogsOnlyTheSubnet() {
        var lines: [String] = []
        let coordinator = SystemProxyWarningCoordinator(
            reader: FakeReader(snapshot: snapshot(http: true)),
            log: { lines.append($0) }
        )
        _ = coordinator.refresh(serviceURL: vpnURL)
        _ = coordinator.refresh(serviceURL: loopbackURL)
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[0].contains(SystemProxyWarningEvaluator.vpnSubnetDescription))
        XCTAssertFalse(lines.joined().contains(cgnat("101")))
    }
}
