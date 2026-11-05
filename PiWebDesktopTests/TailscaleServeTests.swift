import XCTest

final class RemoteAccessControllerTests: XCTestCase {
    private final class RecordingRunner: CommandRunning {
        var snapshot: String? = "{}"
        var succeeds = false

        func run(_ arguments: [String]) -> String? {
            if arguments == ["/fake/tail-cli", "status", "--json"] {
                return "{\"BackendState\": \"Running\", \"Self\": {\"DNSName\": \"mini.example-tailnet\"}}"
            }
            if arguments.contains("--json") { return snapshot }
            return succeeds ? "ok" : nil
        }
    }

    private var defaults: UserDefaults!
    private var suite: String!
    private var runner: RecordingRunner!
    private var controller: RemoteAccessController!

    override func setUpWithError() throws {
        suite = "RemoteAccessControllerTests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        runner = RecordingRunner()
        controller = RemoteAccessController(serve: TailscaleServe(
            runner: runner, candidates: ["/fake/tail-cli"], isExecutable: { _ in true }
        ), defaults: defaults)
        defaults.set(443, forKey: RemoteAccessController.DefaultsKey.port)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        controller = nil
        runner = nil
        defaults = nil
    }

    func testFailedDisableKeepsPortSoTheUserCanRetry() {
        let finished = expectation(description: "disable failed")
        controller.disable { success in
            XCTAssertFalse(success)
            finished.fulfill()
        }
        wait(for: [finished], timeout: 5)
        XCTAssertEqual(controller.activePort, 443)
    }

    func testSuccessfulDisableForgetsPort() {
        runner.succeeds = true
        let finished = expectation(description: "disabled")
        controller.disable { success in
            XCTAssertTrue(success)
            finished.fulfill()
        }
        wait(for: [finished], timeout: 5)
        XCTAssertNil(controller.activePort)
        XCTAssertEqual(controller.state, .off)
    }

    func testQuitKeepsPortWhenRevocationFails() {
        controller.revokeForQuit()
        XCTAssertEqual(controller.activePort, 443)
    }

    func testRefreshKeepsPortWhenSnapshotIsUnreadable() {
        runner.snapshot = nil
        let finished = expectation(description: "refresh completed")
        controller.onChange = { _ in finished.fulfill() }
        controller.refresh(configuration: .default)
        wait(for: [finished], timeout: 5)
        XCTAssertEqual(controller.activePort, 443)
        XCTAssertEqual(controller.state, .unavailable(RemoteAccessController.Failure.commandFailed.message))
    }

    func testRefreshRecognizesNormalizedProxyTarget() {
        runner.snapshot = """
        {"Web": {"mini.example-tailnet:443": {"Handlers": {"/": {"Proxy": "http://127.0.0.1:30141"}}}}}
        """
        let finished = expectation(description: "refresh completed")
        controller.onChange = { _ in finished.fulfill() }
        controller.refresh(configuration: .default)
        wait(for: [finished], timeout: 5)
        XCTAssertEqual(controller.activePort, 443)
        XCTAssertEqual(controller.state.url?.absoluteString, "https://mini.example-tailnet/")
    }

    /// 旧版本把代理目标写成「本机 tailnet 地址」：Tailscale 守护进程代理到自己的
    /// tailnet 地址会一直挂着，那条入口扫码打不开。对账时必须撤销它、作废记录。
    func testRefreshDropsServeEntryProxyingToOwnTailnetAddress() {
        runner.snapshot = """
        {"Web": {"mini.example-tailnet:443": {"Handlers": {"/": {"Proxy": "http://192.168.1.7:30141"}}}}}
        """
        let finished = expectation(description: "refresh completed")
        controller.onChange = { _ in finished.fulfill() }
        controller.refresh(configuration: .default)
        wait(for: [finished], timeout: 5)
        XCTAssertNil(controller.activePort)
        XCTAssertEqual(controller.state, .off)
    }

    /// 服务不再监听回环时，回环目标那条 serve 也进不了服务：同样作废。
    func testRefreshDropsEntryWhenServiceListensElsewhere() {
        runner.snapshot = """
        {"Web": {"mini.example-tailnet:443": {"Handlers": {"/": {"Proxy": "http://127.0.0.1:30141"}}}}}
        """
        var configuration = ServiceConfiguration.default
        configuration.hostname = "192.168.1.7"
        let finished = expectation(description: "refresh completed")
        controller.onChange = { _ in finished.fulfill() }
        controller.refresh(configuration: configuration)
        wait(for: [finished], timeout: 5)
        XCTAssertNil(controller.activePort)
        XCTAssertEqual(controller.state, .off)
    }

