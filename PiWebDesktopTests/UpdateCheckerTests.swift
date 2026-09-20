import XCTest

// GitHub #17 的 unhosted 测试。
//
// 所有副作用都走注入的替身：
// - `RecordingUpdateHTTPClient` 记录每一次请求并返回构造好的响应，测试从不
//   构造 URLSession、从不访问真实网络；
// - `ImmediateUpdateCheckScheduler` 立即执行检查主体与回调，并记录周期计时器
//   的间隔；测试用假时钟推进时间再手动触发计时器，因此没有任何 sleep；
// - `InMemoryUpdateCacheStore` 或临时目录里的文件存储，永不写真实
//   Application Support / UserDefaults（唯一例外是 suiteName 隔离的
//   UserDefaults 开关往返用例，测试结束即删除该 suite）。
//
// 每个用例都断言请求落在白名单主机上、只使用 GET、且不含 cookies /
// Authorization / 会话 / 诊断字段；关闭的分类断言请求次数为 0。

final class UpdateCheckerTests: XCTestCase {

    // MARK: - 固定输入

    private let referenceDate = Date(timeIntervalSince1970: 1_700_000_000)
    private let desktopInstalledVersion = "2.4.0"
    private let piCLIInstalledVersion = "1.2.0"
    private let piWebInstalledVersion = "0.9.0"

    // MARK: - 替身

    private final class FixedClock {
        var now: Date

        init(_ now: Date) {
            self.now = now
        }

        var clock: UpdateClock { UpdateClock { self.now } }
    }

    private final class LogSink {
        private(set) var messages: [String] = []

        func append(_ message: String) {
            messages.append(message)
        }
    }

    private final class RecordingUpdateHTTPClient: UpdateHTTPClient {
        private(set) var requests: [UpdateHTTPRequest] = []
        var responder: ((UpdateHTTPRequest) -> Result<UpdateHTTPResponse, UpdateHTTPFailure>)?
        /// 没有 responder 时依次出队；用完后一律返回 `.transport`。
        var queuedResponses: [Result<UpdateHTTPResponse, UpdateHTTPFailure>] = []

        func perform(
            _ request: UpdateHTTPRequest,
            completion: @escaping (Result<UpdateHTTPResponse, UpdateHTTPFailure>) -> Void
        ) {
            requests.append(request)
            let outcome: Result<UpdateHTTPResponse, UpdateHTTPFailure>
            if let responder {
                outcome = responder(request)
            } else if queuedResponses.isEmpty {
                outcome = .failure(.transport)
            } else {
                outcome = queuedResponses.removeFirst()
            }
            completion(outcome)
        }
    }

    private final class FakeUpdateTimerToken: UpdateTimerToken {
        private(set) var isCancelled = false

        func cancel() {
            isCancelled = true
        }
    }

    private final class ImmediateUpdateCheckScheduler: UpdateCheckScheduling {
        private(set) var timers: [(interval: TimeInterval, token: FakeUpdateTimerToken, work: () -> Void)] = []

        func perform(_ work: @escaping () -> Void) {
            work()
        }

        func deliver(_ work: @escaping () -> Void) {
            work()
        }

        func startRepeating(interval: TimeInterval, _ work: @escaping () -> Void) -> UpdateTimerToken {
            let token = FakeUpdateTimerToken()
            timers.append((interval, token, work))
            return token
        }

        /// 触发全部未取消的计时器（等价于真实时钟到达）。
        func fireTimers() {
            for timer in timers where !timer.token.isCancelled {
                timer.work()
            }
        }

        var activeIntervals: [TimeInterval] {
            timers.filter { !$0.token.isCancelled }.map(\.interval)
        }
    }

    private final class InMemoryUpdateCacheStore: UpdateCacheStoring {
        var file: UpdateCheckCacheFile
        private(set) var saveCount = 0

        init(file: UpdateCheckCacheFile = .empty) {
            self.file = file
        }

        func load() -> UpdateCheckCacheFile {
            file
        }

        func save(_ file: UpdateCheckCacheFile) {
            self.file = file
            saveCount += 1
        }
    }

    private struct World {
        var checker: UpdateChecker
        var client: RecordingUpdateHTTPClient
        var scheduler: ImmediateUpdateCheckScheduler
        var clock: FixedClock
        var store: InMemoryUpdateCacheStore
        var logs: LogSink
        var identity: UpdateCheckIdentity
    }

    // MARK: - 夹具

    private func makeWorld(
        preferences: UpdateCheckPreferences = .factoryDefaults,
        cached: UpdateCheckCacheFile = .empty,
        intervals: UpdateCheckIntervals = .standard,
        ignoredVersions: UpdateIgnoredVersions = .empty,
        responder: ((UpdateHTTPRequest) -> Result<UpdateHTTPResponse, UpdateHTTPFailure>)? = nil
    ) -> World {
        let clock = FixedClock(referenceDate)
        let client = RecordingUpdateHTTPClient()
        client.responder = responder
        let scheduler = ImmediateUpdateCheckScheduler()
        let store = InMemoryUpdateCacheStore(file: cached)
        let logs = LogSink()
        let identity = UpdateCheckIdentity(
            appName: "Pi Web Desktop",
            version: desktopInstalledVersion,
            bundleIdentifier: "io.github.su-luoya.pi-web-desktop"
        )
        let checker = UpdateChecker(
            httpClient: client,
            clock: clock.clock,
            cacheStore: store,
            scheduler: scheduler,
            identity: identity,
            intervals: intervals,
            preferences: preferences,
            ignoredVersions: ignoredVersions,
            log: { logs.append($0) }
        )
        return World(checker: checker, client: client, scheduler: scheduler, clock: clock, store: store, logs: logs, identity: identity)
    }

    private func fullInventory(
        packageName: String = "pi-extension-demo",
        packageVersion: String? = "1.0.0"
    ) -> UpdateCheckInventory {
        UpdateCheckInventory(
            desktopAppVersion: desktopInstalledVersion,
            piCLIVersion: piCLIInstalledVersion,
            piWebVersion: piWebInstalledVersion,
            piPackages: [UpdateCheckPackage(name: packageName, installedVersion: packageVersion)]
        )
    }

    private static func npmHTTPResponse(
        version: String,
        statusCode: Int = 200,
        etag: String? = nil,
        lastModified: String? = nil,
        finalURL: URL? = nil,
        body: String? = nil
    ) -> Result<UpdateHTTPResponse, UpdateHTTPFailure> {
        let text = body ?? "{\"name\":\"demo\",\"version\":\"\(version)\"}"
        var headers: [String: String] = [:]
        if let etag { headers["etag"] = etag }
        if let lastModified { headers["last-modified"] = lastModified }
        return .success(UpdateHTTPResponse(
            statusCode: statusCode,
            headers: headers,
            body: Data(text.utf8),
            finalURL: finalURL
        ))
    }

    private static func githubHTTPResponse(
        tags: [String],
        statusCode: Int = 200,
        etag: String? = nil,
        finalURL: URL? = nil,
        body: String? = nil
    ) -> Result<UpdateHTTPResponse, UpdateHTTPFailure> {
        let defaultBody = "[" + tags.map {
            "{\"tag_name\":\"\($0)\",\"draft\":false,\"prerelease\":false}"
        }.joined(separator: ",") + "]"
        var headers: [String: String] = [:]
        if let etag { headers["etag"] = etag }
        return .success(UpdateHTTPResponse(
            statusCode: statusCode,
            headers: headers,
            body: Data((body ?? defaultBody).utf8),
            finalURL: finalURL
        ))
    }

    private func automaticResponder() -> (UpdateHTTPRequest) -> Result<UpdateHTTPResponse, UpdateHTTPFailure> {
        { request in
            if request.url.host == UpdateCheckUpstream.githubHost {
                return Self.githubHTTPResponse(tags: ["v2.4.1-alpha.2"])
            }
            return Self.npmHTTPResponse(version: "2.0.0")
        }
    }

    private func expectedHost(for category: UpdateCheckCategory) -> String {
        category == .desktopApp ? UpdateCheckUpstream.githubHost : UpdateCheckUpstream.npmRegistryHost
    }

    private func requestMatches(_ request: UpdateHTTPRequest, target: UpdateCheckTarget) -> Bool {
        guard request.url.host == expectedHost(for: target.category) else { return false }
        switch target.category {
        case .desktopApp:
            return true
        case .piCLI:
            return request.url.absoluteString.contains("pi-coding-agent")
        case .piWeb:
            return request.url.absoluteString.contains("%2Fpi-web") || request.url.absoluteString.contains("%2fpi-web")
        case .piPackages:
            guard let packageName = target.packageName else { return false }
            let encoded = UpdateEndpoint.encodedPackageName(packageName) ?? packageName
            return request.url.absoluteString.contains(encoded)
        }
    }

    private func requestCount(_ world: World, category: UpdateCheckCategory, packageName: String? = nil) -> Int {
        let target = UpdateCheckTarget(category: category, packageName: packageName)
        return world.client.requests.filter { requestMatches($0, target: target) }.count
    }

    /// 只按分类判断一次请求（扩展包按夹具包名）；用于“关闭后请求数为 0”类断言。
    private func requestMatchesCategory(_ request: UpdateHTTPRequest, _ category: UpdateCheckCategory) -> Bool {
        switch category {
        case .desktopApp:
            return request.url.host == UpdateCheckUpstream.githubHost
        case .piCLI:
            return request.url.absoluteString.contains("pi-coding-agent")
        case .piWeb:
            return request.url.absoluteString.contains("%2Fpi-web") || request.url.absoluteString.contains("%2fpi-web")
        case .piPackages:
            return request.url.absoluteString.contains("pi-extension-demo")
        }
    }

    private func makeCachedEntry(
        category: UpdateCheckCategory,
        packageName: String? = nil,
        latestVersion: String,
        status: UpdateCheckStatus,
        confidence: DetectionConfidence = .verified,
        installedVersion: String? = nil,
        lastAttemptAt: Date,
        lastSuccessAt: Date?,
        etag: String? = nil,
        lastModified: String? = nil
    ) -> UpdateCacheEntry {
        let target = UpdateCheckTarget(category: category, packageName: packageName)
        return UpdateCacheEntry(
            targetID: target.id,
            category: category.rawValue,
            packageName: packageName,
            lastAttemptAt: lastAttemptAt,
            lastSuccessAt: lastSuccessAt,
            etag: etag,
            lastModified: lastModified,
            latestVersion: latestVersion,
            installedVersion: installedVersion,
            status: status.rawValue,
            confidence: confidence.rawValue
        )
    }

    /// 一条缓存条目的 JSON 片段；`overrides` 用原始 JSON 片段覆盖字段，便于构造
    /// “字段类型错误 / 非法版本 / 未来时间戳 / 目标 id 不一致”等被改写的缓存。
    private func cacheEntryJSON(_ overrides: [String: String] = [:]) -> String {
        var fields: [String: String] = [
            "targetID": "\"desktop-app\"",
            "category": "\"desktop-app\"",
            "latestVersion": "\"0.2.0\"",
            "status": "\"update-available\"",
            "confidence": "\"verified\"",
            "lastAttemptAt": "\"2023-11-14T22:13:20Z\"",
            "lastSuccessAt": "\"2023-11-14T22:13:20Z\""
        ]
        for (key, value) in overrides { fields[key] = value }
        let body = fields.keys.sorted().map { "\"\($0)\":\(fields[$0] ?? "null")" }.joined(separator: ",")
        return "{\(body)}"
    }

    private func cacheFileJSON(
        schemaVersion: Int = UpdateCheckCacheFile.currentSchemaVersion,
        entries: [String]
    ) -> Data {
        Data("{\"schemaVersion\":\(schemaVersion),\"entries\":[\(entries.joined(separator: ","))]}".utf8)
    }

