import Foundation

// MARK: - 检查目标（GitHub #17）

/// 更新检查的分类。每一类都可以按策略独立控制（“服务 → 更新检查设置 → 更新检查
/// 偏好设置…”）：桌面应用 / Pi CLI / Pi Web 为关闭 / 每日 / 每周，扩展包为关闭 /
/// 检查并通知 / 询问后更新；策略定义在 `Sources/UpdateSettings.swift`。
enum UpdateCheckCategory: String, CaseIterable, Equatable {
    case desktopApp = "desktop-app"
    case piCLI = "pi"
    case piWeb = "pi-web"
    case piPackages = "pi-packages"

    var displayName: String {
        switch self {
        case .desktopApp: return "桌面应用"
        case .piCLI: return "Pi CLI"
        case .piWeb: return "Pi Web"
        case .piPackages: return "Pi 扩展包"
        }
    }
}

/// 一个被检查对象：分类 + （扩展包才有的）具体包名。
struct UpdateCheckTarget: Equatable, Hashable {
    var category: UpdateCheckCategory
    /// 扩展包的包名（来自 #16 的 `pi list` 解析结果）；其它分类为 nil。
    var packageName: String?

    var id: String {
        if let packageName {
            return "\(category.rawValue):\(packageName)"
        }
        return category.rawValue
    }

    var displayName: String {
        if let packageName {
            return "\(category.displayName) \(packageName)"
        }
        return category.displayName
    }
}

/// `pi list` 报告的一个扩展包及其本机版本。
struct UpdateCheckPackage: Equatable {
    var name: String
    var installedVersion: String?
}

/// 本机已安装版本清单：#16 的组件识别结果是唯一输入。
///
/// 检查器只读这份清单，不自己执行命令，因此 unhosted 测试可以直接构造它，
/// 不触碰真实 `pi` / `npm`。
struct UpdateCheckInventory: Equatable {
    var desktopAppVersion: String?
    var piCLIVersion: String?
    var piWebVersion: String?
    var piPackages: [UpdateCheckPackage]

    init(
        desktopAppVersion: String? = nil,
        piCLIVersion: String? = nil,
        piWebVersion: String? = nil,
        piPackages: [UpdateCheckPackage] = []
    ) {
        self.desktopAppVersion = desktopAppVersion
        self.piCLIVersion = piCLIVersion
        self.piWebVersion = piWebVersion
        self.piPackages = piPackages
    }

    static let empty = UpdateCheckInventory()

    /// 从 #16 的组件识别结果构造。只使用 `kind`、`packageName` 与 `version`：
    /// 路径与证据不进入更新检查，也不会进入缓存。
    init(components: [ComponentInstallation]) {
        var desktopVersion: String?
        var piVersion: String?
        var piWebVersion: String?
        var packages: [UpdateCheckPackage] = []
        var seen: Set<String> = []
        for component in components {
            switch component.kind {
            case .desktopApp:
                if desktopVersion == nil { desktopVersion = component.version }
            case .piCLI:
                if piVersion == nil { piVersion = component.version }
            case .piWeb:
                if piWebVersion == nil { piWebVersion = component.version }
            case .piPackage:
                // 没有包名的条目无法逐包查询（`pi list` 解析失败时 #16 会给出这样
                // 的条目），跳过而不是猜测。
                guard let name = component.packageName, seen.insert(name).inserted else { continue }
                packages.append(UpdateCheckPackage(name: name, installedVersion: component.version))
            }
        }
        self.init(
            desktopAppVersion: desktopVersion,
            piCLIVersion: piVersion,
            piWebVersion: piWebVersion,
            piPackages: packages
        )
    }
}

// MARK: - 上游端点（白名单）

/// 更新检查访问的全部上游。只有这里列出的主机与路径会被请求；仓库外地址、
/// 环境变量或用户输入都不会拼进 URL。
enum UpdateCheckUpstream {
    /// 桌面应用自己的发布仓库（GitHub Releases）。
    static let desktopRepository = "Su-luoya/pi-web-desktop"
    /// Pi CLI 的 npm 包名（与 #6/#16 的安装清单同一来源，不重复字面值）。
    static let piCLIPackageName = InstallCommandManifest.piCLIPackageName
    /// Pi Web 的 npm 包名（同上）。
    static let piWebPackageName = InstallCommandManifest.piWebPackageName

    static let githubHost = "api.github.com"
    static let npmRegistryHost = "registry.npmjs.org"
}

/// 用户可见的更新检查说明（菜单“更新检查说明…”与 `docs/privacy.md` 用同一
/// 组事实：域名、请求内容、策略与默认值、提示方式、忽略语义、受限自动更新、
/// 缓存位置）。
///
/// 措辞约束：只描述版本查询，不把请求称作遥测；版本查询本身不下载、不安装；
/// “启动前自动更新 Pi Web”只在打开且来源与可信度满足时执行一次受限安装，
/// 并明确写出生效范围与不自动回滚。
enum UpdateCheckDisclosure {
    static func text(cachePath: String) -> String {
        let desktopHours = Int(UpdateCheckIntervals.standard.daily / 3600)
        let packageDays = Int(UpdateCheckIntervals.standard.packageCheck / (24 * 3600))
        return """
        更新检查本身只做只读的版本查询，不下载、不安装任何东西；只有下面“启动前自动更新 Pi Web”打开且条件满足时才会执行一次受限安装。

        · 访问的域名：\(UpdateCheckUpstream.githubHost)（桌面应用发布）、\(UpdateCheckUpstream.npmRegistryHost)（Pi CLI、Pi Web 与扩展包）。
        · 请求内容：GET + JSON 解析；User-Agent 只含应用名、版本与 bundle identifier；不发送 cookies、账号凭据、会话内容或诊断信息。
        · 频率：应用启动后立即检查一次；之后桌面应用 / Pi CLI / Pi Web 默认每 \(desktopHours) 小时（每日）、Pi 扩展包默认每 \(packageDays) 天（检查并通知）复查。四类可分别设为关闭 / 每日 / 每周（扩展包为关闭 / 检查并通知 / 询问后更新）；关闭后不发起对应请求，也不安排复查。应用关闭后不检查（不安装 LaunchAgent）。
        · 提示方式：应用内提示框（不使用系统通知中心、不申请通知权限）；提示只含组件名与版本。发现可用更新时最多在本次运行里提示一次，忽略某个版本后不再提示它。
        · 忽略版本：可以逐类忽略当前提示的版本；忽略与安装来源无关，只抑制这一个版本，上游发布更高版本时会再次提示。不实现版本锁定或降级。
        · 启动前自动更新 Pi Web：默认关闭。打开后只对“来源为已验证的 npm 全局安装”的 Pi Web 生效：应用启动时若有**本次运行刚从白名单主机取得**的已验证可用版本，会以参数数组执行 npm install -g <包名>@<版本>（不使用 shell、不调用 sudo、安装有超时），安装后重新检测版本并做健康检查。其它来源（pnpm、Homebrew、nvm/mise、git checkout、本地路径、未知）仍只显示更新命令，绝不自动安装；应用不承诺所有来源都能回滚。
        · 结果缓存：\(cachePath)（只含版本、时间戳与条件请求字段），删除该文件即可清空。缓存不是可信输入（可被同一用户改写），只用于提示；读取时校验结构与上限、不合法就整份丢弃，且不参与自动安装判定。

        版本查询不是遥测：请求只用于比较版本，不会上传使用数据、会话或诊断内容。
        """
    }
}

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

// MARK: - 请求身份

/// 固定 User-Agent。只由应用标识与版本组成，不含用户名、主机名或设备名。
struct UpdateCheckIdentity: Equatable {
    var appName: String
    var version: String?
    var bundleIdentifier: String?

    init(appName: String = "Pi Web Desktop", version: String? = nil, bundleIdentifier: String? = nil) {
        self.appName = appName
        self.version = version
        self.bundleIdentifier = bundleIdentifier
    }

    /// 运行中的应用自己：版本与 bundle identifier 只从 Info.plist 读取，不在
    /// 源码里写版本字面值。
    static var current: UpdateCheckIdentity {
        let probe = ApplicationInstallationProbe.current
        return UpdateCheckIdentity(
            appName: "Pi Web Desktop",
            version: probe.version,
            bundleIdentifier: probe.bundleIdentifier
        )
    }

    /// `Pi-Web-Desktop/<版本> (<bundle id>)` 形态（不在源码里写版本字面值）；
    /// 缺字段时省略对应片段，至少保留应用名。
    var userAgent: String {
        var token = appName.replacingOccurrences(of: " ", with: "-")
        if let version, !version.isEmpty { token += "/\(version)" }
        if let bundleIdentifier, !bundleIdentifier.isEmpty {
            token += " (\(bundleIdentifier))"
        }
        return token
    }
}