    /// 代理目标只能是回环：Tailscale 守护进程不接受指向自己 tailnet 地址的目标。
    func testLoopbackTargetIsTheLoopbackAddress() {
        XCTAssertEqual(TailscaleServe.loopbackTarget(port: 30141)?.absoluteString, "http://127.0.0.1:30141/")
        XCTAssertNil(TailscaleServe.loopbackTarget(port: 0))
        XCTAssertNil(TailscaleServe.loopbackTarget(port: 65536))
    }

    // MARK: - 自定义隧道地址

    /// 自定义地址只是默认里的一行字符串，关闭时不该去跑任何 CLI，也不该因
    /// Tailscale 不可用而失败。
    func testDisableForgetsCustomAddressWithoutCallingTailscale() {
        defaults.removeObject(forKey: RemoteAccessController.DefaultsKey.port)
        defaults.set("https://tunnel.example-cloud.test:12345", forKey: RemoteAccessController.DefaultsKey.customURL)

        let finished = expectation(description: "disabled")
        controller.disable { success in
            XCTAssertTrue(success)
            finished.fulfill()
        }
        wait(for: [finished], timeout: 5)
        XCTAssertNil(controller.customAddress)
        XCTAssertEqual(controller.state, .off)
    }

    /// 二选一：记住的地址优先，上次切换中途退出留下的 serve 条目顺手撤销。
    func testRefreshPrefersCustomAddressAndRevokesLeftoverServeEntry() {
        runner.succeeds = true
        defaults.set("https://tunnel.example-cloud.test:12345", forKey: RemoteAccessController.DefaultsKey.customURL)

        let state = expectation(description: "state restored")
        controller.onChange = { _ in state.fulfill() }
        controller.refresh(configuration: .default)
        wait(for: [state], timeout: 5)
        XCTAssertEqual(controller.state.url?.absoluteString, "https://tunnel.example-cloud.test:12345")

        let deadline = Date().addingTimeInterval(5)
        while controller.activePort != nil, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        XCTAssertNil(controller.activePort)
    }

    /// 主机名已经在允许列表里就不该重启服务（会话不能因为“重复添加”而断）。
    func testCustomAddressSkipsRestartWhenHostIsAlreadyAllowed() {
        defaults.removeObject(forKey: RemoteAccessController.DefaultsKey.port)
        var configuration = ServiceConfiguration.default
        configuration.allowedHosts = "localhost,Tunnel.Example-Cloud.test"
        let url = CustomTunnelAddress.url(from: "https://tunnel.example-cloud.test:12345")!

        var applied: ServiceConfiguration?
        let finished = expectation(description: "stored")
        controller.useCustomAddress(
            url,
            host: "tunnel.example-cloud.test",
            configuration: configuration,
            applyConfiguration: { updated, completion in
                applied = updated
                completion()
            },
            completion: { _ in finished.fulfill() }
        )
        wait(for: [finished], timeout: 5)
        XCTAssertNil(applied)
        XCTAssertEqual(controller.state, .on(url))
        XCTAssertEqual(controller.customAddress, url)
    }

    /// 主机名不在允许列表里：先写配置等重启，成功后才记地址。
    func testCustomAddressAddsHostBeforeStoring() {
        defaults.removeObject(forKey: RemoteAccessController.DefaultsKey.port)
        var configuration = ServiceConfiguration.default
        configuration.allowedHosts = "localhost"
        let url = CustomTunnelAddress.url(from: "https://tunnel.example-cloud.test:12345")!

        var applied: ServiceConfiguration?
        let finished = expectation(description: "stored")
        controller.useCustomAddress(
            url,
            host: "tunnel.example-cloud.test",
            configuration: configuration,
            applyConfiguration: { updated, completion in
                applied = updated
                completion()
            },
            completion: { _ in finished.fulfill() }
        )
        wait(for: [finished], timeout: 5)
        XCTAssertEqual(applied?.allowedHosts, "localhost,tunnel.example-cloud.test")
        XCTAssertEqual(controller.state, .on(url))
    }
}