    private func makeTemporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pi-web-desktop-update-check-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func component(
        kind: ComponentKind,
        packageName: String? = nil,
        version: String? = nil
    ) -> ComponentInstallation {
        ComponentInstallation(
            kind: kind,
            packageName: packageName,
            version: version,
            executablePath: nil,
            resolvedPath: nil,
            symlinkChain: [],
            packageJSONPath: nil,
            source: .unknown,
            confidence: .unknown,
            evidence: [],
            suggestedCommand: nil
        )
    }

    // MARK: - 启动与周期复查

    func testStartChecksEveryEnabledCategoryImmediately() {
        let world = makeWorld(responder: automaticResponder())

        world.checker.start(inventory: fullInventory())

        XCTAssertEqual(requestCount(world, category: .desktopApp), 1)
        XCTAssertEqual(requestCount(world, category: .piCLI), 1)
        XCTAssertEqual(requestCount(world, category: .piWeb), 1)
        XCTAssertEqual(requestCount(world, category: .piPackages, packageName: "pi-extension-demo"), 1)
        XCTAssertEqual(world.client.requests.count, 4)
        XCTAssertEqual(world.checker.summary.trigger, .launch)
        XCTAssertEqual(world.checker.summary.results.count, 4)
        // 四类都有上游更新：桌面 2.4.1-alpha.2 > 2.4.0，npm 2.0.0 > 1.2.0 / 0.9.0 / 1.0.0。
        XCTAssertEqual(world.checker.summary.updateAvailableCount, 4)
        XCTAssertEqual(world.checker.summary.unknownCount, 0)
    }

    func testLaunchCheckIgnoresFreshCache() {
        var cached = UpdateCheckCacheFile()
        cached.upsert(makeCachedEntry(
            category: .desktopApp,
            latestVersion: desktopInstalledVersion,
            status: .upToDate,
            lastAttemptAt: referenceDate.addingTimeInterval(-3600),
            lastSuccessAt: referenceDate.addingTimeInterval(-3600)
        ))
        let world = makeWorld(cached: cached, responder: automaticResponder())

        world.checker.start(inventory: fullInventory())

        // “启动后立即检查一次”：即使缓存还新也要发一次条件请求。
        XCTAssertEqual(requestCount(world, category: .desktopApp), 1)
    }

    func testScheduledRechecksFollowCategoryIntervals() {
        let world = makeWorld(responder: automaticResponder())
        world.checker.start(inventory: fullInventory())
        XCTAssertEqual(world.scheduler.activeIntervals.sorted(), [TimeInterval(24 * 3600), TimeInterval(7 * 24 * 3600)])

        // 24 小时：桌面 / Pi / Pi Web 复查，扩展包（7 天）不复查。
        world.clock.now = referenceDate.addingTimeInterval(24 * 3600)
        world.scheduler.fireTimers()
        XCTAssertEqual(requestCount(world, category: .desktopApp), 2)
        XCTAssertEqual(requestCount(world, category: .piCLI), 2)
        XCTAssertEqual(requestCount(world, category: .piWeb), 2)
        XCTAssertEqual(requestCount(world, category: .piPackages, packageName: "pi-extension-demo"), 1)

        // 48 小时：再次复查 24 小时分类。
        world.clock.now = referenceDate.addingTimeInterval(48 * 3600)
        world.scheduler.fireTimers()
        XCTAssertEqual(requestCount(world, category: .desktopApp), 3)
        XCTAssertEqual(requestCount(world, category: .piCLI), 3)
        XCTAssertEqual(requestCount(world, category: .piWeb), 3)
        XCTAssertEqual(requestCount(world, category: .piPackages, packageName: "pi-extension-demo"), 1)

        // 7 天：扩展包第一次复查（24 小时分类同时到期，各再加一次）。
        world.clock.now = referenceDate.addingTimeInterval(7 * 24 * 3600)
        world.scheduler.fireTimers()
        XCTAssertEqual(requestCount(world, category: .desktopApp), 4)
        XCTAssertEqual(requestCount(world, category: .piWeb), 4)
        XCTAssertEqual(requestCount(world, category: .piPackages, packageName: "pi-extension-demo"), 2)
    }

    func testUpdateInventoryChecksComponentsThatWereUnknownAtLaunch() {
        let world = makeWorld(responder: automaticResponder())
        world.checker.start(inventory: UpdateCheckInventory(desktopAppVersion: desktopInstalledVersion))

        XCTAssertEqual(requestCount(world, category: .desktopApp), 1)
        XCTAssertEqual(requestCount(world, category: .piCLI), 0)
        XCTAssertEqual(requestCount(world, category: .piWeb), 0)

        // 依赖检测完成后补齐版本清单：没检查过的对象立即补上，已检查的不重复请求。
        world.checker.updateInventory(fullInventory())
        XCTAssertEqual(requestCount(world, category: .piCLI), 1)
        XCTAssertEqual(requestCount(world, category: .piWeb), 1)
        XCTAssertEqual(requestCount(world, category: .piPackages, packageName: "pi-extension-demo"), 1)
        XCTAssertEqual(requestCount(world, category: .desktopApp), 1)
    }

    func testDisablingCategoryStopsItsRequestsAndRemovesItsTimer() {
        let world = makeWorld(responder: automaticResponder())
        world.checker.start(inventory: fullInventory())
        XCTAssertEqual(world.scheduler.activeIntervals.sorted(), [TimeInterval(24 * 3600), TimeInterval(7 * 24 * 3600)])
        let webRequestsBefore = requestCount(world, category: .piWeb)

        var preferences = world.checker.preferences
        preferences.setPolicy(.off, for: .piWeb)
        preferences.setPolicy(.off, for: .piPackages)
        world.checker.preferences = preferences

        XCTAssertEqual(world.scheduler.activeIntervals, [TimeInterval(24 * 3600)])
        XCTAssertTrue(world.scheduler.timers.filter { $0.token.isCancelled }.count >= 2)

        world.clock.now = referenceDate.addingTimeInterval(3 * 24 * 3600)
        world.scheduler.fireTimers()

        XCTAssertEqual(requestCount(world, category: .piWeb), webRequestsBefore)
        XCTAssertEqual(requestCount(world, category: .piPackages, packageName: "pi-extension-demo"), 1)
        XCTAssertGreaterThan(requestCount(world, category: .desktopApp), 1)
    }

    func testDisabledCategoryFromTheStartIsNeverRequested() {
        var preferences = UpdateCheckPreferences.factoryDefaults
        preferences.setPolicy(.off, for: .piWeb)
        preferences.setPolicy(.off, for: .piPackages)
        let world = makeWorld(preferences: preferences, responder: automaticResponder())

        world.checker.start(inventory: fullInventory())
        world.clock.now = referenceDate.addingTimeInterval(8 * 24 * 3600)
        world.scheduler.fireTimers()
        world.checker.checkNow(triggeredBy: .manual, inventory: fullInventory())
        world.clock.now = referenceDate.addingTimeInterval(8 * 24 * 3600)
        world.scheduler.fireTimers()
        XCTAssertEqual(requestCount(world, category: .piPackages, packageName: "pi-extension-demo"), 0)
        XCTAssertGreaterThan(requestCount(world, category: .desktopApp), 0)
    }

    func testAllCategoriesDisabledMakesNoRequest() {
        let preferences = UpdateCheckPreferences(policies: [
            .desktopApp: .off,
            .piCLI: .off,
            .piWeb: .off,
            .piPackages: .off
        ])
        let world = makeWorld(preferences: preferences, responder: automaticResponder())

        world.checker.start(inventory: fullInventory())
        world.checker.checkNow(triggeredBy: .manual, inventory: fullInventory())

        XCTAssertTrue(world.client.requests.isEmpty)
        XCTAssertTrue(world.checker.summary.allDisabled)
        XCTAssertTrue(world.checker.summary.detailText.contains("关闭"))
        XCTAssertTrue(world.scheduler.timers.isEmpty)
    }

    func testStopCancelsTimersAndBlocksFurtherChecks() {
        let world = makeWorld(responder: automaticResponder())
        world.checker.start(inventory: fullInventory())
        let requestsBeforeStop = world.client.requests.count

        world.checker.stop()

        XCTAssertTrue(world.scheduler.timers.allSatisfy { $0.token.isCancelled })
        world.clock.now = referenceDate.addingTimeInterval(8 * 24 * 3600)
        world.scheduler.fireTimers()
        world.checker.checkNow(triggeredBy: .manual)
        world.checker.checkIfDue(triggeredBy: .scheduled)
        XCTAssertEqual(world.client.requests.count, requestsBeforeStop)
    }

    // MARK: - 失败、限流与降级

    /// 网络失败时，TTL 内的上次成功结果仍可展示“上游版本”，但结论必须按当前
    /// 本机版本现算（GitHub #74）：这条用例的缓存条目就是为当前本机版本写的，
    /// 所以现算结果与缓存里的结论一致。
    func testOfflineFailureReusesFreshCachedResult() {
        var cached = UpdateCheckCacheFile()
        let lastSuccess = referenceDate.addingTimeInterval(-3600)
        cached.upsert(makeCachedEntry(
            category: .desktopApp,
            latestVersion: "9.9.9",
            status: .updateAvailable,
            installedVersion: desktopInstalledVersion,
            lastAttemptAt: lastSuccess,
            lastSuccessAt: lastSuccess,
            etag: "\"v1\""
        ))
        let world = makeWorld(cached: cached, responder: { _ in .failure(.offline) })

        world.checker.checkNow(
            triggeredBy: .manual,
            inventory: UpdateCheckInventory(desktopAppVersion: desktopInstalledVersion)
        )

        let result = world.checker.summary.result(for: UpdateCheckTarget(category: .desktopApp).id)
        XCTAssertEqual(result?.status, .updateAvailable)
        XCTAssertEqual(result?.freshness, .cached)
        XCTAssertEqual(result?.failure, .offline)
        XCTAssertEqual(result?.latestVersion, "9.9.9")
        XCTAssertEqual(result?.confidence, .verified)
        XCTAssertEqual(result?.displayText.contains("网络不可用"), true)
        // 上次成功时间不被失败覆盖，etag 保留供下次条件请求使用。
        let entry = world.store.file.entry(for: UpdateCheckTarget(category: .desktopApp).id)
        XCTAssertEqual(entry?.lastSuccessAt, lastSuccess)
        XCTAssertEqual(entry?.etag, "\"v1\"")
        XCTAssertEqual(entry?.failure, UpdateCheckFailure.offline.rawValue)
        XCTAssertEqual(entry?.latestVersion, "9.9.9")
        XCTAssertEqual(entry?.installedVersion, desktopInstalledVersion)
    }

    func testTimeoutRateLimitAndServerErrorAreUnderstoodWithoutCrash() {
        let cases: [(Result<UpdateHTTPResponse, UpdateHTTPFailure>, UpdateCheckFailure, String)] = [
            (.failure(.timedOut), .timedOut, "请求超时"),
            (Self.npmHTTPResponse(version: "0.2.0", statusCode: 429), .rateLimited, "429"),
            (Self.npmHTTPResponse(version: "0.2.0", statusCode: 503), .serverError, "503")
        ]
        for (response, expectedFailure, expectedText) in cases {
            let world = makeWorld(responder: { _ in response })
            world.checker.checkNow(
                triggeredBy: .manual,
                inventory: UpdateCheckInventory(desktopAppVersion: desktopInstalledVersion)
            )

            let result = world.checker.summary.result(for: UpdateCheckTarget(category: .desktopApp).id)
            XCTAssertEqual(result?.status, .unknown)
            XCTAssertEqual(result?.freshness, UpdateResultFreshness.none)
            XCTAssertEqual(result?.failure, expectedFailure)
            XCTAssertEqual(result?.displayText.contains(expectedText), true)
            XCTAssertNotNil(world.store.file.entry(for: UpdateCheckTarget(category: .desktopApp).id))
        }
    }