// MARK: - 响应解析

/// 解析失败的原因（只用于“标记 unknown”和用户可见文案，不含原始文本）。
enum UpdateParseFailure: String, Error, Equatable {
    case malformedJSON
    case unexpectedStructure
    case emptyReleaseList
    case missingVersion
    case unparsableVersion
}

/// 上游最新版本（已解析）。
struct UpdateUpstreamVersion: Equatable {
    var version: String
    var semanticVersion: SemanticVersion
    /// GitHub Release 的 prerelease 标记；npm 端点按版本形态推断。
    var isPrerelease: Bool
}

/// 只做 JSON 解析的纯函数集合：不联网、不读文件，可直接用字符串断言。
enum UpdateResponseParser {
    /// 解析 GitHub Releases 列表：忽略 draft，按语义化版本取最大者（含预发布）。
    static func latestGitHubRelease(from data: Data) -> Result<UpdateUpstreamVersion, UpdateParseFailure> {
        guard let object = try? JSONSerialization.jsonObject(with: data) else {
            return .failure(.malformedJSON)
        }
        guard let releases = object as? [[String: Any]] else {
            return .failure(.unexpectedStructure)
        }
        var best: (tag: String, version: SemanticVersion, prerelease: Bool)?
        for release in releases {
            if (release["draft"] as? Bool) == true { continue }
            guard let tag = release["tag_name"] as? String else { continue }
            guard let version = SemanticVersion(tag) else { continue }
            let prerelease = (release["prerelease"] as? Bool) ?? (version.prerelease != nil)
            if let current = best {
                if current.version < version {
                    best = (tag, version, prerelease)
                }
            } else {
                best = (tag, version, prerelease)
            }
        }
        guard let best else {
            return .failure(releases.isEmpty ? .emptyReleaseList : .missingVersion)
        }
        return .success(UpdateUpstreamVersion(
            version: best.version.description,
            semanticVersion: best.version,
            isPrerelease: best.prerelease
        ))
    }

    /// 解析 npm registry `/latest` 文档：只读顶层 `version` 字段。
    static func latestNpmVersion(from data: Data) -> Result<UpdateUpstreamVersion, UpdateParseFailure> {
        guard let object = try? JSONSerialization.jsonObject(with: data) else {
            return .failure(.malformedJSON)
        }
        guard let document = object as? [String: Any] else {
            return .failure(.unexpectedStructure)
        }
        guard let text = document["version"] as? String else {
            return .failure(.missingVersion)
        }
        guard let version = SemanticVersion(text) else {
            return .failure(.unparsableVersion)
        }
        return .success(UpdateUpstreamVersion(
            version: version.description,
            semanticVersion: version,
            isPrerelease: version.prerelease != nil
        ))
    }
}

// MARK: - 检查结果

/// 单个对象的检查结论。
enum UpdateCheckStatus: String, Equatable {
    case updateAvailable = "update-available"
    case upToDate = "up-to-date"
    case unknown
}

/// 结论只能由“本机版本 + 上游版本”现算，绝不沿用缓存里的旧结论（GitHub #74）。
///
/// 缓存回退、条件请求（304）与本次网络响应都走这里，因此同一种输入在三处
/// 得到同一个结论；缓存条目里记录的 `status` 只是当时那次计算的产物，不是
/// 可以拿去覆盖当前本机版本的事实。
enum UpdateVersionVerdict {
    /// 语义化比较：本机 < 上游 → 有新版本；本机 >= 上游 → 已是最新；
    /// 任一侧缺失或无法解析 → nil（不可判定，不猜）。
    static func status(installed: String?, upstream: String?) -> UpdateCheckStatus? {
        guard let installed,
              let upstream,
              let installedVersion = SemanticVersion(installed),
              let upstreamVersion = SemanticVersion(upstream) else {
            return nil
        }
        return installedVersion < upstreamVersion ? .updateAvailable : .upToDate
    }
}

/// 检查失败的原因；写入缓存的只有这个枚举的 rawValue，没有自由文本。
enum UpdateCheckFailure: String, Equatable {
    case timedOut
    case offline
    case cancelled
    case transport
    case rateLimited
    case serverError
    case httpError
    case unexpectedRedirect
    case unexpectedHost
    case invalidResponse
    case unparsableVersion
    case installedVersionUnknown
    case invalidPackageName

    /// 用户可见的原因文本，不含 HTTP 状态码（状态码由调用方按需追加）。
    var text: String {
        switch self {
        case .timedOut: return "请求超时"
        case .offline: return "网络不可用"
        case .cancelled: return "请求被取消"
        case .transport: return "网络错误"
        case .rateLimited: return "上游限流"
        case .serverError: return "上游服务错误"
        case .httpError: return "上游返回非预期状态码"
        case .unexpectedRedirect: return "上游尝试重定向到非预期地址"
        case .unexpectedHost: return "响应来自非预期主机"
        case .invalidResponse: return "响应无法解析"
        case .unparsableVersion: return "上游版本无法进行语义化比较"
        case .installedVersionUnknown: return "无法确定本机已安装版本，未发起请求"
        case .invalidPackageName: return "包名不符合 npm 规范，未发起请求"
        }
    }
}

/// 结果新鲜度：本次真实响应、沿用的缓存、或没有可用结果。
enum UpdateResultFreshness: String, Equatable {
    case fresh
    case cached
    case none
}

/// 检查结果的来源（GitHub #59 / alpha.3 安全审查 A-1）。
///
/// **只有 `.network` 允许作为自动安装（受限自动更新）的判定依据**：它表示本次
/// 运行刚从白名单主机取得的响应。`.cachedFallback` 的版本值来自本机缓存文件
/// （同一用户可改写，不是可信输入），只允许用于提示；`.unavailable` 表示没有
/// 可用结果（没有缓存或整份缓存被丢弃）。
///
/// 与 `freshness` 的分工：`freshness` 描述本次网络往返是否成功，`origin` 描述
/// 判定所用的**数据**从哪里来。条件请求命中 304 时网络往返是成功的
/// （`freshness` 仍为 `.fresh`），但版本值来自缓存文件，因此 `origin` 是
/// `.cachedFallback`：304 只确认“缓存里的那个版本仍然是上游最新”，不能让
/// 本地可改写的版本字符串变成自动安装的目标。
enum UpdateCheckOrigin: String, Equatable {
    case network
    case cachedFallback = "cached-fallback"
    case unavailable

    var displayName: String {
        switch self {
        case .network: return "本次网络检查"
        case .cachedFallback: return "本机缓存"
        case .unavailable: return "无可用结果"
        }
    }

    /// 是否允许作为自动安装的判定依据。只有本次网络结果可以。
    var isEligibleForAutomaticInstall: Bool { self == .network }

    /// 自动安装前的来源拒绝文案（Pi Web / Pi CLI / Pi 扩展包共用同一组固定
    /// 事实）。缓存回退分支包含“缓存”与缓存写入时间，且不出现“已验证”“官方”
    /// 之类会被读成“本次已由上游确认”的措辞。
    func autoInstallRefusalText(cacheWrittenAt: Date?) -> String {
        switch self {
        case .cachedFallback:
            let stamp = cacheWrittenAt.map { "（缓存写入时间 \(UpdateCheckTimestamp.text($0))）" } ?? ""
            return "判定所用的检查结果来自本机缓存\(stamp)，不是本次运行从白名单主机取得的网络结果；缓存不是可信输入，自动更新不做"
        case .network:
            return "判定所用的检查结果不是本次运行从白名单主机取得的网络结果"
        case .unavailable:
            return "本次运行没有可用的网络检查结果；缓存回退与缓存缺失都不触发自动更新"
        }
    }
}

/// 缓存时间戳的固定展示格式：UTC、秒级，不依赖机器时区与语言，日志、诊断与
/// 测试断言因此是确定性的。
enum UpdateCheckTimestamp {
    static func text(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        return formatter.string(from: date)
    }
}

/// 一个对象的用户可见结论。只包含版本、状态与固定文案，不含路径、请求细节或
/// 诊断内容。`ignoredVersion` 记录用户为该分类忽略、因而本次不再提示的版本。
struct UpdateCheckResult: Equatable {
    var target: UpdateCheckTarget
    var status: UpdateCheckStatus
    var installedVersion: String?
    var latestVersion: String?
    /// 上游版本经过预期端点 + 可解析结构验证时为 `verified`；否则 `unknown`。
    var confidence: DetectionConfidence
    var freshness: UpdateResultFreshness
    var failure: UpdateCheckFailure?
    var httpStatusCode: Int?
    var checkedAt: Date?
    var lastSuccessAt: Date?
    /// 本次结论对应的版本被用户忽略时，这里是那个版本（等于 `latestVersion`）。
    var ignoredVersion: String? = nil
    /// 结论来源。默认值是最安全的一档（不可用）：漏传时绝不会退化成“允许自动安装”。
    var origin: UpdateCheckOrigin = .unavailable
    /// `origin == .cachedFallback` 时缓存条目的写入时间；其余情况为 nil。
    var cacheWrittenAt: Date? = nil