/// 自填隧道地址的解析：只接受 http/https 带主机名，端口与路径保留但不是主机名。
final class CustomTunnelAddressTests: XCTestCase {
    func testAcceptsHTTPSAndHTTPWithPort() {
        XCTAssertEqual(
            CustomTunnelAddress.url(from: "https://tunnel.example-cloud.test:12345")?.absoluteString,
            "https://tunnel.example-cloud.test:12345"
        )
        XCTAssertEqual(
            CustomTunnelAddress.url(from: " http://tunnel.example-cloud.test:8080/ui ")?.absoluteString,
            "http://tunnel.example-cloud.test:8080/ui"
        )
    }

    func testRejectsWhatCannotBeOpenedDirectly() {
        // 缺 scheme：URLComponents 会把域名当 scheme，必须自己拒。
        XCTAssertNil(CustomTunnelAddress.url(from: "tunnel.example-cloud.test:12345"))
        XCTAssertNil(CustomTunnelAddress.url(from: "ftp://tunnel.example-cloud.test"))
        XCTAssertNil(CustomTunnelAddress.url(from: "https://"))
        XCTAssertNil(CustomTunnelAddress.url(from: "   "))
        // 带凭据的地址不保存：它会连同密码一起进剪贴板与二维码。
        XCTAssertNil(CustomTunnelAddress.url(from: "https://user:pass@tunnel.example-cloud.test"))
    }

    /// 写进允许列表的是主机名：pi-web 按主机名（不含端口）逐条精确比对。
    func testAllowedHostDropsPortAndLowercases() {
        let url = CustomTunnelAddress.url(from: "https://Tunnel.Example-Cloud.test:12345/deep/path")!
        XCTAssertEqual(CustomTunnelAddress.allowedHost(for: url), "tunnel.example-cloud.test")
    }
}

/// Tailscale serve 编排层的纯逻辑测试：状态解析、端口选择、命令参数、
/// 「不覆盖别人条目」与「没装时不报错只降级」。
///
/// 所有 CLI 调用都打到假 runner，测试不启动真实命令、不读写真实网络。
/// 覆盖网络的产品名与 tailnet 后缀在仓库文本里受身份扫描限制，因此测试数据里
/// 的示例域名统一用 `example-tailnet` 形式。
final class TailscaleServeTests: XCTestCase {
    /// 假 runner：按「参数拼成的键」返回预置输出，并记录每次调用。
    private final class RecordingRunner: CommandRunning {
        var responses: [String: String] = [:]
        private(set) var calls: [[String]] = []

        func run(_ arguments: [String]) -> String? {
            calls.append(arguments)
            return responses[arguments.joined(separator: " ")]
        }
    }

    private let binary = "/fake/tail-cli"

    private func makeServe(runner: RecordingRunner, executable: Bool = true) -> TailscaleServe {
        TailscaleServe(
            runner: runner,
            candidates: [binary],
            isExecutable: { _ in executable }
        )
    }

    private func statusJSON(backendState: String, dnsName: String?) -> String {
        let selfNode = dnsName.map { "{\"DNSName\": \"\($0)\"}" } ?? "{}"
        return "{\"BackendState\": \"\(backendState)\", \"Self\": \(selfNode)}"
    }

    // MARK: - 后端状态

    func testDetectParsesRunningBackendAndTrimsTrailingDot() {
        let runner = RecordingRunner()
        runner.responses["\(binary) status --json"] = statusJSON(
            backendState: "Running",
            dnsName: "mini.example-tailnet."
        )
        XCTAssertEqual(makeServe(runner: runner).detect(), .ready(dnsName: "mini.example-tailnet"))
    }

    func testDetectReportsNotRunningWithBackendState() {
        let runner = RecordingRunner()
        runner.responses["\(binary) status --json"] = statusJSON(
            backendState: "NeedsLogin",
            dnsName: "mini.example-tailnet."
        )
        XCTAssertEqual(makeServe(runner: runner).detect(), .notRunning(backendState: "NeedsLogin"))
    }

    func testDetectTreatsMalformedOutputAsNotRunning() {
        let runner = RecordingRunner()
        runner.responses["\(binary) status --json"] = "not json"
        XCTAssertEqual(makeServe(runner: runner).detect(), .notRunning(backendState: nil))
    }