    func testStaleCacheBeyondTTLBecomesUnknown() {
        // 桌面 TTL 是 24 小时；上次成功是 25 小时前。扩展包 TTL 是 7 天。
        var cached = UpdateCheckCacheFile()
        cached.upsert(makeCachedEntry(
            category: .desktopApp,
            latestVersion: "0.2.0",
            status: .updateAvailable,
            lastAttemptAt: referenceDate.addingTimeInterval(-25 * 3600),
            lastSuccessAt: referenceDate.addingTimeInterval(-25 * 3600)
        ))
        cached.upsert(makeCachedEntry(
            category: .piPackages,
            packageName: "pi-extension-demo",
            latestVersion: "2.0.0",
            status: .updateAvailable,
            lastAttemptAt: referenceDate.addingTimeInterval(-8 * 24 * 3600),
            lastSuccessAt: referenceDate.addingTimeInterval(-8 * 24 * 3600)
        ))
        let world = makeWorld(cached: cached, responder: { _ in .failure(.offline) })

        world.checker.checkNow(triggeredBy: .manual, inventory: fullInventory())

        let desktop = world.checker.summary.result(for: UpdateCheckTarget(category: .desktopApp).id)
        XCTAssertEqual(desktop?.status, .unknown)
        XCTAssertEqual(desktop?.freshness, .cached)
        XCTAssertEqual(desktop?.latestVersion, "0.2.0")
        XCTAssertEqual(desktop?.confidence, .unknown)

        let package = world.checker.summary.result(
            for: UpdateCheckTarget(category: .piPackages, packageName: "pi-extension-demo").id
        )
        XCTAssertEqual(package?.status, .unknown)
        XCTAssertEqual(package?.freshness, .cached)
    }

    func testFreshCacheWithinTTLIsStillReusableForPackages() {
        var cached = UpdateCheckCacheFile()
        let lastSuccess = referenceDate.addingTimeInterval(-6 * 24 * 3600)
        cached.upsert(makeCachedEntry(
            category: .piPackages,
            packageName: "pi-extension-demo",
            latestVersion: "2.0.0",
            status: .updateAvailable,
            installedVersion: "1.0.0",
            lastAttemptAt: lastSuccess,
            lastSuccessAt: lastSuccess
        ))
        let world = makeWorld(cached: cached, responder: { _ in .failure(.offline) })
        var preferences = UpdateCheckPreferences.factoryDefaults
        preferences.setPolicy(.off, for: .desktopApp)
        preferences.setPolicy(.off, for: .piCLI)
        preferences.setPolicy(.off, for: .piWeb)
        world.checker.preferences = preferences

        world.checker.checkNow(
            triggeredBy: .manual,
            inventory: UpdateCheckInventory(
                piPackages: [UpdateCheckPackage(name: "pi-extension-demo", installedVersion: "1.0.0")]
            )
        )

        let package = world.checker.summary.result(
            for: UpdateCheckTarget(category: .piPackages, packageName: "pi-extension-demo").id
        )
        XCTAssertEqual(package?.status, .updateAvailable)
        XCTAssertEqual(package?.freshness, .cached)
    }

    func testParseFailureIsUnknownAndKeepsPreviousSuccessfulResult() {
        var cached = UpdateCheckCacheFile()
        let lastSuccess = referenceDate.addingTimeInterval(-3600)
        cached.upsert(makeCachedEntry(
            category: .desktopApp,
            latestVersion: "0.2.0",
            status: .updateAvailable,
            lastAttemptAt: lastSuccess,
            lastSuccessAt: lastSuccess,
            etag: "\"v1\""
        ))
        let world = makeWorld(cached: cached, responder: { _ in
            Self.githubHTTPResponse(tags: [], body: "{\"not\":\"a release list\"}")
        })

        world.checker.checkNow(
            triggeredBy: .manual,
            inventory: UpdateCheckInventory(desktopAppVersion: desktopInstalledVersion)
        )

        let result = world.checker.summary.result(for: UpdateCheckTarget(category: .desktopApp).id)
        XCTAssertEqual(result?.status, .unknown)
        XCTAssertEqual(result?.failure, .invalidResponse)
        XCTAssertEqual(result?.freshness, .cached)
        XCTAssertEqual(result?.latestVersion, "0.2.0")
        XCTAssertEqual(result?.confidence, .unknown)
        // 解析失败不得覆盖上次成功结果与条件请求字段。
        let entry = world.store.file.entry(for: UpdateCheckTarget(category: .desktopApp).id)
        XCTAssertEqual(entry?.latestVersion, "0.2.0")
        XCTAssertEqual(entry?.lastSuccessAt, lastSuccess)
        XCTAssertEqual(entry?.etag, "\"v1\"")
    }

    func testMalformedNpmDocumentIsUnknown() {
        let world = makeWorld(responder: { _ in
            Self.npmHTTPResponse(version: "0.2.0", body: "{\"name\":\"demo\"}")
        })

        world.checker.checkNow(
            triggeredBy: .manual,
            inventory: UpdateCheckInventory(desktopAppVersion: desktopInstalledVersion)
        )

        let result = world.checker.summary.result(for: UpdateCheckTarget(category: .desktopApp).id)
        XCTAssertEqual(result?.status, .unknown)
        XCTAssertEqual(result?.failure, .invalidResponse)
    }

    func testUnparsableUpstreamVersionIsUnknown() {
        var cached = UpdateCheckCacheFile()
        let lastSuccess = referenceDate.addingTimeInterval(-3600)
        cached.upsert(makeCachedEntry(
            category: .desktopApp,
            latestVersion: "0.2.0",
            status: .upToDate,
            lastAttemptAt: lastSuccess,
            lastSuccessAt: lastSuccess
        ))
        let world = makeWorld(cached: cached, responder: { _ in
            Self.npmHTTPResponse(version: "0.2.0", body: "{\"name\":\"demo\",\"version\":\"not-a-version\"}")
        })

        world.checker.checkNow(
            triggeredBy: .manual,
            inventory: UpdateCheckInventory(desktopAppVersion: desktopInstalledVersion)
        )

        let result = world.checker.summary.result(for: UpdateCheckTarget(category: .desktopApp).id)
        XCTAssertEqual(result?.status, .unknown)
        XCTAssertEqual(result?.failure, .invalidResponse)
    }

    func testUnexpectedResponseHostIsUnknown() {
        var cached = UpdateCheckCacheFile()
        let lastSuccess = referenceDate.addingTimeInterval(-3600)
        cached.upsert(makeCachedEntry(
            category: .desktopApp,
            latestVersion: "0.2.0",
            status: .updateAvailable,
            lastAttemptAt: lastSuccess,
            lastSuccessAt: lastSuccess
        ))
        let world = makeWorld(cached: cached, responder: { _ in
            Self.githubHTTPResponse(
                tags: ["v9.9.9"],
                finalURL: URL(string: "https://unexpected.example/releases")
            )
        })

        world.checker.checkNow(
            triggeredBy: .manual,
            inventory: UpdateCheckInventory(desktopAppVersion: desktopInstalledVersion)
        )

        let result = world.checker.summary.result(for: UpdateCheckTarget(category: .desktopApp).id)
        XCTAssertEqual(result?.status, .unknown)
        XCTAssertEqual(result?.failure, .unexpectedHost)
        XCTAssertEqual(result?.latestVersion, "0.2.0")
        XCTAssertEqual(result?.confidence, .unknown)
    }

    func testRedirectStatusIsUnknown() {
        let world = makeWorld(responder: { _ in
            Self.githubHTTPResponse(tags: ["v9.9.9"], statusCode: 301)
        })

        world.checker.checkNow(
            triggeredBy: .manual,
            inventory: UpdateCheckInventory(desktopAppVersion: desktopInstalledVersion)
        )

        let result = world.checker.summary.result(for: UpdateCheckTarget(category: .desktopApp).id)
        XCTAssertEqual(result?.status, .unknown)
        XCTAssertEqual(result?.failure, .unexpectedRedirect)
        XCTAssertEqual(result?.displayText.contains("301"), true)
    }

    /// 304 是成功的网络往返（freshness 仍为 .fresh），但版本值来自缓存文件，
    /// 因此 origin 是缓存回退，只用于提示（GitHub #59）。
    func testNotModifiedKeepsFreshnessButMarksCacheOrigin() {
        var cached = UpdateCheckCacheFile()
        let lastSuccess = referenceDate.addingTimeInterval(-30 * 3600)
        cached.upsert(makeCachedEntry(
            category: .desktopApp,
            latestVersion: desktopInstalledVersion,
            status: .upToDate,
            installedVersion: desktopInstalledVersion,
            lastAttemptAt: lastSuccess,
            lastSuccessAt: lastSuccess,
            etag: "\"v1\""
        ))
        let world = makeWorld(cached: cached, responder: { _ in
            Self.githubHTTPResponse(tags: [], statusCode: 304, etag: "\"v1\"")
        })

        world.checker.checkNow(
            triggeredBy: .manual,
            inventory: UpdateCheckInventory(desktopAppVersion: desktopInstalledVersion)
        )

        let result = world.checker.summary.result(for: UpdateCheckTarget(category: .desktopApp).id)
        XCTAssertEqual(result?.status, .upToDate)
        XCTAssertEqual(result?.freshness, .fresh)
        XCTAssertEqual(result?.confidence, .verified)
        XCTAssertNil(result?.failure)
        XCTAssertEqual(result?.latestVersion, desktopInstalledVersion)
        XCTAssertEqual(result?.origin, .cachedFallback)
        XCTAssertEqual(result?.cacheWrittenAt, lastSuccess)
        XCTAssertFalse(result?.origin.isEligibleForAutomaticInstall ?? true)
        let entry = world.store.file.entry(for: UpdateCheckTarget(category: .desktopApp).id)
        XCTAssertEqual(entry?.lastSuccessAt, referenceDate)
        XCTAssertEqual(entry?.etag, "\"v1\"")
    }

    func testInstalledVersionUnknownSkipsRequest() {
        let world = makeWorld(responder: automaticResponder())
        let inventory = UpdateCheckInventory(
            desktopAppVersion: desktopInstalledVersion,
            piCLIVersion: nil,
            piWebVersion: nil,
            piPackages: []
        )

        world.checker.start(inventory: inventory)

        XCTAssertEqual(requestCount(world, category: .piCLI), 0)
        XCTAssertEqual(requestCount(world, category: .piWeb), 0)
        XCTAssertEqual(requestCount(world, category: .desktopApp), 1)
        let result = world.checker.summary.result(for: UpdateCheckTarget(category: .piCLI).id)
        XCTAssertEqual(result?.status, .unknown)
        XCTAssertEqual(result?.failure, .installedVersionUnknown)
        XCTAssertEqual(result?.freshness, UpdateResultFreshness.none)
    }

    func testInvalidPackageNameSkipsRequest() {
        let inventory = UpdateCheckInventory(
            desktopAppVersion: desktopInstalledVersion,
            piCLIVersion: piCLIInstalledVersion,
            piWebVersion: piWebInstalledVersion,
            piPackages: [
                UpdateCheckPackage(name: "bad name!", installedVersion: "1.0.0"),
                UpdateCheckPackage(name: "good-pkg", installedVersion: "1.0.0")
            ]
        )
        let world = makeWorld(responder: automaticResponder())

        world.checker.start(inventory: inventory)

        XCTAssertEqual(world.client.requests.filter { $0.url.absoluteString.contains("bad") }.count, 0)
        XCTAssertEqual(requestCount(world, category: .piPackages, packageName: "good-pkg"), 1)
        let result = world.checker.summary.result(
            for: UpdateCheckTarget(category: .piPackages, packageName: "bad name!").id
        )
        XCTAssertEqual(result?.status, .unknown)
        XCTAssertEqual(result?.failure, .invalidPackageName)
    }

