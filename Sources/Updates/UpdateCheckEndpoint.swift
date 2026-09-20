/// Endpoint description plus the injectable HTTP client used by update checks.

import Foundation

/// 一个只读端点：固定 URL + 允许的最终主机。
///
/// 检查器只接受由本类型的工厂方法构造的端点，因此端点主机是编译期常量，
/// 不会因为包名、配置或环境变量而指向其它主机。响应最终落到别的主机
/// （重定向）时，检查结果记为 unknown，不采信其内容。
struct UpdateEndpoint: Equatable {
    let url: URL
    /// 允许的最终主机（小写）。重定向后必须仍然命中，否则结果记为 unknown。
    let allowedHosts: Set<String>

    /// GitHub Releases 列表：取最近若干条发布，按语义化版本挑最高者（含预发布，
    /// 因为应用自身处于 alpha 阶段）。
    static let githubReleasePageSize = 20

    static func githubReleases(repository: String) -> UpdateEndpoint? {
        guard isRepositorySlug(repository) else { return nil }
        var components = URLComponents()
        components.scheme = "https"
        components.host = UpdateCheckUpstream.githubHost
        components.path = "/repos/\(repository)/releases"
        components.queryItems = [URLQueryItem(name: "per_page", value: String(githubReleasePageSize))]
        guard let url = components.url else { return nil }
        return UpdateEndpoint(url: url, allowedHosts: [UpdateCheckUpstream.githubHost])
    }

    /// npm registry 的 `/latest` 文档端点。作用域包名里的 `/` 编码为 `%2F`。
    static func npmLatest(packageName: String) -> UpdateEndpoint? {
        guard let encoded = encodedPackageName(packageName) else { return nil }
        guard let url = URL(string: "https://\(UpdateCheckUpstream.npmRegistryHost)/\(encoded)/latest") else {
            return nil
        }
        return UpdateEndpoint(url: url, allowedHosts: [UpdateCheckUpstream.npmRegistryHost])
    }

    /// `owner/repo` 形态校验：两段都非空，且只含 ASCII 字母、数字与 `-._`。
    static func isRepositorySlug(_ text: String) -> Bool {
        let parts = text.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return false }
        return parts.allSatisfy { part in
            !part.isEmpty && part.allSatisfy { character in
                character.isASCII && (character.isLetter || character.isNumber || character == "-" || character == "_" || character == ".")
            }
        }
    }

    /// npm 包名 → registry 路径段。复用 #16 的包名形态校验，只额外做百分号编码。
    static func encodedPackageName(_ packageName: String) -> String? {
        guard ComponentInstallationDetector.isPackageName(packageName) else { return nil }
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "@._-~")
        return packageName.addingPercentEncoding(withAllowedCharacters: allowed)
    }

    /// 主机是否在该端点的白名单内（大小写不敏感）。
    func allows(host: String?) -> Bool {
        guard let host = host?.lowercased(), !host.isEmpty else { return false }
        return allowedHosts.contains(host)
    }
}

// MARK: - HTTP 抽象（可注入）

/// 传输层失败的归类。只保留可理解的类别，不携带 URL、响应体或系统错误文本，
/// 因此不会把诊断信息带进缓存或界面。
enum UpdateHTTPFailure: String, Error, Equatable {
    case timedOut
    case offline
    case cancelled
    case transport
}

/// 一次只读 GET 请求。
///
/// 头字段刻意只有白名单内的四个：`Accept`、`User-Agent`、条件请求字段。
/// `sanitized()` 会丢弃其它任何头（cookie、Authorization、会话、诊断字段），
/// 生产客户端在发请求前也会再过滤一次，保证凭据永远不会被发出。
struct UpdateHTTPRequest: Equatable {
    var url: URL
    var method: String = "GET"
    var headers: [String: String] = [:]
    var timeout: TimeInterval = UpdateChecker.requestTimeout

    /// 允许出现的请求头（小写比较）。
    static let allowedHeaderNames: Set<String> = [
        "accept",
        "user-agent",
        "if-none-match",
        "if-modified-since"
    ]

