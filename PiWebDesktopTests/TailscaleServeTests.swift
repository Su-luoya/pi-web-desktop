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
}