    func testPackageWithoutVersionIsUnknownWithoutRequest() {
        let inventory = UpdateCheckInventory(
            desktopAppVersion: desktopInstalledVersion,
            piCLIVersion: piCLIInstalledVersion,
            piWebVersion: piWebInstalledVersion,
            piPackages: [UpdateCheckPackage(name: "no-version-pkg", installedVersion: nil)]
        )
        let world = makeWorld(responder: automaticResponder())

        world.checker.start(inventory: inventory)

        XCTAssertEqual(requestCount(world, category: .piPackages, packageName: "no-version-pkg"), 0)
        let result = world.checker.summary.result(
            for: UpdateCheckTarget(category: .piPackages, packageName: "no-version-pkg").id
        )
        XCTAssertEqual(result?.status, .unknown)
        XCTAssertEqual(result?.failure, .installedVersionUnknown)
    }

    func testScopedPackageNameIsPercentEncoded() {
        let inventory = UpdateCheckInventory(
            desktopAppVersion: desktopInstalledVersion,
            piCLIVersion: piCLIInstalledVersion,
            piWebVersion: piWebInstalledVersion,
            piPackages: [UpdateCheckPackage(name: "@demo/scoped-pkg", installedVersion: "1.0.0")]
        )
        let world = makeWorld(responder: automaticResponder())

        world.checker.start(inventory: inventory)

        let request = world.client.requests.first { $0.url.absoluteString.contains("scoped-pkg") }
        XCTAssertNotNil(request)
        XCTAssertEqual(request?.url.absoluteString, "https://registry.npmjs.org/@demo%2Fscoped-pkg/latest")
    }

    // MARK: - 结果来源（GitHub #59 / alpha.3 安全审查 A-1）

    /// 本次网络结果：origin = network，没有缓存写入时间与缓存标注。
    func testFreshNetworkResultsAreMarkedAsNetworkOrigin() {
        let world = makeWorld(responder: automaticResponder())

        world.checker.start(inventory: fullInventory())

        XCTAssertEqual(world.checker.summary.results.count, 4)
        for result in world.checker.summary.results {
            XCTAssertEqual(result.origin, .network)
            XCTAssertEqual(result.freshness, .fresh)
            XCTAssertNil(result.cacheWrittenAt)
            XCTAssertNil(result.cacheOriginAnnotation)
            XCTAssertTrue(result.origin.isEligibleForAutomaticInstall)
        }
    }

    /// 网络失败沿用缓存结论：origin = cachedFallback，带缓存写入时间；提示文本
    /// 标注“缓存”与时间，且不含“已验证/官方”之类误导措辞。
    func testOfflineFallbackIsMarkedAsCacheOriginWithWriteTime() {
        var cached = UpdateCheckCacheFile()
        let lastSuccess = referenceDate.addingTimeInterval(-3600)
        cached.upsert(makeCachedEntry(
            category: .desktopApp,
            latestVersion: "9.9.9",
            status: .updateAvailable,
            installedVersion: desktopInstalledVersion,
            lastAttemptAt: lastSuccess,
            lastSuccessAt: lastSuccess
        ))
        let world = makeWorld(cached: cached, responder: { _ in .failure(.offline) })

        world.checker.checkNow(
            triggeredBy: .manual,
            inventory: UpdateCheckInventory(desktopAppVersion: desktopInstalledVersion)
        )

        let result = world.checker.summary.result(for: UpdateCheckTarget(category: .desktopApp).id)
        XCTAssertEqual(result?.status, .updateAvailable)
        XCTAssertEqual(result?.freshness, .cached)
        XCTAssertEqual(result?.origin, .cachedFallback)
        XCTAssertEqual(result?.cacheWrittenAt, lastSuccess)
        XCTAssertFalse(result?.origin.isEligibleForAutomaticInstall ?? true)
        let text = result?.displayText ?? ""
        XCTAssertTrue(text.contains("缓存"))
        XCTAssertTrue(text.contains(UpdateCheckTimestamp.text(lastSuccess)))
        XCTAssertFalse(text.contains("已验证"))
        XCTAssertFalse(text.contains("官方"))
        XCTAssertEqual(result?.cacheOriginAnnotation?.contains("只用于提示"), true)
    }

    /// 没有缓存可用时（失败、缓存被丢弃）结论是 unavailable：连提示版本都没有。
    func testFailureWithoutCacheIsMarkedAsUnavailableOrigin() {
        let world = makeWorld(responder: { _ in .failure(.offline) })

        world.checker.checkNow(
            triggeredBy: .manual,
            inventory: UpdateCheckInventory(desktopAppVersion: desktopInstalledVersion)
        )

        let result = world.checker.summary.result(for: UpdateCheckTarget(category: .desktopApp).id)
        XCTAssertEqual(result?.status, .unknown)
        XCTAssertEqual(result?.freshness, UpdateResultFreshness.none)
        XCTAssertEqual(result?.origin, .unavailable)
        XCTAssertNil(result?.latestVersion)
        XCTAssertNil(result?.cacheWrittenAt)
        XCTAssertNil(result?.cacheOriginAnnotation)
        XCTAssertFalse(result?.origin.isEligibleForAutomaticInstall ?? true)
    }

    /// 本机版本未知而不发请求（skip）：有缓存版本时标为缓存回退，无缓存时不可用。
    func testSkippedChecksCarryCacheOriginOnlyWhenACachedVersionExists() {
        var cached = UpdateCheckCacheFile()
        let lastSuccess = referenceDate.addingTimeInterval(-3600)
        cached.upsert(makeCachedEntry(
            category: .piCLI,
            latestVersion: "1.9.0",
            status: .updateAvailable,
            lastAttemptAt: lastSuccess,
            lastSuccessAt: lastSuccess
        ))
        let withCache = makeWorld(cached: cached, responder: automaticResponder())
        withCache.checker.checkNow(
            triggeredBy: .manual,
            inventory: UpdateCheckInventory(desktopAppVersion: desktopInstalledVersion, piWebVersion: piWebInstalledVersion)
        )
        let piCLI = withCache.checker.summary.result(for: UpdateCheckTarget(category: .piCLI).id)
        XCTAssertEqual(piCLI?.failure, .installedVersionUnknown)
        XCTAssertEqual(piCLI?.origin, .cachedFallback)
        XCTAssertEqual(piCLI?.cacheWrittenAt, lastSuccess)
        XCTAssertEqual(piCLI?.latestVersion, "1.9.0")

        let withoutCache = makeWorld(responder: automaticResponder())
        withoutCache.checker.checkNow(
            triggeredBy: .manual,
            inventory: UpdateCheckInventory(desktopAppVersion: desktopInstalledVersion, piWebVersion: piWebInstalledVersion)
        )
        let skipped = withoutCache.checker.summary.result(for: UpdateCheckTarget(category: .piCLI).id)
        XCTAssertEqual(skipped?.failure, .installedVersionUnknown)
        XCTAssertEqual(skipped?.origin, .unavailable)
        XCTAssertEqual(requestCount(withoutCache, category: .piCLI), 0)
    }

    // MARK: - 缓存回退结论按当前本机版本现算（GitHub #74）

    /// 方向一：缓存写于本机 3.0.0（当时上游 2.0.0 → up-to-date），本机降到
    /// 1.0.0 后网络失败。缓存里的旧结论不得沿用，必须现算出“可更新 2.0.0”。
    func testCachedUpToDateIsRecomputedForADowngradedLocalVersion() {
        var cached = UpdateCheckCacheFile()
        let lastSuccess = referenceDate.addingTimeInterval(-3600)
        cached.upsert(makeCachedEntry(
            category: .piWeb,
            latestVersion: "2.0.0",
            status: .upToDate,
            installedVersion: "3.0.0",
            lastAttemptAt: lastSuccess,
            lastSuccessAt: lastSuccess
        ))
        let world = makeWorld(cached: cached, responder: { _ in .failure(.offline) })

        world.checker.checkNow(
            triggeredBy: .manual,
            inventory: UpdateCheckInventory(piWebVersion: "1.0.0")
        )

        let result = world.checker.summary.result(for: UpdateCheckTarget(category: .piWeb).id)
        XCTAssertEqual(result?.status, .updateAvailable)
        XCTAssertEqual(result?.latestVersion, "2.0.0")
        XCTAssertEqual(result?.installedVersion, "1.0.0")
        XCTAssertEqual(result?.failure, .offline)
        XCTAssertFalse(result?.displayText.contains("已是最新") ?? true)
        XCTAssertTrue(result?.displayText.contains("上游有新版本 2.0.0") ?? false)
        // 结论可以提示，但来源仍是缓存回退，不参与自动安装。
        XCTAssertEqual(result?.origin, .cachedFallback)
        XCTAssertFalse(result?.origin.isEligibleForAutomaticInstall ?? true)
        XCTAssertEqual(world.checker.summary.updateAvailableCount, 1)
        XCTAssertEqual(
            UpdateNotificationPlanner.plan(
                results: world.checker.summary.results,
                preferences: world.checker.preferences,
                ignoredVersions: .empty,
                alreadyNotified: [:]
            ).map(\.latestVersion),
            ["2.0.0"]
        )

        // 同一条目即使写下的本机版本就是当前版本、存储的 status 仍是与版本对
        // 不上的 up-to-date（被改写/旧结论），也只能按现算结果展示。
        var contradictory = UpdateCheckCacheFile()
        contradictory.upsert(makeCachedEntry(
            category: .piWeb,
            latestVersion: "2.0.0",
            status: .upToDate,
            installedVersion: "1.0.0",
            lastAttemptAt: lastSuccess,
            lastSuccessAt: lastSuccess
        ))
        let second = makeWorld(cached: contradictory, responder: { _ in .failure(.offline) })
        second.checker.checkNow(
            triggeredBy: .manual,
            inventory: UpdateCheckInventory(piWebVersion: "1.0.0")
        )
        let secondResult = second.checker.summary.result(for: UpdateCheckTarget(category: .piWeb).id)
        XCTAssertEqual(secondResult?.status, .updateAvailable)
        XCTAssertFalse(secondResult?.displayText.contains("已是最新") ?? true)
        XCTAssertEqual(secondResult?.confidence, .verified)
    }

    /// 方向二：缓存写于本机 1.0.0（当时上游 2.0.0 → update-available），本机
    /// 升到 2.0.0 后网络失败。不得沿用旧结论进入通知名单或菜单计数。
    func testCachedUpdateAvailableIsRecomputedForAnUpgradedLocalVersion() {
        var cached = UpdateCheckCacheFile()
        let lastSuccess = referenceDate.addingTimeInterval(-3600)
        cached.upsert(makeCachedEntry(
            category: .piWeb,
            latestVersion: "2.0.0",
            status: .updateAvailable,
            installedVersion: "1.0.0",
            lastAttemptAt: lastSuccess,
            lastSuccessAt: lastSuccess
        ))
        let world = makeWorld(cached: cached, responder: { _ in .failure(.offline) })

        world.checker.checkNow(
            triggeredBy: .manual,
            inventory: UpdateCheckInventory(piWebVersion: "2.0.0")
        )

        let result = world.checker.summary.result(for: UpdateCheckTarget(category: .piWeb).id)
        XCTAssertEqual(result?.status, .upToDate)
        XCTAssertEqual(result?.latestVersion, "2.0.0")
        XCTAssertEqual(result?.installedVersion, "2.0.0")
        XCTAssertEqual(result?.failure, .offline)
        XCTAssertFalse(result?.displayText.contains("上游有新版本") ?? true)
        XCTAssertEqual(world.checker.summary.updateAvailableCount, 0)
        XCTAssertTrue(
            UpdateNotificationPlanner.plan(
                results: world.checker.summary.results,
                preferences: world.checker.preferences,
                ignoredVersions: .empty,
                alreadyNotified: [:]
            ).isEmpty
        )
        XCTAssertEqual(
            world.checker.summary.categoryStatuses.first { $0.category == .piWeb }?.status,
            .upToDate
        )
    }

