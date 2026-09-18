import Foundation

struct ServiceConfiguration: Equatable {
    enum QuitBehavior: String, CaseIterable {
        case ask
        case keepRunning
        case stopService

        var title: String {
            switch self {
            case .ask: return "每次退出时询问"
            case .keepRunning: return "退出但保持服务运行"
            case .stopService: return "退出并停止服务"
            }
        }
    }

    var hostname: String
    var port: Int
    var piWebPath: String
    var allowedHosts: String
    var httpProxy: String
    var httpsProxy: String
    var noProxy: String
    var autoStart: Bool
    var quitBehavior: QuitBehavior

    static let defaultHostname = "127.0.0.1"
    static let defaultPort = 30141
    static let defaultAllowedHosts = ""
    static let defaultProxy = ""
    static let defaultNoProxy = "localhost,127.0.0.1,::1"

    private enum Key {
        static let hostname = "service.hostname"
        static let port = "service.port"
        static let piWebPath = "service.piWebPath"
        static let allowedHosts = "service.allowedHosts"
        static let httpProxy = "service.httpProxy"
        static let httpsProxy = "service.httpsProxy"
        static let noProxy = "service.noProxy"
        static let autoStart = "service.autoStart"
        static let quitBehavior = "service.quitBehavior"
    }

    static var `default`: ServiceConfiguration {
        ServiceConfiguration(
            hostname: defaultHostname,
            port: defaultPort,
            piWebPath: "",
            allowedHosts: defaultAllowedHosts,
            httpProxy: defaultProxy,
            httpsProxy: defaultProxy,
            noProxy: defaultNoProxy,
            autoStart: true,
            quitBehavior: .ask
        )
    }

    static func load(from defaults: UserDefaults = .standard) -> ServiceConfiguration {
        let fallback = Self.default
        let behavior = QuitBehavior(rawValue: defaults.string(forKey: Key.quitBehavior) ?? "") ?? fallback.quitBehavior
        let storedPort = defaults.object(forKey: Key.port) as? Int

        return ServiceConfiguration(
            hostname: defaults.string(forKey: Key.hostname) ?? fallback.hostname,
            port: storedPort.flatMap { (1...65535).contains($0) ? $0 : nil } ?? fallback.port,
            piWebPath: defaults.string(forKey: Key.piWebPath) ?? fallback.piWebPath,
            allowedHosts: defaults.string(forKey: Key.allowedHosts) ?? fallback.allowedHosts,
            httpProxy: defaults.string(forKey: Key.httpProxy) ?? fallback.httpProxy,
            httpsProxy: defaults.string(forKey: Key.httpsProxy) ?? fallback.httpsProxy,
            noProxy: defaults.string(forKey: Key.noProxy) ?? fallback.noProxy,
            autoStart: defaults.object(forKey: Key.autoStart) as? Bool ?? fallback.autoStart,
            quitBehavior: behavior
        )
    }

    func save(to defaults: UserDefaults = .standard) {
        defaults.set(hostname, forKey: Key.hostname)
        defaults.set(port, forKey: Key.port)
        defaults.set(piWebPath, forKey: Key.piWebPath)
        defaults.set(allowedHosts, forKey: Key.allowedHosts)
        defaults.set(httpProxy, forKey: Key.httpProxy)
        defaults.set(httpsProxy, forKey: Key.httpsProxy)
        defaults.set(noProxy, forKey: Key.noProxy)
        defaults.set(autoStart, forKey: Key.autoStart)
        defaults.set(quitBehavior.rawValue, forKey: Key.quitBehavior)
    }

    var serviceURL: URL {
        var components = URLComponents()
        components.scheme = "http"
        // IPv6 字面量必须加方括号：URLComponents 对 host = "::1" 会返回 nil，
        // 否则这里会静默回落到 127.0.0.1 并连错地址。
        components.host = RemoteAccessPolicy.urlHost(for: hostname)
        components.port = port
        components.path = "/"
        return components.url ?? URL(string: "http://127.0.0.1:30141/")!
    }

    var runtimeSignature: String {
        [hostname, String(port), piWebPath, allowedHosts, httpProxy, httpsProxy, noProxy].joined(separator: "\u{1F}.")
    }
}
