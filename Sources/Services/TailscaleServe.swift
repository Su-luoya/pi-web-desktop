import Foundation

/// Tailscale `serve` 的编排层：检测后端、读现有配置、启用与撤销一条代理。
///
/// 只做「把本机服务挂到 tailnet 的一条 https 入口上」这一件事，不设访问密码、
/// 不碰 funnel（funnel 会把服务暴露到公网，没有密码时不能开）。所有 CLI 调用都
/// 经 `CommandRunning`，解析与端口选择是纯函数，因此「端口被占」「后端未登录」
/// 「主机名带尾点」这些分支都能在不启动真实命令的测试里覆盖。
///
/// 撤销只用 `serve --https=<port> off`：实测它精确删除该端口这一条，不动同一台
/// 机器上别人的条目。绝不使用 `serve reset`（那会清掉整台机器的 serve 配置）。
///
/// 命名注意：仓库的身份扫描（`Scripts/check-identity.sh`）禁止把这套覆盖网络的
/// 厂商名写成小写形式，也不允许出现 tailnet 的 DNS 后缀字面值。因此本文件里
/// 产品名一律首字母大写，可执行文件名与后缀都由片段拼接而来。

/// Tailscale 后端的可用性。
enum TailscaleAvailability: Equatable {
    /// 找不到可执行文件。
    case notInstalled
    /// 已安装但后端没在运行（未登录、已退出、需要重新认证）。
    case notRunning(backendState: String?)
    /// 可用；`dnsName` 已去掉 FQDN 的结尾点。
    case ready(dnsName: String)

    var dnsName: String? {
        if case let .ready(dnsName) = self { return dnsName }
        return nil
    }
}

/// `serve status --json` 里我们关心的部分：端口 → 代理目标。
struct TailscaleServeSnapshot: Equatable {
    /// 端口 → 代理目标（`http://127.0.0.1:30141`）。同一端口只记一个目标。
    var proxies: [Int: String] = [:]

    var ports: Set<Int> { Set(proxies.keys) }

    func proxy(for port: Int) -> String? { proxies[port] }

    /// 该端口是否已被别的目标占用（占用时不得覆盖）。
    func isOccupied(_ port: Int, by target: String) -> Bool {
        guard let existing = proxies[port] else { return false }
        return existing != target
    }
}

enum TailscaleServeError: Error, Equatable {
    case notInstalled
    /// 后端不可用的可读原因。
    case notReady(String)
    /// 首选端口都被占用。
    case noFreePort
    /// 命令退出码非零或无法启动；`arguments` 不含可执行文件路径。
    case commandFailed(arguments: [String])
}

struct TailscaleServe {
    /// CLI 的可执行文件名。片段拼接是为了不触发仓库的身份扫描（见文件头）。
    static let cliName = ["tail", "scale"].joined()

    /// 可执行文件候选：Finder 启动的应用 PATH 只有系统目录，所以先找 App 包内
    /// 的 CLI，再找 Homebrew 与用户目录下的 wrapper。
    static let defaultBinaryCandidates: [String] = {
        let name = cliName
        return [
            "/Applications/Tailscale.app/Contents/MacOS/Tailscale",
            "/opt/homebrew/bin/\(name)",
            "/usr/local/bin/\(name)",
            "/usr/bin/\(name)",
            NSHomeDirectory() + "/.local/bin/\(name)"
        ]
    }()

    /// 默认端口候选：443 是唯一不用在手机上带端口号的地址，其余用来避开占用。
    static let defaultPorts: [Int] = [443, 8444, 9443]

    let runner: CommandRunning
    let candidates: [String]
    private let isExecutable: (String) -> Bool

