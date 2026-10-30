import Foundation

/// 远程访问（Tailscale serve）的 App 层编排：把纯决策（`RemoteAccessPlanner`）
/// 落成「写配置 → 等重启 → 调 CLI → 记住端口」这条时序。
///
/// 三条不变量：
/// 1. 端口记在自己名下（`UserDefaults` 的 `remoteAccess.port`），退出时凭它精确撤销
///    这一条，绝不 `reset`（同一台机器上可能还有别人的条目）。
/// 2. CLI 调用全部在后台队列（`CommandProbeDispatch`），主线程只更新状态。
/// 3. 没有访问密码：这台机器的 tailnet 身份就是唯一的边界，因此从不调用 funnel。
final class RemoteAccessController {
    enum DefaultsKey {
        static let port = "remoteAccess.port"
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

    init(runner: CommandRunning, defaults: UserDefaults = .standard) {
        self.serve = TailscaleServe(runner: runner)
        self.defaults = defaults
    }

    /// 记录里那条端口；nil 表示我们没有在用远程访问。
    var activePort: Int? {
        defaults.object(forKey: DefaultsKey.port) as? Int
    }

    // MARK: - 状态

    /// 启动时对账：记录还在、Tailscale 里那条也还在，就恢复成「已开启」；
    /// 否则清掉记录（上次异常退出留下的残迹由这里收尾）。
    func refresh(configuration: ServiceConfiguration) {
        let serve = self.serve
        let recordedPort = activePort
        CommandProbeDispatch.runOffMain(work: {
            (serve.detect(), serve.snapshot())
        }) { [weak self] result in
            let (detection, snapshot) = result
            guard let self else { return }
            guard let port = recordedPort else {
                self.update(.off)
                return
            }
            switch detection {
            case .notInstalled:
                self.update(.unavailable(Failure.notInstalled.message))
            case .notRunning:
                self.update(.unavailable(Failure.notRunning.message))
            case let .ready(dnsName):
                let target = configuration.serviceURL.absoluteString
                guard snapshot.proxy(for: port) == target,
                      let url = TailscaleServe.publicURL(dnsName: dnsName, port: port) else {
                    // 配置变了（监听地址/端口）或那条 serve 已经不在了：记录作废。
                    self.forget()
                    self.update(.off)
                    return
                }
                self.update(.on(url))
            }
        }
    }

    // MARK: - 启用

    /// 启用远程访问。
    ///
    /// - `applyConfiguration` 是「保存配置并等重启走完」的统一入口
    ///   （`applyPreferencesConfiguration`），只在需要把主机名补进允许列表时调用一次；
    ///   它会中断当前会话，因此确认框在调用方、这里只管执行。
    func enable(
        configuration: ServiceConfiguration,
        applyConfiguration: @escaping (ServiceConfiguration, @escaping () -> Void) -> Void,
        completion: @escaping (Result<URL, Failure>) -> Void
    ) {
        let serve = self.serve
        let target = configuration.serviceURL
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
            guard let updatedAllowedHosts = plan.updatedAllowedHosts else {
                install()
                return
            }
            var updated = configuration
            updated.allowedHosts = updatedAllowedHosts
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

    // MARK: - 关闭

    /// 撤销自己那一条。`success` 为 false 表示 CLI 失败了（记录仍会被清掉：
    /// 留着一条指向未知状态的记录比丢失它更糟）。
    func disable(completion: @escaping (Bool) -> Void) {
        guard let port = activePort else {
            update(.off)
            completion(true)
            return
        }
        let serve = self.serve
        CommandProbeDispatch.runOffMain(work: {
            serve.disable(port: port)
        }) { [weak self] succeeded in
            guard let self else { return }
            self.forget()
            self.update(.off)
            completion(succeeded)
        }
    }

    /// 退出时的同步撤销：不留后台任务，`applicationWillTerminate` 返回前做完。
    ///
    /// 失败也不阻止退出（这里只尽力而为），但记录会被清掉，下次启动不会再假装
    /// 远程访问还开着。
    func revokeForQuit() {
        guard let port = activePort else { return }
        serve.disable(port: port)
        forget()
    }

    // MARK: - 内部

    private func forget() {
        defaults.removeObject(forKey: DefaultsKey.port)
    }

    private func update(_ newState: RemoteAccessViewState) {
        state = newState
        onChange?(newState)
    }
}
