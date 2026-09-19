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
        preferences: UpdateCheckPreferences = .allEnabled,
        cached: UpdateCheckCacheFile = .empty,
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
            intervals: .standard,
            preferences: preferences,
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

    private func makeCachedEntry(
        category: UpdateCheckCategory,
        packageName: String? = nil,
        latestVersion: String,
        status: UpdateCheckStatus,
        confidence: DetectionConfidence = .verified,
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
            status: status.rawValue,
            confidence: confidence.rawValue
        )
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
        preferences.piWebEnabled = false
        preferences.piPackagesEnabled = false
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
        var preferences = UpdateCheckPreferences.allEnabled
        preferences.piWebEnabled = false
        preferences.piPackagesEnabled = false
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
        let preferences = UpdateCheckPreferences(
            desktopAppEnabled: false,
            piCLIEnabled: false,
            piWebEnabled: false,
            piPackagesEnabled: false
        )
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

    func testOfflineFailureReusesFreshCachedResult() {
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
        let world = makeWorld(cached: cached, responder: { _ in .failure(.offline) })

        world.checker.checkNow(
            triggeredBy: .manual,
            inventory: UpdateCheckInventory(desktopAppVersion: desktopInstalledVersion)
        )

        let result = world.checker.summary.result(for: UpdateCheckTarget(category: .desktopApp).id)
        XCTAssertEqual(result?.status, .updateAvailable)
        XCTAssertEqual(result?.freshness, .cached)
        XCTAssertEqual(result?.failure, .offline)
        XCTAssertEqual(result?.latestVersion, "0.2.0")
        XCTAssertEqual(result?.confidence, .verified)
        XCTAssertEqual(result?.displayText.contains("网络不可用"), true)
        // 上次成功时间不被失败覆盖，etag 保留供下次条件请求使用。
        let entry = world.store.file.entry(for: UpdateCheckTarget(category: .desktopApp).id)
        XCTAssertEqual(entry?.lastSuccessAt, lastSuccess)
        XCTAssertEqual(entry?.etag, "\"v1\"")
        XCTAssertEqual(entry?.failure, UpdateCheckFailure.offline.rawValue)
        XCTAssertEqual(entry?.latestVersion, "0.2.0")
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
            lastAttemptAt: lastSuccess,
            lastSuccessAt: lastSuccess
        ))
        let world = makeWorld(cached: cached, responder: { _ in .failure(.offline) })
        var preferences = UpdateCheckPreferences.allEnabled
        preferences.desktopAppEnabled = false
        preferences.piCLIEnabled = false
        preferences.piWebEnabled = false
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

    func testNotModifiedRefreshesSuccessFromCache() {
        var cached = UpdateCheckCacheFile()
        let lastSuccess = referenceDate.addingTimeInterval(-30 * 3600)
        cached.upsert(makeCachedEntry(
            category: .desktopApp,
            latestVersion: desktopInstalledVersion,
            status: .upToDate,
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
            preferences: .allEnabled
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

        XCTAssertEqual(UpdateCheckPreferences.load(from: defaults), .allEnabled)

        var preferences = UpdateCheckPreferences.allEnabled
        preferences.setEnabled(false, for: .piWeb)
        preferences.setEnabled(false, for: .piPackages)
        preferences.save(to: defaults)

        let loaded = UpdateCheckPreferences.load(from: defaults)
        XCTAssertFalse(loaded.piWebEnabled)
        XCTAssertFalse(loaded.piPackagesEnabled)
        XCTAssertTrue(loaded.desktopAppEnabled)
        XCTAssertTrue(loaded.piCLIEnabled)
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
}