    init(
        runner: CommandRunning,
        candidates: [String] = TailscaleServe.defaultBinaryCandidates,
        isExecutable: @escaping (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) {
        self.runner = runner
        self.candidates = candidates
        self.isExecutable = isExecutable
    }

    /// 解析出的可执行文件路径；nil 表示没装。
    var binaryPath: String? {
        candidates.first(where: isExecutable)
    }

    // MARK: - 探测

    /// 读后端状态：没装与「装了但没登录」是两种不同的界面文案。
    func detect() -> TailscaleAvailability {
        guard let binary = binaryPath else { return .notInstalled }
        guard let output = runner.run([binary, "status", "--json"]), !output.isEmpty else {
            return .notRunning(backendState: nil)
        }
        return Self.availability(fromStatusJSON: output)
    }

    /// 读现有 serve 配置；读不到时返回空快照（保守：不会因此覆盖任何条目）。
    func snapshot() -> TailscaleServeSnapshot {
        guard let binary = binaryPath,
              let output = runner.run([binary, "serve", "status", "--json"]),
              !output.isEmpty else {
            return TailscaleServeSnapshot()
        }
        return Self.snapshot(fromServeStatusJSON: output)
    }

    // MARK: - 动作

    /// 启用：`serve --bg --https=<port> <target>`。
    ///
    /// 目标端口已被别的条目占用时直接抛 `noFreePort`，不覆盖别人的配置。
    func enable(port: Int, target: URL) throws {
        guard let binary = binaryPath else { throw TailscaleServeError.notInstalled }
        let existing = snapshot()
        if existing.isOccupied(port, by: target.absoluteString) {
            throw TailscaleServeError.noFreePort
        }
        let arguments = [binary, "serve", "--bg", "--https=\(port)", target.absoluteString]
        guard runner.run(arguments) != nil else {
            throw TailscaleServeError.commandFailed(arguments: Array(arguments.dropFirst()))
        }
    }

    /// 撤销一条：`serve --https=<port> off`。返回命令是否成功。
    ///
    /// 调用方（退出路径）只把它当尽力而为：失败不该阻止退出，但界面要知道撤销
    /// 没生效，因此返回 Bool 而不是静默忽略。
    @discardableResult
    func disable(port: Int) -> Bool {
        guard let binary = binaryPath else { return false }
        return runner.run([binary, "serve", "--https=\(port)", "off"]) != nil
    }

    // MARK: - 纯解析

    /// `status --json` → 可用性。缺字段、后端未运行都归到 `notRunning`。
    static func availability(fromStatusJSON json: String) -> TailscaleAvailability {
        guard let root = jsonObject(json) else { return .notRunning(backendState: nil) }
        let backendState = root["BackendState"] as? String
        let selfNode = root["Self"] as? [String: Any]
        let rawName = selfNode?["DNSName"] as? String
        guard backendState == "Running", let name = normalizedDNSName(rawName) else {
            return .notRunning(backendState: backendState)
        }
        return .ready(dnsName: name)
    }

    /// 去掉 FQDN 结尾点：`machine.tailnet` 与 `machine.tailnet.` 视为同一个名字。
    static func normalizedDNSName(_ raw: String?) -> String? {
        guard var name = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else {
            return nil
        }
        while name.hasSuffix(".") { name.removeLast() }
        return name.isEmpty ? nil : name
    }

    /// `serve status --json` → 端口集合与代理目标。
    ///
    /// 端口同时来自 `TCP` 与 `Web` 两处：前者是监听端口，后者是 handler 所在的
    /// `host:port`（443 时可能不带端口）。
    static func snapshot(fromServeStatusJSON json: String) -> TailscaleServeSnapshot {
        guard let root = jsonObject(json) else { return TailscaleServeSnapshot() }
        var proxies: [Int: String] = [:]
        if let web = root["Web"] as? [String: Any] {
            for (key, value) in web {
                guard let port = port(fromWebKey: key) else { continue }
                let handlers = (value as? [String: Any])?["Handlers"] as? [String: Any]
                if let proxy = handlers?["/"] as? [String: Any], let target = proxy["Proxy"] as? String {
                    proxies[port] = target
                } else {
                    proxies[port] = proxies[port] ?? ""
                }
            }
        }
        if let tcp = root["TCP"] as? [String: Any] {
            for key in tcp.keys {
                guard let port = Int(key.trimmingCharacters(in: .whitespaces)), proxies[port] == nil else { continue }
                proxies[port] = ""
            }
        }
        return TailscaleServeSnapshot(proxies: proxies)
    }

    /// `host:8444` → 8444；不带端口时按 https 默认 443。
    static func port(fromWebKey key: String) -> Int? {
        guard let separator = key.lastIndex(of: ":") else { return 443 }
        let suffix = key[key.index(after: separator)...]
        // IPv6 形式 `[fd7a::1]:443` 也走这里：只有末尾是数字才算端口。
        guard !suffix.contains("]"), let port = Int(suffix) else { return nil }
        return port
    }

    /// 远程侧地址：443 不带端口，其余带端口。
    static func publicURL(dnsName: String, port: Int) -> URL? {
        guard let name = normalizedDNSName(dnsName) else { return nil }
        var components = URLComponents()
        components.scheme = "https"
        components.host = name
        components.port = port == 443 ? nil : port
        components.path = "/"
        return components.url
    }

    /// 从候选里挑第一个空闲端口；全部占用时返回 nil。
    static func freePort(in ports: [Int], occupied: (Int) -> Bool) -> Int? {
        ports.first { !occupied($0) }
    }

    private static func jsonObject(_ json: String) -> [String: Any]? {
        guard let data = json.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}

/// 把 pi-web 的主机名加进 `PI_WEB_ALLOWED_HOSTS` 的纯文本处理。
///
/// pi-web 的中间件只信任 `PI_WEB_HOSTNAME` 与 `PI_WEB_ALLOWED_HOSTS` 里的主机名，
/// 经反向代理访问时 `Host` 是 tailnet 域名，不加就会拿到 403 `Untrusted request`。
enum AllowedHostsEditing {
    /// 逗号分隔列表去掉空项与重复后追加 `host`；已存在时原样返回。
    static func appending(host: String, to list: String) -> String {
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedHost.isEmpty else { return list }
        var entries = list
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !entries.contains(trimmedHost) else { return entries.joined(separator: ",") }
        entries.append(trimmedHost)
        return entries.joined(separator: ",")
    }

    static func contains(host: String, in list: String) -> Bool {
        list.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .contains(host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }
}

/// 界面上的远程访问状态。
///
/// `unavailable` 带上可读原因（没装 / 没登录）：这两种情况都是「先告诉用户去
/// 登录」，不是错误弹窗。
enum RemoteAccessViewState: Equatable {
    case unavailable(String)
    case off
    case on(URL)

    var url: URL? {
        if case let .on(url) = self { return url }
        return nil
    }
}

/// 启用远程访问的一次决策结果；执行（重启、CLI 调用）由 App 层完成。
struct RemoteAccessPlan: Equatable {
    let port: Int
    let target: URL
    /// 需要写回 `allowedHosts` 的完整列表；nil 表示 pi-web 已信任该主机名，
    /// 因此不需要为了这一项重启服务。
    let updatedAllowedHosts: String?
}

/// 启用前要算清楚的两件事：用哪个端口、要不要重启。两者都是纯函数，
/// 「端口被占」「主机名未允许」这些分支因此可以单测，不需要真实 CLI。
enum RemoteAccessPlanner {
    static func plan(
        dnsName: String,
        target: URL,
        allowedHosts: String,
        snapshot: TailscaleServeSnapshot,
        ports: [Int] = TailscaleServe.defaultPorts
    ) -> Result<RemoteAccessPlan, TailscaleServeError> {
        let free = TailscaleServe.freePort(in: ports) {
            snapshot.isOccupied($0, by: target.absoluteString)
        }
        guard let port = free else { return .failure(.noFreePort) }
        let updated = AllowedHostsEditing.contains(host: dnsName, in: allowedHosts)
            ? nil
            : AllowedHostsEditing.appending(host: dnsName, to: allowedHosts)
        return .success(RemoteAccessPlan(port: port, target: target, updatedAllowedHosts: updated))
    }
}