    var failureText: String {
        guard let failure else { return "未知原因" }
        switch failure {
        case .rateLimited, .serverError, .httpError, .unexpectedRedirect:
            let code = httpStatusCode.map { "（HTTP \($0)）" } ?? ""
            return failure.text + code
        default:
            return failure.text
        }
    }

    var displayText: String {
        var text: String
        switch status {
        case .updateAvailable:
            text = "\(target.displayName)：上游有新版本 \(latestVersion ?? "未知")，本机 \(installedVersion ?? "未知")。只提示，不自动安装。"
            if let latestVersion, ignoredVersion == latestVersion {
                text += "该版本已被忽略，上游发布更高版本时会再次提示。"
            }
        case .upToDate:
            text = "\(target.displayName)：已是最新（本机 \(installedVersion ?? "未知")，上游 \(latestVersion ?? "未知")）。"
        case .unknown:
            text = "\(target.displayName)：无法确定\(installedVersion.map { "（本机 \($0)）" } ?? "")。"
        }
        if failure != nil {
            if freshness == .cached, let latestVersion {
                text += " 本次未验证成功：\(failureText)；保留上次成功结果：\(latestVersion)。"
            } else {
                text += " 原因：\(failureText)。"
            }
        }
        if let annotation = cacheOriginAnnotation {
            text += annotation
        }
        return text
    }

    /// 缓存回退的固定来源标注：包含“缓存”与缓存写入时间，并说明它只用于提示。
    /// 不写“已验证”“官方”之类会让用户以为本次已由上游确认的措辞。
    var cacheOriginAnnotation: String? {
        guard origin == .cachedFallback else { return nil }
        let stamp = cacheWrittenAt.map { "，写入于 \(UpdateCheckTimestamp.text($0))" } ?? "，写入时间未知"
        return "（来源：本机缓存\(stamp)；缓存不是可信输入，只用于提示，不用于自动安装。）"
    }
}

/// 触发来源。只用于状态文案与测试断言，不改变检查对象的范围。
enum UpdateCheckTrigger: String, Equatable {
    case launch
    case scheduled
    case manual

    var displayName: String {
        switch self {
        case .launch: return "启动"
        case .scheduled: return "周期"
        case .manual: return "手动"
        }
    }
}

/// 一次检查（或一次“没有可检查对象”的判定）的汇总。`categoryStatuses` 是四类
/// 组件的状态快照（最近检查 / 结果 / 忽略版本 / 下次检查），由检查器在主线程
/// 发布，供诊断页与偏好窗口渲染。
struct UpdateCheckSummary: Equatable {
    var results: [UpdateCheckResult]
    var checkedAt: Date?
    var trigger: UpdateCheckTrigger
    /// 本次运行中处于开启状态的分类；全部关闭时 `results` 必然为空。
    var enabledCategories: [UpdateCheckCategory]
    var categoryStatuses: [UpdateCategoryStatus]

    static let empty = UpdateCheckSummary(
        results: [],
        checkedAt: nil,
        trigger: .manual,
        enabledCategories: UpdateCheckCategory.allCases,
        categoryStatuses: []
    )

    init(
        results: [UpdateCheckResult],
        checkedAt: Date?,
        trigger: UpdateCheckTrigger,
        enabledCategories: [UpdateCheckCategory],
        categoryStatuses: [UpdateCategoryStatus] = []
    ) {
        self.results = results
        self.checkedAt = checkedAt
        self.trigger = trigger
        self.enabledCategories = enabledCategories
        self.categoryStatuses = categoryStatuses
    }

    var allDisabled: Bool { enabledCategories.isEmpty }

    var updateAvailableCount: Int { results.filter { $0.status == .updateAvailable }.count }
    var unknownCount: Int { results.filter { $0.status == .unknown }.count }

    func result(for targetID: String) -> UpdateCheckResult? {
        results.first { $0.target.id == targetID }
    }

    /// 菜单状态行。
    var statusLine: String {
        if allDisabled { return "更新检查：已全部关闭" }
        guard !results.isEmpty else { return "更新检查：尚未检查" }
        if updateAvailableCount > 0 {
            return "更新检查：发现 \(updateAvailableCount) 项可用更新"
        }
        if unknownCount > 0 {
            return "更新检查：有 \(unknownCount) 项无法确定"
        }
        return "更新检查：全部已是最新"
    }

