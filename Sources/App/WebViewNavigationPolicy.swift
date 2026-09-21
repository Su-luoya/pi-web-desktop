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