    /// 304 命中的缓存条目也按当前本机版本现算（本机 1.0.0 / 缓存上游 2.0.0
    /// → 可更新）：这就是缓存回退要走的同一条比较路径。
    func testNotModifiedRecomputesTheStatusForTheCurrentInstalledVersion() {
        var cached = UpdateCheckCacheFile()
        let lastSuccess = referenceDate.addingTimeInterval(-3600)
        cached.upsert(makeCachedEntry(
            category: .piWeb,
            latestVersion: "2.0.0",
            status: .upToDate,
            installedVersion: "3.0.0",
            lastAttemptAt: lastSuccess,
            lastSuccessAt: lastSuccess,
            etag: "\"v1\""
        ))
        let world = makeWorld(cached: cached, responder: { _ in
            .success(UpdateHTTPResponse(statusCode: 304, headers: ["etag": "\"v1\""], body: Data(), finalURL: nil))
        })

        world.checker.checkNow(
            triggeredBy: .manual,
            inventory: UpdateCheckInventory(piWebVersion: "1.0.0")
        )

        let result = world.checker.summary.result(for: UpdateCheckTarget(category: .piWeb).id)
        XCTAssertEqual(result?.status, .updateAvailable)
        XCTAssertEqual(result?.origin, .cachedFallback)
        XCTAssertEqual(result?.freshness, .fresh)
        XCTAssertFalse(result?.displayText.contains("已是最新") ?? true)
    }

    /// 缓存条目缺 `installedVersion`（旧 schema 或手工改写）时结论不可判定：
    /// 即便现算看起来像“可更新”，也不把未绑定的结论当成事实。
    func testCacheEntryWithoutRecordedInstalledVersionIsUndecidable() {
        var cached = UpdateCheckCacheFile()
        let lastSuccess = referenceDate.addingTimeInterval(-3600)
        cached.upsert(makeCachedEntry(
            category: .piWeb,
            latestVersion: "2.0.0",
            status: .upToDate,
            lastAttemptAt: lastSuccess,
            lastSuccessAt: lastSuccess
        ))
        let world = makeWorld(cached: cached, responder: { _ in .failure(.offline) })

        world.checker.checkNow(
            triggeredBy: .manual,
            inventory: UpdateCheckInventory(piWebVersion: "1.0.0")
        )

        let result = world.checker.summary.result(for: UpdateCheckTarget(category: .piWeb).id)
        XCTAssertEqual(result?.status, .unknown)
        XCTAssertEqual(result?.latestVersion, "2.0.0")
        XCTAssertEqual(result?.freshness, .cached)
        XCTAssertFalse(result?.displayText.contains("已是最新") ?? true)
        XCTAssertFalse(result?.displayText.contains("上游有新版本") ?? true)
        XCTAssertEqual(world.checker.summary.updateAvailableCount, 0)
    }

    /// 本机版本不可解析 + 缓存存在：结论 `.unknown`，绝不沿用缓存里的旧结论；
    /// 记录的本机版本与当前一致或不一致都一样。
    func testUnparsableInstalledVersionWithCacheIsUnknown() {
        for recorded in [nil, "1.0.0", "dev-build"] {
            var cached = UpdateCheckCacheFile()
            let lastSuccess = referenceDate.addingTimeInterval(-3600)
            cached.upsert(makeCachedEntry(
                category: .piWeb,
                latestVersion: "2.0.0",
                status: .upToDate,
                installedVersion: recorded,
                lastAttemptAt: lastSuccess,
                lastSuccessAt: lastSuccess
            ))
            let world = makeWorld(cached: cached, responder: { _ in .failure(.offline) })

            world.checker.checkNow(
                triggeredBy: .manual,
                inventory: UpdateCheckInventory(piWebVersion: "dev-build")
            )

            let result = world.checker.summary.result(for: UpdateCheckTarget(category: .piWeb).id)
            XCTAssertEqual(result?.status, .unknown, "recorded=\(recorded ?? "nil")")
            XCTAssertFalse(result?.displayText.contains("已是最新") ?? true)
            XCTAssertFalse(result?.displayText.contains("上游有新版本") ?? true)
        }
    }

    /// 旧 schema（1）整文件缓存：读取不崩溃、不当作损坏丢弃，但条目缺少
    /// `installedVersion`，结论一律不可判定；写回时升级到当前 schema。
    func testLegacySchemaCacheWithoutInstalledVersionIsDowngradedToUnknown() throws {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("update-check-cache.json")
        try cacheFileJSON(schemaVersion: UpdateCheckCacheFile.legacySchemaVersion, entries: [
            cacheEntryJSON([
                "targetID": "\"pi-web\"",
                "category": "\"pi-web\"",
                "latestVersion": "\"2.0.0\""
            ])
        ]).write(to: fileURL)

        let clock = FixedClock(referenceDate)
        let client = RecordingUpdateHTTPClient()
        client.responder = { _ in .failure(.offline) }
        let store = UpdateCheckCacheFileStore(fileURL: fileURL, clock: clock.clock)
        let logs = LogSink()
        let checker = UpdateChecker(
            httpClient: client,
            clock: clock.clock,
            cacheStore: store,
            scheduler: ImmediateUpdateCheckScheduler(),
            identity: UpdateCheckIdentity(appName: "Pi Web Desktop", version: desktopInstalledVersion, bundleIdentifier: nil),
            intervals: .standard,
            preferences: .factoryDefaults,
            log: { logs.append($0) }
        )

        checker.checkNow(triggeredBy: .manual, inventory: UpdateCheckInventory(piWebVersion: "1.0.0"))

        let result = checker.summary.result(for: UpdateCheckTarget(category: .piWeb).id)
        XCTAssertEqual(result?.status, .unknown)
        XCTAssertEqual(result?.latestVersion, "2.0.0")
        XCTAssertEqual(result?.freshness, .cached)
        XCTAssertEqual(result?.origin, .cachedFallback)
        XCTAssertFalse(result?.origin.isEligibleForAutomaticInstall ?? true)
        XCTAssertTrue(UpdateNotificationPlanner.plan(
            results: checker.summary.results,
            preferences: checker.preferences,
            ignoredVersions: .empty,
            alreadyNotified: [:]
        ).isEmpty)

        // 旧文件被兼容读取（不当作损坏、不写拒绝日志），写回时升级 schema
        // 并记录本机版本。
        XCTAssertNil(store.lastLoadRejection)
        XCTAssertFalse(logs.messages.contains { $0.contains("缓存已丢弃") })
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let saved = try decoder.decode(UpdateCheckCacheFile.self, from: Data(contentsOf: fileURL))
        XCTAssertEqual(saved.schemaVersion, UpdateCheckCacheFile.currentSchemaVersion)
        XCTAssertEqual(
            saved.entry(for: UpdateCheckTarget(category: .piWeb).id)?.installedVersion,
            "1.0.0"
        )
    }

    // MARK: - 版本比较

    func testUpdateAvailableUsesSemanticComparisonIncludingPrereleases() {
        let world = makeWorld(responder: { request in
            if request.url.host == UpdateCheckUpstream.githubHost {
                return Self.githubHTTPResponse(tags: ["v2.4.1-alpha.2"])
            }
            return Self.npmHTTPResponse(version: "2.4.1-alpha.2")
        })

        world.checker.checkNow(triggeredBy: .manual, inventory: fullInventory())

        let desktop = world.checker.summary.result(for: UpdateCheckTarget(category: .desktopApp).id)
        XCTAssertEqual(desktop?.status, .updateAvailable)
        XCTAssertEqual(desktop?.latestVersion, "2.4.1-alpha.2")
        XCTAssertEqual(desktop?.confidence, .verified)
        XCTAssertEqual(desktop?.freshness, .fresh)
    }

    func testStableInstalledVersionIsNotDowngradedByPrerelease() {
        let world = makeWorld(responder: { request in
            if request.url.host == UpdateCheckUpstream.githubHost {
                return Self.githubHTTPResponse(tags: ["v2.4.0-alpha.9"])
            }
            return Self.npmHTTPResponse(version: "0.9.0")
        })
        let inventory = UpdateCheckInventory(desktopAppVersion: "2.4.0")

        world.checker.checkNow(triggeredBy: .manual, inventory: inventory)

        let desktop = world.checker.summary.result(for: UpdateCheckTarget(category: .desktopApp).id)
        XCTAssertEqual(desktop?.status, .upToDate)
        XCTAssertEqual(desktop?.latestVersion, "2.4.0-alpha.9")
    }

    func testGitHubParserPicksHighestVersionAndIgnoresDrafts() {
        let body = """
        [
          {"tag_name":"v2.4.1-alpha.2","draft":false,"prerelease":true},
          {"tag_name":"v2.4.1-alpha.10","draft":false,"prerelease":true},
          {"tag_name":"v9.9.9","draft":true,"prerelease":false}
        ]
        """
        let world = makeWorld(responder: { _ in
            Self.githubHTTPResponse(tags: [], body: body)
        })

        world.checker.checkNow(triggeredBy: .manual, inventory: fullInventory())

        let desktop = world.checker.summary.result(for: UpdateCheckTarget(category: .desktopApp).id)
        XCTAssertEqual(desktop?.latestVersion, "2.4.1-alpha.10")
        XCTAssertEqual(desktop?.status, .updateAvailable)
    }

    func testSemanticVersionPrereleaseOrdering() {
        XCTAssertLessThan(SemanticVersion("1.0.0-alpha.1")!, SemanticVersion("1.0.0-alpha.2")!)
        XCTAssertLessThan(SemanticVersion("1.0.0-alpha.2")!, SemanticVersion("1.0.0-alpha.10")!)
        XCTAssertLessThan(SemanticVersion("1.0.0-alpha.10")!, SemanticVersion("1.0.0-beta.1")!)
        XCTAssertLessThan(SemanticVersion("1.0.0-alpha.1")!, SemanticVersion("1.0.0-alpha.1.1")!)
        XCTAssertLessThan(SemanticVersion("1.0.0-1")!, SemanticVersion("1.0.0-alpha")!)
        XCTAssertLessThan(SemanticVersion("2.4.0-alpha.2")!, SemanticVersion("2.4.0")!)
        XCTAssertEqual(SemanticVersion("v2.4.1-alpha.2"), SemanticVersion("2.4.1-alpha.2"))
        XCTAssertFalse(SemanticVersion("1.0.0-alpha.2")! < SemanticVersion("1.0.0-alpha.2")!)
    }

    func testInventoryMapsComponentsAndDropsUnnamedPackages() {
        let inventory = UpdateCheckInventory(components: [
            component(kind: .desktopApp, version: "2.4.0"),
            component(kind: .piCLI, packageName: "@earendil-works/pi-coding-agent", version: "1.2.3"),
            component(kind: .piPackage, packageName: "@scope/a", version: "1.0.0"),
            component(kind: .piPackage, packageName: "@scope/a", version: "1.0.0"),
            component(kind: .piPackage, version: "9.9.9"),
            component(kind: .piPackage, packageName: "b", version: nil)
        ])

        XCTAssertEqual(inventory.desktopAppVersion, "2.4.0")
        XCTAssertEqual(inventory.piCLIVersion, "1.2.3")
        XCTAssertNil(inventory.piWebVersion)
        XCTAssertEqual(inventory.piPackages, [
            UpdateCheckPackage(name: "@scope/a", installedVersion: "1.0.0"),
            UpdateCheckPackage(name: "b", installedVersion: nil)
        ])
    }

    // MARK: - 请求卫生（不发送 cookies / 凭据 / 会话 / 诊断字段）

