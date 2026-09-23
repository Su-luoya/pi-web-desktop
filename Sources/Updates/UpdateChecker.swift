/// Orchestrates update checks: cache, network, policy and notifications.

import Foundation

// MARK: - 检查器

/// 版本检查器（GitHub #17，设置与忽略版本见 GitHub #18）。
///
/// 行为边界：
/// - 只检查：本类型没有任何安装/下载/执行路径，也不读启动前的自动更新设置位
///   （安装与版本验证由 `PiWebUpdateCoordinator` 负责，见 GitHub #20）；
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
            upstreamTag: item.cached?.upstreamTag,
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
        var upstreamTag: String?
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
            upstreamTag: String?,
            confidence: DetectionConfidence,
            freshness: UpdateResultFreshness,
            failure: UpdateCheckFailure?,
            httpStatusCode: Int?,
            origin: UpdateCheckOrigin,
            cacheWrittenAt: Date?,
            keepSuccessFields: Bool
        ) -> (UpdateCacheEntry, UpdateCheckResult) {
            entry.latestVersion = latestVersion
            entry.upstreamTag = upstreamTag
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
                upstreamTag: upstreamTag,
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
                upstreamTag: fallback.upstreamTag,
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
                    upstreamTag: fallback.upstreamTag,
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
                            upstreamTag: fallback.upstreamTag,
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
                        upstreamTag: upstream.tag,
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
                        upstreamTag: fallback.upstreamTag,
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
                        upstreamTag: fallback.upstreamTag,
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
                    upstreamTag: cachedEntry.upstreamTag,
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
                    upstreamTag: fallback.upstreamTag,
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
                upstreamTag: nil,
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
                upstreamTag: entry.upstreamTag,
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
            upstreamTag: entry.upstreamTag,
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
