import Foundation
import XCTest

final class WebViewNavigationPolicyTests: XCTestCase {
    private let port = 30141

    private func url(_ raw: String) throws -> URL {
        try XCTUnwrap(URL(string: raw), "invalid URL literal: \(raw)")
    }

    /// 默认服务地址，与 `ServiceConfiguration` 的默认值一致。
    private var defaultService: String { "http://127.0.0.1:\(port)/" }

    private func decision(_ raw: String, service rawService: String) throws -> WebViewNavigationDecision {
        try WebViewNavigationPolicy.decision(for: url(raw), serviceURL: url(rawService))
    }

    func testLoopbackHostsOnTheServicePortAreLocal() throws {
        for host in ["127.0.0.1", "localhost", "[::1]", "LOCALHOST"] {
            let localURL = try url("http://\(host):\(port)/index.html")
            XCTAssertTrue(WebViewNavigationPolicy.isLocalURL(localURL, port: port), host)
            XCTAssertEqual(try decision("http://\(host):\(port)/index.html", service: defaultService), .allow, host)
        }
    }

    func testLoopbackURLsWithoutAPortUseTheConfiguredPort() throws {
        XCTAssertTrue(WebViewNavigationPolicy.isLocalURL(try url("http://127.0.0.1/"), port: port))
        XCTAssertTrue(WebViewNavigationPolicy.isLocalURL(try url("http://localhost/app"), port: port))
        XCTAssertTrue(WebViewNavigationPolicy.isLocalURL(try url("https://127.0.0.1:\(port)/app"), port: port))
        XCTAssertEqual(try decision("http://127.0.0.1/", service: defaultService), .allow)
    }

    func testLoopbackOnAnotherPortOpensExternally() throws {
        let otherPortURL = try url("http://127.0.0.1:30142/")
        XCTAssertFalse(WebViewNavigationPolicy.isLocalURL(otherPortURL, port: port))
        XCTAssertEqual(try decision("http://127.0.0.1:30142/", service: defaultService), .openExternally)
    }

    func testNonLoopbackHostsOpenExternally() throws {
        for raw in ["https://example.com/", "http://192.168.0.10:\(port)/", "http://127.0.0.1.example.com/", "http://[::2]:\(port)/"] {
            XCTAssertEqual(try decision(raw, service: defaultService), .openExternally, raw)
        }
    }

    /// outD-5：只有 http/https/mailto 允许交给系统默认 handler。`file:` 会让
    /// LaunchServices 直接启动任意 .app，自定义 scheme 会拉起任意第三方 handler。
    func testOnlyWebAndMailSchemesMayOpenExternally() throws {
        XCTAssertEqual(try decision("https://example.com/a", service: defaultService), .openExternally)
        XCTAssertEqual(try decision("http://example.com/a", service: defaultService), .openExternally)
        XCTAssertEqual(try decision("mailto:someone@example.invalid", service: defaultService), .openExternally)
        // 大小写不敏感（URL scheme 规范化后仍是小写，这里同时把原始字符串写大写验证）。
        XCTAssertTrue(WebViewNavigationPolicy.canOpenExternally(try url("MAILTO:a@b.invalid")))

        let blocked = [
            "file:///System/Applications/Calculator.app",
            "file:///etc/hosts",
            "x-apple.systempreferences:com.apple.preference.security",
            "ssh://someone@example.invalid",
            "ftp://127.0.0.1/file",
            "tel:+123456",
            "javascript:alert(1)"
        ]
        for raw in blocked {
            let candidate = try url(raw)
            XCTAssertEqual(try decision(raw, service: defaultService), .block, raw)
            XCTAssertFalse(WebViewNavigationPolicy.canOpenExternally(candidate), raw)
            XCTAssertFalse(WebViewNavigationPolicy.isAllowedURL(candidate, serviceURL: try url(defaultService)), raw)
        }
        // 没有 scheme 的相对 URL 不能外开。
        XCTAssertEqual(try decision("relative/path", service: defaultService), .block)
    }

    /// 外开白名单不能把 loopback 其它端口 / 外部主机的 http(s) 收回来：它们仍然是外开。
    func testExternalHTTPSStillOpensExternally() throws {
        for raw in ["https://example.com/", "http://192.168.0.10:\(port)/"] {
            XCTAssertEqual(try decision(raw, service: defaultService), .openExternally, raw)
        }
    }

    func testInlineSchemesStayInTheWebView() throws {
        for raw in ["about:blank", "data:text/html,hello", "blob:http://127.0.0.1:\(port)/blob-id"] {
            let inlineURL = try url(raw)
            XCTAssertEqual(try decision(raw, service: defaultService), .allow, raw)
            XCTAssertFalse(WebViewNavigationPolicy.isLocalURL(inlineURL, port: port), raw)
            XCTAssertFalse(WebViewNavigationPolicy.isAllowedURL(inlineURL, serviceURL: try url(defaultService)), raw)
        }
    }