    func testDetectWithoutBinaryIsNotInstalled() {
        let runner = RecordingRunner()
        let serve = makeServe(runner: runner, executable: false)
        XCTAssertEqual(serve.detect(), .notInstalled)
        XCTAssertNil(serve.binaryPath)
        XCTAssertTrue(runner.calls.isEmpty)
    }

    func testAvailabilityRequiresDNSName() {
        let json = statusJSON(backendState: "Running", dnsName: nil)
        XCTAssertEqual(TailscaleServe.availability(fromStatusJSON: json), .notRunning(backendState: "Running"))
    }

    // MARK: - serve 配置解析

    func testSnapshotReadsPortsAndProxyTargets() throws {
        let json = """
        {
          "TCP": { "443": { "HTTPS": true }, "8444": { "HTTPS": true } },
          "Web": {
            "mini.example-tailnet:443": { "Handlers": { "/": { "Proxy": "http://127.0.0.1:30141" } } },
            "mini.example-tailnet:8444": { "Handlers": { "/": { "Proxy": "http://127.0.0.1:8765" } } }
          }
        }
        """
        let snapshot = try XCTUnwrap(TailscaleServe.snapshot(fromServeStatusJSON: json))
        XCTAssertEqual(snapshot.proxy(for: 443), "http://127.0.0.1:30141")
        XCTAssertEqual(snapshot.proxy(for: 8444), "http://127.0.0.1:8765")
        XCTAssertEqual(snapshot.ports, [443, 8444])
    }

    func testSnapshotKeepsTCPOnlyPortsOccupied() throws {
        let json = "{\"TCP\": {\"8443\": {\"HTTPS\": true}}}"
        let snapshot = try XCTUnwrap(TailscaleServe.snapshot(fromServeStatusJSON: json))
        XCTAssertEqual(snapshot.ports, [8443])
        // 只有 TCP 监听、读不到 handler 时目标为空串：归属未知一律算占用，
        // 因此绝不会被我们的 `enable` 覆盖。
        XCTAssertEqual(snapshot.proxy(for: 8443), "")
        XCTAssertTrue(snapshot.isOccupied(8443, by: "http://127.0.0.1:30141"))
    }

    func testEmptySnapshotIsNotOccupied() {
        XCTAssertNil(TailscaleServe.snapshot(fromServeStatusJSON: ""))
        XCTAssertEqual(TailscaleServe.snapshot(fromServeStatusJSON: "null\n"), TailscaleServeSnapshot())
        XCTAssertEqual(TailscaleServe.snapshot(fromServeStatusJSON: "{}"), TailscaleServeSnapshot())
        XCTAssertFalse(TailscaleServeSnapshot().isOccupied(443, by: "http://127.0.0.1:30141"))
    }

    func testSnapshotRejectsUnreadableOrInvalidConfiguration() {
        for json in ["not json", "[]", "{\"TCP\": []}", "{\"Web\": []}"] {
            XCTAssertNil(TailscaleServe.snapshot(fromServeStatusJSON: json), json)
        }
        XCTAssertNil(makeServe(runner: RecordingRunner()).snapshot())
    }

    func testSnapshotDoesNotAdoptAPortWithOtherHandlers() throws {
        let json = """
        {"Web": {"mini.example-tailnet:443": {"Handlers": {
          "/": {"Proxy": "http://127.0.0.1:30141/"},
          "/other": {"Text": "another service"}
        }}}}
        """
        let snapshot = try XCTUnwrap(TailscaleServe.snapshot(fromServeStatusJSON: json))
        XCTAssertTrue(snapshot.isOccupied(443, by: "http://127.0.0.1:30141/"))
    }

    func testSnapshotKeepsPublicFunnelPortsOccupiedEvenForOurTarget() throws {
        let json = """
        {"Web": {"mini.example-tailnet:443": {"Handlers": {
          "/": {"Proxy": "http://127.0.0.1:30141/"}
        }}}, "AllowFunnel": {"mini.example-tailnet:443": true}}
        """
        let snapshot = try XCTUnwrap(TailscaleServe.snapshot(fromServeStatusJSON: json))
        XCTAssertTrue(snapshot.isOccupied(443, by: target.absoluteString))
    }

    func testSnapshotKeepsPortsSharedByMultipleHostsOccupied() throws {
        let json = """
        {"Web": {
          "mini.example-tailnet:443": {"Handlers": {"/": {"Proxy": "http://127.0.0.1:30141/"}}},
          "other.example-tailnet:443": {"Handlers": {"/": {"Proxy": "http://127.0.0.1:30141/"}}}
        }}
        """
        let snapshot = try XCTUnwrap(TailscaleServe.snapshot(fromServeStatusJSON: json))
        XCTAssertTrue(snapshot.isOccupied(443, by: target.absoluteString))
    }

