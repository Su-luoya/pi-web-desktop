import Cocoa
import WebKit

/// Navigation failure reported to AppDelegate. AppDelegate owns the user
/// visible copy and decides whether to react (it ignores failures while the app
/// is quitting).
enum WebViewNavigationFailure: Equatable {
    case loadFailed(String)
    case connectionFailed(String)
}

/// Owns the WebKit surface: web view creation and configuration, navigation
/// policy, downloads, external links, the find bar and zoom.
///
/// AppDelegate only keeps the window and menu wiring and observes the minimal
/// callbacks below.
final class WebViewController: NSObject, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate {
    let webView: WKWebView

    /// Called when a page load fails; AppDelegate decides what to show.
    var onNavigationFailure: ((WebViewNavigationFailure) -> Void)?
    /// Called when WebKit starts a download. AppDelegate may observe it.
    var onDownloadStarted: (() -> Void)?

    private var serviceURL: URL
    private var servicePort: Int
    private let windowProvider: () -> NSWindow?
    private var findBar: NSView?
    private var findField: NSSearchField?

    init(serviceURL: URL, servicePort: Int, windowProvider: @escaping () -> NSWindow?) {
        self.serviceURL = serviceURL
        self.servicePort = servicePort
        self.windowProvider = windowProvider

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.preferences.setValue(true, forKey: "developerExtrasEnabled")
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()

        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsMagnification = true
        webView.allowsBackForwardNavigationGestures = true
    }

    // MARK: - Service endpoint

    func updateService(url: URL, port: Int) {
        serviceURL = url
        servicePort = port
    }

    func loadServicePage() {
        webView.load(URLRequest(url: serviceURL, cachePolicy: .reloadIgnoringLocalCacheData))
    }

    func reload() { webView.reload() }
    func reloadFromOrigin() { webView.reloadFromOrigin() }
    func zoomIn() { webView.pageZoom = min(webView.pageZoom + 0.1, 3.0) }
    func zoomOut() { webView.pageZoom = max(webView.pageZoom - 0.1, 0.5) }
    func resetZoom() { webView.pageZoom = 1.0 }

    // MARK: - Status pages

    func showLoadingPage(message: String) {
        let safe = Self.escapedHTML(message)
        let html = """
        <!doctype html><meta charset="utf-8"><style>
        html,body{height:100%;margin:0;background:#0b1020;color:#d7fff8;font:15px -apple-system,BlinkMacSystemFont,sans-serif}body{display:grid;place-items:center}.box{text-align:center}.pi{font:700 88px ui-monospace,monospace;color:#7fffe8;text-shadow:0 0 28px #21d9cc88}.msg{margin-top:18px;color:#a8b3cc}.dot{display:inline-block;animation:pulse 1s infinite alternate}@keyframes pulse{to{opacity:.25}}</style>
        <div class="box"><div class="pi">π</div><div class="msg">\(safe) <span class="dot">●</span></div></div>
        """
        webView.loadHTMLString(html, baseURL: nil)
    }

    /// 依赖前置不满足时的占位页：不加载服务页面，也不执行任何安装命令。
    func showDependencyPage(message: String) {
        let safe = Self.escapedHTML(message)
        let html = """
        <!doctype html><meta charset="utf-8"><style>
        html,body{height:100%;margin:0;background:#0b1020;color:#d7fff8;font:15px -apple-system,BlinkMacSystemFont,sans-serif}body{display:grid;place-items:center}.box{max-width:640px;padding:24px}.pi{font:700 64px ui-monospace,monospace;color:#7fffe8;text-shadow:0 0 28px #21d9cc88}h1{margin:14px 0 10px;font-size:18px}pre{margin:0;white-space:pre-wrap;color:#a8b3cc;font:13px ui-monospace,monospace;line-height:1.6}</style>
        <div class="box"><div class="pi">π</div><h1>无法启动 Pi Web 服务</h1><pre>\(safe)</pre></div>
        """
        webView.loadHTMLString(html, baseURL: nil)
    }