    /// 提示文案：只讲检查结果、上游范围与“不安装”，不做任何要求用户操作的诱导。
    var detailText: String {
        if allDisabled {
            return "四类更新检查都已关闭，应用不会向上游发起任何版本请求。"
                + "可以在“服务 → 更新检查设置”里重新打开；应用只检查、不安装。"
        }
        guard !results.isEmpty else {
            return "本次没有需要检查的对象（本机版本未知，或还没有到期）。"
        }
        var lines = results.map(\.displayText)
        if updateAvailableCount > 0 {
            lines.append("")
            lines.append("发现 \(updateAvailableCount) 项可用更新。应用只提示版本，不会自动下载或安装。")
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - 缓存

/// 缓存里的一个条目。
///
/// 只保存时间戳、条件请求字段与结果本身：**不含**凭据、cookie、会话、URL、
/// 响应体、错误文本或诊断内容。删除该文件不会影响应用与服务。
struct UpdateCacheEntry: Codable, Equatable {
    var targetID: String
    var category: String
    var packageName: String?
    var lastAttemptAt: Date?
    var lastSuccessAt: Date?
    var etag: String?
    var lastModified: String?
    var latestVersion: String?
    /// 写下这条结论时的本机版本（GitHub #74）。缓存里的 `status` 只对写下它的
    /// 那个本机版本成立，因此复用任何结论字段前都要先与当前本机版本核对；
    /// 旧缓存（schema 1）没有这个字段，读取后一律按“结论不可判定”处理。
    var installedVersion: String?
    var status: String?
    var confidence: String?
    var failure: String?
    var httpStatusCode: Int?

    init(
        targetID: String,
        category: String,
        packageName: String? = nil,
        lastAttemptAt: Date? = nil,
        lastSuccessAt: Date? = nil,
        etag: String? = nil,
        lastModified: String? = nil,
        latestVersion: String? = nil,
        installedVersion: String? = nil,
        status: String? = nil,
        confidence: String? = nil,
        failure: String? = nil,
        httpStatusCode: Int? = nil
    ) {
        self.targetID = targetID
        self.category = category
        self.packageName = packageName
        self.lastAttemptAt = lastAttemptAt
        self.lastSuccessAt = lastSuccessAt
        self.etag = etag
        self.lastModified = lastModified
        self.latestVersion = latestVersion
        self.installedVersion = installedVersion
        self.status = status
        self.confidence = confidence
        self.failure = failure
        self.httpStatusCode = httpStatusCode
    }

    var decodedConfidence: DetectionConfidence? { confidence.flatMap(DetectionConfidence.init(rawValue:)) }

    /// 上次成功结果是否仍可沿用：有版本、有成功时间，且没有超过该分类的 TTL。
    func isReusable(at date: Date, ttl: TimeInterval) -> Bool {
        guard latestVersion != nil, let lastSuccessAt else { return false }
        return date.timeIntervalSince(lastSuccessAt) <= ttl
    }
}

/// 缓存文件结构。`schemaVersion` 不在 `supportedSchemaVersions` 内时整份缓存
/// 视为不可用（返回空缓存），因此未来格式变化不会让旧数据以错误语义被读入；
/// 已知的旧版本按当前结构读入，缺少 `installedVersion` 的旧条目由检查器降级为
/// 不可判定（见 `cachedFallback`）。
struct UpdateCheckCacheFile: Codable, Equatable {
    static let currentSchemaVersion = 2
    /// 兼容读取的旧版本（GitHub #74 之前写入）：条目没有 `installedVersion`，
    /// 无法判断缓存里的结论是否适用于当前本机版本，因此不参与结论复用。
    static let legacySchemaVersion = 1
    /// 可读取的 schema 版本。旧版本读入后按当前版本处理，不部分采用。
    static let supportedSchemaVersions: [Int] = [legacySchemaVersion, currentSchemaVersion]
    /// 条目上限：包名列表长期变化时避免文件无限增长。
    static let maximumEntries = 200
    /// 文件大小上限：超过它的缓存文件不解析、不部分采用，直接丢弃。
    /// 上限比满额缓存（200 条 × 各字段上限）更大，因此合法缓存不会被它拒绝。
    static let maximumFileBytes = 1024 * 1024
    /// 单个版本字符串的长度上限（版本值还必须是规范化的语义化版本）。
    static let maximumVersionLength = 64
    /// 条件请求字段（`etag` / `lastModified`）的长度上限。
    static let maximumConditionalHeaderLength = 512
    /// 目标 id 的长度上限。
    static let maximumTargetIDLength = 256
    /// 允许的时钟偏移（秒）：比“未来”宽松一点点，但不改变“未来时间戳不可信”。
    static let futureTimestampTolerance: TimeInterval = 300

    var schemaVersion: Int
    var entries: [UpdateCacheEntry]

    init(schemaVersion: Int = UpdateCheckCacheFile.currentSchemaVersion, entries: [UpdateCacheEntry] = []) {
        self.schemaVersion = schemaVersion
        self.entries = entries
    }

    static let empty = UpdateCheckCacheFile()

    func entry(for targetID: String) -> UpdateCacheEntry? {
        entries.first { $0.targetID == targetID }
    }

    mutating func upsert(_ entry: UpdateCacheEntry) {
        if let index = entries.firstIndex(where: { $0.targetID == entry.targetID }) {
            entries[index] = entry
        } else {
            entries.append(entry)
        }
    }

    /// 按最后尝试时间保留最近的条目（nil 视为最旧），超出上限的丢弃。
    mutating func pruneToMaximumEntries() {
        guard entries.count > Self.maximumEntries else { return }
        let sorted = entries.sorted { left, right in
            (left.lastAttemptAt ?? .distantPast) > (right.lastAttemptAt ?? .distantPast)
        }
        entries = Array(sorted.prefix(Self.maximumEntries))
    }
}

/// 缓存被丢弃的原因。全部是固定文案：不回显缓存文件里的任何内容，因此损坏或
/// 被改写的文件不能把任意文本带进日志与诊断。
enum UpdateCheckCacheRejection: Equatable {
    /// 文件存在但读不出来。
    case unreadable
    /// 文件超过大小上限（在解析前就拒绝）。
    case tooLarge(bytes: Int)
    /// 结构无法解析（JSON 损坏、字段类型不对）。
    case malformedStructure
    /// `schemaVersion` 不是当前版本。
    case unsupportedSchemaVersion(Int)
    /// 条目数超过上限。
    case tooManyEntries(Int)
    /// 条目字段不合法（分类、包名、状态、目标 id 或条件请求字段）。
    case invalidEntry
    /// 版本字符串不是规范化的语义化版本。
    case invalidVersionShape
    /// 时间戳落在未来（超过允许的时钟偏移）。
    case timestampInTheFuture

    var text: String {
        switch self {
        case .unreadable:
            return "缓存文件无法读取"
        case .tooLarge(let bytes):
            return "缓存文件超过大小上限（\(bytes) 字节 > \(UpdateCheckCacheFile.maximumFileBytes) 字节）"
        case .malformedStructure:
            return "缓存结构无法解析（字段类型或形状不合法）"
        case .unsupportedSchemaVersion(let version):
            return "缓存 schema 版本不受支持（\(version) ≠ \(UpdateCheckCacheFile.currentSchemaVersion)）"
        case .tooManyEntries(let count):
            return "缓存条目数超过上限（\(count) > \(UpdateCheckCacheFile.maximumEntries)）"
        case .invalidEntry:
            return "缓存条目字段不合法（分类、包名、目标 id、状态或条件请求字段）"
        case .invalidVersionShape:
            return "缓存里的版本字符串不是规范化的语义化版本"
        case .timestampInTheFuture:
            return "缓存时间戳落在未来"
        }
    }

    /// 完整日志行：固定文案 + 结论（只影响提示，不参与自动安装判定）。
    var logLine: String {
        "更新检查缓存已丢弃（\(text)）；本次按“没有可用缓存”处理：只影响提示，不参与自动安装判定。"
    }
}

// MARK: - 缓存校验

/// 单条缓存条目的结构校验。返回 nil 表示合法。
///
/// 校验只看形状与一致性：分类/包名/目标 id 互相对得上、枚举值是已知取值、版本
/// 字符串是规范化的语义化版本、时间戳不落在未来。任何一项不满足都丢弃整份缓存
/// （不部分采用），因为一个被改写的条目与其余条目的可信度无法区分。
extension UpdateCacheEntry {
    func validationRejection(at now: Date) -> UpdateCheckCacheRejection? {
        guard !targetID.isEmpty,
              targetID.count <= UpdateCheckCacheFile.maximumTargetIDLength else { return .invalidEntry }
        guard let category = UpdateCheckCategory(rawValue: category) else { return .invalidEntry }
        if let packageName {
            guard ComponentInstallationDetector.isPackageName(packageName) else { return .invalidEntry }
        }
        if category != .piPackages, packageName != nil { return .invalidEntry }
        guard targetID == UpdateCheckTarget(category: category, packageName: packageName).id else {
            return .invalidEntry
        }
        if let status, UpdateCheckStatus(rawValue: status) == nil { return .invalidEntry }
        if let confidence, DetectionConfidence(rawValue: confidence) == nil { return .invalidEntry }
        if let failure, UpdateCheckFailure(rawValue: failure) == nil { return .invalidEntry }
        if let httpStatusCode, !(100...599).contains(httpStatusCode) { return .invalidEntry }
        if let etag, etag.count > UpdateCheckCacheFile.maximumConditionalHeaderLength { return .invalidEntry }
        if let lastModified, lastModified.count > UpdateCheckCacheFile.maximumConditionalHeaderLength {
            return .invalidEntry
        }
        if let latestVersion {
            guard latestVersion.count <= UpdateCheckCacheFile.maximumVersionLength,
                  let parsed = SemanticVersion(latestVersion),
                  parsed.description == latestVersion else { return .invalidVersionShape }
        }
        // 写入结论时的本机版本不必是规范化的语义化版本（本机安装元数据可以是
        // `dev-build` 这类值），但必须是有限长度、不含控制字符的字符串：它只
        // 用于与当前本机版本核对，不进入界面。
        if let installedVersion {
            guard !installedVersion.isEmpty,
                  installedVersion.count <= UpdateCheckCacheFile.maximumVersionLength,
                  !installedVersion.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) else {
                return .invalidEntry
            }
        }
        // 时间戳不能落在未来；允许小幅时钟偏移，但偏移必须小于容差。
        for timestamp in [lastAttemptAt, lastSuccessAt].compactMap({ $0 }) where
            timestamp.timeIntervalSince(now) > UpdateCheckCacheFile.futureTimestampTolerance {
            return .timestampInTheFuture
        }
        return nil
    }
}

extension UpdateCheckCacheFile {
    /// 读取时的整体校验。任何不合法都返回整份 `.empty` 与拒绝原因：不崩溃、
    /// 不部分采用，调用方按 `unavailable` 处理。
    static func validated(
        _ data: Data,
        now: Date
    ) -> (file: UpdateCheckCacheFile, rejection: UpdateCheckCacheRejection?) {
        guard data.count <= maximumFileBytes else {
            return (.empty, .tooLarge(bytes: data.count))
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let file = try? decoder.decode(UpdateCheckCacheFile.self, from: data) else {
            return (.empty, .malformedStructure)
        }
        guard supportedSchemaVersions.contains(file.schemaVersion) else {
            return (.empty, .unsupportedSchemaVersion(file.schemaVersion))
        }
        // 旧 schema 按当前结构使用（GitHub #74）：条目里缺少 `installedVersion`
        // 时结论不可判定，由 `cachedFallback` 降级为 unknown，不沿用旧结论。
        let normalized = UpdateCheckCacheFile(schemaVersion: currentSchemaVersion, entries: file.entries)
        guard normalized.entries.count <= maximumEntries else {
            return (.empty, .tooManyEntries(normalized.entries.count))
        }
        for entry in normalized.entries {
            if let rejection = entry.validationRejection(at: now) {
                return (.empty, rejection)
            }
        }
        return (normalized, nil)
    }
}

/// 缓存读写接口（可注入）。测试用内存替身，不写真实 Application Support。
protocol UpdateCacheStoring: AnyObject {
    func load() -> UpdateCheckCacheFile
    func save(_ file: UpdateCheckCacheFile)
    /// 最近一次 `load()` 丢弃整份缓存的原因；nil 表示读到合法缓存或本来就没有文件。
    var lastLoadRejection: UpdateCheckCacheRejection? { get }
}

extension UpdateCacheStoring {
    /// 默认没有拒绝原因：内存替身不必实现它。
    var lastLoadRejection: UpdateCheckCacheRejection? { nil }
}

/// 生产实现：Application Support 下的独立 JSON 文件。
///
/// 读失败（文件不存在、损坏、schema 不匹配）返回空缓存；写失败静默——更新
/// 检查的任何问题都不得影响应用或正在运行的服务。
final class UpdateCheckCacheFileStore: UpdateCacheStoring {
    let fileURL: URL
    private let fileManager: FileManager
    private let clock: UpdateClock

    /// 最近一次读取丢弃整份缓存的原因（供调用方记录固定文案）。
    private(set) var lastLoadRejection: UpdateCheckCacheRejection?

    init(fileURL: URL, fileManager: FileManager = .default, clock: UpdateClock = .system) {
        self.fileURL = fileURL
        self.fileManager = fileManager
        self.clock = clock
    }

    func load() -> UpdateCheckCacheFile {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            lastLoadRejection = nil
            return .empty
        }
        guard let attributes = try? fileManager.attributesOfItem(atPath: fileURL.path),
              let size = (attributes[.size] as? NSNumber)?.intValue else {
            lastLoadRejection = .unreadable
            return .empty
        }
        // 先看大小再读内容：超大文件不进入内存，也不进入 JSON 解析。
        guard size <= UpdateCheckCacheFile.maximumFileBytes else {
            lastLoadRejection = .tooLarge(bytes: size)
            return .empty
        }
        guard let data = try? Data(contentsOf: fileURL) else {
            lastLoadRejection = .unreadable
            return .empty
        }
        let outcome = UpdateCheckCacheFile.validated(data, now: clock.now())
        lastLoadRejection = outcome.rejection
        return outcome.file
    }

    func save(_ file: UpdateCheckCacheFile) {
        var file = file
        // 写盘一律用当前 schema：旧版本读入的缓存会在下一次保存时自动升级。
        file.schemaVersion = UpdateCheckCacheFile.currentSchemaVersion
        file.pruneToMaximumEntries()
        do {
            try fileManager.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
            let data = try encoder.encode(file)
            // 不写自己会拒绝读取的文件（正常情况下远小于上限）。
            guard data.count <= UpdateCheckCacheFile.maximumFileBytes else { return }
            try data.write(to: fileURL, options: [.atomic])
        } catch {
            // 静默：缓存写入失败不影响检查结果、服务或退出路径。
        }
    }
}

// MARK: - 时钟与调度（可注入）

/// 时间来源。默认系统时钟；测试注入由假时钟驱动的闭包，推进时间即可，不需要
/// 真实 sleep。
struct UpdateClock {
    var now: () -> Date

    static let system = UpdateClock { Date() }
}

/// 周期计时器的取消句柄。
protocol UpdateTimerToken: AnyObject {
    func cancel()
}

/// 更新检查用到的调度原语。
///
/// - `perform`：执行一次检查主体（生产：后台串行队列；测试：立即执行）；
/// - `deliver`：把结果回到主线程（生产：主队列；测试：立即执行）；
/// - `startRepeating`：按间隔重复触发（生产：主 run loop Timer；测试：记录间隔
///   并由测试手动触发）。
///
/// 测试用替身让整个检查同步完成，因此断言是确定性的，且从不 sleep、从不联网。
protocol UpdateCheckScheduling: AnyObject {
    func perform(_ work: @escaping () -> Void)
    func deliver(_ work: @escaping () -> Void)
    func startRepeating(interval: TimeInterval, _ work: @escaping () -> Void) -> UpdateTimerToken
}

/// 生产实现：后台串行队列 + 主队列回调 + 主 run loop 重复计时器。
final class DispatchUpdateCheckScheduler: UpdateCheckScheduling {
    private let queue = DispatchQueue(label: "io.github.su-luoya.pi-web-desktop.update-check", qos: .utility)

    func perform(_ work: @escaping () -> Void) {
        queue.async(execute: work)
    }

    func deliver(_ work: @escaping () -> Void) {
        DispatchQueue.main.async(execute: work)
    }

    func startRepeating(interval: TimeInterval, _ work: @escaping () -> Void) -> UpdateTimerToken {
        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in work() }
        return TimerUpdateToken(timer: timer)
    }
}

private final class TimerUpdateToken: UpdateTimerToken {
    private let timer: Timer