    func testProxyComparisonAcceptsTheCLIsNormalizedRootPath() {
        let snapshot = TailscaleServeSnapshot(proxies: [443: "http://127.0.0.1:30141"])
        XCTAssertFalse(snapshot.isOccupied(443, by: target.absoluteString))
        XCTAssertTrue(snapshot.isOccupied(443, by: "http://127.0.0.1:30141/path"))
    }

    func testPortFromWebKey() {
        XCTAssertEqual(TailscaleServe.port(fromWebKey: "mini.example-tailnet:8444"), 8444)
        XCTAssertEqual(TailscaleServe.port(fromWebKey: "mini.example-tailnet"), 443)
        XCTAssertEqual(TailscaleServe.port(fromWebKey: "[fd7a:115c::1]:9443"), 9443)
        XCTAssertNil(TailscaleServe.port(fromWebKey: "mini.example-tailnet:http"))
        XCTAssertNil(TailscaleServe.port(fromWebKey: "mini.example-tailnet:0"))
        XCTAssertNil(TailscaleServe.port(fromWebKey: "mini.example-tailnet:65536"))
    }

    // MARK: - 地址与端口

    func testPublicURLDropsPortForHTTPSDefault() {
        XCTAssertEqual(
            TailscaleServe.publicURL(dnsName: "mini.example-tailnet.", port: 443)?.absoluteString,
            "https://mini.example-tailnet/"
        )
        XCTAssertEqual(
            TailscaleServe.publicURL(dnsName: "mini.example-tailnet", port: 8444)?.absoluteString,
            "https://mini.example-tailnet:8444/"
        )
        XCTAssertNil(TailscaleServe.publicURL(dnsName: "  ", port: 443))
    }

    func testFreePortSkipsOccupiedCandidates() {
        let occupied: Set<Int> = [443, 8444]
        XCTAssertEqual(TailscaleServe.freePort(in: [443, 8444, 9443]) { occupied.contains($0) }, 9443)
        XCTAssertNil(TailscaleServe.freePort(in: [443, 8444]) { occupied.contains($0) })
    }

    // MARK: - 命令

    func testEnableRunsBackgroundServeForTarget() throws {
        let runner = RecordingRunner()
        runner.responses["\(binary) serve status --json"] = "{\"TCP\": {}}"
        runner.responses["\(binary) serve --bg --https=443 http://127.0.0.1:30141/"] = "ok"
        let target = URL(string: "http://127.0.0.1:30141/")!
        try makeServe(runner: runner).enable(port: 443, target: target)
        XCTAssertEqual(
            runner.calls.last,
            [binary, "serve", "--bg", "--https=443", "http://127.0.0.1:30141/"]
        )
    }

    func testEnableRefusesPortOwnedByAnotherTarget() {
        let runner = RecordingRunner()
        runner.responses["\(binary) serve status --json"] = """
        {"Web": {"mini.example-tailnet:443": {"Handlers": {"/": {"Proxy": "http://127.0.0.1:8765"}}}}}
        """
        let target = URL(string: "http://127.0.0.1:30141/")!
        XCTAssertThrowsError(try makeServe(runner: runner).enable(port: 443, target: target)) { error in
            XCTAssertEqual(error as? TailscaleServeError, .noFreePort)
        }
        XCTAssertEqual(runner.calls.filter { $0.contains("--bg") }.count, 0)
    }

    func testEnableRefusesToMutateWhenConfigurationCannotBeRead() {
        for response in [nil, "", "not json", "{\"Web\": []}"] as [String?] {
            let runner = RecordingRunner()
            runner.responses["\(binary) serve status --json"] = response
            runner.responses["\(binary) serve --bg --https=443 http://127.0.0.1:30141/"] = "ok"
            XCTAssertThrowsError(try makeServe(runner: runner).enable(port: 443, target: target))
            XCTAssertFalse(runner.calls.contains { $0.contains("--bg") })
        }
    }

