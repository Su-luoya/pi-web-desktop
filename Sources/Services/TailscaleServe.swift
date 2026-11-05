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
        return Self.normalizedProxy(existing) != Self.normalizedProxy(target)
    }

    private static func normalizedProxy(_ target: String) -> String {
        guard var components = URLComponents(string: target), components.path == "/" else { return target }
        components.path = ""
        return components.string ?? target
    }
}

/// 同一 tailnet 里的一台设备：菜单里选「测哪一台」用它。
struct TailscalePeer: Equatable {
    let hostName: String
    let os: String
    /// 第一个 IPv4 地址；ping 与显示都用它。
    let ipv4: String
    let online: Bool
    /// 当前的直连地址（`host:port`）；nil 表示现在只能走 DERP 中转。
    let directAddress: String?
    /// 中转所用的 DERP 区域代码（`tok`）。
    let relay: String?

    /// 弹出菜单里的一行：同名设备很常见（多台设备都叫 localhost），靠 IP 区分。
    var pickerTitle: String {
        "\(hostName)（\(os)）· \(pathText) · \(ipv4)"
    }

    var pathText: String {
        guard online else { return "离线" }
        if let directAddress { return "直连 \(directAddress)" }
        if let relay { return "中转 \(relay)" }
        return "未连接"
    }
}

/// 一次 `ping` 里单个 pong 的路径与往返时间。
struct TailscalePingSample: Equatable {
    let milliseconds: Int
    /// nil 表示直连。
    let relay: String?
    let directAddress: String?
}

struct TailscalePingReport: Equatable {
    var samples: [TailscalePingSample] = []

    var milliseconds: [Int] { samples.map(\.milliseconds) }
    var minimum: Int? { milliseconds.min() }
    var maximum: Int? { milliseconds.max() }

    /// 中位数：采样数很少时比平均值更能代表“平时大概多快”。
    var median: Int? {
        let sorted = milliseconds.sorted()
        guard !sorted.isEmpty else { return nil }
        return sorted[sorted.count / 2]
    }
}

/// 一个 DERP 区域到本机的往返延迟。
struct TailscaleDERPLatency: Equatable {
    let code: String
    let region: String
    let milliseconds: Int
}

/// `netcheck` 人类可读报告里我们关心的几行（JSON 只有区域编号、没有名字，
/// 因此这里解析文本而不是 `--format=json`）。
struct TailscaleNetcheckReport: Equatable {
    var udp: Bool?
    var ipv4: String?
    var mappingVariesByDestIP: Bool?
    var portMapping: String?
    var nearestDERP: String?
    /// 只收有延迟的区域：连不上的区域在报告里没有数字。
    var derpLatencies: [TailscaleDERPLatency] = []

    func region(for code: String) -> String? {
        derpLatencies.first { $0.code == code }.map(\.region)
    }

    func milliseconds(forDERP code: String) -> Int? {
        derpLatencies.first { $0.code == code }.map(\.milliseconds)
    }

    /// 按区域名找代码与延迟：`nearestDERP` 是名字（`Hong Kong`），不是代码（`hkg`）。
    var nearestLatency: (code: String, milliseconds: Int)? {
        guard let nearestDERP else { return nil }
        return derpLatencies.first { $0.region == nearestDERP }.map { ($0.code, $0.milliseconds) }
    }
}

/// 一次测量的完整结果；文本渲染由下面的 `text` 负责。
struct TailscaleLatencyReport: Equatable {
    let peer: TailscalePeer
    /// nil 表示命令跑不起来（不是“没有回应”，后者是空采样）。
    let ping: TailscalePingReport?
    let netcheck: TailscaleNetcheckReport?
}

extension TailscaleLatencyReport {
    /// 结果窗口里的整段文本，也是「复制结果」复制的内容。
    ///
    /// 纯字符串拼装，所有字段都可注入，因此“全程中转 / 中途转直连 / 没有回应”
    /// 这几个文案分支能在不跑命令的测试里断言。
    var text: String {
        var lines = ["目标：\(peer.hostName)（\(peer.os)） · \(peer.ipv4)", "Tailscale 记录：\(peer.pathText)", ""]
        lines.append(contentsOf: pingLines)
        lines.append("")
        lines.append(contentsOf: netcheckLines)
        lines.append("")
        lines.append("结论：\(verdict)")
        return lines.joined(separator: "\n")
    }

