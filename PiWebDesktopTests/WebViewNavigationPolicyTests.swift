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
}
