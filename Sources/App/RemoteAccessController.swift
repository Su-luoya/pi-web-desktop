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
        /// 用户自填的隧道地址（完整 URL）。它只是“记住这个地址”，没有任何机器配置
        /// 需要撤销，所以退出时不会清掉它。
        static let customURL = "remoteAccess.customURL"
    }

    /// 启用失败的可读原因；`noFreePort` 与命令失败要分开说，否则用户不知道该改什么。
    enum Failure: Error, Equatable {
        case notInstalled
        case notRunning
        case noFreePort
        case commandFailed

        var message: String {
            switch self {
            case .notInstalled:
                return "没有找到 Tailscale 命令行工具。请先安装并登录 Tailscale。"
            case .notRunning:
                return "Tailscale 没有在运行或尚未登录，请登录后再试。"
            case .noFreePort:
                return "443、8444、9443 都已被其他服务占用，无法再挂一条 HTTPS 入口。"
            case .commandFailed:
                return "Tailscale 拒绝了这条命令，请检查 Tailscale 是否正常。"
            }
        }
    }

    private let serve: TailscaleServe
    private let defaults: UserDefaults
    private(set) var state: RemoteAccessViewState = .off
    /// 状态变化（主线程回调）。菜单用它刷新标题与可用性。
    var onChange: ((RemoteAccessViewState) -> Void)?

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
    /// 其余情况一律清掉记录并回到「未开启」：上次异常退出留下的残迹、旧版本把代理
    /// 目标写成 `http://<本机 tailnet 地址>:<端口>` 的情况（tailscaled 代理到自己的
    /// tailnet 地址会一直挂着，那条入口扫码打不开），以及监听地址被改成非回环之后
    /// 目标不再可达的情况。这样的条目先尽力撤销（只动记录里的那个端口，不认别人的
    /// 条目），再忘掉记录，让「启用」重新装一条干净的。
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
        guard let port = recordedPort,
              let target = TailscaleServe.loopbackTarget(port: configuration.port) else {
            update(.off)
            return
        }
        let listensOnLoopback = RemoteAccessPolicy.isLoopbackHostname(configuration.hostname)
        CommandProbeDispatch.runOffMain(work: { () -> RefreshOutcome in
            switch serve.detect() {
            case .notInstalled:
                return .unavailable(Failure.notInstalled.message)
            case .notRunning:
                return .unavailable(Failure.notRunning.message)
            case let .ready(dnsName):
                guard let snapshot = serve.snapshot() else {
                    return .unavailable(Failure.commandFailed.message)
                }
                if snapshot.proxy(for: port) != nil,
                   listensOnLoopback,
                   !snapshot.isOccupied(port, by: target.absoluteString),
                   let url = TailscaleServe.publicURL(dnsName: dnsName, port: port) {
                    return .on(url)
                }
                serve.disable(port: port)
                return .stale
            }
        }) { [weak self] outcome in
            guard let self else { return }
            switch outcome {
            case let .on(url):
                self.update(.on(url))
            case let .unavailable(message):
                self.update(.unavailable(message))
            case .stale:
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
        /// 那条入口不指向回环或已经不在：已尽力撤销，记录作废。
        case stale
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
        let serve = self.serve
        // 代理目标只能是回环（见 `TailscaleServe.loopbackTarget`），监听地址也必须
        // 是回环：服务绑在 tailnet 地址上时旧版本会造出一条扫码打不开的入口。
        guard let target = TailscaleServe.loopbackTarget(port: configuration.port) else {
            completion(.failure(.commandFailed))
            return
        }
        CommandProbeDispatch.runOffMain(work: {
            (serve.detect(), serve.snapshot())
        }) { [weak self] result in
            let (detection, snapshot) = result
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
            guard let snapshot else {
                completion(.failure(.commandFailed))
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
        // 二选一：Tailscale 这条装上后，自定义地址的记录就该让位。
        defaults.removeObject(forKey: DefaultsKey.customURL)
        CommandProbeDispatch.runOffMain(work: {
            do {
                try serve.enable(port: plan.port, target: plan.target)
                return true
            } catch {
                return false
            }
        }) { [weak self] succeeded in
            guard let self else { return }
            guard succeeded, let url = TailscaleServe.publicURL(dnsName: dnsName, port: plan.port) else {
                completion(.failure(.commandFailed))
                return
            }
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
        guard let port = activePort else {
            // 自定义地址只是默认里的一行字符串，没有机器配置要撤销。
            forgetCustomAddress()
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
                self.update(.off)
            }
            completion(succeeded)
        }
    }

    /// 退出时的同步撤销：不留后台任务，`applicationWillTerminate` 返回前做完。
    ///
    /// 失败也不阻止退出，但保留记录供下次启动核对并重试撤销。
    func revokeForQuit() {
        guard let port = activePort else { return }
        if serve.disable(port: port) { forget() }
    }

    // MARK: - 内部

    private func forget() {
        defaults.removeObject(forKey: DefaultsKey.port)
    }

    private func forgetCustomAddress() {
        defaults.removeObject(forKey: DefaultsKey.customURL)
    }

    private func update(_ newState: RemoteAccessViewState) {
        state = newState
        onChange?(newState)
    }
}
