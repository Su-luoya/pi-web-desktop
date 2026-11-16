import Foundation

/// 远程访问（Tailscale serve）的 App 层编排：把纯决策（`RemoteAccessPlanner`）
/// 落成「写配置 → 等重启 → 调 CLI → 记住端口」这条时序。
///
/// 三条不变量：
/// 1. 端口记在自己名下（`UserDefaults` 的 `remoteAccess.port`），退出时凭它精确撤销
///    这一条，绝不 `reset`（同一台机器上可能还有别人的条目）。
/// 2. CLI 调用全部在后台队列（`CommandProbeDispatch`），主线程只更新状态。
/// 3. 没有访问密码：这台机器的 tailnet 身份就是唯一的边界，因此从不调用 funnel。
///    自定义隧道地址是唯一会把控制台放到公网上的入口，所以它在 App 层必须先过一句
///    显式的“我明白”，且与 Tailscale 那条二选一（不存两套入口，状态始终是单一 URL）。
final class RemoteAccessController {
    enum DefaultsKey {
        static let port = "remoteAccess.port"
        /// 已核实的未完成 HTTPS 入口：只能重试或撤销，不能在启动时恢复成已开启。
        static let cleanupPending = "remoteAccess.cleanupPending"
        /// 用户自填的隧道地址（完整 URL）。它只是“记住这个地址”，没有任何机器配置
        /// 需要撤销，所以退出时不会清掉它。
        static let customURL = "remoteAccess.customURL"
        /// 退出前远程访问是开着的，记下当时那条 serve 的端口。
        ///
        /// 退出会撤掉入口（留着只会让手机打开 502），但用户的手机书签不该因此失效：
        /// 这个标记让下次启动自动重挂，并优先用回同一个端口。
        static let restorePending = "remoteAccess.restorePending"
    }

    /// 启用失败的可读原因；`noFreePort` 与命令失败要分开说，否则用户不知道该改什么。
    enum Failure: Error, Equatable {
        case notInstalled
        case notRunning
        case noFreePort
        case commandFailed
        case commandError(String)
        /// tailnet 没启用 HTTPS；`url` 是 Tailscale 给出的启用链接。
        case httpsNotEnabled(url: URL?, entryInstalled: Bool = false)

        /// 需要用户去点一下的链接（目前只有启用 HTTPS 这一种）。
        var actionURL: URL? {
            if case let .httpsNotEnabled(url, _) = self { return url }
            return nil
        }

        var message: String {
            switch self {
            case .notInstalled:
                return "没有找到 Tailscale 命令行工具。请先安装并登录 Tailscale。"
            case .notRunning:
                return "Tailscale 没有在运行或尚未登录，请登录后再试。"
            case .noFreePort:
                return "443、8444、9443 都已被其他服务占用，无法再挂一条 HTTPS 入口。"
            case .commandFailed:
                return "Tailscale 命令执行失败，请检查 Tailscale 是否正常。"
            case let .commandError(message):
                return LogRedactor().redact(message)
            case let .httpsNotEnabled(url, _):
                // 文案只在 TailscaleServeError 里维护一份（弹窗要直接给出链接）。
                return TailscaleServeError.httpsNotEnabled(url: url).message
            }
        }
    }

    private let serve: TailscaleServe
    private let defaults: UserDefaults
    private(set) var state: RemoteAccessViewState = .off
    /// 状态变化（主线程回调）。菜单用它刷新标题与可用性。
    var onChange: ((RemoteAccessViewState) -> Void)?
    /// 诊断日志的落点（生产环境由 `AppDelegate` 接到 `LogWriter`）。
    /// 丢掉重挂标记这件事在菜单上完全看不见，只能靠日志复盘。
    var log: ((String) -> Void)?
    /// 启动重挂的代际：用户一旦手动启用/关闭，启动时那次还在跑的 CLI 结果就该作废。
    /// 否则晚到的「未开启」会盖掉用户刚点出来的「已开启」，还顺手清掉端口记录（退出就撤不掉了）。
    private var restoreGeneration = 0

    convenience init(runner: CommandRunning, defaults: UserDefaults = .standard) {
        self.init(serve: TailscaleServe(runner: runner), defaults: defaults)
    }

    init(serve: TailscaleServe, defaults: UserDefaults = .standard) {
        self.serve = serve
        self.defaults = defaults
    }