    func testRequestsUseGetWhitelistedHostsAndConditionalHeadersOnly() {
        var cached = UpdateCheckCacheFile()
        let lastSuccess = referenceDate.addingTimeInterval(-3600)
        for category in [UpdateCheckCategory.desktopApp, .piCLI] {
            cached.upsert(makeCachedEntry(
                category: category,
                latestVersion: desktopInstalledVersion,
                status: .upToDate,
                lastAttemptAt: lastSuccess,
                lastSuccessAt: lastSuccess,
                etag: "\"v1\"",
                lastModified: "Mon, 01 Jan 2024 00:00:00 GMT"
            ))
        }
        let world = makeWorld(cached: cached, responder: automaticResponder())

        world.checker.start(inventory: fullInventory())

        XCTAssertFalse(world.client.requests.isEmpty)
        let allowedHosts: Set<String> = [UpdateCheckUpstream.githubHost, UpdateCheckUpstream.npmRegistryHost]
        let forbiddenHeaderNames = ["cookie", "authorization", "session", "diagnostic", "token", "password", "secret"]
        for request in world.client.requests {
            XCTAssertEqual(request.method, "GET")
            XCTAssertEqual(request.url.scheme, "https")
            XCTAssertTrue(allowedHosts.contains(request.url.host ?? ""))
            for name in request.headers.keys {
                let lowered = name.lowercased()
                XCTAssertTrue(
                    UpdateHTTPRequest.allowedHeaderNames.contains(lowered),
                    "请求头 \(name) 不在白名单内"
                )
                for forbidden in forbiddenHeaderNames {
                    XCTAssertFalse(lowered.contains(forbidden), "请求头 \(name) 命中禁用字段 \(forbidden)")
                }
            }
            XCTAssertEqual(request.headers["User-Agent"], world.identity.userAgent)
            XCTAssertEqual(request.headers["Accept"], "application/json")
        }
        // 条件请求字段来自缓存。
        let desktopRequest = world.client.requests.first { $0.url.host == UpdateCheckUpstream.githubHost }
        XCTAssertEqual(desktopRequest?.headers["If-None-Match"], "\"v1\"")
        XCTAssertEqual(desktopRequest?.headers["If-Modified-Since"], "Mon, 01 Jan 2024 00:00:00 GMT")
        XCTAssertFalse(world.client.requests.contains { $0.url.query?.contains("password") == true })
    }

    func testSanitizedRequestDropsForbiddenHeadersAndForcesGet() {
        var request = UpdateHTTPRequest(
            url: URL(string: "https://api.github.com/repos/a/b/releases")!,
            headers: [
                "Cookie": "session=abc",
                "Authorization": "Bearer secret",
                "X-Session-Id": "abc",
                "X-Diagnostics": "true",
                "Accept": "application/json",
                "User-Agent": "Pi-Web-Desktop/2.4.0"
            ]
        )
        request.method = "POST"

        let sanitized = request.sanitized()

        XCTAssertEqual(sanitized.method, "GET")
        XCTAssertEqual(sanitized.headers, [
            "Accept": "application/json",
            "User-Agent": "Pi-Web-Desktop/2.4.0"
        ])
    }

    func testEndpointWhitelistRejectsUnsafeInput() {
        XCTAssertNil(UpdateEndpoint.githubReleases(repository: "Su-luoya pi-web-desktop"))
        XCTAssertNil(UpdateEndpoint.githubReleases(repository: "Su-luoya/pi-web-desktop/extra"))
        XCTAssertNil(UpdateEndpoint.githubReleases(repository: "../etc/passwd"))
        XCTAssertNil(UpdateEndpoint.npmLatest(packageName: "bad name"))
        XCTAssertNil(UpdateEndpoint.npmLatest(packageName: "../etc/passwd"))
        XCTAssertNil(UpdateEndpoint.npmLatest(packageName: "@scope"))
        XCTAssertEqual(
            UpdateEndpoint.githubReleases(repository: UpdateCheckUpstream.desktopRepository)?.url.host,
            UpdateCheckUpstream.githubHost
        )
        XCTAssertEqual(
            UpdateEndpoint.npmLatest(packageName: "@agegr/pi-web")?.url.absoluteString,
            "https://registry.npmjs.org/@agegr%2Fpi-web/latest"
        )
        XCTAssertEqual(
            UpdateEndpoint.npmLatest(packageName: "@agegr/pi-web")?.allowedHosts,
            [UpdateCheckUpstream.npmRegistryHost]
        )
    }

    func testRequestsOnlyHitTheInjectedClient() {
        // 替身记录每一次请求；断言请求总数与白名单主机完全一致，等价于
        // “没有任何请求绕过替身打到真实网络”。
        let world = makeWorld(responder: automaticResponder())
        world.checker.start(inventory: fullInventory())
        world.clock.now = referenceDate.addingTimeInterval(8 * 24 * 3600)
        world.scheduler.fireTimers()

        let recorded = world.client.requests.count
        let whitelisted = world.client.requests.filter {
            [UpdateCheckUpstream.githubHost, UpdateCheckUpstream.npmRegistryHost].contains($0.url.host ?? "")
        }.count
        XCTAssertEqual(recorded, whitelisted)
        XCTAssertGreaterThan(recorded, 0)
    }

    // MARK: - 缓存文件

    func testCacheFileRoundTripInTemporaryDirectory() {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("update-check-cache.json")
        let store = UpdateCheckCacheFileStore(fileURL: fileURL)
        var file = UpdateCheckCacheFile()
        file.upsert(makeCachedEntry(
            category: .desktopApp,
            latestVersion: "0.2.0",
            status: .updateAvailable,
            lastAttemptAt: referenceDate,
            lastSuccessAt: referenceDate,
            etag: "\"v1\""
        ))

        store.save(file)

        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
        XCTAssertTrue(fileURL.path.hasPrefix(FileManager.default.temporaryDirectory.path))
        XCTAssertEqual(store.load(), file)
        XCTAssertEqual(store.load().entry(for: UpdateCheckTarget(category: .desktopApp).id)?.latestVersion, "0.2.0")
    }

    func testCacheFileContainsNoCredentialsOrDiagnostics() throws {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("update-check-cache.json")
        let store = UpdateCheckCacheFileStore(fileURL: fileURL)
        var file = UpdateCheckCacheFile()
        file.upsert(makeCachedEntry(
            category: .piPackages,
            packageName: "pi-extension-demo",
            latestVersion: "2.0.0",
            status: .updateAvailable,
            lastAttemptAt: referenceDate,
            lastSuccessAt: referenceDate,
            etag: "\"v1\""
        ))

        store.save(file)

        let json = try XCTUnwrap(String(data: Data(contentsOf: fileURL), encoding: .utf8)).lowercased()
        for forbidden in ["cookie", "authorization", "password", "token", "bearer", "session", "diagnostic", "/users/"] {
            XCTAssertFalse(json.contains(forbidden), "缓存不得包含 \(forbidden)")
        }
        XCTAssertTrue(json.contains("etag"))
        XCTAssertTrue(json.contains("lastsuccessat"))
    }

    func testCacheFileIgnoresCorruptedAndOldSchema() throws {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("update-check-cache.json")
        let store = UpdateCheckCacheFileStore(fileURL: fileURL)

        try Data("{not json".utf8).write(to: fileURL)
        XCTAssertEqual(store.load(), .empty)

        try Data("{\"schemaVersion\":99,\"entries\":[]}".utf8).write(to: fileURL)
        XCTAssertEqual(store.load(), .empty)
    }

    // MARK: - 缓存结构校验（GitHub #59）

    /// 损坏结构、字段类型错误、非法版本与未来时间戳：整份缓存丢弃，不部分采用。
    func testCacheValidationRejectsMalformedTypesVersionsAndFutureTimestamps() {
        let now = referenceDate

        var outcome = UpdateCheckCacheFile.validated(Data("{not json".utf8), now: now)
        XCTAssertEqual(outcome.rejection, .malformedStructure)
        XCTAssertEqual(outcome.file, .empty)

        // 字段类型错误：latestVersion 是数字而不是字符串。
        outcome = UpdateCheckCacheFile.validated(
            cacheFileJSON(entries: [cacheEntryJSON(["latestVersion": "5"])]),
            now: now
        )
        XCTAssertEqual(outcome.rejection, .malformedStructure)
        XCTAssertEqual(outcome.file, .empty)

        // 非法版本字符串（不是规范化的语义化版本）。
        outcome = UpdateCheckCacheFile.validated(
            cacheFileJSON(entries: [cacheEntryJSON(["latestVersion": "\"not-a-version\""])]),
            now: now
        )
        XCTAssertEqual(outcome.rejection, .invalidVersionShape)
        XCTAssertEqual(outcome.file, .empty)

        // 未来时间戳（超过允许的时钟偏移）。
        outcome = UpdateCheckCacheFile.validated(
            cacheFileJSON(entries: [cacheEntryJSON(["lastSuccessAt": "\"2999-01-01T00:00:00Z\""])]),
            now: now
        )
        XCTAssertEqual(outcome.rejection, .timestampInTheFuture)
        XCTAssertEqual(outcome.file, .empty)

        // 目标 id 与分类不一致。
        outcome = UpdateCheckCacheFile.validated(
            cacheFileJSON(entries: [cacheEntryJSON(["targetID": "\"pi-web\""])]),
            now: now
        )
        XCTAssertEqual(outcome.rejection, .invalidEntry)
        XCTAssertEqual(outcome.file, .empty)

        // 未知枚举值与非法分类。
        outcome = UpdateCheckCacheFile.validated(
            cacheFileJSON(entries: [cacheEntryJSON(["category": "\"not-a-category\""])]),
            now: now
        )
        XCTAssertEqual(outcome.rejection, .invalidEntry)

        // schema 版本不是当前版本。
        outcome = UpdateCheckCacheFile.validated(cacheFileJSON(schemaVersion: 99, entries: []), now: now)
        XCTAssertEqual(outcome.rejection, .unsupportedSchemaVersion(99))
        XCTAssertEqual(outcome.file, .empty)
    }

    /// 条目数超限与文件超大：在解析前就拒绝。
    func testCacheValidationRejectsTooManyEntriesAndOversizedData() {
        let entries = (0..<(UpdateCheckCacheFile.maximumEntries + 1)).map { index in
            cacheEntryJSON([
                "targetID": "\"pi-packages:pkg-\(index)\"",
                "category": "\"pi-packages\"",
                "packageName": "\"pkg-\(index)\""
            ])
        }
        var outcome = UpdateCheckCacheFile.validated(cacheFileJSON(entries: entries), now: referenceDate)
        XCTAssertEqual(outcome.rejection, .tooManyEntries(entries.count))
        XCTAssertEqual(outcome.file, .empty)

        let oversized = Data(repeating: 0x7B, count: UpdateCheckCacheFile.maximumFileBytes + 1)
        outcome = UpdateCheckCacheFile.validated(oversized, now: referenceDate)
        XCTAssertEqual(outcome.rejection, .tooLarge(bytes: oversized.count))
        XCTAssertEqual(outcome.file, .empty)
    }

    /// 一条合法 + 一条被改写：整份缓存丢弃，合法条目也不被采用。
    func testCacheValidationDropsTheWholeFileWhenOneEntryIsRewritten() {
        let outcome = UpdateCheckCacheFile.validated(
            cacheFileJSON(entries: [
                cacheEntryJSON(),
                cacheEntryJSON(["targetID": "\"pi-web\"", "category": "\"pi-web\"", "latestVersion": "\"v0.2\""])
            ]),
            now: referenceDate
        )

        XCTAssertEqual(outcome.rejection, .invalidVersionShape)
        XCTAssertEqual(outcome.file, .empty)
        XCTAssertNil(outcome.file.entry(for: "desktop-app"))
    }

