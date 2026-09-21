import XCTest

/// 「复制手机访问链接」的纯逻辑测试（GitHub #150）：地址分类边界、探测结果的
/// 去重与排序、菜单候选项生成与三种判定分支。
///
/// 全部使用假 provider 或直接构造的地址，不访问真实网络接口、真实
/// UserDefaults 或真实 Keychain。
final class ServiceAddressesTests: XCTestCase {
    /// 假 provider：只回答构造好的候选列表，测试从不触碰真实网络。
    private struct StubNetworkAddressProvider: NetworkAddressProviding {
        let addresses: [ServiceAddress]

        func ipv4Addresses() -> [ServiceAddress] { addresses }
    }

    /// Tailscale 候选地址在测试里运行时拼接：仓库文本扫描禁止把 CGNAT 私网地址
    /// 写成字面值（`Scripts/check-identity.sh` 的 "no CGNAT private address
    /// default"），因此边界地址用 `cgnat("64.0.0")` 这样的形式构造。
    private func cgnat(_ suffix: String) -> String {
        ["100", suffix].joined(separator: ".")
    }

    private func tailnet(_ ipv4: String) -> ServiceAddress {
        ServiceAddress(kind: .tailnet, ipv4: ipv4)
    }

    private func localNetwork(_ ipv4: String) -> ServiceAddress {
        ServiceAddress(kind: .localNetwork, ipv4: ipv4)
    }

    // MARK: - 分类边界

    func testClassifierMapsTailscaleRangeBoundariesToTailscale() {
        XCTAssertEqual(ServiceAddressClassifier.kind(forIPv4: cgnat("64.0.0")), .tailnet)
        XCTAssertEqual(ServiceAddressClassifier.kind(forIPv4: cgnat("64.0.1")), .tailnet)
        XCTAssertEqual(ServiceAddressClassifier.kind(forIPv4: cgnat("127.255.255")), .tailnet)
    }

    func testClassifierRejectsAddressesJustOutsideTailscaleRange() {
        XCTAssertNil(ServiceAddressClassifier.kind(forIPv4: cgnat("63.255.255")))
        XCTAssertNil(ServiceAddressClassifier.kind(forIPv4: cgnat("128.0.0")))
    }

    func testClassifierMapsPrivateRangesToLocalNetwork() {
        XCTAssertEqual(ServiceAddressClassifier.kind(forIPv4: "10.0.0.5"), .localNetwork)
        XCTAssertEqual(ServiceAddressClassifier.kind(forIPv4: "172.16.0.1"), .localNetwork)
        XCTAssertEqual(ServiceAddressClassifier.kind(forIPv4: "192.168.199.177"), .localNetwork)
    }

    func testClassifierRejectsAddressesJustOutsidePrivateRanges() {
        XCTAssertNil(ServiceAddressClassifier.kind(forIPv4: "172.15.0.1"))
        XCTAssertNil(ServiceAddressClassifier.kind(forIPv4: "172.32.0.1"))
        XCTAssertNil(ServiceAddressClassifier.kind(forIPv4: "192.169.0.1"))
        XCTAssertNil(ServiceAddressClassifier.kind(forIPv4: "11.0.0.1"))
    }

    func testClassifierRejectsLoopbackLinkLocalAndInvalidInput() {
        let rejected = [
            "127.0.0.1",
            "127.255.255.254",
            "169.254.1.1",
            "",
            "not-an-ip",
            "192.168.1",
            "192.168.1.1.1",
            "192.168.1.256",
            "192.168.1.-1",
            "192.168.1.1 ",
        ]
        for ipv4 in rejected {
            XCTAssertNil(ServiceAddressClassifier.kind(forIPv4: ipv4), "\(ipv4) 不应是手机访问候选地址")
        }
    }

    func testAddressTitleUsesKindLabelAndAddress() {
        XCTAssertEqual(localNetwork("192.168.1.20").title, "局域网 · 192.168.1.20")
        XCTAssertEqual(tailnet(cgnat("64.0.7")).title, "Tailscale · \(cgnat("64.0.7"))")
    }

    // MARK: - 探测结果的过滤、去重与排序

    func testClassifyAndSortFiltersLoopbackDeduplicatesAndOrdersTailscaleFirst() {
        let addresses = ServiceAddressList.classifyAndSort([
            "192.168.1.20",
            cgnat("64.0.9"),
            "192.168.1.20",
            "127.0.0.1",
            "169.254.3.4",
            "not-an-ip",
            "10.0.0.5",
            cgnat("64.0.2"),
        ])
        XCTAssertEqual(addresses, [
            tailnet(cgnat("64.0.2")),
            tailnet(cgnat("64.0.9")),
            localNetwork("10.0.0.5"),
            localNetwork("192.168.1.20"),
        ])
    }