    /// 记录里那条端口；nil 表示我们没有在用远程访问。
    var activePort: Int? {
        defaults.object(forKey: DefaultsKey.port) as? Int
    }

    /// 用户自填的隧道地址；nil 表示在用 Tailscale 或干脆没开。
    /// 存的是原始字符串，读的时候重新过一遍解析——手改 defaults 写坏了也不至于崩。
    var customAddress: URL? {
        guard let raw = defaults.string(forKey: DefaultsKey.customURL) else { return nil }
        return CustomTunnelAddress.url(from: raw)
    }

    // MARK: - 状态

    /// 启动时对账：记录还在、Tailscale 里那条也还在且指向回环，就恢复成「已开启」。
    ///
    /// 过期条目需要撤销：上次异常退出留下的残迹、旧版本把代理
    /// 目标写成 `http://<本机 tailnet 地址>:<端口>` 的情况（Tailscale 守护进程代理到自己的
    /// tailnet 地址会一直挂着，那条入口扫码打不开），以及监听地址被改成非回环之后
    /// 目标不再可达的情况。条目已不存在或撤销成功才忘掉记录；撤销失败则保留端口，
    /// 让菜单能重试关闭，退出时也仍有记录可供收尾。
    func refresh(configuration: ServiceConfiguration) {
        let serve = self.serve
        let recordedPort = activePort
        if let custom = customAddress {
            // 二选一：自定义地址优先。上次切换中途退出会留下 serve 条目，这里顺手收尾。
            update(.on(custom))
            guard let port = recordedPort else { return }
            CommandProbeDispatch.runOffMain(work: {
                serve.disable(port: port)
            }) { [weak self] succeeded in
                if succeeded { self?.forget() }
            }
            return
        }
        // 正常退出会把 serve 条目撤销并只留下这个标记：启动时重挂，手机书签不用重扫。
        if recordedPort == nil,
           let restorePort = defaults.object(forKey: DefaultsKey.restorePending) as? Int {
            restore(port: restorePort, configuration: configuration)
            return
        }
        guard let port = recordedPort,
              let target = TailscaleServe.loopbackTarget(port: configuration.port) else {
            update(.off)
            return
        }
        let listensOnLoopback = RemoteAccessPolicy.isLoopbackHostname(configuration.hostname)
        let cleanupPending = defaults.bool(forKey: DefaultsKey.cleanupPending)
        CommandProbeDispatch.runOffMain(work: { () -> RefreshOutcome in
            switch serve.detect() {
            case .notInstalled:
                return .unavailable(Failure.notInstalled.message)
            case .notRunning:
                return .unavailable(Failure.notRunning.message)
            case let .ready(dnsName):
                guard let snapshot = try? serve.snapshot() else {
                    return .unavailable(Failure.commandFailed.message)
                }
                guard snapshot.proxy(for: port) != nil else { return .stale }
                if !cleanupPending, listensOnLoopback,
                   !snapshot.isOccupied(port, by: target.absoluteString),
                   let url = TailscaleServe.publicURL(dnsName: dnsName, port: port) {
                    return .on(url)
                }
                return serve.disable(port: port)
                    ? .stale
                    : .unavailable(Failure.commandFailed.message)
            }
        }) { [weak self] outcome in
            guard let self else { return }
            switch outcome {
            case let .on(url):
                self.defaults.removeObject(forKey: DefaultsKey.restorePending)
                self.update(.on(url))
            case let .unavailable(message):
                self.update(.unavailable(message))
            case .stale:
                self.forget()
                self.update(.off)
            }
        }
    }