    func testEnableAcceptsTheCLIsNullConfiguration() throws {
        let runner = RecordingRunner()
        runner.responses["\(binary) serve status --json"] = "null\n"
        runner.responses["\(binary) serve --bg --https=443 http://127.0.0.1:30141/"] = "ok"
        try makeServe(runner: runner).enable(port: 443, target: target)
        XCTAssertTrue(runner.calls.contains { $0.contains("--bg") })
    }

    func testEnableReportsCommandFailure() {
        let runner = RecordingRunner()
        runner.responses["\(binary) serve status --json"] = "{\"TCP\": {}}"
        let target = URL(string: "http://127.0.0.1:30141/")!
        XCTAssertThrowsError(try makeServe(runner: runner).enable(port: 443, target: target)) { error in
            XCTAssertEqual(
                error as? TailscaleServeError,
                .commandFailed(arguments: ["serve", "--bg", "--https=443", "http://127.0.0.1:30141/"])
            )
        }
    }

    func testEnableWithoutBinaryThrowsNotInstalled() {
        let runner = RecordingRunner()
        let target = URL(string: "http://127.0.0.1:30141/")!
        XCTAssertThrowsError(try makeServe(runner: runner, executable: false).enable(port: 443, target: target)) { error in
            XCTAssertEqual(error as? TailscaleServeError, .notInstalled)
        }
        XCTAssertTrue(runner.calls.isEmpty)
    }

    func testDisableRunsOffForSinglePort() {
        let runner = RecordingRunner()
        runner.responses["\(binary) serve --https=8444 off"] = "ok"
        XCTAssertTrue(makeServe(runner: runner).disable(port: 8444))
        XCTAssertEqual(runner.calls, [[binary, "serve", "--https=8444", "off"]])
    }

    func testDisableReportsFailureWithoutThrowing() {
        let runner = RecordingRunner()
        XCTAssertFalse(makeServe(runner: runner).disable(port: 8444))
    }

    // MARK: - 允许的主机名

    func testAllowedHostsAppendingDeduplicatesAndKeepsOrder() {
        XCTAssertEqual(
            AllowedHostsEditing.appending(host: "mini.example-tailnet", to: ""),
            "mini.example-tailnet"
        )
        XCTAssertEqual(
            AllowedHostsEditing.appending(host: "mini.example-tailnet", to: "a.example, b.example"),
            "a.example,b.example,mini.example-tailnet"
        )
        XCTAssertEqual(
            AllowedHostsEditing.appending(host: "mini.example-tailnet", to: "mini.example-tailnet"),
            "mini.example-tailnet"
        )
    }

    func testAllowedHostsContainsIsCaseInsensitive() {
        XCTAssertTrue(AllowedHostsEditing.contains(host: "Mini.Example-Tailnet", in: "other,mini.example-tailnet"))
        XCTAssertFalse(AllowedHostsEditing.contains(host: "mini.example-tailnet", in: ""))
    }

    // MARK: - 启用计划

    private let target = URL(string: "http://127.0.0.1:30141/")!

    func testPlanUsesHTTPSPortAndRequiresAllowedHosts() throws {
        let plan = try RemoteAccessPlanner.plan(
            dnsName: "mini.example-tailnet",
            target: target,
            allowedHosts: "",
            snapshot: TailscaleServeSnapshot()
        ).get()
        XCTAssertEqual(plan.port, 443)
        XCTAssertEqual(plan.target, target)
        XCTAssertEqual(plan.updatedAllowedHosts, "mini.example-tailnet")
    }

    func testPlanSkipsPortsOwnedByOtherTargets() throws {
        let snapshot = TailscaleServeSnapshot(proxies: [443: "http://127.0.0.1:8765"])
        let plan = try RemoteAccessPlanner.plan(
            dnsName: "mini.example-tailnet",
            target: target,
            allowedHosts: "mini.example-tailnet",
            snapshot: snapshot
        ).get()
        XCTAssertEqual(plan.port, 8444)
        XCTAssertNil(plan.updatedAllowedHosts, "已允许的主机名不应触发重启")
    }

    func testPlanReusesPortAlreadyServingOurTarget() throws {
        let snapshot = TailscaleServeSnapshot(proxies: [443: target.absoluteString])
        let plan = try RemoteAccessPlanner.plan(
            dnsName: "mini.example-tailnet",
            target: target,
            allowedHosts: "mini.example-tailnet",
            snapshot: snapshot
        ).get()
        XCTAssertEqual(plan.port, 443)
    }