    /// 旧 schema（1）是兼容读取：按当前结构载入、无拒绝原因，条目缺少
    /// `installedVersion` 由检查器降级（GitHub #74）。
    func testCacheValidationReadsLegacySchemaAndNormalizesItToCurrent() {
        let outcome = UpdateCheckCacheFile.validated(
            cacheFileJSON(schemaVersion: UpdateCheckCacheFile.legacySchemaVersion, entries: [cacheEntryJSON()]),
            now: referenceDate
        )

        XCTAssertNil(outcome.rejection)
        XCTAssertEqual(outcome.file.schemaVersion, UpdateCheckCacheFile.currentSchemaVersion)
        XCTAssertEqual(outcome.file.entries.count, 1)
        XCTAssertNil(outcome.file.entries.first?.installedVersion)
    }

    /// `installedVersion` 是缓存里唯一允许非规范化语义化版本的字段（本机安装
    /// 元数据可以是 `dev-build` 这类值），但仍要有长度上限、不含控制字符。
    func testCacheValidationRestrictsInstalledVersionShape() {
        let rejected = [
            cacheEntryJSON(["installedVersion": "\"\""]),
            cacheEntryJSON(["installedVersion": "\"1.0.0\\n（注入）\""]),
            cacheEntryJSON(["installedVersion": "\"1.0.0\u{7F}\""])
        ]
        for entry in rejected {
            let outcome = UpdateCheckCacheFile.validated(cacheFileJSON(entries: [entry]), now: referenceDate)
            XCTAssertEqual(outcome.rejection, .invalidEntry)
            XCTAssertEqual(outcome.file, .empty)
        }

        let valid = UpdateCheckCacheFile.validated(
            cacheFileJSON(entries: [cacheEntryJSON(["installedVersion": "\"dev-build\""])]),
            now: referenceDate
        )
        XCTAssertNil(valid.rejection)
        XCTAssertEqual(valid.file.entries.first?.installedVersion, "dev-build")
    }

    /// 文件存储：未来时间戳与被改写的版本一律丢弃，并给出原因；合法缓存仍然可读。
    func testCacheFileStoreRejectsRewrittenCacheAndKeepsValidOne() throws {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("update-check-cache.json")
        let store = UpdateCheckCacheFileStore(fileURL: fileURL, clock: UpdateClock { self.referenceDate })

        try Data("{\"schemaVersion\":1,\"entries\":[]}".utf8).write(to: fileURL)
        XCTAssertEqual(store.load(), .empty)
        XCTAssertNil(store.lastLoadRejection)

        try cacheFileJSON(entries: [cacheEntryJSON(["latestVersion": "\"9.9\""])]).write(to: fileURL)
        XCTAssertEqual(store.load(), .empty)
        XCTAssertEqual(store.lastLoadRejection, .invalidVersionShape)

        try cacheFileJSON(entries: [cacheEntryJSON(["lastAttemptAt": "\"2999-01-01T00:00:00Z\""])]).write(to: fileURL)
        XCTAssertEqual(store.load(), .empty)
        XCTAssertEqual(store.lastLoadRejection, .timestampInTheFuture)

        // 合法缓存（包括从未来偏移到允许范围内的时钟）仍然正常读回。
        var valid = UpdateCheckCacheFile()
        valid.upsert(makeCachedEntry(
            category: .desktopApp,
            latestVersion: "0.2.0",
            status: .updateAvailable,
            lastAttemptAt: referenceDate,
            lastSuccessAt: referenceDate
        ))
        store.save(valid)
        let reloaded = store.load()
        XCTAssertNil(store.lastLoadRejection)
        XCTAssertEqual(reloaded, valid)
    }

    /// 超大缓存文件在读取前就拒绝（不进入 JSON 解析、不进入内存）。
    func testCacheFileStoreRejectsOversizedFileBeforeParsing() throws {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("update-check-cache.json")
        let size = UpdateCheckCacheFile.maximumFileBytes + 1
        try Data(repeating: 0x20, count: size).write(to: fileURL)

        let store = UpdateCheckCacheFileStore(fileURL: fileURL, clock: UpdateClock { self.referenceDate })

        XCTAssertEqual(store.load(), .empty)
        XCTAssertEqual(store.lastLoadRejection, .tooLarge(bytes: size))
    }

    /// 被改写/损坏的缓存进入检查器：丢弃、记录固定原因、当作不可用，不崩溃。
    func testDiscardedCacheIsLoggedAndTreatedAsUnavailableByTheChecker() throws {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("update-check-cache.json")
        try Data("{not json".utf8).write(to: fileURL)

        let clock = FixedClock(referenceDate)
        let client = RecordingUpdateHTTPClient()
        client.responder = { _ in .failure(.offline) }
        let store = UpdateCheckCacheFileStore(fileURL: fileURL, clock: clock.clock)
        let logs = LogSink()
        let checker = UpdateChecker(
            httpClient: client,
            clock: clock.clock,
            cacheStore: store,
            scheduler: ImmediateUpdateCheckScheduler(),
            identity: UpdateCheckIdentity(appName: "Pi Web Desktop", version: desktopInstalledVersion, bundleIdentifier: nil),
            intervals: .standard,
            preferences: .factoryDefaults,
            log: { logs.append($0) }
        )

        checker.checkNow(triggeredBy: .manual, inventory: fullInventory())

        XCTAssertEqual(store.lastLoadRejection, .malformedStructure)
        XCTAssertTrue(logs.messages.contains { $0.contains("缓存已丢弃") && $0.contains("无法解析") })
        XCTAssertEqual(checker.summary.results.count, 4)
        for result in checker.summary.results {
            XCTAssertEqual(result.origin, .unavailable)
            XCTAssertNil(result.latestVersion)
        }
        // 日志只写固定结论：不回显缓存内容、临时目录或凭据。
        let joined = logs.messages.joined(separator: "\n")
        XCTAssertFalse(joined.contains(directory.path))
        XCTAssertFalse(joined.contains("not json"))
        XCTAssertFalse(joined.contains("{"))
    }

    func testCachePrunesToMaximumEntries() {
        var file = UpdateCheckCacheFile()
        for index in 0..<(UpdateCheckCacheFile.maximumEntries + 5) {
            file.upsert(UpdateCacheEntry(
                targetID: "pi-packages:pkg-\(index)",
                category: UpdateCheckCategory.piPackages.rawValue,
                packageName: "pkg-\(index)",
                lastAttemptAt: referenceDate.addingTimeInterval(TimeInterval(index))
            ))
        }

        file.pruneToMaximumEntries()

        XCTAssertEqual(file.entries.count, UpdateCheckCacheFile.maximumEntries)
        // 保留的是最近尝试的条目。
        XCTAssertNotNil(file.entry(for: "pi-packages:pkg-\(UpdateCheckCacheFile.maximumEntries + 4)"))
        XCTAssertNil(file.entry(for: "pi-packages:pkg-0"))
    }

    func testFailingRunWritesOnlyTheInjectedCacheFile() {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("update-check-cache.json")
        let client = RecordingUpdateHTTPClient()
        client.responder = { _ in .failure(.timedOut) }
        let checker = UpdateChecker(
            httpClient: client,
            clock: UpdateClock { self.referenceDate },
            cacheStore: UpdateCheckCacheFileStore(fileURL: fileURL),
            scheduler: ImmediateUpdateCheckScheduler(),
            identity: UpdateCheckIdentity(appName: "Pi Web Desktop", version: desktopInstalledVersion, bundleIdentifier: nil),
            intervals: .standard,
            preferences: .factoryDefaults
        )

        checker.checkNow(triggeredBy: .manual, inventory: fullInventory())

        let contents = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        XCTAssertEqual(contents, ["update-check-cache.json"])
        XCTAssertEqual(checker.summary.unknownCount, checker.summary.results.count)
    }

    // MARK: - 提示文案与开关持久化

    func testSummaryTextsAreUnderstandable() {
        let world = makeWorld(responder: automaticResponder())
        world.checker.start(inventory: fullInventory())

        XCTAssertTrue(world.checker.summary.statusLine.contains("可用更新"))
        XCTAssertTrue(world.checker.summary.detailText.contains("不会自动下载或安装"))
        for result in world.checker.summary.results {
            XCTAssertTrue(result.displayText.contains(result.target.displayName))
        }
    }

    func testAllUpToDateSummary() {
        let world = makeWorld(responder: { request in
            if request.url.host == UpdateCheckUpstream.githubHost {
                return Self.githubHTTPResponse(tags: ["v2.4.0"])
            }
            return Self.npmHTTPResponse(version: "1.0.0")
        })
        let inventory = UpdateCheckInventory(
            desktopAppVersion: desktopInstalledVersion,
            piCLIVersion: "1.0.0",
            piWebVersion: "1.0.0",
            piPackages: []
        )

        world.checker.checkNow(triggeredBy: .manual, inventory: inventory)

        XCTAssertEqual(world.checker.summary.unknownCount, 0)
        XCTAssertEqual(world.checker.summary.updateAvailableCount, 0)
        XCTAssertTrue(world.checker.summary.statusLine.contains("已是最新"))
    }

    func testLoggerReceivesOnlyStatusCounts() {
        let world = makeWorld(responder: automaticResponder())

        world.checker.start(inventory: fullInventory())

        XCTAssertFalse(world.logs.messages.isEmpty)
        let joined = world.logs.messages.joined(separator: "\n")
        XCTAssertTrue(joined.contains("可用更新"))
        XCTAssertFalse(joined.contains("http"))
        XCTAssertFalse(joined.contains("registry.npmjs.org"))
        XCTAssertFalse(joined.contains("api.github.com"))
        XCTAssertFalse(joined.contains("{"))
    }

    func testDisclosureTextListsHostsFrequencyDisableAndCache() {
        let text = UpdateCheckDisclosure.text(
            cachePath: "~/Library/Application Support/Pi Web Desktop/update-check-cache.json"
        )

        XCTAssertTrue(text.contains(UpdateCheckUpstream.githubHost))
        XCTAssertTrue(text.contains(UpdateCheckUpstream.npmRegistryHost))
        XCTAssertTrue(text.contains("24 小时"))
        XCTAssertTrue(text.contains("7 天"))
        XCTAssertTrue(text.contains("关闭"))
        XCTAssertTrue(text.contains("不下载、不安装"))
        XCTAssertTrue(text.contains("不是遥测"))
        XCTAssertTrue(text.contains("update-check-cache.json"))
    }

    func testPreferencesRoundTripThroughIsolatedUserDefaults() {
        let suiteName = "pi-web-desktop-update-check-tests-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("无法创建隔离的 UserDefaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertEqual(UpdateCheckPreferences.load(from: defaults), .factoryDefaults)

        var preferences = UpdateCheckPreferences.factoryDefaults
        preferences.setPolicy(.weekly, for: .piWeb)
        preferences.setPolicy(.off, for: .piPackages)
        preferences.save(to: defaults)

        let loaded = UpdateCheckPreferences.load(from: defaults)
        XCTAssertEqual(loaded.policy(for: .piWeb), .weekly)
        XCTAssertEqual(loaded.policy(for: .piPackages), .off)
        XCTAssertEqual(loaded.policy(for: .desktopApp), .daily)
        XCTAssertEqual(loaded.policy(for: .piCLI), .daily)
        XCTAssertTrue(loaded.isEnabled(.desktopApp))
        XCTAssertFalse(loaded.isEnabled(.piPackages))
    }

    func testResultsCallbackFiresOncePerCompletedCheck() {
        let world = makeWorld(responder: automaticResponder())
        var summaries: [UpdateCheckSummary] = []
        world.checker.onResultsChanged = { summaries.append($0) }

        world.checker.start(inventory: fullInventory())
        XCTAssertEqual(summaries.count, 1)

        world.clock.now = referenceDate.addingTimeInterval(24 * 3600)
        world.scheduler.fireTimers()
        XCTAssertEqual(summaries.count, 2)

        // 没有到期对象时不会发布新的汇总（避免菜单时间戳被周期计时器刷掉）。
        world.clock.now = referenceDate.addingTimeInterval(24 * 3600 + 60)
        world.scheduler.fireTimers()
        XCTAssertEqual(summaries.count, 2)
    }