    /// 启动时把退出前那条入口重新挂上。
    ///
    /// 只做「挂入口」这一件事：允许主机名在启用时已经写进配置，退出不会清掉它，所以
    /// 正常情况下不需要重启服务、用户的会话也不会断。万一确实要改配置（机器名变过、
    /// 配置被重置过），这里不去驱动启动流程重启服务，而是作废标记，把这一次重启交给
    /// 菜单里的「启用」——那条路径本来就会先弹确认框说明会话会中断。
    private func restore(port: Int, configuration: ServiceConfiguration) {
        restoreGeneration &+= 1
        let generation = restoreGeneration
        guard RemoteAccessPolicy.isLoopbackHostname(configuration.hostname),
              let target = TailscaleServe.loopbackTarget(port: configuration.port) else {
            // 监听地址不是回环：这条入口到了也连不上。等用户手动启用（那次会顺带改回回环）。
            log?("远程访问：丢弃重启重挂标记（监听地址 \(configuration.hostname) 不是回环）")
            forget()
            update(.off)
            return
        }
        let serve = self.serve
        let allowedHosts = configuration.allowedHosts
        // 优先用回退出前那个端口：手机书签里可能带着端口号（例如 :8444）。
        let ports = [port] + TailscaleServe.defaultPorts
        CommandProbeDispatch.runOffMain(work: { () -> RestoreOutcome in
            switch serve.detect() {
            case .notInstalled:
                return .unavailable(Failure.notInstalled.message)
            case .notRunning:
                return .unavailable(Failure.notRunning.message)
            case let .ready(dnsName):
                guard let snapshot = try? serve.snapshot() else {
                    return .unavailable(Failure.commandFailed.message)
                }
                switch RemoteAccessPlanner.plan(
                    dnsName: dnsName,
                    target: target,
                    allowedHosts: allowedHosts,
                    snapshot: snapshot,
                    ports: ports
                ) {
                case let .failure(error):
                    return .unavailable(Self.failure(from: error).message)
                case let .success(plan):
                    guard plan.updatedAllowedHosts == nil else {
                        return .skip(reason: "允许主机名里缺 \(dnsName)，补上要重启服务")
                    }
                    guard let url = TailscaleServe.publicURL(dnsName: dnsName, port: plan.port) else {
                        return .skip(reason: "无法拼出 \(dnsName) 的公开地址")
                    }
                    do {
                        try serve.enable(port: plan.port, target: plan.target)
                    } catch {
                        let failure = Self.failure(from: error)
                        // CLI 已经把入口挂上了（只是 tailnet 没启用 HTTPS）：它现在真的在机器上，
                        // 就得记在自己名下，否则退出时撤不掉，手机拿到的正是这次改动要避免的 502。
                        if case .httpsNotEnabled(_, true) = failure {
                            return .installedButUnusable(message: failure.message, port: plan.port)
                        }
                        return .unavailable(failure.message)
                    }
                    return .restored(url: url, port: plan.port)
                }
            }
        }) { [weak self] outcome in
            guard let self, generation == self.restoreGeneration else { return }
            switch outcome {
            case let .restored(url, port):
                self.forget()
                self.defaults.set(port, forKey: DefaultsKey.port)
                self.update(.on(url))
            case let .unavailable(message):
                // 这次挂不上（没装、没登录、CLI 失败）：标记留着，下次启动再试一次。
                self.update(.unavailable(message))
            case let .installedButUnusable(message, port):
                self.defaults.set(port, forKey: DefaultsKey.port)
                self.defaults.set(true, forKey: DefaultsKey.cleanupPending)
                self.update(.unavailable(message))
            case let .skip(reason):
                // 入口照旧有效，只是要改配置才能重挂：交给菜单里的「启用」，它会先警告。
                self.log?("远程访问：丢弃重启重挂标记（\(reason)）")
                self.forget()
                self.update(.off)
            }
        }
    }

    /// 启动对账的一次结果：CLI 全部在后台队列跑完，主线程只落地状态。
    private enum RefreshOutcome {
        case on(URL)
        /// Tailscale 不可用：记录留着，菜单给重试入口。
        case unavailable(String)
        /// 那条入口已经不在或已成功撤销：记录作废。
        case stale
    }

    /// 启动时重挂的一次结果。
    private enum RestoreOutcome {
        /// 挂上了：端口记回自己名下。
        case restored(url: URL, port: Int)
        /// 这次挂不上：标记留着，下次启动再试。
        case unavailable(String)
        /// 入口挂上了但打不开（tailnet 没启用 HTTPS）：和「启用」一样记在自己名下，
        /// 让退出能撤掉、下次启动按未完成入口对账。
        case installedButUnusable(message: String, port: Int)
        /// 需要改配置才能挂：不自动重启服务，交给菜单里的「启用」。
        case skip(reason: String)
    }

    // MARK: - 启用

