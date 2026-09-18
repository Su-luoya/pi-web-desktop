import Foundation

/// What WebKit should do with a navigation request.
enum WebViewNavigationDecision: Equatable {
    case allow
    case openExternally
}

/// Pure navigation policy used by `WebViewController`.
///
/// Kept free of Cocoa/WebKit so the local/external URL rules can be unit tested
/// in the unhosted test target.
enum WebViewNavigationPolicy {
    /// Hosts that belong to the local service.
    static let localHosts: Set<String> = ["127.0.0.1", "localhost", "::1"]
    /// Schemes rendered inside the web view without a network request.
    static let inlineSchemes: Set<String> = ["about", "blob", "data"]

    /// A URL is local when it uses http(s), targets a loopback host and either
    /// states the configured port or omits it.
    static func isLocalURL(_ url: URL, port: Int) -> Bool {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return false }
        return localHosts.contains(url.host?.lowercased() ?? "") && (url.port ?? port) == port
    }

    static func isInlineScheme(_ scheme: String?) -> Bool {
        inlineSchemes.contains(scheme?.lowercased() ?? "")
    }

    /// Navigation decision: local and inline URLs stay in the web view,
    /// everything else opens in the default browser.
    static func decision(for url: URL, port: Int) -> WebViewNavigationDecision {
        if isLocalURL(url, port: port) || isInlineScheme(url.scheme) {
            return .allow
        }
        return .openExternally
    }
}