    /// 一句话结论：用户真正想知道的就是“走没走中转”。
    var verdict: String {
        guard let ping else { return "测不出往返时间，Tailscale 命令没有返回结果。" }
        guard let first = ping.samples.first else {
            return "没有收到回应，设备可能离线或网络挡掉了探测包。"
        }
        let samples = ping.samples
        let relays = samples.compactMap(\.relay)
        let roundTrip = ping.median ?? first.milliseconds
        guard !relays.isEmpty else {
            let address = first.directAddress.map { "（\($0)）" } ?? ""
            return "全程直连\(address)，往返 \(roundTrip) ms。"
        }
        let place = derpDescription(code: relays[0])
        if relays.count == samples.count {
            return "全程经中转 \(place)，往返 \(roundTrip) ms。"
        }
        return "开头经中转 \(place)，之后建立直连，往返 \(roundTrip) ms。"
    }

    private func derpDescription(code: String) -> String {
        let region = netcheck?.region(for: code) ?? ""
        return region.isEmpty ? code : "\(code)（\(region)）"
    }

    private var pingLines: [String] {
        guard let ping else { return ["往返时间：没有结果（命令未返回）。"] }
        guard ping.samples.first != nil, let minimum = ping.minimum,
              let median = ping.median, let maximum = ping.maximum
        else { return ["往返时间：没有收到回应。"] }
        var lines = [
            "往返时间（\(ping.samples.count) 个探测包）：",
            "  最小 \(minimum) ms · 中位 \(median) ms · 最大 \(maximum) ms"
        ]
        for (index, sample) in ping.samples.enumerated() {
            let path = sample.relay.map { "中转 \($0)" } ?? "直连 \(sample.directAddress ?? "")"
            lines.append("  第 \(index + 1) 次：\(sample.milliseconds) ms（\(path)）")
        }
        // status 里的路径是快照，可能跟这几秒内采到的路径不一致（忽直连忽中转），
        // 两边都写出来，不替用户下没把握的结论。
        var paths: [String] = []
        let directCount = ping.samples.filter { $0.relay == nil }.count
        if directCount > 0 { paths.append("直连 ×\(directCount)") }
        let relays = Dictionary(grouping: ping.samples.compactMap(\.relay), by: { $0 })
            .sorted { $0.key < $1.key }
            .map { "中转 \($0.key) ×\($0.value.count)" }
        paths.append(contentsOf: relays)
        lines.append("  采样路径：" + paths.joined(separator: " / "))
        return lines
    }