    /// 只保留白名单内的头，并强制 GET。调用方误加的头不会到达网络层。
    func sanitized() -> UpdateHTTPRequest {
        var copy = self
        copy.method = "GET"
        copy.headers = headers.filter { Self.allowedHeaderNames.contains($0.key.lowercased()) }
        return copy
    }
}

/// 一次响应。`headers` 只保留条件请求与内容类型字段；`Set-Cookie`、
/// `x-ratelimit-*` 等响应头既不读取也不保存。
struct UpdateHTTPResponse: Equatable {
    var statusCode: Int
    var headers: [String: String]
    var body: Data
    /// 跟随重定向后的最终 URL；nil 表示没有重定向。
    var finalURL: URL?

    /// 生产客户端从 `HTTPURLResponse` 里保留的响应头。
    static let retainedHeaderNames: Set<String> = ["etag", "last-modified", "content-type"]

    var etag: String? { headers["etag"]?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty }
    var lastModified: String? { headers["last-modified"]?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty }

    static func retainedHeaders(from http: HTTPURLResponse) -> [String: String] {
        var headers: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
            guard let name = (key as? String)?.lowercased(),
                  retainedHeaderNames.contains(name),
                  let text = value as? String else { continue }
            headers[name] = text
        }
        return headers
    }
}

/// 更新检查使用的 HTTP 客户端。生产实现是 `URLSession`，测试注入替身并记录
/// 每一次请求，因此测试从不访问真实网络。
protocol UpdateHTTPClient: AnyObject {
    func perform(
        _ request: UpdateHTTPRequest,
        completion: @escaping (Result<UpdateHTTPResponse, UpdateHTTPFailure>) -> Void
    )
}

/// 生产实现：`URLSession` + 临时配置（不持久化缓存、cookies、凭据）。
///
/// 隐私约束：
/// - `URLSessionConfiguration.ephemeral` + `httpCookieStorage = nil` +
///   `httpShouldSetCookies = false` + `urlCredentialStorage = nil`：不发 cookie、
///   不保存凭据、不读取用户会话；
/// - 不跟随重定向：`willPerformHTTPRedirection` 一律拒绝，把 3xx 原样交给
///   检查器，因此请求不会落到白名单以外的主机；
/// - 只保留条件请求与内容类型响应头，其余（含 `Set-Cookie`）读完即丢。
final class URLSessionUpdateHTTPClient: NSObject, UpdateHTTPClient, URLSessionTaskDelegate {
    private let defaultTimeout: TimeInterval

    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = defaultTimeout
        configuration.timeoutIntervalForResource = defaultTimeout
        configuration.httpMaximumConnectionsPerHost = 1
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()

    init(timeout: TimeInterval = UpdateChecker.requestTimeout) {
        self.defaultTimeout = timeout
        super.init()
    }

    func perform(
        _ request: UpdateHTTPRequest,
        completion: @escaping (Result<UpdateHTTPResponse, UpdateHTTPFailure>) -> Void
    ) {
        let sanitized = request.sanitized()
        var urlRequest = URLRequest(url: sanitized.url)
        urlRequest.httpMethod = sanitized.method
        urlRequest.timeoutInterval = sanitized.timeout
        for (name, value) in sanitized.headers {
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }
        let task = session.dataTask(with: urlRequest) { data, response, error in
            if let error {
                completion(.failure(Self.failure(from: error)))
                return
            }
            guard let http = response as? HTTPURLResponse else {
                completion(.failure(.transport))
                return
            }
            completion(.success(UpdateHTTPResponse(
                statusCode: http.statusCode,
                headers: UpdateHTTPResponse.retainedHeaders(from: http),
                body: data ?? Data(),
                finalURL: http.url
            )))
        }
        task.resume()
    }

    /// 不跟随任何重定向。跨主机重定向因此不可能发生；同主机重定向也一律拒绝，
    /// 保持“只访问名单内的固定端点”这一可断言的规则。
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }

    static func failure(from error: Error) -> UpdateHTTPFailure {
        guard let urlError = error as? URLError else { return .transport }
        switch urlError.code {
        case .timedOut:
            return .timedOut
        case .notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost, .cannotFindHost,
             .dnsLookupFailed, .dataNotAllowed, .internationalRoamingOff:
            return .offline
        case .cancelled:
            return .cancelled
        default:
            return .transport
        }
    }
}