    func testInlineSchemeHelperIsCaseInsensitiveAndRejectsUnknownSchemes() {
        XCTAssertTrue(WebViewNavigationPolicy.isInlineScheme("ABOUT"))
        XCTAssertTrue(WebViewNavigationPolicy.isInlineScheme("Data"))
        XCTAssertFalse(WebViewNavigationPolicy.isInlineScheme("http"))
        XCTAssertFalse(WebViewNavigationPolicy.isInlineScheme(nil))
    }

    /// scheme 与 host 大小写不影响判定，端口必须精确匹配；`localhost.localdomain`
    /// 这类同前缀主机不能因为看起来像 localhost 而被放行。
    func testSchemeAndHostComparisonIsNormalized() throws {
        XCTAssertEqual(try decision("HTTP://127.0.0.1:\(port)/app", service: defaultService), .allow)
        XCTAssertEqual(try decision("HTTPS://LOCALHOST/", service: "https://localhost:\(port)/"), .allow)
        XCTAssertEqual(try decision("http://[::1]/", service: "http://[::1]:\(port)/"), .allow)
        XCTAssertEqual(try decision("http://127.0.0.1:80/", service: defaultService), .openExternally)
        XCTAssertEqual(try decision("http://localhost.localdomain/", service: defaultService), .openExternally)
    }

    // MARK: - 当前服务地址（#149）

    /// 夹具用 100 段的非 CGNAT 地址：`Scripts/check-identity.sh` 会扫描 CGNAT 私有段的
    /// 字面量并判失败，所以测试里不写真实 CGNAT 地址。判定与网段无关，只比 host 是否
    /// 与配置完全一致。
    private let remoteServiceHost = "100.200.13.7"

    private var remoteService: String { "http://\(remoteServiceHost):\(port)/" }

    /// 应用自己配置并启动的服务来源留在 WebView：只比对来源（scheme + host + port），
    /// 路径与查询串不参与判定；服务地址不是 loopback 时同样放行。
    func testConfiguredServiceOriginStaysInTheWebViewEvenWhenItIsNotLoopback() throws {
        for raw in [
            "http://\(remoteServiceHost):\(port)/",
            "http://\(remoteServiceHost):\(port)/index.html",
            "HTTP://\(remoteServiceHost):\(port)/app",
            "http://\(remoteServiceHost):\(port)/?q=1",
        ] {
            XCTAssertEqual(try decision(raw, service: remoteService), .allow, raw)
        }
    }

    /// 服务地址之外的主机一律外开：同一配置 host 的其它端口、同网段的其它地址、
    /// mDNS 后缀与普通域名都不例外（判定不做任何网段或后缀白名单）。
    func testHostsOtherThanTheConfiguredServiceOriginOpenExternally() throws {
        for raw in [
            "http://\(remoteServiceHost):30142/",
            "http://100.200.13.8:\(port)/",
            "http://192.168.0.10:\(port)/",
            "http://pi.local:\(port)/",
            "http://example.com/",
        ] {
            XCTAssertEqual(try decision(raw, service: remoteService), .openExternally, raw)
        }
    }

    /// 来源比对要求 scheme 一致：服务地址是 http 时，https 的同一主机不算同一来源。
    func testServiceOriginRequiresTheSameScheme() throws {
        XCTAssertEqual(try decision("https://\(remoteServiceHost):\(port)/", service: remoteService), .openExternally)
        XCTAssertEqual(try decision("http://\(remoteServiceHost):\(port)/", service: "https://\(remoteServiceHost):\(port)/"), .openExternally)
        XCTAssertEqual(try decision("HTTP://\(remoteServiceHost):\(port)/app", service: remoteService), .allow)
    }

    /// 服务地址是 IPv6 字面量时，方括号形式与 `ServiceConfiguration.serviceURL` 的
    /// 拼装路径一致（`RemoteAccessPolicy.urlHost(for:)` 补方括号），带方括号的导航
    /// URL 能被判定为同一来源，其它 IPv6 主机仍然外开。
    func testIPv6ServiceOriginMatchesAcrossBracketForms() throws {
        var components = URLComponents()
        components.scheme = "http"
        components.host = RemoteAccessPolicy.urlHost(for: "::1")
        components.port = port
        components.path = "/"
        let configuredService = try XCTUnwrap(components.url)
        XCTAssertEqual(configuredService.absoluteString, "http://[::1]:\(port)/")
        XCTAssertTrue(WebViewNavigationPolicy.isServiceURL(try url("http://[::1]:\(port)/app"), serviceURL: configuredService))
        XCTAssertEqual(try decision("http://[::1]:\(port)/app", service: configuredService.absoluteString), .allow)
        XCTAssertEqual(try decision("http://[::2]:\(port)/app", service: configuredService.absoluteString), .openExternally)
    }

    /// loopback 允许面保留：服务配置在别的地址上时，loopback + 服务端口仍留在 WebView。
    func testLoopbackSurfaceStaysAllowedForANonLoopbackService() throws {
        for raw in ["http://127.0.0.1:\(port)/", "http://localhost:\(port)/", "http://[::1]:\(port)/"] {
            XCTAssertEqual(try decision(raw, service: remoteService), .allow, raw)
        }
        XCTAssertEqual(try decision("http://127.0.0.1:30142/", service: remoteService), .openExternally)
    }