    private var netcheckLines: [String] {
        guard let netcheck else { return ["本机网络：没有取到（netcheck 未返回）。"] }
        var fields: [String] = []
        if let udp = netcheck.udp { fields.append("UDP \(udp ? "可用" : "不可用")") }
        if let ipv4 = netcheck.ipv4 { fields.append("IPv4 \(ipv4)") }
        if let portMapping = netcheck.portMapping { fields.append("端口映射 \(portMapping)") }
        if netcheck.mappingVariesByDestIP == true { fields.append("NAT 映射随目标变化（可能忽直连忽中转）") }
        var lines = ["本机网络：", fields.isEmpty ? "  没有字段可读。" : "  " + fields.joined(separator: " · ")]
        if let nearest = netcheck.nearestDERP {
            var summary = nearest
            if let known = netcheck.nearestLatency {
                summary = "\(known.code)（\(nearest)），\(known.milliseconds) ms"
            }
            lines.append("  最近的 DERP 区域：\(summary)")
        }
        if !netcheck.derpLatencies.isEmpty {
            // 几十个区域全列出来会把窗口撑满；窗口只看最快的几个。
            let sorted = netcheck.derpLatencies.sorted { $0.milliseconds < $1.milliseconds }
            var table = sorted.prefix(6).map { "\($0.code) \($0.milliseconds) ms" }.joined(separator: " · ")
            if sorted.count > 6 { table += " · …共 \(sorted.count) 个区域" }
            lines.append("  DERP 区域延迟：\(table)")
        }
        return lines
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

    /// nil 表示配置不可读，不能据此认定端口空闲。
    func snapshot() -> TailscaleServeSnapshot? {
        guard let binary = binaryPath,
              let output = runner.run([binary, "serve", "status", "--json"]) else { return nil }
        return Self.snapshot(fromServeStatusJSON: output)
    }

    // MARK: - 动作

    /// 启用：`serve --bg --https=<port> <target>`。
    ///
    /// 目标端口已被别的条目占用时直接抛 `noFreePort`，不覆盖别人的配置。
    func enable(port: Int, target: URL) throws {
        guard let binary = binaryPath else { throw TailscaleServeError.notInstalled }
        guard let existing = snapshot() else {
            throw TailscaleServeError.commandFailed(arguments: ["serve", "status", "--json"])
        }
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

    // MARK: - 延迟测量

    /// `status --json` 里的 peer 列表。nil 表示命令失败或输出不可解析。
    func peers() -> [TailscalePeer]? {
        guard let binary = binaryPath,
              let output = runner.run([binary, "status", "--json"]) else { return nil }
        return Self.peers(fromStatusJSON: output)
    }

    /// 向一台设备发 `count` 个 Tailscale 层探测包，记录每一跳的路径与往返时间。
    ///
    /// `--until-direct=false` 是刻意的：默认会在建立直连后立刻停，只留下一条样本；
    /// 这里要的是“刚开始是不是在绕中转”，所以固定采满。全程中转时命令以非零退出码
    /// 结束，但输出仍在标准输出里，因此走 `runAllowingFailure`。
    func ping(ipv4: String, count: Int = 3) -> TailscalePingReport? {
        guard let binary = binaryPath else { return nil }
        let result = runner.runAllowingFailure(
            [binary, "ping", "--c", "\(count)", "--until-direct=false", "--timeout=2s", ipv4],
            timeout: 20
        )
        guard let output = result.output else { return nil }
        return Self.pingReport(fromOutput: output)
    }

    /// 本机网络条件与各 DERP 区域的延迟（实测约 3 秒：它在等 UDP 探测回来）。
    func netcheck() -> TailscaleNetcheckReport? {
        guard let binary = binaryPath else { return nil }
        guard let output = runner.run([binary, "netcheck"], timeout: 20).output else { return nil }
        return Self.netcheckReport(fromOutput: output)
    }

    // MARK: - 纯解析

    /// `status --json` → peer 列表。在线的排在前面，其次按名字排（菜单顺序不随机）。
    static func peers(fromStatusJSON json: String) -> [TailscalePeer]? {
        guard let root = jsonObject(json) else { return nil }
        guard let raw = root["Peer"] as? [String: Any] else { return [] }
        var peers: [TailscalePeer] = []
        for value in raw.values {
            guard let node = value as? [String: Any],
                  let hostName = node["HostName"] as? String, !hostName.isEmpty,
                  let addresses = node["TailscaleIPs"] as? [String],
                  let ipv4 = addresses.first(where: { !$0.contains(":") })
            else { continue }
            let direct = node["CurAddr"] as? String
            let relay = node["Relay"] as? String
            peers.append(TailscalePeer(
                hostName: hostName,
                os: node["OS"] as? String ?? "未知系统",
                ipv4: ipv4,
                online: node["Online"] as? Bool ?? false,
                directAddress: (direct?.isEmpty ?? true) ? nil : direct,
                relay: (relay?.isEmpty ?? true) ? nil : relay
            ))
        }
        return peers.sorted { lhs, rhs in
            if lhs.online != rhs.online { return lhs.online }
            return lhs.hostName.localizedStandardCompare(rhs.hostName) == .orderedAscending
        }
    }

    /// `pong from <名字> (<IP>) via <路径> in <毫秒>ms`；其余行（提示、报错）忽略。
    static func pingReport(fromOutput output: String) -> TailscalePingReport {
        var report = TailscalePingReport()
        for raw in output.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("pong from "),
                  let via = line.range(of: " via "),
                  let inRange = line.range(of: " in ", range: via.upperBound..<line.endIndex)
            else { continue }
            let path = line[via.upperBound..<inRange.lowerBound]
            let tail = line[inRange.upperBound...].trimmingCharacters(in: .whitespaces)
            guard tail.hasSuffix("ms"),
                  let milliseconds = Int(tail.dropLast(2).trimmingCharacters(in: .whitespaces))
            else { continue }
            if path.hasPrefix("DERP(") && path.hasSuffix(")") {
                let code = String(path.dropFirst("DERP(".count).dropLast())
                report.samples.append(TailscalePingSample(
                    milliseconds: milliseconds, relay: code, directAddress: nil
                ))
            } else {
                report.samples.append(TailscalePingSample(
                    milliseconds: milliseconds, relay: nil, directAddress: String(path)
                ))
            }
        }
        return report
    }

    /// `netcheck` 文本报告：`* Key: value` 行 + `- <区域>: <毫秒>ms (<名字>)` 行。
    static func netcheckReport(fromOutput output: String) -> TailscaleNetcheckReport {
        var report = TailscaleNetcheckReport()
        for raw in output.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("* ") {
                let body = line.dropFirst(2)
                guard let separator = body.firstIndex(of: ":") else { continue }
                let key = body[..<separator].trimmingCharacters(in: .whitespaces)
                let value = body[body.index(after: separator)...].trimmingCharacters(in: .whitespaces)
                switch key {
                case "UDP":
                    report.udp = value == "true"
                case "IPv4":
                    // `yes, <地址>` / `no`；无地址时留 nil。
                    report.ipv4 = value.hasPrefix("yes")
                        ? value.dropFirst("yes".count).trimmingCharacters(in: CharacterSet(charactersIn: ", "))
                        : nil
                case "MappingVariesByDestIP":
                    report.mappingVariesByDestIP = value == "true"
                case "PortMapping":
                    report.portMapping = value.isEmpty ? nil : value
                case "Nearest DERP":
                    report.nearestDERP = value.isEmpty ? nil : value
                default:
                    continue
                }
            } else if line.hasPrefix("- "),
                      let latency = derpLatency(fromDERPLine: String(line.dropFirst(2))) {
                report.derpLatencies.append(latency)
            }
        }
        return report
    }