    init(timer: Timer) {
        self.timer = timer
    }

    func cancel() {
        timer.invalidate()
    }
}

// MARK: - 检查器

/// 版本检查器（GitHub #17，设置与忽略版本见 GitHub #18）。
///
/// 行为边界：
/// - 只检查：本类型没有任何安装/下载/执行路径，也不读启动前的自动更新设置位
///   （安装与版本验证由 `PiWebUpdateAdapter` 负责，见 GitHub #20）；
/// - 只 GET 固定白名单端点；请求头只有 `Accept` / `User-Agent` / 条件请求字段；
/// - 失败（网络、超时、限流、5xx、解析失败、非预期主机）只改变检查结果状态，
///   不抛出、不重试轰炸、不触碰服务状态；
/// - 解析失败或非预期主机一律 `unknown`，并保留上一次成功结果（仍在缓存里）；
/// - 缓存只写注入的存储（生产：Application Support 下的独立文件），不含凭据、
///   会话或诊断内容；
/// - 所有时间与网络都来自注入的时钟、HTTP 客户端与调度器，测试不 sleep、
///   不联网；
/// - 调度完全由设置驱动（`UpdateCheckPreferences`）：关闭的分类既不调度也不
///   请求；每日 / 每周 / 扩展包 7 天分别对应 `UpdateCheckIntervals` 里的间隔；
/// - `stop()` 之后不再检查：应用退出路径不发起任何请求，也不安装 LaunchAgent。
///
/// 线程约定：`start` / `stop` / `updateInventory` / `checkNow` / `checkIfDue` /
/// `preferences` / `ignoredVersions` / `summary` 在主线程调用；检查主体在调度器
/// 提供的执行队列上运行，结果经 `deliver` 回到主线程后回调 `onResultsChanged`。
final class UpdateChecker {
    /// 单次请求超时（秒）。
    static let requestTimeout: TimeInterval = 15

    private let httpClient: UpdateHTTPClient
    private let clock: UpdateClock
    private let cacheStore: UpdateCacheStoring
    private let scheduler: UpdateCheckScheduling
    private let identity: UpdateCheckIdentity
    private let intervals: UpdateCheckIntervals
    private let log: ((String) -> Void)?

    /// 结果变化回调（主线程）。只传汇总，不含请求细节。
    var onResultsChanged: ((UpdateCheckSummary) -> Void)?

    /// 最近一次发布的汇总（主线程读取）。
    private(set) var summary: UpdateCheckSummary = .empty

    /// 用户策略。改变后（已 `start` 时）立即按新策略重建周期计时器，因此关闭
    /// 某一类后该分类不再被调度。
    var preferences: UpdateCheckPreferences {
        didSet {
            guard started, !stopped else { return }
            restartTimers()
        }
    }

    /// 被用户忽略的版本。只影响提示与状态标记，不影响已写入的缓存；改变后
    /// 下一次检查立即生效。

    private var inventory: UpdateCheckInventory = .empty
    private var cache: UpdateCheckCacheFile = .empty
    private var cacheLoaded = false
    private var started = false
    private var stopped = false
    private var isChecking = false
    private var timerTokens: [UpdateTimerToken] = []

    /// 忽略版本。由调用方（`AppDelegate`）从 UserDefaults 读入并在界面里更新；
    /// `UpdateChecker` 自己从不写 UserDefaults。
    var ignoredVersions: UpdateIgnoredVersions = .empty

    init(
        httpClient: UpdateHTTPClient,
        clock: UpdateClock = .system,
        cacheStore: UpdateCacheStoring,
        scheduler: UpdateCheckScheduling,
        identity: UpdateCheckIdentity = .current,
        intervals: UpdateCheckIntervals = .standard,
        preferences: UpdateCheckPreferences = .factoryDefaults,
        ignoredVersions: UpdateIgnoredVersions = .empty,
        log: ((String) -> Void)? = nil
    ) {
        self.httpClient = httpClient
        self.clock = clock
        self.cacheStore = cacheStore
        self.scheduler = scheduler
        self.identity = identity
        self.intervals = intervals
        self.preferences = preferences
        self.ignoredVersions = ignoredVersions
        self.log = log
    }

    /// 是否已经启动（应用只在启动时调用一次 `start`）。
    var isStarted: Bool { started }