    // MARK: - 策略与调度（GitHub #18）

    /// 四类组件各自关闭后：该类请求数为 0、无对应计时器，其它分类不受影响。
    func testEachCategoryOffMakesZeroRequestsAndSchedulesNothing() {
        for category in UpdateCheckCategory.allCases {
            var preferences = UpdateCheckPreferences.factoryDefaults
            preferences.setPolicy(.off, for: category)
            let world = makeWorld(preferences: preferences, responder: automaticResponder())

            world.checker.start(inventory: fullInventory())
            // 假时钟推进 8 天并触发全部计时器：每日与每周策略都会到期。
            world.clock.now = referenceDate.addingTimeInterval(8 * 24 * 3600)
            world.scheduler.fireTimers()
            world.checker.checkNow(triggeredBy: .manual, inventory: fullInventory())

            XCTAssertFalse(world.client.requests.isEmpty, "关闭 \(category.rawValue) 后其它分类仍应检查")
            XCTAssertTrue(
                world.client.requests.allSatisfy { !requestMatchesCategory($0, category) },
                "关闭的 \(category.rawValue) 不应产生请求"
            )

            let enabled = UpdateCheckCategory.allCases.filter { preferences.isEnabled($0) }
            let expectedIntervals = Set(enabled.map {
                UpdateCheckIntervals.standard.interval(for: $0, policy: preferences.policy(for: $0)) ?? -1
            })
            XCTAssertEqual(Set(world.scheduler.activeIntervals), expectedIntervals, "计时器应与开启分类的策略一致")
        }
    }

    /// 每日 / 每周 / 扩展包 7 天的到期判定全部由假时钟推进驱动。
    func testDailyAndWeeklyCadenceFollowTheFakeClock() {
        var preferences = UpdateCheckPreferences.factoryDefaults
        preferences.setPolicy(.weekly, for: .desktopApp)
        preferences.setPolicy(.weekly, for: .piWeb)
        preferences.setPolicy(.daily, for: .piCLI)
        let world = makeWorld(preferences: preferences, responder: automaticResponder())

        world.checker.start(inventory: fullInventory())
        XCTAssertEqual(requestCount(world, category: .desktopApp), 1)
        XCTAssertEqual(requestCount(world, category: .piCLI), 1)
        XCTAssertEqual(requestCount(world, category: .piWeb), 1)
        XCTAssertEqual(requestCount(world, category: .piPackages, packageName: "pi-extension-demo"), 1)

        // 24 小时后：只有每日的 Pi CLI 到期。
        world.clock.now = referenceDate.addingTimeInterval(24 * 3600)
        world.scheduler.fireTimers()
        XCTAssertEqual(requestCount(world, category: .piCLI), 2)
        XCTAssertEqual(requestCount(world, category: .desktopApp), 1)
        XCTAssertEqual(requestCount(world, category: .piWeb), 1)
        XCTAssertEqual(requestCount(world, category: .piPackages, packageName: "pi-extension-demo"), 1)

        // 7 天后：每周的两类与 7 天节奏的扩展包各再检查一次。
        world.clock.now = referenceDate.addingTimeInterval(7 * 24 * 3600)
        world.scheduler.fireTimers()
        XCTAssertEqual(requestCount(world, category: .desktopApp), 2)
        XCTAssertEqual(requestCount(world, category: .piWeb), 2)
        XCTAssertEqual(requestCount(world, category: .piPackages, packageName: "pi-extension-demo"), 2)
    }

    /// 迁移后的旧版布尔键直接决定调度：`false` 等于关闭（零请求）。
    func testLegacyEnabledKeysDriveSchedulingAfterMigration() {
        let suiteName = "pi-web-desktop-update-check-tests-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("无法创建隔离的 UserDefaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(false, forKey: UpdateSettingKeys.legacyEnabled(for: .piWeb))
        defaults.set(true, forKey: UpdateSettingKeys.legacyEnabled(for: .desktopApp))

        var diagnostics: [String] = []
        let preferences = UpdateCheckPreferences.load(from: defaults) { diagnostics.append($0) }
        XCTAssertTrue(diagnostics.isEmpty)
        XCTAssertEqual(preferences.policy(for: .piWeb), .off)
        XCTAssertEqual(preferences.policy(for: .desktopApp), .daily)

        let world = makeWorld(preferences: preferences, responder: automaticResponder())
        world.checker.start(inventory: fullInventory())
        world.checker.checkNow(triggeredBy: .manual, inventory: fullInventory())
        XCTAssertEqual(requestCount(world, category: .piWeb), 0)
        XCTAssertEqual(requestCount(world, category: .desktopApp), 2)
    }

    /// 应用关闭（`stop()`）后不再调度：假时钟推进 30 天也没有任何新请求。
    func testStoppedCheckerNeverSchedulesEvenAfterALongFakeClockAdvance() {
        let world = makeWorld(responder: automaticResponder())
        world.checker.start(inventory: fullInventory())
        let requestsBeforeStop = world.client.requests.count

        world.checker.stop()
        world.clock.now = referenceDate.addingTimeInterval(30 * 24 * 3600)
        world.scheduler.fireTimers()
        world.checker.checkNow(triggeredBy: .manual, inventory: fullInventory())

        XCTAssertEqual(world.client.requests.count, requestsBeforeStop)
        XCTAssertTrue(world.scheduler.timers.allSatisfy { $0.token.isCancelled })
    }

    // MARK: - 忽略版本（GitHub #18）

    func testIgnoringCurrentVersionSuppressesRepromptAndNewerUpstreamReprompts() {
        let world = makeWorld(responder: automaticResponder())
        let target = UpdateCheckTarget(category: .piWeb)
        world.checker.start(inventory: fullInventory())
        XCTAssertEqual(world.checker.summary.result(for: target.id)?.status, .updateAvailable)
        XCTAssertNil(world.checker.summary.result(for: target.id)?.ignoredVersion)

        var ignored = UpdateIgnoredVersions.empty
        ignored.ignore("2.0.0", for: .piWeb, at: referenceDate)
        world.checker.ignoredVersions = ignored

        // 忽略后不再进入通知名单。
        XCTAssertTrue(UpdateNotificationPlanner.plan(
            results: world.checker.summary.results,
            preferences: world.checker.preferences,
            ignoredVersions: ignored,
            alreadyNotified: [:]
        ).allSatisfy { $0.category != .piWeb })

        // 下一次检查把忽略标记带进结果与状态快照。
        world.checker.checkNow(triggeredBy: .manual, inventory: fullInventory())
        let afterIgnore = world.checker.summary.result(for: target.id)
        XCTAssertEqual(afterIgnore?.status, .updateAvailable)
        XCTAssertEqual(afterIgnore?.ignoredVersion, "2.0.0")
        XCTAssertEqual(
            world.checker.summary.categoryStatuses.first { $0.category == .piWeb }?.ignoredVersion,
            "2.0.0"
        )
        XCTAssertTrue(
            world.checker.summary.categoryStatuses.first { $0.category == .piWeb }?.resultTitle.contains("已忽略") == true
        )

        // 上游发布更高版本：同一份忽略记录不再匹配，重新提示。
        let newerWorld = makeWorld(
            ignoredVersions: ignored,
            responder: { request in
                if request.url.host == UpdateCheckUpstream.githubHost {
                    return Self.githubHTTPResponse(tags: ["v2.4.0"])
                }
                return Self.npmHTTPResponse(version: "2.1.0")
            }
        )
        newerWorld.checker.checkNow(triggeredBy: .manual, inventory: fullInventory())
        let newer = newerWorld.checker.summary.result(for: target.id)
        XCTAssertEqual(newer?.status, .updateAvailable)
        XCTAssertEqual(newer?.latestVersion, "2.1.0")
        XCTAssertNil(newer?.ignoredVersion)
        // 其他组件此刻也可能有可用更新，所以这里只断言本类别重新进入通知名单。
        let newerPlans = UpdateNotificationPlanner.plan(
            results: newerWorld.checker.summary.results,
            preferences: newerWorld.checker.preferences,
            ignoredVersions: ignored,
            alreadyNotified: [:]
        )
        XCTAssertEqual(newerPlans.filter { $0.category == .piWeb }.map(\.latestVersion), ["2.1.0"])
    }

    func testScheduledResultsProduceAtMostOneNotificationPerVersion() {
        let world = makeWorld(responder: automaticResponder())
        world.checker.start(inventory: fullInventory())

        var notified: [UpdateCheckCategory: String] = [:]
        let first = UpdateNotificationPlanner.plan(
            results: world.checker.summary.results,
            preferences: world.checker.preferences,
            ignoredVersions: .empty,
            alreadyNotified: notified
        )
        XCTAssertEqual(first.count, 4)
        for entry in first { notified[entry.category] = entry.latestVersion }

        world.clock.now = referenceDate.addingTimeInterval(24 * 3600)
        world.scheduler.fireTimers()
        let second = UpdateNotificationPlanner.plan(
            results: world.checker.summary.results,
            preferences: world.checker.preferences,
            ignoredVersions: .empty,
            alreadyNotified: notified
        )
        XCTAssertTrue(second.isEmpty, "同一版本在本次运行里不应重复提示")
    }

    // MARK: - 状态与启动前自动更新开关

    func testSummaryPublishesPerCategoryStatusWithNextCheckTime() {
        let world = makeWorld(responder: automaticResponder())
        world.checker.start(inventory: fullInventory())

        let statuses = world.checker.summary.categoryStatuses
        XCTAssertEqual(statuses.count, UpdateCheckCategory.allCases.count)
        for status in statuses {
            XCTAssertNotNil(status.lastAttemptAt, "\(status.category.rawValue) 应记录最近检查时间")
            XCTAssertNotNil(status.nextCheckAt, "\(status.category.rawValue) 应给出下次检查时间")
            XCTAssertEqual(status.status, .updateAvailable)
        }
        let desktop = statuses.first { $0.category == .desktopApp }
        XCTAssertEqual(desktop?.nextCheckAt, referenceDate.addingTimeInterval(24 * 3600))
        let packages = statuses.first { $0.category == .piPackages }
        XCTAssertEqual(packages?.nextCheckAt, referenceDate.addingTimeInterval(7 * 24 * 3600))
    }

    /// 设置位打开后：检查器的请求、结果与调度与关闭时完全一致——安装行为只由
    /// `PiWebUpdatePlanner` 的前置条件与来源判定决定（GitHub #20），`UpdateChecker`
    /// 自己依旧没有任何安装/执行路径。
    func testAutoUpdateSettingDoesNotChangeCheckerRuntimeBehavior() {
        var reserved = UpdateCheckPreferences.factoryDefaults
        reserved.autoUpdatePiWebBeforeLaunch = true
        XCTAssertTrue(UpdateCheckPreferences.autoUpdateBeforeLaunchIsEffective)

        let off = makeWorld(preferences: .factoryDefaults, responder: automaticResponder())
        let on = makeWorld(preferences: reserved, responder: automaticResponder())
        off.checker.start(inventory: fullInventory())
        on.checker.start(inventory: fullInventory())

        XCTAssertEqual(on.client.requests.map(\.url), off.client.requests.map(\.url))
        XCTAssertEqual(on.checker.summary.results.map(\.status), off.checker.summary.results.map(\.status))
        XCTAssertEqual(on.checker.summary.categoryStatuses, off.checker.summary.categoryStatuses)
        XCTAssertEqual(on.scheduler.activeIntervals.sorted(), off.scheduler.activeIntervals.sorted())

        // 检查器只有 GET 请求这一种外部动作；设置位不会增加检查器的任何动作。
        XCTAssertTrue(on.client.requests.allSatisfy { $0.method == "GET" })
        XCTAssertEqual(on.client.requests.count, off.client.requests.count)
        XCTAssertTrue(UpdateAutomationBoundary.restrictedExplanation.contains("npm 全局"))
    }
}