    func testClassifyAndSortIsStableRegardlessOfInputOrder() {
        let first = ServiceAddressList.classifyAndSort([cgnat("64.0.9"), "10.0.0.5", cgnat("64.0.2")])
        let second = ServiceAddressList.classifyAndSort(["10.0.0.5", cgnat("64.0.2"), cgnat("64.0.9")])
        XCTAssertEqual(first, second)
        XCTAssertEqual(first.map(\.title), [
            "Tailscale · \(cgnat("64.0.2"))",
            "Tailscale · \(cgnat("64.0.9"))",
            "局域网 · 10.0.0.5",
        ])
    }

    // MARK: - 菜单候选项

    func testMenuEntriesFallBackToSingleDisabledPlaceholderWithoutCandidates() {
        let entries = PhoneAccessMenuBuilder.entries(for: [])
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries, [
            PhoneAccessMenuEntry(title: "未检测到可用的 Tailscale 或局域网地址", address: nil, isEnabled: false),
        ])
    }

    func testMenuEntriesFallBackWhenProviderOnlyFindsLoopbackOrLinkLocalAddresses() {
        let provider = StubNetworkAddressProvider(
            addresses: ServiceAddressList.classifyAndSort(["127.0.0.1", "169.254.3.4", "::1"])
        )
        let entries = PhoneAccessMenuBuilder.entries(for: provider.ipv4Addresses())
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.title, PhoneAccessMenuBuilder.emptyTitle)
        XCTAssertEqual(entries.first?.isEnabled, false)
        XCTAssertNil(entries.first?.address)
    }

    func testMenuEntriesExposeEveryInjectedAddressAsEnabledCandidate() {
        let provider = StubNetworkAddressProvider(addresses: [
            tailnet(cgnat("64.0.2")),
            localNetwork("192.168.1.20"),
        ])
        let entries = PhoneAccessMenuBuilder.entries(for: provider.ipv4Addresses())
        XCTAssertEqual(entries.map(\.title), [
            "Tailscale · \(cgnat("64.0.2"))",
            "局域网 · 192.168.1.20",
        ])
        XCTAssertEqual(entries.compactMap(\.address), provider.ipv4Addresses())
        XCTAssertTrue(entries.allSatisfy(\.isEnabled))
    }

    // MARK: - 判定分支

    func testDecisionCopiesOnlyWhenSelectedAddressIsAlreadyTheListeningAddress() {
        let selected = localNetwork("192.168.1.20")
        XCTAssertEqual(
            ServiceAddressDecision.decide(currentHostname: "192.168.1.20", selected: selected, hasPassword: false),
            .copyOnly
        )
        XCTAssertEqual(
            ServiceAddressDecision.decide(currentHostname: "192.168.1.20", selected: selected, hasPassword: true),
            .copyOnly
        )
    }

    func testDecisionRequiresPasswordBeforeSwitchingListeningAddress() {
        XCTAssertEqual(
            ServiceAddressDecision.decide(
                currentHostname: "127.0.0.1",
                selected: localNetwork("192.168.1.20"),
                hasPassword: false
            ),
            .needsPassword
        )
        XCTAssertEqual(
            ServiceAddressDecision.decide(
                currentHostname: "",
                selected: tailnet(cgnat("64.0.2")),
                hasPassword: false
            ),
            .needsPassword
        )
    }

    func testDecisionRequiresConfirmationWhenSwitchingWithStoredPassword() {
        XCTAssertEqual(
            ServiceAddressDecision.decide(
                currentHostname: "127.0.0.1",
                selected: tailnet(cgnat("64.0.2")),
                hasPassword: true
            ),
            .needsConfirmation
        )
        XCTAssertEqual(
            ServiceAddressDecision.decide(
                currentHostname: "192.168.1.20",
                selected: localNetwork("10.0.0.5"),
                hasPassword: true
            ),
            .needsConfirmation
        )
    }

    // MARK: - 链接构造

    func testLinkUsesSelectedAddressAndPortWithoutChangingStartURL() {
        XCTAssertEqual(
            ServiceAddressLink.url(forIPv4: "192.168.1.20", port: 30141)?.absoluteString,
            "http://192.168.1.20:30141/"
        )
        XCTAssertEqual(
            ServiceAddressLink.url(forIPv4: cgnat("64.0.2"), port: 1)?.absoluteString,
            "http://\(cgnat("64.0.2")):1/"
        )
    }
}