    // MARK: - 导航失败判定

    private func urlError(_ code: Int, description: String? = nil) -> NSError {
        var userInfo: [String: Any] = [:]
        if let description {
            userInfo[NSLocalizedDescriptionKey] = description
        }
        return NSError(domain: NSURLErrorDomain, code: code, userInfo: userInfo)
    }

    private func webKitWrapper(around error: NSError, description: String? = nil) -> NSError {
        var userInfo: [String: Any] = [NSUnderlyingErrorKey: error]
        if let description {
            userInfo[NSLocalizedDescriptionKey] = description
        }
        return NSError(domain: "WebKitErrorDomain", code: 302, userInfo: userInfo)
    }

    /// -999（`NSURLErrorCancelled`）不是导航失败：直接以 `URLError` / `NSError`
    /// 上报时都返回 `nil`。
    func testCancelledNavigationIsNotReportedAsFailure() {
        XCTAssertNil(WebViewNavigationPolicy.navigationFailure(for: URLError(.cancelled)))
        XCTAssertNil(WebViewNavigationPolicy.navigationFailure(for: urlError(-999)))
    }

    /// WebKit 常把真正的加载错误包在 `NSUnderlyingErrorKey` 里；无论包装多少层，
    /// 链上的 -999 都必须判定为取消。
    func testDeeplyWrappedCancelledNavigationIsNotReportedAsFailure() {
        let inner = urlError(-999, description: "已取消")
        let middle = webKitWrapper(around: inner)
        let outer = webKitWrapper(around: middle)
        XCTAssertNil(WebViewNavigationPolicy.navigationFailure(for: outer))
    }

    /// -1004（`NSURLErrorCannotConnectToHost`）与 -1001（`NSURLErrorTimedOut`）
    /// 归为「无法连接」；包装在非 URL 错误域里的 -1004 也要沿包装链找到。
    /// 上报文案保持顶层错误的 `localizedDescription`，与修复前一致。
    func testConnectionErrorsAreReportedAsConnectionFailures() {
        XCTAssertEqual(
            WebViewNavigationPolicy.navigationFailure(for: urlError(-1004, description: "连不上")),
            .connectionFailed("连不上")
        )
        XCTAssertEqual(
            WebViewNavigationPolicy.navigationFailure(for: urlError(-1001, description: "超时")),
            .connectionFailed("超时")
        )
        let wrapped = webKitWrapper(around: urlError(-1004, description: "连不上"), description: "WebKit 包装")
        XCTAssertEqual(WebViewNavigationPolicy.navigationFailure(for: wrapped), .connectionFailed("WebKit 包装"))
    }

    /// -1003（`NSURLErrorCannotFindHost`）不属于连接失败 → `.loadFailed`。
    func testHostLookupErrorsAreReportedAsPageLoadFailures() {
        XCTAssertEqual(
            WebViewNavigationPolicy.navigationFailure(for: urlError(-1003, description: "找不到主机")),
            .loadFailed("找不到主机")
        )
    }

    /// 非 URL 加载错误（自定义错误域）同样归为 `.loadFailed`，保持原有错误页路径。
    func testNonURLLoadingErrorsAreReportedAsPageLoadFailures() {
        let error = NSError(domain: "ExampleDomain", code: 1, userInfo: [NSLocalizedDescriptionKey: "解析失败"])
        XCTAssertEqual(WebViewNavigationPolicy.navigationFailure(for: error), .loadFailed("解析失败"))
    }

    // MARK: - 外开白名单的接线（源码级，outD-5）

    /// 执行侧唯一允许调用 `NSWorkspace.open` 的入口必须过白名单。
    /// 回归点：修复前两条路径都是裸调 `NSWorkspace.shared.open(url)`。
    func testWebViewControllerGatesEveryExternalOpen() throws {
        let source = SourceScan.codeText(of: try SourceScan.text(named: "WebViewController.swift"))
        let opens = source.components(separatedBy: "NSWorkspace.shared.open(")
        XCTAssertEqual(opens.count - 1, 1, "外开只能集中在一处，否则闸控会被绕过")
        let helper = try XCTUnwrap(source.range(of: "private func openExternally"))
        let helperBody = String(source[helper.lowerBound...].prefix(400))
        XCTAssertTrue(
            helperBody.contains("guard WebViewNavigationPolicy.canOpenExternally(url)"),
            "外开前必须过协议白名单"
        )
        XCTAssertTrue(source.contains("onBlockedExternalNavigation?(url)"), "被拒绝时必须上报，不能静默")
        XCTAssertTrue(source.contains("case .block:"), "策略的 `.block` 分支必须有处理")
    }

    /// AppDelegate 必须把拒绝事件接上日志（否则拒绝证据在诊断里不可见）。
    func testAppDelegateLogsBlockedExternalNavigation() throws {
        let app = try SourceScan.codeText(of: try SourceScan.text(ofFamily: "AppDelegate"))
        XCTAssertTrue(app.contains("controller.onBlockedExternalNavigation = {"))
        XCTAssertTrue(app.contains("已拒绝打开非白名单协议的链接"))
    }
}