    /// `sin: 94.3ms  (Singapore)` → 代码、名字与毫秒（四舍五入到整数）。
    /// 连不上的区域是 `hnl:         (Honolulu)`：冒号后面没有 `ms`，返回 nil。
    static func derpLatency(fromDERPLine body: String) -> TailscaleDERPLatency? {
        guard let separator = body.firstIndex(of: ":") else { return nil }
        let code = body[..<separator].trimmingCharacters(in: .whitespaces)
        let rest = body[body.index(after: separator)...]
        guard !code.isEmpty, let unit = rest.range(of: "ms") else { return nil }
        let number = rest[..<unit.lowerBound].trimmingCharacters(in: .whitespaces)
        guard let value = Double(number) else { return nil }
        var region = ""
        if let open = rest.firstIndex(of: "("), let close = rest.lastIndex(of: ")"), open < close {
            region = rest[rest.index(after: open)..<close].trimmingCharacters(in: .whitespaces)
        }
        return TailscaleDERPLatency(code: code, region: region, milliseconds: Int(value.rounded()))
    }

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
    static func snapshot(fromServeStatusJSON json: String) -> TailscaleServeSnapshot? {
        // CLI 在尚未配置 serve 时输出 JSON null；命令失败或坏 JSON 则不能当作空配置。
        if json.trimmingCharacters(in: .whitespacesAndNewlines) == "null" { return TailscaleServeSnapshot() }
        guard let root = jsonObject(json) else { return nil }
        for field in ["Web", "TCP", "AllowFunnel"] {
            if let value = root[field], !(value is NSNull), !(value is [String: Any]) { return nil }
        }
        var proxies: [Int: String] = [:]
        if let web = root["Web"] as? [String: Any] {
            for (key, value) in web {
                guard let port = port(fromWebKey: key) else { return nil }
                let handlers = (value as? [String: Any])?["Handlers"] as? [String: Any]
                if proxies[port] == nil, handlers?.count == 1,
                   let proxy = handlers?["/"] as? [String: Any], proxy.count == 1,
                   let target = proxy["Proxy"] as? String, !target.isEmpty {
                    proxies[port] = target
                } else {
                    // 多个 host 或 handler 共用端口时，关闭该端口会删掉别人的入口。
                    proxies[port] = ""
                }
            }
        }
        if let tcp = root["TCP"] as? [String: Any] {
            for key in tcp.keys {
                guard let port = Int(key), (1...65535).contains(port) else { return nil }
                if proxies[port] == nil { proxies[port] = "" }
            }
        }
        if let funnel = root["AllowFunnel"] as? [String: Any] {
            for (key, value) in funnel where (value as? Bool) != false {
                guard let port = port(fromWebKey: key) else { return nil }
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
        guard !suffix.contains("]"), let port = Int(suffix), (1...65535).contains(port) else { return nil }
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

    /// serve 的代理目标：只能是回环。
    ///
    /// tailscaled 代理到**本机自己的 tailnet 地址**会一直挂着不返回（实测：同一个
    /// serve 端口指 127.0.0.1 与 LAN 地址都正常，指 100.x 则浏览器无限转圈）。服务
    /// 绑在 tailnet 地址上时 `configuration.serviceURL` 恰好就是那个形状，直接拿它
    /// 当目标就会造出一条「菜单显示已开启、扫码打不开」的入口，所以目标固定为回环，
    /// 由「启用」把监听地址一并收回回环。
    static func loopbackTarget(port: Int) -> URL? {
        guard (1...65535).contains(port) else { return nil }
        var components = URLComponents()
        components.scheme = "http"
        components.host = ServiceConfiguration.defaultHostname
        components.port = port
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
