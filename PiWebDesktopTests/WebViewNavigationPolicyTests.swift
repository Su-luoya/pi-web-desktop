import Foundation
import XCTest

final class WebViewNavigationPolicyTests: XCTestCase {
    private let port = 30141

    private func url(_ raw: String) throws -> URL {
        try XCTUnwrap(URL(string: raw), "invalid URL literal: \(raw)")
    }

    func testLoopbackHostsOnTheServicePortAreLocal() throws {
        for host in ["127.0.0.1", "localhost", "[::1]", "LOCALHOST"] {
            let localURL = try url("http://\(host):\(port)/index.html")
            XCTAssertTrue(WebViewNavigationPolicy.isLocalURL(localURL, port: port), host)
            XCTAssertEqual(WebViewNavigationPolicy.decision(for: localURL, port: port), .allow, host)
        }
    }

    func testLoopbackURLsWithoutAPortUseTheConfiguredPort() throws {
        XCTAssertTrue(WebViewNavigationPolicy.isLocalURL(try url("http://127.0.0.1/"), port: port))
        XCTAssertTrue(WebViewNavigationPolicy.isLocalURL(try url("http://localhost/app"), port: port))
        XCTAssertTrue(WebViewNavigationPolicy.isLocalURL(try url("https://127.0.0.1:\(port)/app"), port: port))
    }

    func testLoopbackOnAnotherPortOpensExternally() throws {
        let otherPortURL = try url("http://127.0.0.1:30142/")
        XCTAssertFalse(WebViewNavigationPolicy.isLocalURL(otherPortURL, port: port))
        XCTAssertEqual(WebViewNavigationPolicy.decision(for: otherPortURL, port: port), .openExternally)
    }

    func testNonLoopbackHostsOpenExternally() throws {
        for raw in ["https://example.com/", "http://192.168.0.10:\(port)/", "http://127.0.0.1.example.com/", "http://[::2]:\(port)/"] {
            XCTAssertEqual(WebViewNavigationPolicy.decision(for: try url(raw), port: port), .openExternally, raw)
        }
    }

    func testNonHTTPSchemesOpenExternally() throws {
        for raw in ["file:///tmp/index.html", "ftp://127.0.0.1/file", "mailto:someone@example.invalid"] {
            XCTAssertEqual(WebViewNavigationPolicy.decision(for: try url(raw), port: port), .openExternally, raw)
        }
        XCTAssertFalse(WebViewNavigationPolicy.isLocalURL(try url("ftp://127.0.0.1/file"), port: port))
    }

    func testInlineSchemesStayInTheWebView() throws {
        for raw in ["about:blank", "data:text/html,hello", "blob:http://127.0.0.1:\(port)/blob-id"] {
            let inlineURL = try url(raw)
            XCTAssertEqual(WebViewNavigationPolicy.decision(for: inlineURL, port: port), .allow, raw)
            XCTAssertFalse(WebViewNavigationPolicy.isLocalURL(inlineURL, port: port), raw)
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
        XCTAssertEqual(WebViewNavigationPolicy.decision(for: try url("HTTP://127.0.0.1:\(port)/app"), port: port), .allow)
        XCTAssertEqual(WebViewNavigationPolicy.decision(for: try url("HTTPS://LOCALHOST/"), port: port), .allow)
        XCTAssertEqual(WebViewNavigationPolicy.decision(for: try url("http://[::1]/"), port: port), .allow)
        XCTAssertEqual(WebViewNavigationPolicy.decision(for: try url("http://127.0.0.1:80/"), port: port), .openExternally)
        XCTAssertEqual(WebViewNavigationPolicy.decision(for: try url("http://localhost.localdomain/"), port: port), .openExternally)
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
}