    /// 应用启动：立即执行一次检查（尊重各类开关，忽略 TTL），并为开启的分类
    /// 安排周期复查。之后 `updateInventory` 补齐的对象会在下一次到期判断里
    /// 被检查，因此启动时还未知的组件不需要额外强制请求。
    func start(inventory: UpdateCheckInventory) {
        guard !stopped else { return }
        self.inventory = inventory
        started = true
        restartTimers()
        checkNow(triggeredBy: .launch)
    }

    /// 依赖检测完成后更新本机版本清单（不强制发请求；未检查过的对象会在到期
    /// 判断里被补上）。
    func updateInventory(_ inventory: UpdateCheckInventory) {
        self.inventory = inventory
        checkIfDue(triggeredBy: .launch)
    }

    /// 手动触发：忽略 TTL，但仍尊重每一类的开关。`inventory` 非 nil 时先用它
    /// 替换本机版本清单（不额外触发周期判断），供启动后“先手动检查一次”的
    /// 调用点与测试使用。
    func checkNow(
        triggeredBy trigger: UpdateCheckTrigger,
        inventory: UpdateCheckInventory? = nil,
        completion: (() -> Void)? = nil
    ) {
        guard !stopped else {
            completion?()
            return
        }
        scheduler.perform { [weak self] in
            guard let self else { return }
            if let inventory { self.inventory = inventory }
            self.performCheck(triggeredBy: trigger, onlyDue: false, completion: completion)
        }
    }

    /// 周期触发：只检查已经到期的对象。
    func checkIfDue(triggeredBy trigger: UpdateCheckTrigger = .scheduled, completion: (() -> Void)? = nil) {
        guard !stopped else {
            completion?()
            return
        }
        scheduler.perform { [weak self] in
            self?.performCheck(triggeredBy: trigger, onlyDue: true, completion: completion)
        }
    }

    /// 应用退出：取消全部计时器，此后的触发一律忽略（关闭时不检查）。
    func stop() {
        stopped = true
        started = false
        for token in timerTokens { token.cancel() }
        timerTokens = []
    }

    // MARK: - 周期调度

    private func restartTimers() {
        for token in timerTokens { token.cancel() }
        timerTokens = []
        // 每个不同的间隔一个计时器；计时器只负责“到期判断”，真正的检查范围
        // 仍由 plan 按各自 lastAttemptAt 决定。关闭的分类不产生计时器，也不
        // 产生请求。
        var intervalsInUse: [TimeInterval] = []
        for category in UpdateCheckCategory.allCases {
            guard let interval = intervals.interval(for: category, policy: preferences.policy(for: category)) else { continue }
            guard !intervalsInUse.contains(interval) else { continue }
            intervalsInUse.append(interval)
        }
        for interval in intervalsInUse {
            let token = scheduler.startRepeating(interval: interval) { [weak self] in
                self?.checkIfDue(triggeredBy: .scheduled)
            }
            timerTokens.append(token)
        }
    }

    // MARK: - 检查主体

    private struct PlanItem {
        var target: UpdateCheckTarget
        var endpoint: UpdateEndpoint?
        var installedVersion: String?
        var cached: UpdateCacheEntry?
    }

    private func performCheck(
        triggeredBy trigger: UpdateCheckTrigger,
        onlyDue: Bool,
        completion: (() -> Void)?
    ) {
        guard !stopped else {
            scheduler.deliver { completion?() }
            return
        }
        guard !isChecking else {
            scheduler.deliver { completion?() }
            return
        }
        isChecking = true
        loadCacheIfNeeded()

        let enabled = UpdateCheckCategory.allCases.filter { preferences.isEnabled($0) }
        let now = clock.now()
        let items = plan(enabledCategories: enabled, onlyDueAt: onlyDue ? now : nil)

        // 周期触发时可能没有任何到期对象：保持上一次汇总，不刷新时间戳。
        guard !items.isEmpty || enabled.isEmpty else {
            isChecking = false
            scheduler.deliver { completion?() }
            return
        }

        runItems(items, at: 0, collected: [], now: now) { [weak self] results in
            guard let self else { return }
            self.cacheStore.save(self.cache)
            self.isChecking = false
            let summary = UpdateCheckSummary(
                results: results,
                checkedAt: self.clock.now(),
                trigger: trigger,
                enabledCategories: enabled,
                categoryStatuses: UpdateCategoryStatusBuilder.statuses(
                    preferences: self.preferences,
                    intervals: self.intervals,
                    cache: self.cache,
                    ignoredVersions: self.ignoredVersions,
                    results: results
                )
            )
            self.logSummary(summary)
            self.scheduler.deliver {
                self.summary = summary
                self.onResultsChanged?(summary)
                completion?()
            }
        }
    }

    /// 生成一次运行要检查的对象。`onlyDueAt` 非 nil 时按每个对象自己的
    /// `lastAttemptAt` 过滤（扩展包逐个判断）。
    private func plan(enabledCategories: [UpdateCheckCategory], onlyDueAt: Date?) -> [PlanItem] {
        var items: [PlanItem] = []
        for category in enabledCategories {
            switch category {
            case .desktopApp:
                appendItem(category: category, packageName: nil, installedVersion: inventory.desktopAppVersion, onlyDueAt: onlyDueAt, into: &items)
            case .piCLI:
                appendItem(category: category, packageName: nil, installedVersion: inventory.piCLIVersion, onlyDueAt: onlyDueAt, into: &items)
            case .piWeb:
                appendItem(category: category, packageName: nil, installedVersion: inventory.piWebVersion, onlyDueAt: onlyDueAt, into: &items)
            case .piPackages:
                for package in inventory.piPackages {
                    appendItem(category: category, packageName: package.name, installedVersion: package.installedVersion, onlyDueAt: onlyDueAt, into: &items)
                }
            }
        }
        return items
    }

    private func appendItem(
        category: UpdateCheckCategory,
        packageName: String?,
        installedVersion: String?,
        onlyDueAt: Date?,
        into items: inout [PlanItem]
    ) {
        let target = UpdateCheckTarget(category: category, packageName: packageName)
        let cached = cache.entry(for: target.id)
        if let onlyDueAt {
            // 关闭的分类没有间隔，永远不会成为到期对象。
            guard let interval = intervals.interval(for: category, policy: preferences.policy(for: category)) else {
                return
            }
            if let lastAttempt = cached?.lastAttemptAt, onlyDueAt.timeIntervalSince(lastAttempt) < interval {
                return
            }
        }
        items.append(PlanItem(
            target: target,
            endpoint: endpoint(for: category, packageName: packageName),
            installedVersion: installedVersion,
            cached: cached
        ))
    }

    private func endpoint(for category: UpdateCheckCategory, packageName: String?) -> UpdateEndpoint? {
        switch category {
        case .desktopApp:
            return UpdateEndpoint.githubReleases(repository: UpdateCheckUpstream.desktopRepository)
        case .piCLI:
            return UpdateEndpoint.npmLatest(packageName: UpdateCheckUpstream.piCLIPackageName)
        case .piWeb:
            return UpdateEndpoint.npmLatest(packageName: UpdateCheckUpstream.piWebPackageName)
        case .piPackages:
            guard let packageName else { return nil }
            return UpdateEndpoint.npmLatest(packageName: packageName)
        }
    }

    /// 顺序执行：一次只有一个请求在飞，避免对上游形成突发流量，也让结果与
    /// 缓存写入顺序可预测。
    private func runItems(
        _ items: [PlanItem],
        at index: Int,
        collected: [UpdateCheckResult],
        now: Date,
        completion: @escaping ([UpdateCheckResult]) -> Void
    ) {
        guard index < items.count else {
            completion(collected)
            return
        }
        let item = items[index]
        // 本机版本未知或包名非法：不发起请求，直接给出可理解的 unknown。
        // 这类“跳过”不写入缓存，也不计入 lastAttemptAt：一旦依赖检测补上版本，
        // 下一次到期判断会立即把它补检，而不是等一个完整周期。
        if item.installedVersion == nil || (item.target.category == .piPackages && item.endpoint == nil) {
            let failure: UpdateCheckFailure = item.installedVersion == nil ? .installedVersionUnknown : .invalidPackageName
            let result = skip(item: item, failure: failure, at: now)
            runItems(items, at: index + 1, collected: collected + [result], now: now, completion: completion)
            return
        }
        guard let endpoint = item.endpoint else {
            let result = skip(item: item, failure: .httpError, at: now)
            runItems(items, at: index + 1, collected: collected + [result], now: now, completion: completion)
            return
        }
        let request = makeRequest(endpoint: endpoint, cached: item.cached)
        httpClient.perform(request) { [weak self] response in
            guard let self else { return }
            let (entry, result) = self.evaluate(item: item, endpoint: endpoint, response: response, at: now)
            self.cache.upsert(entry)
            self.runItems(items, at: index + 1, collected: collected + [result], now: now, completion: completion)
        }
    }

