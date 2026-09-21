import Foundation

/// What WebKit should do with a navigation request.

/// Local/external URL classification for web navigation.

enum WebViewNavigationDecision: Equatable {
    case allow
    case openExternally
}

/// Navigation failure classification for web navigation.

enum WebViewNavigationFailure: Equatable {
    case loadFailed(String)
    case connectionFailed(String)
}

/// Pure navigation policy used by `WebViewController`.
///
/// Kept free of Cocoa/WebKit so the local/external URL rules and the failure
/// mapping can be unit tested in the unhosted test target.
enum WebViewNavigationPolicy {
    /// Hosts that belong to the local service.
    static let localHosts: Set<String> = ["127.0.0.1", "localhost", "::1"]
    /// Schemes rendered inside the web view without a network request.
    static let inlineSchemes: Set<String> = ["about", "blob", "data"]

    /// A URL is local when it uses http(s), targets a loopback host and either
    /// states the configured port or omits it.
    static func isLocalURL(_ url: URL, port: Int) -> Bool {
        guard isWebScheme(url.scheme) else { return false }
        return localHosts.contains(normalizedHost(url.host)) && (url.port ?? port) == port
    }

    /// A URL is the configured service origin when scheme, host and port match
    /// `serviceURL` exactly; path and query are irrelevant.
    ///
    /// This is the only non-loopback entry in the allow surface (#149), and it
    /// exists because the app compares against the address it configured and
    /// started itself. It is not a network-class rule: the configured service
    /// may sit behind a tunnel or be any other host, but only that exact origin
    /// is allowed, so the allow surface never widens beyond the service.
    static func isServiceURL(_ url: URL, serviceURL: URL) -> Bool {
        guard isWebScheme(url.scheme), isWebScheme(serviceURL.scheme) else { return false }
        return url.scheme?.lowercased() == serviceURL.scheme?.lowercased()
            && normalizedHost(url.host) == normalizedHost(serviceURL.host)
            && url.port == serviceURL.port
    }

    /// Everything without an inline scheme that stays inside the web view: the
    /// configured service origin plus the loopback URLs on the service port.
    static func isAllowedURL(_ url: URL, serviceURL: URL) -> Bool {
        if isServiceURL(url, serviceURL: serviceURL) { return true }
        // 没有配置端口时不存在“端口等于服务端口”的 loopback 允许面。
        guard let port = serviceURL.port else { return false }
        return isLocalURL(url, port: port)
    }

    static func isInlineScheme(_ scheme: String?) -> Bool {
        inlineSchemes.contains(scheme?.lowercased() ?? "")
    }

    /// Navigation decision: the configured service, loopback URLs and inline
    /// URLs stay in the web view, everything else opens in the default browser.
    static func decision(for url: URL, serviceURL: URL) -> WebViewNavigationDecision {
        if isAllowedURL(url, serviceURL: serviceURL) || isInlineScheme(url.scheme) {
            return .allow
        }
        return .openExternally
    }

    /// http(s) 是唯一允许留在 WebView 里的协议；`file:`、`mailto:` 等一律外开。
    private static func isWebScheme(_ scheme: String?) -> Bool {
        ["http", "https"].contains(scheme?.lowercased() ?? "")
    }

    /// 比较用的 host：大小写不敏感，IPv6 字面量去掉方括号，`[::1]` 与 `::1`
    /// 视为同一主机。去括号规则复用 `RemoteAccessPolicy.normalizedHostname`，
    /// 与配置保存、`urlHost(for:)` 拼 URL 时的规范化保持同一处定义。
    private static func normalizedHost(_ host: String?) -> String {
        RemoteAccessPolicy.normalizedHostname(host ?? "").lowercased()
    }

    /// 无法连接类错误码：连不上主机（-1004）与请求超时（-1001）。
    /// 找不到主机（-1003）、DNS 解析失败（-1006）等其余加载错误都归为
    /// `.loadFailed`。
    static let connectionFailureCodes: Set<URLError.Code> = [.cannotConnectToHost, .timedOut]

    /// 把 WebKit 报出的错误映射为需要上报的导航失败。
    ///
    /// 按错误码判定（不匹配 `localizedDescription` 文本），优先级从高到低：
    /// 1. `NSURLErrorCancelled`（-999）→ `nil`：取消不是失败，例如外链交给
    ///    系统浏览器打开后 WebKit 取消掉的导航；
    /// 2. `connectionFailureCodes`（-1004、-1001）→ `.connectionFailed`；
    /// 3. 其余 → `.loadFailed`。
    ///
    /// WebKit 常把真正的加载错误包在 `NSError` 的 `NSUnderlyingErrorKey`
    /// 里，所以判定沿包装链查找：链上任何一层是取消就按取消处理，否则链上
    /// 存在「无法连接」错误码时按 `.connectionFailed` 处理。上报文案保持原
    /// 错误对象的 `localizedDescription`，与修复前一致。
    static func navigationFailure(for error: Error) -> WebViewNavigationFailure? {
        let nsError = error as NSError
        let codes = urlLoadingErrorCodes(in: nsError)
        if codes.contains(.cancelled) {
            return nil
        }
        if codes.contains(where: connectionFailureCodes.contains) {
            return .connectionFailed(nsError.localizedDescription)
        }
        return .loadFailed(nsError.localizedDescription)
    }

    /// 沿 `NSUnderlyingErrorKey` 包装链收集 `NSURLErrorDomain` 错误码。
    private static func urlLoadingErrorCodes(in error: NSError) -> [URLError.Code] {
        var codes: [URLError.Code] = []
        var current: NSError? = error
        // 真实场景只有一两层包装，这里仍设上限，避免异常 userInfo 构造出环。
        for _ in 0..<8 {
            guard let candidate = current else { break }
            if candidate.domain == NSURLErrorDomain {
                codes.append(URLError.Code(rawValue: candidate.code))
            }
            current = candidate.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return codes
    }
}