    /// 启用手机访问（Tailscale serve）。
    ///
    /// - `applyConfiguration` 是「保存配置并等重启走完」的统一入口
    ///   （`applyPreferencesConfiguration`），在需要把监听地址收回回环、或把主机名
    ///   补进允许列表时调用一次；它会中断当前会话，因此确认框在调用方、这里只管执行。
    func enable(
        configuration: ServiceConfiguration,
        applyConfiguration: @escaping (ServiceConfiguration, @escaping () -> Void) -> Void,
        completion: @escaping (Result<URL, Failure>) -> Void
    ) {
        // 用户的显式操作优先：启动时那次重挂还在跑的话，它的结果从这里开始作废。
        restoreGeneration &+= 1
        let serve = self.serve
        // 代理目标只能是回环（见 `TailscaleServe.loopbackTarget`），监听地址也必须
        // 是回环：服务绑在 tailnet 地址上时旧版本会造出一条扫码打不开的入口。
        guard let target = TailscaleServe.loopbackTarget(port: configuration.port) else {
            completion(.failure(.commandFailed))
            return
        }
        CommandProbeDispatch.runOffMain(work: {
            (serve.detect(), Result { try serve.snapshot() })
        }) { [weak self] result in
            let (detection, snapshotResult) = result
            guard let self else { return }
            let dnsName: String
            switch detection {
            case .notInstalled:
                completion(.failure(.notInstalled))
                return
            case .notRunning:
                self.update(.unavailable(Failure.notRunning.message))
                completion(.failure(.notRunning))
                return
            case let .ready(name):
                dnsName = name
            }
            let snapshot: TailscaleServeSnapshot
            do {
                snapshot = try snapshotResult.get()
            } catch {
                completion(.failure(Self.failure(from: error)))
                return
            }
            let plan: RemoteAccessPlan
            switch RemoteAccessPlanner.plan(
                dnsName: dnsName,
                target: target,
                allowedHosts: configuration.allowedHosts,
                snapshot: snapshot
            ) {
            case let .success(value):
                plan = value
            case .failure:
                completion(.failure(.noFreePort))
                return
            }

            let install: () -> Void = { [weak self] in
                self?.install(plan: plan, dnsName: dnsName, completion: completion)
            }
            // 监听地址不是回环时一并改回来：serve 的目标固定是 127.0.0.1，服务不在
            // 那里就白装一条。合并成一次 applyConfiguration，只重启一次。
            var updated = configuration
            var changed = false
            if !RemoteAccessPolicy.isLoopbackHostname(updated.hostname) {
                updated.hostname = ServiceConfiguration.defaultHostname
                changed = true
            }
            if let updatedAllowedHosts = plan.updatedAllowedHosts {
                updated.allowedHosts = updatedAllowedHosts
                changed = true
            }
            guard changed else {
                install()
                return
            }
            applyConfiguration(updated, install)
        }
    }

    /// 配置已经允许该主机名后的最后一步：调 CLI 挂上这条入口。
    private func install(
        plan: RemoteAccessPlan,
        dnsName: String,
        completion: @escaping (Result<URL, Failure>) -> Void
    ) {
        let serve = self.serve
        CommandProbeDispatch.runOffMain(work: { () -> Result<Void, Failure> in
            do {
                try serve.enable(port: plan.port, target: plan.target)
                return .success(())
            } catch {
                return .failure(Self.failure(from: error))
            }
        }) { [weak self] result in
            guard let self else { return }
            if case let .failure(failure) = result {
                if case .httpsNotEnabled(_, true) = failure {
                    self.defaults.set(plan.port, forKey: DefaultsKey.port)
                    self.defaults.set(true, forKey: DefaultsKey.cleanupPending)
                    if self.customAddress == nil { self.update(.unavailable(failure.message)) }
                }
                completion(.failure(failure))
                return
            }
            guard let url = TailscaleServe.publicURL(dnsName: dnsName, port: plan.port) else {
                completion(.failure(.commandFailed))
                return
            }
            self.forgetCustomAddress()
            self.forget()
            self.defaults.set(plan.port, forKey: DefaultsKey.port)
            self.update(.on(url))
            completion(.success(url))
        }
    }

    // MARK: - 延迟测量

    /// 菜单要列出的 peer。nil 表示 Tailscale 不配合（没装 / 没登录）。
    func peers(completion: @escaping ([TailscalePeer]?) -> Void) {
        let serve = self.serve
        CommandProbeDispatch.runOffMain(work: {
            serve.peers()
        }, completion: completion)
    }