    /// 请求头只有 UA / Accept / 条件请求字段；`sanitized()` 再兜底过滤一次。
    private func makeRequest(endpoint: UpdateEndpoint, cached: UpdateCacheEntry?) -> UpdateHTTPRequest {
        var headers: [String: String] = [
            "Accept": "application/json",
            "User-Agent": identity.userAgent
        ]
        if let etag = cached?.etag, !etag.isEmpty {
            headers["If-None-Match"] = etag
        }
        if let lastModified = cached?.lastModified, !lastModified.isEmpty {
            headers["If-Modified-Since"] = lastModified
        }
        return UpdateHTTPRequest(url: endpoint.url, method: "GET", headers: headers).sanitized()
    }

    // MARK: - 结果判定

    /// 未发起请求时的结论（本机版本未知 / 包名非法）。
    ///
    /// 不写入缓存：没有请求就没有新结果，缓存里的上次成功结果（若有）保持
    /// 不变；因为不计入 `lastAttemptAt`，依赖检测补齐版本后下一次到期判断
    /// 会立即重试。
    private func skip(item: PlanItem, failure: UpdateCheckFailure, at now: Date) -> UpdateCheckResult {
        let cacheOrigin = Self.cacheOrigin(for: item.cached)
        return UpdateCheckResult(
            target: item.target,
            status: .unknown,
            installedVersion: item.installedVersion,
            latestVersion: item.cached?.latestVersion,
            confidence: .unknown,
            freshness: item.cached?.latestVersion == nil ? .none : .cached,
            failure: failure,
            httpStatusCode: nil,
            checkedAt: now,
            lastSuccessAt: item.cached?.lastSuccessAt,
            origin: cacheOrigin.origin,
            cacheWrittenAt: cacheOrigin.cacheWrittenAt
        )
    }

    /// 缓存回退的来源信息：有可展示的版本才叫“缓存回退”，否则是“不可用”。
    /// 缓存写入时间取该条目的上次成功时间（没有成功时间的旧条目退到上次尝试时间）。
    private static func cacheOrigin(for entry: UpdateCacheEntry?) -> (origin: UpdateCheckOrigin, cacheWrittenAt: Date?) {
        guard let entry, entry.latestVersion != nil else { return (.unavailable, nil) }
        return (.cachedFallback, entry.lastSuccessAt ?? entry.lastAttemptAt)
    }

    /// 一次缓存回退的结论（含来源标注）。
    private struct CachedFallbackOutcome {
        var status: UpdateCheckStatus
        var latestVersion: String?
        var confidence: DetectionConfidence
        var freshness: UpdateResultFreshness
        var origin: UpdateCheckOrigin
        var cacheWrittenAt: Date?
    }

    private func evaluate(
        item: PlanItem,
        endpoint: UpdateEndpoint,
        response: Result<UpdateHTTPResponse, UpdateHTTPFailure>,
        at now: Date
    ) -> (UpdateCacheEntry, UpdateCheckResult) {
        var entry = baseEntry(for: item)
        entry.lastAttemptAt = now

        func resolve(
            status: UpdateCheckStatus,
            latestVersion: String?,
            confidence: DetectionConfidence,
            freshness: UpdateResultFreshness,
            failure: UpdateCheckFailure?,
            httpStatusCode: Int?,
            origin: UpdateCheckOrigin,
            cacheWrittenAt: Date?,
            keepSuccessFields: Bool
        ) -> (UpdateCacheEntry, UpdateCheckResult) {
            entry.latestVersion = latestVersion
            entry.status = status.rawValue
            entry.confidence = confidence.rawValue
            entry.failure = failure?.rawValue
            entry.httpStatusCode = httpStatusCode
            if keepSuccessFields {
                entry.lastSuccessAt = now
            }
            // 只抑制用户明确忽略的那一个版本：上游版本不同就不算忽略，
            // 因此新版本会重新进入提示。
            let ignoredVersion = status == .updateAvailable
                ? latestVersion.flatMap { self.ignoredVersions.isIgnored($0, for: item.target.category) ? $0 : nil }
                : nil
            let result = UpdateCheckResult(
                target: item.target,
                status: status,
                installedVersion: item.installedVersion,
                latestVersion: latestVersion,
                confidence: confidence,
                freshness: freshness,
                failure: failure,
                httpStatusCode: httpStatusCode,
                checkedAt: now,
                lastSuccessAt: entry.lastSuccessAt,
                ignoredVersion: ignoredVersion,
                origin: origin,
                cacheWrittenAt: cacheWrittenAt
            )
            return (entry, result)
        }

        switch response {
        case .failure(let transportFailure):
            let failure = Self.checkFailure(from: transportFailure)
            let fallback = cachedFallback(
                entry: item.cached,
                installedVersion: item.installedVersion,
                at: now,
                allowStatus: true
            )
            return resolve(
                status: fallback.status,
                latestVersion: fallback.latestVersion,
                confidence: fallback.confidence,
                freshness: fallback.freshness,
                failure: failure,
                httpStatusCode: nil,
                origin: fallback.origin,
                cacheWrittenAt: fallback.cacheWrittenAt,
                keepSuccessFields: false
            )

        case .success(let http):
            // 最终主机不在白名单内：不采信内容，未经验证 → unknown，保留上一次成功结果。
            if let finalURL = http.finalURL, !endpoint.allows(host: finalURL.host) {
                let fallback = cachedFallback(
                    entry: item.cached,
                    installedVersion: item.installedVersion,
                    at: now,
                    allowStatus: false
                )
                return resolve(
                    status: fallback.status,
                    latestVersion: fallback.latestVersion,
                    confidence: fallback.confidence,
                    freshness: fallback.freshness,
                    failure: .unexpectedHost,
                    httpStatusCode: http.statusCode,
                    origin: fallback.origin,
                    cacheWrittenAt: fallback.cacheWrittenAt,
                    keepSuccessFields: false
                )
            }
            switch http.statusCode {
            case 200:
                let parsed = parse(endpoint: endpoint, body: http.body)
                switch parsed {
                case .success(let upstream):
                    // 只有“预期端点 + 结构可解析”才标记 verified。
                    entry.etag = http.etag ?? item.cached?.etag
                    entry.lastModified = http.lastModified ?? item.cached?.lastModified
                    guard let verdict = UpdateVersionVerdict.status(
                        installed: item.installedVersion,
                        upstream: upstream.version
                    ) else {
                        // 上游版本无法与本机版本比较：未经验证 → unknown。
                        let fallback = cachedFallback(
                            entry: item.cached,
                            installedVersion: item.installedVersion,
                            at: now,
                            allowStatus: false
                        )
                        return resolve(
                            status: fallback.status,
                            latestVersion: fallback.latestVersion,
                            confidence: fallback.confidence,
                            freshness: fallback.freshness,
                            failure: .unparsableVersion,
                            httpStatusCode: http.statusCode,
                            origin: fallback.origin,
                            cacheWrittenAt: fallback.cacheWrittenAt,
                            keepSuccessFields: false
                        )
                    }
                    // 本次网络响应：来源是网络，可以作为自动安装的判定依据。
                    return resolve(
                        status: verdict,
                        latestVersion: upstream.version,
                        confidence: .verified,
                        freshness: .fresh,
                        failure: nil,
                        httpStatusCode: http.statusCode,
                        origin: .network,
                        cacheWrittenAt: nil,
                        keepSuccessFields: true
                    )
                case .failure:
                    // 解析失败：未经验证 → unknown，并保留上一次成功结果与条件请求字段。
                    let fallback = cachedFallback(
                        entry: item.cached,
                        installedVersion: item.installedVersion,
                        at: now,
                        allowStatus: false
                    )
                    return resolve(
                        status: fallback.status,
                        latestVersion: fallback.latestVersion,
                        confidence: fallback.confidence,
                        freshness: fallback.freshness,
                        failure: .invalidResponse,
                        httpStatusCode: http.statusCode,
                        origin: fallback.origin,
                        cacheWrittenAt: fallback.cacheWrittenAt,
                        keepSuccessFields: false
                    )
                }
            case 304:
                // 条件请求命中：沿用缓存里的成功结果。
                guard let cachedVersion = item.cached?.latestVersion,
                      let cachedEntry = item.cached,
                      let verdict = UpdateVersionVerdict.status(
                          installed: item.installedVersion,
                          upstream: cachedVersion
                      ) else {
                    let fallback = cachedFallback(
                        entry: item.cached,
                        installedVersion: item.installedVersion,
                        at: now,
                        allowStatus: false
                    )
                    return resolve(
                        status: fallback.status,
                        latestVersion: fallback.latestVersion,
                        confidence: fallback.confidence,
                        freshness: fallback.freshness,
                        failure: .invalidResponse,
                        httpStatusCode: http.statusCode,
                        origin: fallback.origin,
                        cacheWrittenAt: fallback.cacheWrittenAt,
                        keepSuccessFields: false
                    )
                }
                entry.etag = http.etag ?? cachedEntry.etag
                entry.lastModified = http.lastModified ?? cachedEntry.lastModified
                // 304 只证明“缓存里的那个版本仍是上游最新”：网络往返成功
                // （freshness 仍为 .fresh），但版本值来自本机缓存文件。缓存不是
                // 可信输入，因此 origin 记为缓存回退，只用于提示。
                let cacheOrigin = Self.cacheOrigin(for: item.cached)
                return resolve(
                    status: verdict,
                    latestVersion: cachedVersion,
                    confidence: .verified,
                    freshness: .fresh,
                    failure: nil,
                    httpStatusCode: http.statusCode,
                    origin: cacheOrigin.origin,
                    cacheWrittenAt: cacheOrigin.cacheWrittenAt,
                    keepSuccessFields: true
                )
            default:
                let failure = Self.failure(forStatusCode: http.statusCode)
                // 重定向属于未经验证的响应；限流 / 5xx 等明确的上游回答可以沿用旧缓存。
                let allowCachedStatus = failure != .unexpectedRedirect
                let fallback = cachedFallback(
                    entry: item.cached,
                    installedVersion: item.installedVersion,
                    at: now,
                    allowStatus: allowCachedStatus
                )
                return resolve(
                    status: fallback.status,
                    latestVersion: fallback.latestVersion,
                    confidence: fallback.confidence,
                    freshness: fallback.freshness,
                    failure: failure,
                    httpStatusCode: http.statusCode,
                    origin: fallback.origin,
                    cacheWrittenAt: fallback.cacheWrittenAt,
                    keepSuccessFields: false
                )
            }
        }
    }