    func testPlanFailsWhenEveryCandidatePortIsTaken() {
        let snapshot = TailscaleServeSnapshot(proxies: [
            443: "http://127.0.0.1:8765",
            8444: "http://127.0.0.1:8766",
            9443: "http://127.0.0.1:8767"
        ])
        let result = RemoteAccessPlanner.plan(
            dnsName: "mini.example-tailnet",
            target: target,
            allowedHosts: "",
            snapshot: snapshot
        )
        XCTAssertThrowsError(try result.get()) { error in
            XCTAssertEqual(error as? TailscaleServeError, .noFreePort)
        }
    }

    // MARK: - 延迟测量

    /// 全程中转时 `ping` 以非零退出码结束，输出仍在标准输出：不能当成“没测到”。
    private final class FailingExitRunner: CommandRunning {
        var output: String?

        func run(_ arguments: [String]) -> String? { nil }

        func runAllowingFailure(_ arguments: [String], timeout: TimeInterval) -> CommandRunResult {
            CommandRunResult(output: output)
        }
    }

    private func peersJSON() -> String {
        """
        {"Peer": {
          "a": {"HostName": "pixel", "OS": "android", "TailscaleIPs": ["192.0.2.9", "fd7a::9"],
                "Online": true, "CurAddr": "", "Relay": "tok"},
          "b": {"HostName": "mini", "OS": "macOS", "TailscaleIPs": ["192.0.2.3"],
                "Online": true, "CurAddr": "192.168.1.5:41641", "Relay": "tok"},
          "c": {"HostName": "old-pc", "OS": "windows", "TailscaleIPs": ["192.0.2.7"],
                "Online": false, "CurAddr": ""}
        }}
        """
    }

    func testPeersParseRelayedAndDirectPaths() throws {
        let peers = try XCTUnwrap(TailscaleServe.peers(fromStatusJSON: peersJSON()))
        XCTAssertEqual(peers.map(\.hostName), ["mini", "pixel", "old-pc"], "在线的排前面")
        let pix = try XCTUnwrap(peers.first { $0.hostName == "pixel" })
        XCTAssertEqual(pix.ipv4, "192.0.2.9", "IPv6 地址不能拿来 ping")
        XCTAssertNil(pix.directAddress)
        XCTAssertEqual(pix.pathText, "中转 tok")
        XCTAssertTrue(pix.pickerTitle.contains("中转 tok"))
        let mini = try XCTUnwrap(peers.first { $0.hostName == "mini" })
        XCTAssertEqual(mini.pathText, "直连 192.168.1.5:41641")
        let offline = try XCTUnwrap(peers.first { $0.hostName == "old-pc" })
        XCTAssertEqual(offline.pathText, "离线")
    }

    func testPeersRejectsMalformedJSON() {
        XCTAssertNil(TailscaleServe.peers(fromStatusJSON: "not json"))
        XCTAssertEqual(TailscaleServe.peers(fromStatusJSON: "{}"), [])
    }

    func testPingParsesRelayAndDirectSamples() {
        let output = """
        pong from pixel (192.0.2.9) via DERP(tok) in 178ms
        pong from pixel (192.0.2.9) via 192.168.1.5:41641 in 4ms
        direct connection not established
        """
        let report = TailscaleServe.pingReport(fromOutput: output)
        XCTAssertEqual(report.samples, [
            TailscalePingSample(milliseconds: 178, relay: "tok", directAddress: nil),
            TailscalePingSample(milliseconds: 4, relay: nil, directAddress: "192.168.1.5:41641")
        ])
        XCTAssertEqual(report.minimum, 4)
        XCTAssertEqual(report.maximum, 178)
        // 采样数为偶数时取中间偏大的那个：[4, 178] 的中位就是 178。
        XCTAssertEqual(report.median, 178)
    }

    func testPingKeepsOutputWhenTheCommandExitsNonZero() throws {
        let silent = RecordingRunner()
        let serve = TailscaleServe(runner: silent, candidates: [binary], isExecutable: { _ in true })
        XCTAssertNil(serve.ping(ipv4: "192.0.2.9"), "命令无输出时应为 nil，而不是空报告")

        let relayed = FailingExitRunner()
        relayed.output = "pong from pixel (192.0.2.9) via DERP(tok) in 281ms\n"
        let report = try XCTUnwrap(TailscaleServe(runner: relayed, candidates: [binary], isExecutable: { _ in true })
            .ping(ipv4: "192.0.2.9"))
        XCTAssertEqual(report.samples.first?.relay, "tok")
    }