    /// 测一台设备：先 ping 看链路（直连还是中转、多少毫秒），再 netcheck 拿本机的
    /// DERP 延迟做参照。两个命令都可能失败，报告本身仍会交付，由文案说明原因。
    func sample(peer: TailscalePeer, completion: @escaping (TailscaleLatencyReport) -> Void) {
        let serve = self.serve
        CommandProbeDispatch.runOffMain(work: {
            TailscaleLatencyReport(peer: peer, ping: serve.ping(ipv4: peer.ipv4), netcheck: serve.netcheck())
        }, completion: completion)
    }

    // MARK: - 自定义隧道地址

    /// 记住一个自填的隧道地址，并把它上面的主机名补进允许列表。
    ///
    /// 与自己建隧道的那部分无关：隧道进程、端口映射全在外部工具里，这里只负责
    /// “以后菜单里这个地址能复制、能出二维码、能通过 pi-web 的 Host 校验”。
    /// 需要重启服务时会经过 `applyConfiguration`，因此调用方要先警告会话会断。
    func useCustomAddress(
        _ url: URL,
        host: String,
        configuration: ServiceConfiguration,
        applyConfiguration: @escaping (ServiceConfiguration, @escaping () -> Void) -> Void,
        completion: @escaping (Bool) -> Void
    ) {
        let serve = self.serve
        let recordedPort = activePort
        CommandProbeDispatch.runOffMain(work: {
            // 二选一：先撤掉 serve 那条入口，撤不掉就不记新地址。
            guard let port = recordedPort else { return true }
            return serve.disable(port: port)
        }) { [weak self] cleared in
            guard let self else { return }
            guard cleared else {
                completion(false)
                return
            }
            let store: () -> Void = { [weak self] in
                guard let self else { return }
                self.forget()
                self.defaults.set(url.absoluteString, forKey: DefaultsKey.customURL)
                self.update(.on(url))
                completion(true)
            }
            guard !AllowedHostsEditing.contains(host: host, in: configuration.allowedHosts) else {
                store()
                return
            }
            var updated = configuration
            updated.allowedHosts = AllowedHostsEditing.appending(host: host, to: configuration.allowedHosts)
            applyConfiguration(updated, store)
        }
    }

    // MARK: - 关闭

    /// 撤销成功才清掉记录；失败时保留端口与状态，以便重试或下次启动对账。
    func disable(completion: @escaping (Bool) -> Void) {
        // 同上：用户关了就不再让启动时的重挂结果回头把状态改成「已开启」。
        restoreGeneration &+= 1
        guard let port = activePort else {
            // 自定义地址只是默认里的一行字符串，没有机器配置要撤销；
            // 顺手清掉「下次启动重挂」的标记——用户明确关掉了，就不该再自己开回来。
            forgetCustomAddress()
            forget()
            update(.off)
            completion(true)
            return
        }
        let serve = self.serve
        CommandProbeDispatch.runOffMain(work: {
            serve.disable(port: port)
        }) { [weak self] succeeded in
            guard let self else { return }
            if succeeded {
                self.forget()
                self.forgetCustomAddress()
                self.update(.off)
            }
            completion(succeeded)
        }
    }

    /// 退出时的同步撤销：不留后台任务，`applicationWillTerminate` 返回前做完。
    ///
    /// 失败也不阻止退出，但保留记录供下次启动核对并重试撤销。
    /// 撤销成功则记下端口，让下次启动自动重挂（见 `DefaultsKey.restorePending`）：
    /// 应用不在时不留一条指向 502 的入口，但用户手机上的地址在应用回来后又通了。
    func revokeForQuit() {
        guard let port = activePort else { return }
        guard serve.disable(port: port) else { return }
        forget()
        defaults.set(port, forKey: DefaultsKey.restorePending)
    }

    // MARK: - 内部

    private static func failure(from error: Error) -> Failure {
        guard let error = error as? TailscaleServeError else { return .commandFailed }
        switch error {
        case .notInstalled: return .notInstalled
        case .noFreePort: return .noFreePort
        case let .httpsNotEnabled(url, entryInstalled):
            return .httpsNotEnabled(url: url, entryInstalled: entryInstalled)
        default: return .commandError(error.message)
        }
    }

    private func forget() {
        defaults.removeObject(forKey: DefaultsKey.port)
        defaults.removeObject(forKey: DefaultsKey.cleanupPending)
        defaults.removeObject(forKey: DefaultsKey.restorePending)
    }

    private func forgetCustomAddress() {
        defaults.removeObject(forKey: DefaultsKey.customURL)
    }

    private func update(_ newState: RemoteAccessViewState) {
        state = newState
        onChange?(newState)
    }
}