    private func parse(endpoint: UpdateEndpoint, body: Data) -> Result<UpdateUpstreamVersion, UpdateParseFailure> {
        if endpoint.allowedHosts.contains(UpdateCheckUpstream.githubHost) {
            return UpdateResponseParser.latestGitHubRelease(from: body)
        }
        return UpdateResponseParser.latestNpmVersion(from: body)
    }

    /// 失败时的结论。
    ///
    /// - `allowStatus == true`（网络失败、超时、429/5xx）：TTL 内的上次成功结果
    ///   可以拿来展示，但**结论一律按当前本机版本现算**（GitHub #74）：用当前
    ///   本机版本与缓存里的上游版本走与 304 分支同一条
    ///   `UpdateVersionVerdict.status(installed:upstream:)` 路径，绝不沿用条目里
    ///   的旧 `status`。本机版本或缓存版本无法解析时降级为 `.unknown`（不猜）。
    /// - `allowStatus == false`（解析失败、非预期主机/重定向、版本无法比较）：
    ///   响应未经验证，本次结论一律 unknown，但仍展示上次成功版本。
    ///
    /// 旧缓存条目（schema 1）没有记录写下结论时的本机版本，无法判断缓存里的
    /// 结论是否适用于当前本机版本，因此一律按不可判定处理（`.unknown`）；
    /// 记录存在但与当前本机版本不同、或者本机版本无法解析时，同样只相信现算
    /// 的结果，不沿用旧结论。条目的可信度标记只在与当前本机版本一致时才继承。
    ///
    /// 无论哪种情况，结论来源都是 `.cachedFallback`（没有可展示版本时为
    /// `.unavailable`）：缓存文件不是可信输入，因此这些结论只供提示。
    private func cachedFallback(
        entry: UpdateCacheEntry?,
        installedVersion: String?,
        at now: Date,
        allowStatus: Bool
    ) -> CachedFallbackOutcome {
        let cacheOrigin = Self.cacheOrigin(for: entry)
        guard let entry, let latestVersion = entry.latestVersion else {
            return CachedFallbackOutcome(
                status: .unknown,
                latestVersion: nil,
                confidence: .unknown,
                freshness: .none,
                origin: cacheOrigin.origin,
                cacheWrittenAt: cacheOrigin.cacheWrittenAt
            )
        }
        func undecidable() -> CachedFallbackOutcome {
            CachedFallbackOutcome(
                status: .unknown,
                latestVersion: latestVersion,
                confidence: .unknown,
                freshness: .cached,
                origin: cacheOrigin.origin,
                cacheWrittenAt: cacheOrigin.cacheWrittenAt
            )
        }
        if !allowStatus {
            return undecidable()
        }
        let ttl = UpdateCheckCategory(rawValue: entry.category).map { intervals.ttl(for: $0) }
            ?? intervals.ttl(for: .desktopApp)
        guard entry.isReusable(at: now, ttl: ttl) else {
            return undecidable()
        }
        // 缓存里的结论没有绑定到“写下它时的本机版本”：旧缓存缺字段，无法判定。
        guard let cachedInstalledVersion = entry.installedVersion else {
            return undecidable()
        }
        // 现算：当前本机版本 vs 缓存里的上游版本；本机版本不可解析 → unknown。
        guard let status = UpdateVersionVerdict.status(installed: installedVersion, upstream: latestVersion) else {
            return undecidable()
        }
        // 缓存条目的可信度只对写下它的那个本机版本成立：版本不一致时本轮结论
        // 是重新推导的，不继承缓存里的置信度标记。
        let confidence = isSameInstalledVersion(cachedInstalledVersion, installedVersion)
            ? (entry.decodedConfidence ?? .unknown)
            : .unknown
        return CachedFallbackOutcome(
            status: status,
            latestVersion: latestVersion,
            confidence: confidence,
            freshness: .cached,
            origin: cacheOrigin.origin,
            cacheWrittenAt: cacheOrigin.cacheWrittenAt
        )
    }

    /// 写下缓存结论时的本机版本与当前本机版本是否是同一个版本。两边都能解析时
    /// 按语义化版本比较（`v2.0.0` 与 `2.0.0` 视为同一个版本），否则退回字符串
    /// 相等；任一为 nil 时不等（调用方在此之前已把缺字段降级为 unknown）。
    private func isSameInstalledVersion(_ lhs: String?, _ rhs: String?) -> Bool {
        guard let lhs, let rhs else { return false }
        if let left = SemanticVersion(lhs), let right = SemanticVersion(rhs) { return left == right }
        return lhs == rhs
    }

    private func baseEntry(for item: PlanItem) -> UpdateCacheEntry {
        if var cached = item.cached {
            cached.category = item.target.category.rawValue
            cached.packageName = item.target.packageName
            // 记录写下结论时的本机版本：下一次缓存回退据此判断旧结论是否仍
            // 适用于当前本机版本（GitHub #74）。
            cached.installedVersion = item.installedVersion
            return cached
        }
        return UpdateCacheEntry(
            targetID: item.target.id,
            category: item.target.category.rawValue,
            packageName: item.target.packageName,
            installedVersion: item.installedVersion
        )
    }

    private static func failure(forStatusCode statusCode: Int) -> UpdateCheckFailure {
        switch statusCode {
        case 429:
            return .rateLimited
        case 500...599:
            return .serverError
        case 300...399:
            return .unexpectedRedirect
        default:
            return .httpError
        }
    }

    private static func checkFailure(from failure: UpdateHTTPFailure) -> UpdateCheckFailure {
        switch failure {
        case .timedOut: return .timedOut
        case .offline: return .offline
        case .cancelled: return .cancelled
        case .transport: return .transport
        }
    }

    // MARK: - 缓存与日志

    private func loadCacheIfNeeded() {
        guard !cacheLoaded else { return }
        cacheLoaded = true
        let loaded = cacheStore.load()
        // 结构校验失败（损坏、被改写、超大、未来时间戳）：整份缓存按不可用处理，
        // 并记录固定原因。日志只写结论，不回显缓存内容。
        if let rejection = cacheStore.lastLoadRejection {
            log?(rejection.logLine)
        }
        cache = UpdateCheckCacheFile.supportedSchemaVersions.contains(loaded.schemaVersion) ? loaded : .empty
    }

    /// 只记录状态计数：不记录 URL、响应体、包名列表或任何请求细节。
    private func logSummary(_ summary: UpdateCheckSummary) {
        guard let log else { return }
        log("更新检查完成（\(summary.trigger.displayName)）：可用更新 \(summary.updateAvailableCount) 项，"
            + "无法确定 \(summary.unknownCount) 项，共检查 \(summary.results.count) 项。")
    }
}

// MARK: - 小工具

private extension String {
    var nonEmpty: String? {
        isEmpty ? nil : self
    }
}