    func testNetcheckParsesLatenciesAndSkipsUnreachableRegions() {
        let output = """
        Report:
        	* UDP: true
        	* IPv4: yes, 1.2.3.4:41641
        	* MappingVariesByDestIP: false
        	* PortMapping: UPnP
        	* Nearest DERP: Tokyo
        	* DERP latency:
        		- sin: 94.3ms  (Singapore)
        		- tok: 178.6ms  (Tokyo)
        		- hnl:         (Honolulu)
        """
        let report = TailscaleServe.netcheckReport(fromOutput: output)
        XCTAssertEqual(report.udp, true)
        XCTAssertEqual(report.ipv4, "1.2.3.4:41641")
        XCTAssertEqual(report.mappingVariesByDestIP, false)
        XCTAssertEqual(report.portMapping, "UPnP")
        XCTAssertEqual(report.nearestDERP, "Tokyo")
        XCTAssertEqual(report.derpLatencies, [
            TailscaleDERPLatency(code: "sin", region: "Singapore", milliseconds: 94),
            TailscaleDERPLatency(code: "tok", region: "Tokyo", milliseconds: 179)
        ])
        XCTAssertEqual(report.region(for: "tok"), "Tokyo")
    }

    func testReportTextStatesThatThePathIsRelayed() {
        let peer = TailscalePeer(
            hostName: "pixel", os: "android", ipv4: "192.0.2.9",
            online: true, directAddress: nil, relay: "tok"
        )
        let report = TailscaleLatencyReport(
            peer: peer,
            ping: TailscalePingReport(samples: [
                TailscalePingSample(milliseconds: 178, relay: "tok", directAddress: nil),
                TailscalePingSample(milliseconds: 181, relay: "tok", directAddress: nil)
            ]),
            netcheck: TailscaleNetcheckReport(
                udp: true, ipv4: "1.2.3.4:41641", mappingVariesByDestIP: false,
                portMapping: "UPnP", nearestDERP: "tok",
                derpLatencies: [TailscaleDERPLatency(code: "tok", region: "Tokyo", milliseconds: 178)]
            )
        )
        XCTAssertEqual(report.verdict, "全程经中转 tok（Tokyo），往返 181 ms。")
        XCTAssertTrue(report.text.contains("最小 178 ms · 中位 181 ms · 最大 181 ms"))
        XCTAssertTrue(report.text.contains("UDP 可用"))
        XCTAssertTrue(report.text.contains("Tailscale 记录：中转 tok"))
        XCTAssertTrue(report.text.contains("采样路径：中转 tok ×2"))
    }

    func testReportSeparatesStatusSnapshotFromMeasuredPaths() {
        // 真实案例：status 说是中转，三包全是直连。一行“当前路径：中转”会被误读成
        // “现在就在绕中转”，所以快照和实测分开写。
        let peer = TailscalePeer(
            hostName: "li-server-2060", os: "linux", ipv4: "192.0.2.4",
            online: true, directAddress: nil, relay: "tok"
        )
        let report = TailscaleLatencyReport(
            peer: peer,
            ping: TailscalePingReport(samples: [
                TailscalePingSample(milliseconds: 195, relay: nil, directAddress: "198.51.100.5:41641"),
                TailscalePingSample(milliseconds: 143, relay: nil, directAddress: "198.51.100.5:41641"),
                TailscalePingSample(milliseconds: 21, relay: nil, directAddress: "198.51.100.5:41641")
            ]),
            netcheck: nil
        )
        XCTAssertTrue(report.text.contains("Tailscale 记录：中转 tok"))
        XCTAssertTrue(report.text.contains("采样路径：直连 ×3"))
        XCTAssertEqual(report.verdict, "全程直连（198.51.100.5:41641），往返 143 ms。")
    }

    func testReportTextExplainsSilenceWithoutPretendingItIsSlow() {
        let peer = TailscalePeer(
            hostName: "old-pc", os: "windows", ipv4: "192.0.2.7",
            online: false, directAddress: nil, relay: nil
        )
        let report = TailscaleLatencyReport(peer: peer, ping: TailscalePingReport(), netcheck: nil)
        XCTAssertTrue(report.verdict.contains("没有收到回应"))
        XCTAssertTrue(report.text.contains("本机网络：没有取到"))
    }
}