    private static func escapedHTML(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    func showErrorPage(message: String) {
        showLoadingPage(message: message)
    }

    // MARK: - Find bar

    func showFindBar(in window: NSWindow) {
        if findBar == nil { createFindBar(in: window) }
        findBar?.isHidden = false
        window.makeFirstResponder(findField)
    }

    private func createFindBar(in window: NSWindow) {
        guard let contentView = window.contentView else { return }
        let bar = NSVisualEffectView()
        bar.material = .headerView
        bar.blendingMode = .withinWindow
        bar.translatesAutoresizingMaskIntoConstraints = false
        let field = NSSearchField()
        field.placeholderString = "在页面中查找"
        field.target = self
        field.action = #selector(findText(_:))
        field.translatesAutoresizingMaskIntoConstraints = false
        let previous = NSButton(title: "‹", target: self, action: #selector(findPrevious(_:)))
        let next = NSButton(title: "›", target: self, action: #selector(findNext(_:)))
        let close = NSButton(title: "完成", target: self, action: #selector(closeFindBar(_:)))
        for button in [previous, next, close] { button.translatesAutoresizingMaskIntoConstraints = false; bar.addSubview(button) }
        bar.addSubview(field)
        contentView.addSubview(bar)
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: contentView.topAnchor), bar.trailingAnchor.constraint(equalTo: contentView.trailingAnchor), bar.heightAnchor.constraint(equalToConstant: 44), bar.widthAnchor.constraint(equalToConstant: 410),
            field.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 10), field.centerYAnchor.constraint(equalTo: bar.centerYAnchor), field.widthAnchor.constraint(equalToConstant: 250),
            previous.leadingAnchor.constraint(equalTo: field.trailingAnchor, constant: 4), previous.centerYAnchor.constraint(equalTo: bar.centerYAnchor), previous.widthAnchor.constraint(equalToConstant: 32),
            next.leadingAnchor.constraint(equalTo: previous.trailingAnchor, constant: 2), next.centerYAnchor.constraint(equalTo: bar.centerYAnchor), next.widthAnchor.constraint(equalToConstant: 32),
            close.leadingAnchor.constraint(equalTo: next.trailingAnchor, constant: 4), close.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -8), close.centerYAnchor.constraint(equalTo: bar.centerYAnchor)
        ])
        findBar = bar
        findField = field
    }

    @objc private func findText(_ sender: Any?) { performFind(backwards: false) }
    @objc private func findNext(_ sender: Any?) { performFind(backwards: false) }
    @objc private func findPrevious(_ sender: Any?) { performFind(backwards: true) }

    private func performFind(backwards: Bool) {
        guard let text = findField?.stringValue, !text.isEmpty else { return }
        if #available(macOS 11.0, *) {
            let configuration = WKFindConfiguration()
            configuration.backwards = backwards
            configuration.wraps = true
            webView.find(text, configuration: configuration) { _ in }
        }
    }

    @objc private func closeFindBar(_ sender: Any?) {
        findBar?.isHidden = true
        windowProvider()?.makeFirstResponder(webView)
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        onNavigationFailure?(.loadFailed(error.localizedDescription))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        onNavigationFailure?(.connectionFailed(error.localizedDescription))
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else { decisionHandler(.cancel); return }
        switch WebViewNavigationPolicy.decision(for: url, port: servicePort) {
        case .allow:
            decisionHandler(.allow)
        case .openExternally:
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        if !navigationResponse.canShowMIMEType {
            if #available(macOS 11.3, *) { decisionHandler(.download) } else { decisionHandler(.cancel) }
        } else { decisionHandler(.allow) }
    }

    // MARK: - WKDownloadDelegate

    @available(macOS 11.3, *)
    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = self
        onDownloadStarted?()
    }

    @available(macOS 11.3, *)
    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = self
        onDownloadStarted?()
    }

    @available(macOS 11.3, *)
    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
        guard let window = windowProvider() else {
            completionHandler(nil)
            return
        }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedFilename
        panel.beginSheetModal(for: window) { result in completionHandler(result == .OK ? panel.url : nil) }
    }

    // MARK: - WKUIDelegate

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        // Same rule as the pre-split implementation: a popup that targets the
        // local service replaces the current page, everything else is handed to
        // the system.
        if let url = navigationAction.request.url {
            if WebViewNavigationPolicy.isLocalURL(url, port: servicePort) {
                webView.load(URLRequest(url: url))
            } else {
                NSWorkspace.shared.open(url)
            }
        }
        return nil
    }

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) {
        guard let window = windowProvider() else {
            completionHandler(nil)
            return
        }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.canChooseFiles = true
        panel.beginSheetModal(for: window) { response in completionHandler(response == .OK ? panel.urls : nil) }
    }
}
