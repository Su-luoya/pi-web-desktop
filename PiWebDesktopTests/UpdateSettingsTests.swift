import XCTest

// GitHub #18 的设置模型、迁移、忽略版本与通知判定的 unhosted 测试。
//
// 全部是纯值类型断言 + suiteName 隔离的 UserDefaults（测试结束删除）：
// 不访问真实网络、不写真实 UserDefaults / Application Support、不创建进程、
// 不执行任何安装命令，也没有任何依赖。

final class UpdateSettingsTests: XCTestCase {

    private let referenceDate = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - 夹具

    private func withIsolatedDefaults(_ body: (UserDefaults, String) -> Void) {
        let suiteName = "pi-web-desktop-update-settings-tests-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("无法创建隔离的 UserDefaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }
        body(defaults, suiteName)
    }

    /// 固定格式：测试断言不依赖时区与本地化。
    private func fixedFormat(_ date: Date) -> String {
        "T+\(Int(date.timeIntervalSince(referenceDate)))"
    }

    private func result(
        category: UpdateCheckCategory,
        packageName: String? = nil,
        status: UpdateCheckStatus,
        installed: String? = nil,
        latest: String? = nil,
        failure: UpdateCheckFailure? = nil,
        ignoredVersion: String? = nil,
        checkedAt: Date? = nil,
        origin: UpdateCheckOrigin = .unavailable,
        cacheWrittenAt: Date? = nil
    ) -> UpdateCheckResult {
        UpdateCheckResult(
            target: UpdateCheckTarget(category: category, packageName: packageName),
            status: status,
            installedVersion: installed,
            latestVersion: latest,
            confidence: .verified,
            freshness: .fresh,
            failure: failure,
            httpStatusCode: nil,
            checkedAt: checkedAt ?? referenceDate,
            lastSuccessAt: checkedAt ?? referenceDate,
            ignoredVersion: ignoredVersion,
            origin: origin,
            cacheWrittenAt: cacheWrittenAt
        )
    }

    private func cacheEntry(
        category: UpdateCheckCategory,
        packageName: String? = nil,
        latestVersion: String,
        status: UpdateCheckStatus,
        installedVersion: String? = nil,
        lastAttemptAt: Date,
        lastSuccessAt: Date?
    ) -> UpdateCacheEntry {
        UpdateCacheEntry(
            targetID: UpdateCheckTarget(category: category, packageName: packageName).id,
            category: category.rawValue,
            packageName: packageName,
            lastAttemptAt: lastAttemptAt,
            lastSuccessAt: lastSuccessAt,
            latestVersion: latestVersion,
            installedVersion: installedVersion,
            status: status.rawValue,
            confidence: DetectionConfidence.verified.rawValue
        )
    }

    // MARK: - 默认值与策略

    func testDefaultPoliciesMatchDocumentedDefaults() {
        let preferences = UpdateCheckPreferences.factoryDefaults

        XCTAssertEqual(preferences.policy(for: .desktopApp), .daily)
        XCTAssertEqual(preferences.policy(for: .piCLI), .daily)
        XCTAssertEqual(preferences.policy(for: .piWeb), .daily)
        XCTAssertEqual(preferences.policy(for: .piPackages), .checkAndNotify)
        XCTAssertFalse(preferences.autoUpdatePiWebBeforeLaunch)
        XCTAssertTrue(preferences.enabledCategories.count == UpdateCheckCategory.allCases.count)
        XCTAssertFalse(preferences.allDisabled)

        // 文档默认值的常量：每日 24 小时、每周 7 天、扩展包 7 天。
        XCTAssertEqual(UpdateCheckIntervals.standard.daily, 24 * 60 * 60)
        XCTAssertEqual(UpdateCheckIntervals.standard.weekly, 7 * 24 * 60 * 60)
        XCTAssertEqual(UpdateCheckIntervals.standard.packageCheck, 7 * 24 * 60 * 60)
        // GitHub #20：设置位已生效，但只对来源为已验证的 npm 全局安装的 Pi Web 生效。
        XCTAssertTrue(UpdateCheckPreferences.autoUpdateBeforeLaunchIsEffective)
        XCTAssertTrue(UpdateAutomationBoundary.autoUpdateIsEffective)
    }

    func testPolicyTitlesAndAllowedSets() {
        XCTAssertEqual(UpdateCheckPolicy.off.title, "关闭")
        XCTAssertEqual(UpdateCheckPolicy.daily.title, "每日")
        XCTAssertEqual(UpdateCheckPolicy.weekly.title, "每周")
        XCTAssertEqual(UpdateCheckPolicy.checkAndNotify.title, "检查并通知")
        XCTAssertEqual(UpdateCheckPolicy.askBeforeUpdate.title, "询问后更新")

        XCTAssertEqual(UpdateCheckPolicy.allowed(for: .desktopApp), [.off, .daily, .weekly])
        XCTAssertEqual(UpdateCheckPolicy.allowed(for: .piCLI), [.off, .daily, .weekly])
        XCTAssertEqual(UpdateCheckPolicy.allowed(for: .piWeb), [.off, .daily, .weekly])
        XCTAssertEqual(UpdateCheckPolicy.allowed(for: .piPackages), [.off, .checkAndNotify, .askBeforeUpdate])
    }

    func testSetPolicyRejectsCombinationsOutsideTheCategory() {
        var preferences = UpdateCheckPreferences.factoryDefaults

        XCTAssertFalse(preferences.setPolicy(.weekly, for: .piPackages))
        XCTAssertFalse(preferences.setPolicy(.askBeforeUpdate, for: .piWeb))
        XCTAssertEqual(preferences.policy(for: .piPackages), .checkAndNotify)
        XCTAssertEqual(preferences.policy(for: .piWeb), .daily)

        XCTAssertTrue(preferences.setPolicy(.askBeforeUpdate, for: .piPackages))
        XCTAssertEqual(preferences.policy(for: .piPackages), .askBeforeUpdate)
    }

    func testMenuShortcutToggleUsesTheCategoryDefaultPolicy() {
        var preferences = UpdateCheckPreferences.factoryDefaults

        preferences.setEnabled(false, for: .piWeb)
        XCTAssertEqual(preferences.policy(for: .piWeb), .off)
        preferences.setEnabled(true, for: .piWeb)
        XCTAssertEqual(preferences.policy(for: .piWeb), .daily)

        preferences.setEnabled(false, for: .piPackages)
        XCTAssertEqual(preferences.policy(for: .piPackages), .off)
        preferences.setEnabled(true, for: .piPackages)
        XCTAssertEqual(preferences.policy(for: .piPackages), .checkAndNotify)

        preferences.setEnabled(false, for: .desktopApp)
        XCTAssertTrue(preferences.isEnabled(.piCLI))
        XCTAssertEqual(preferences.enabledCategories, [.piCLI, .piWeb, .piPackages])
    }

    // MARK: - 迁移

    func testMigrationMissingKeysUsesDefaults() {
        let outcome = UpdateCheckSettingsMigration.resolve(values: [:])

        XCTAssertEqual(outcome.preferences, .factoryDefaults)
        XCTAssertTrue(outcome.diagnostics.isEmpty)
    }

    func testMigrationReadsLegacyEnabledKeys() {
        let values: [String: Any] = [
            UpdateSettingKeys.legacyEnabled(for: .desktopApp): false,
            UpdateSettingKeys.legacyEnabled(for: .piCLI): true,
            UpdateSettingKeys.legacyEnabled(for: .piPackages): false
        ]
        let outcome = UpdateCheckSettingsMigration.resolve(values: values)

        XCTAssertEqual(outcome.preferences.policy(for: .desktopApp), .off)
        XCTAssertEqual(outcome.preferences.policy(for: .piCLI), .daily)
        XCTAssertEqual(outcome.preferences.policy(for: .piPackages), .off)
        XCTAssertEqual(outcome.preferences.policy(for: .piWeb), .daily)
        XCTAssertTrue(outcome.diagnostics.isEmpty)
    }

    func testMigrationNewPolicyKeyWinsOverLegacyKey() {
        let values: [String: Any] = [
            UpdateSettingKeys.policy(for: .piWeb): UpdateCheckPolicy.weekly.rawValue,
            UpdateSettingKeys.legacyEnabled(for: .piWeb): false
        ]
        let outcome = UpdateCheckSettingsMigration.resolve(values: values)

        XCTAssertEqual(outcome.preferences.policy(for: .piWeb), .weekly)
        XCTAssertTrue(outcome.diagnostics.isEmpty)
    }

    func testMigrationUnknownValuesFallBackToDefaultsWithDiagnostics() {
        let values: [String: Any] = [
            UpdateSettingKeys.policy(for: .desktopApp): "sometimes",
            UpdateSettingKeys.policy(for: .piPackages): "daily",
            UpdateSettingKeys.legacyEnabled(for: .piCLI): 1,
            UpdateSettingKeys.autoUpdatePiWebBeforeLaunch: "yes"
        ]
        let outcome = UpdateCheckSettingsMigration.resolve(values: values)

        XCTAssertEqual(outcome.preferences, .factoryDefaults)
        XCTAssertEqual(outcome.diagnostics.count, 4)
        for key in [
            UpdateSettingKeys.policy(for: .desktopApp),
            UpdateSettingKeys.policy(for: .piPackages),
            UpdateSettingKeys.legacyEnabled(for: .piCLI),
            UpdateSettingKeys.autoUpdatePiWebBeforeLaunch
        ] {
            XCTAssertTrue(outcome.diagnostics.contains { $0.contains(key) }, "诊断应提到 \(key)")
        }
        // 诊断不回显原始值，避免把用户数据带进日志。
        XCTAssertTrue(outcome.diagnostics.allSatisfy { !$0.contains("sometimes") && !$0.contains("yes") })
    }

    func testBooleanMigrationOnlyAcceptsRealBooleans() {
        XCTAssertEqual(UpdateCheckSettingsMigration.booleanValue(true), true)
        XCTAssertEqual(UpdateCheckSettingsMigration.booleanValue(false), false)
        XCTAssertNil(UpdateCheckSettingsMigration.booleanValue(1))
        XCTAssertNil(UpdateCheckSettingsMigration.booleanValue(0))
        XCTAssertNil(UpdateCheckSettingsMigration.booleanValue("true"))
        XCTAssertNil(UpdateCheckSettingsMigration.booleanValue([true]))

        let reservedKey = UpdateSettingKeys.autoUpdatePiWebBeforeLaunch
        XCTAssertTrue(UpdateCheckSettingsMigration.resolve(values: [reservedKey: true])
            .preferences.autoUpdatePiWebBeforeLaunch)
        XCTAssertFalse(UpdateCheckSettingsMigration.resolve(values: [reservedKey: 1])
            .preferences.autoUpdatePiWebBeforeLaunch)
    }

    // MARK: - UserDefaults 往返与隐私边界

    func testPreferencesRoundTripWritesOnlyPoliciesAndReservedFlag() {
        withIsolatedDefaults { defaults, suiteName in
            var preferences = UpdateCheckPreferences.factoryDefaults
            preferences.setPolicy(.askBeforeUpdate, for: .piPackages)
            preferences.setPolicy(.off, for: .piWeb)
            preferences.autoUpdatePiWebBeforeLaunch = true
            preferences.save(to: defaults)

            XCTAssertEqual(UpdateCheckPreferences.load(from: defaults), preferences)

            let domain = defaults.persistentDomain(forName: suiteName) ?? [:]
            XCTAssertEqual(Set(domain.keys), Set(UpdateSettingKeys.writtenPreferencesKeys))
            for (key, value) in domain {
                let text = String(describing: value)
                XCTAssertFalse(text.contains("/"), "键 \(key) 不应包含路径")
                XCTAssertFalse(text.contains("~"), "键 \(key) 不应包含 Home 路径")
                for secret in ["password", "token", "secret", "Bearer"] {
                    XCTAssertFalse(text.lowercased().contains(secret.lowercased()), "键 \(key) 不应包含凭据形状")
                }
            }
        }
    }

    func testSaveRemovesLegacyEnabledKeys() {
        withIsolatedDefaults { defaults, _ in
            for category in UpdateCheckCategory.allCases {
                defaults.set(false, forKey: UpdateSettingKeys.legacyEnabled(for: category))
            }
            UpdateCheckPreferences.factoryDefaults.save(to: defaults)

            for category in UpdateCheckCategory.allCases {
                XCTAssertNil(defaults.object(forKey: UpdateSettingKeys.legacyEnabled(for: category)))
                XCTAssertEqual(
                    defaults.string(forKey: UpdateSettingKeys.policy(for: category)),
                    UpdateCheckPreferences.defaultPolicy(for: category).rawValue
                )
            }
        }
    }

    func testIgnoredVersionsRoundTripStoresOnlyVersionAndTimestamp() {
        withIsolatedDefaults { defaults, suiteName in
            var ignored = UpdateIgnoredVersions.empty
            ignored.ignore("2.4.1-alpha.2", for: .desktopApp, at: referenceDate)

            XCTAssertTrue(ignored.isIgnored("2.4.1-alpha.2", for: .desktopApp))
            XCTAssertFalse(ignored.isIgnored("2.4.1-alpha.3", for: .desktopApp))
            // 忽略值与组件来源、分类无关：只按版本字符串比较。
            XCTAssertFalse(ignored.isIgnored("2.4.1-alpha.2", for: .piCLI))

            ignored.save(to: defaults)
            let loaded = UpdateIgnoredVersions.load(from: defaults)
            XCTAssertEqual(loaded.ignored(for: .desktopApp)?.version, "2.4.1-alpha.2")
            XCTAssertEqual(loaded.ignored(for: .desktopApp)?.ignoredAt, referenceDate)
            XCTAssertNil(loaded.ignored(for: .piCLI))

            let domain = defaults.persistentDomain(forName: suiteName) ?? [:]
            XCTAssertEqual(
                Set(domain.keys),
                Set([
                    UpdateSettingKeys.ignoredVersion(for: .desktopApp),
                    UpdateSettingKeys.ignoredVersionAt(for: .desktopApp)
                ])
            )
        }
    }

    func testIgnoredVersionsRejectInvalidValuesWithDiagnostics() {
        withIsolatedDefaults { defaults, _ in
            defaults.set("not-a-version", forKey: UpdateSettingKeys.ignoredVersion(for: .piCLI))
            defaults.set("yesterday", forKey: UpdateSettingKeys.ignoredVersionAt(for: .piCLI))
            defaults.set("2.0.0", forKey: UpdateSettingKeys.ignoredVersion(for: .piWeb))
            defaults.set("yesterday", forKey: UpdateSettingKeys.ignoredVersionAt(for: .piWeb))

            var diagnostics: [String] = []
            let loaded = UpdateIgnoredVersions.load(from: defaults) { diagnostics.append($0) }

            XCTAssertNil(loaded.ignored(for: .piCLI))
            XCTAssertEqual(loaded.ignored(for: .piWeb)?.version, "2.0.0")
            XCTAssertNil(loaded.ignored(for: .piWeb)?.ignoredAt)
            XCTAssertEqual(diagnostics.count, 2)
        }
    }

    func testIgnoringAcceptsOnlyComparableVersionsAndCanBeCleared() {
        var ignored = UpdateIgnoredVersions.empty
        ignored.ignore("not-a-version", for: .desktopApp, at: referenceDate)
        XCTAssertNil(ignored.ignored(for: .desktopApp))

        ignored.ignore("2.0.0", for: .desktopApp, at: referenceDate)
        XCTAssertTrue(ignored.isIgnored("2.0.0", for: .desktopApp))
        ignored.clear(.desktopApp)
        XCTAssertNil(ignored.ignored(for: .desktopApp))
    }

    // MARK: - 间隔与状态

    func testIntervalsMapPoliciesAndTreatOffAsNoSchedule() {
        let intervals = UpdateCheckIntervals(daily: 10, weekly: 20, packageCheck: 30)

        XCTAssertNil(intervals.interval(for: UpdateCheckPolicy.off))
        XCTAssertEqual(intervals.interval(for: .daily), 10)
        XCTAssertEqual(intervals.interval(for: .weekly), 20)
        XCTAssertEqual(intervals.interval(for: .checkAndNotify), 30)
        XCTAssertEqual(intervals.interval(for: .askBeforeUpdate), 30)
        XCTAssertNil(intervals.interval(for: .piPackages, policy: .off))
        // 缓存 TTL 用该分类的出厂默认策略。
        XCTAssertEqual(intervals.ttl(for: .desktopApp), 10)
        XCTAssertEqual(intervals.ttl(for: .piPackages), 30)
    }

    func testCategoryStatusBuilderShowsLastCheckResultIgnoredAndNextCheck() {
        let lastAttempt = referenceDate
        var cache = UpdateCheckCacheFile()
        cache.upsert(cacheEntry(
            category: .desktopApp,
            latestVersion: "2.4.1-alpha.2",
            status: .updateAvailable,
            installedVersion: "2.4.0",
            lastAttemptAt: lastAttempt,
            lastSuccessAt: lastAttempt
        ))
        var ignored = UpdateIgnoredVersions.empty
        ignored.ignore("2.4.1-alpha.2", for: .desktopApp, at: lastAttempt)

        let statuses = UpdateCategoryStatusBuilder.statuses(
            preferences: .factoryDefaults,
            intervals: UpdateCheckIntervals(daily: 10, weekly: 20, packageCheck: 30),
            cache: cache,
            ignoredVersions: ignored
        )

        let desktop = statuses.first { $0.category == .desktopApp }
        XCTAssertEqual(desktop?.status, .updateAvailable)
        XCTAssertEqual(desktop?.latestVersion, "2.4.1-alpha.2")
        XCTAssertEqual(desktop?.lastAttemptAt, lastAttempt)
        XCTAssertEqual(desktop?.nextCheckAt, lastAttempt.addingTimeInterval(10))
        XCTAssertEqual(desktop?.ignoredVersion, "2.4.1-alpha.2")
        XCTAssertEqual(desktop?.resultTitle, "可更新 2.4.1-alpha.2（已忽略此版本）")

        let piCLI = statuses.first { $0.category == .piCLI }
        XCTAssertNil(piCLI?.status)
        XCTAssertNil(piCLI?.nextCheckAt)
        XCTAssertEqual(piCLI?.resultTitle, "尚未检查")

        let line = UpdateStatusPresenter.line(
            for: piCLI ?? UpdateCategoryStatus(category: .piCLI),
            policy: .daily,
            format: fixedFormat
        )
        XCTAssertTrue(line.contains("最近检查：尚未检查"))
        XCTAssertTrue(line.contains("被忽略版本：无"))
        XCTAssertTrue(line.contains("下次检查：—"))
    }

    /// 没有本次结果时也不能沿用缓存里的旧结论（GitHub #74）：用条目记录的
    /// 本机版本现算；缺 `installedVersion` 时降级为“尚未判定”，不猜。
    func testCategoryStatusBuilderRecomputesCachedStatusForRecordedInstalledVersion() {
        var cache = UpdateCheckCacheFile()
        cache.upsert(cacheEntry(
            category: .desktopApp,
            latestVersion: "2.4.1-alpha.2",
            status: .upToDate,
            installedVersion: "2.4.0",
            lastAttemptAt: referenceDate,
            lastSuccessAt: referenceDate
        ))

        let statuses = UpdateCategoryStatusBuilder.statuses(
            preferences: .factoryDefaults,
            intervals: .standard,
            cache: cache,
            ignoredVersions: .empty
        )

        let desktop = statuses.first { $0.category == .desktopApp }
        XCTAssertEqual(desktop?.status, .updateAvailable)
        XCTAssertEqual(desktop?.latestVersion, "2.4.1-alpha.2")
        XCTAssertEqual(desktop?.resultTitle, "可更新 2.4.1-alpha.2")
        XCTAssertEqual(desktop?.origin, .cachedFallback)

        var legacy = UpdateCheckCacheFile()
        legacy.upsert(cacheEntry(
            category: .desktopApp,
            latestVersion: "2.4.1-alpha.2",
            status: .updateAvailable,
            lastAttemptAt: referenceDate,
            lastSuccessAt: referenceDate
        ))
        let legacyStatuses = UpdateCategoryStatusBuilder.statuses(
            preferences: .factoryDefaults,
            intervals: .standard,
            cache: legacy,
            ignoredVersions: .empty
        )
        let legacyDesktop = legacyStatuses.first { $0.category == .desktopApp }
        XCTAssertEqual(legacyDesktop?.status, .unknown)
        XCTAssertEqual(legacyDesktop?.resultTitle, "未知")
        XCTAssertFalse(legacyDesktop?.resultTitle.contains("可更新") ?? true)
    }

    func testCategoryStatusShowsFailureAndOffPolicy() {
        var preferences = UpdateCheckPreferences.factoryDefaults
        preferences.setPolicy(.off, for: .piPackages)
        let failed = result(category: .piPackages, packageName: "demo", status: .unknown, installed: "1.0.0", failure: .offline)

        let statuses = UpdateCategoryStatusBuilder.statuses(
            preferences: preferences,
            intervals: .standard,
            cache: .empty,
            ignoredVersions: .empty,
            results: [failed]
        )

        let packages = statuses.first { $0.category == .piPackages }
        XCTAssertEqual(packages?.status, .unknown)
        XCTAssertEqual(packages?.failure, .offline)
        XCTAssertEqual(packages?.resultTitle, "失败")
        XCTAssertNil(packages?.nextCheckAt)

        let line = UpdateStatusPresenter.line(
            for: packages ?? UpdateCategoryStatus(category: .piPackages),
            policy: .off,
            format: fixedFormat
        )
        XCTAssertTrue(line.contains("策略：关闭"))
        XCTAssertTrue(line.contains("结果：失败（网络不可用）"))
        XCTAssertTrue(line.contains("下次检查：已关闭"))
    }

    /// 缓存回退的状态必须标注来源与缓存写入时间：界面与诊断不能把“上次检查
    /// 结果显示有更新”读成本次已验证（GitHub #59）。
    func testCategoryStatusAnnotatesCacheOriginWithWriteTime() {
        let cachedAt = referenceDate.addingTimeInterval(-3600)
        let cached = result(
            category: .piWeb,
            status: .updateAvailable,
            installed: "0.9.0",
            latest: "0.9.2",
            origin: .cachedFallback,
            cacheWrittenAt: cachedAt
        )

        let statuses = UpdateCategoryStatusBuilder.statuses(
            preferences: .factoryDefaults,
            intervals: .standard,
            cache: .empty,
            ignoredVersions: .empty,
            results: [cached]
        )
        let piWeb = statuses.first { $0.category == .piWeb }
        XCTAssertEqual(piWeb?.status, .updateAvailable)
        XCTAssertEqual(piWeb?.latestVersion, "0.9.2")
        XCTAssertEqual(piWeb?.origin, .cachedFallback)
        XCTAssertEqual(piWeb?.cacheWrittenAt, cachedAt)

        let line = UpdateStatusPresenter.line(
            for: piWeb ?? UpdateCategoryStatus(category: .piWeb),
            policy: .daily,
            format: fixedFormat
        )
        XCTAssertTrue(line.contains("结果：可更新 0.9.2"))
        XCTAssertTrue(line.contains("来源：本机缓存"))
        XCTAssertTrue(line.contains(fixedFormat(cachedAt)))
        XCTAssertFalse(line.contains("已验证"))
    }

    /// 本次网络结果不产生缓存来源标注。
    func testCategoryStatusOmitsCacheAnnotationForNetworkOrigin() {
        let fresh = result(
            category: .piWeb,
            status: .updateAvailable,
            installed: "0.9.0",
            latest: "0.9.2",
            origin: .network
        )
        let statuses = UpdateCategoryStatusBuilder.statuses(
            preferences: .factoryDefaults,
            intervals: .standard,
            cache: .empty,
            ignoredVersions: .empty,
            results: [fresh]
        )
        let line = UpdateStatusPresenter.line(
            for: statuses.first { $0.category == .piWeb } ?? UpdateCategoryStatus(category: .piWeb),
            policy: .daily,
            format: fixedFormat
        )
        XCTAssertFalse(line.contains("本机缓存"))
    }

    func testCategoryStatusBuilderPrefersAvailableUpdateAcrossPackages() {
        let results = [
            result(category: .piPackages, packageName: "a", status: .upToDate, installed: "1.0.0", latest: "1.0.0"),
            result(category: .piPackages, packageName: "b", status: .unknown, installed: "1.0.0", failure: .offline),
            result(category: .piPackages, packageName: "c", status: .updateAvailable, installed: "1.0.0", latest: "2.0.0")
        ]

        let statuses = UpdateCategoryStatusBuilder.statuses(
            preferences: .factoryDefaults,
            intervals: .standard,
            cache: .empty,
            ignoredVersions: .empty,
            results: results
        )

        let packages = statuses.first { $0.category == .piPackages }
        XCTAssertEqual(packages?.status, .updateAvailable)
        XCTAssertEqual(packages?.latestVersion, "2.0.0")
        XCTAssertEqual(packages?.installedVersion, "1.0.0")
    }

    // MARK: - 通知判定与文案

    func testNotificationPlannerRespectsIgnoreAndNotifyOnce() {
        let entries = [result(category: .piWeb, status: .updateAvailable, installed: "0.9.0", latest: "2.0.0")]

        let planned = UpdateNotificationPlanner.plan(
            results: entries,
            preferences: .factoryDefaults,
            ignoredVersions: .empty,
            alreadyNotified: [:]
        )
        XCTAssertEqual(planned.count, 1)
        XCTAssertEqual(planned.first?.target.category, .piWeb)
        XCTAssertEqual(planned.first?.latestVersion, "2.0.0")
        XCTAssertEqual(planned.first?.policy, .daily)

        // 同一个版本在本次运行里不重复提示。
        XCTAssertTrue(UpdateNotificationPlanner.plan(
            results: entries,
            preferences: .factoryDefaults,
            ignoredVersions: .empty,
            alreadyNotified: [.piWeb: "2.0.0"]
        ).isEmpty)

        // 忽略当前版本后不再提示；忽略的是另一个版本时不影响。
        var ignored = UpdateIgnoredVersions.empty
        ignored.ignore("2.0.0", for: .piWeb, at: referenceDate)
        XCTAssertTrue(UpdateNotificationPlanner.plan(
            results: entries,
            preferences: .factoryDefaults,
            ignoredVersions: ignored,
            alreadyNotified: [:]
        ).isEmpty)

        var otherIgnored = UpdateIgnoredVersions.empty
        otherIgnored.ignore("1.5.0", for: .piWeb, at: referenceDate)
        XCTAssertEqual(UpdateNotificationPlanner.plan(
            results: entries,
            preferences: .factoryDefaults,
            ignoredVersions: otherIgnored,
            alreadyNotified: [:]
        ).count, 1)

        // 上游出现更高版本后重新提示。
        let newer = [result(category: .piWeb, status: .updateAvailable, installed: "0.9.0", latest: "2.1.0")]
        XCTAssertEqual(UpdateNotificationPlanner.plan(
            results: newer,
            preferences: .factoryDefaults,
            ignoredVersions: ignored,
            alreadyNotified: [.piWeb: "2.0.0"]
        ).count, 1)
    }

    func testNotificationPlannerSkipsDisabledCategoriesAndNonUpdates() {
        let offPreferences: UpdateCheckPreferences = {
            var preferences = UpdateCheckPreferences.factoryDefaults
            preferences.setPolicy(.off, for: .piWeb)
            return preferences
        }()
        let entries = [result(category: .piWeb, status: .updateAvailable, installed: "0.9.0", latest: "2.0.0")]

        XCTAssertTrue(UpdateNotificationPlanner.plan(
            results: entries,
            preferences: offPreferences,
            ignoredVersions: .empty,
            alreadyNotified: [:]
        ).isEmpty)

        let upToDate = [result(category: .piWeb, status: .upToDate, installed: "2.0.0", latest: "2.0.0")]
        XCTAssertTrue(UpdateNotificationPlanner.plan(
            results: upToDate,
            preferences: .factoryDefaults,
            ignoredVersions: .empty,
            alreadyNotified: [:]
        ).isEmpty)

        let unknown = [result(category: .piWeb, status: .unknown, installed: "2.0.0", failure: .offline)]
        XCTAssertTrue(UpdateNotificationPlanner.plan(
            results: unknown,
            preferences: .factoryDefaults,
            ignoredVersions: .empty,
            alreadyNotified: [:]
        ).isEmpty)
    }

    func testNotificationTextUsesAskForPackagesAndNeverLeaksPathsOrCredentials() {
        let packages = result(
            category: .piPackages,
            packageName: "pi-extension-demo",
            status: .updateAvailable,
            installed: "1.0.0",
            latest: "2.0.0"
        )
        var preferences = UpdateCheckPreferences.factoryDefaults
        preferences.setPolicy(.askBeforeUpdate, for: .piPackages)
        let entries = UpdateNotificationPlanner.plan(
            results: [packages],
            preferences: preferences,
            ignoredVersions: .empty,
            alreadyNotified: [:]
        )
        XCTAssertEqual(entries.first?.policy, .askBeforeUpdate)

        let text = UpdateNotificationText.title(for: entries) + "\n" + UpdateNotificationText.body(for: entries)
        XCTAssertTrue(text.contains("无人值守"))
        XCTAssertTrue(text.contains("确认"))
        for forbidden in ["/", "~", "password", "token", "secret", "Bearer", "http", "Keychain"] {
            XCTAssertFalse(text.contains(forbidden), "提示内容不应包含 \(forbidden)")
        }
    }

    func testDisclosureTextDocumentsPoliciesIgnoreAndAutoUpdateScope() {
        let text = UpdateCheckDisclosure.text(cachePath: "~/Library/Application Support/Pi Web Desktop/update-check-cache.json")

        XCTAssertTrue(text.contains("每日"))
        XCTAssertTrue(text.contains("每周"))
        XCTAssertTrue(text.contains("检查并通知"))
        XCTAssertTrue(text.contains("询问后更新"))
        XCTAssertTrue(text.contains("忽略"))
        XCTAssertTrue(text.contains("启动前自动更新"))
        XCTAssertTrue(text.contains("npm 全局"))
        XCTAssertTrue(text.contains("不调用 sudo"))
        XCTAssertTrue(text.contains("不承诺所有来源都能回滚"))
        XCTAssertTrue(text.contains("系统通知中心"))
        XCTAssertTrue(text.contains("24 小时"))
        XCTAssertTrue(text.contains("7 天"))
        XCTAssertTrue(text.contains("不下载、不安装"))
        XCTAssertTrue(text.contains(UpdateCheckUpstream.githubHost))
        XCTAssertTrue(text.contains(UpdateCheckUpstream.npmRegistryHost))
    }

    // MARK: - AppConfiguration 接线

    func testAppConfigurationRoundTripsUpdateSettingsThroughInjectedDefaults() {
        withIsolatedDefaults { defaults, _ in
            let configuration = AppConfiguration(
                supportURL: FileManager.default.temporaryDirectory.appendingPathComponent("pi-web-desktop-tests-support", isDirectory: true),
                logsRootURL: FileManager.default.temporaryDirectory.appendingPathComponent("pi-web-desktop-tests-logs", isDirectory: true),
                defaults: defaults
            )

            XCTAssertEqual(configuration.updateCheckPreferences(), .factoryDefaults)
            XCTAssertEqual(configuration.updateCheckIgnoredVersions(), .empty)

            var preferences = UpdateCheckPreferences.factoryDefaults
            preferences.setPolicy(.weekly, for: .piCLI)
            preferences.autoUpdatePiWebBeforeLaunch = true
            configuration.save(preferences)

            var ignored = UpdateIgnoredVersions.empty
            ignored.ignore("1.2.3", for: .piCLI, at: referenceDate)
            configuration.save(ignored)

            XCTAssertEqual(configuration.updateCheckPreferences(), preferences)
            XCTAssertEqual(configuration.updateCheckIgnoredVersions().ignored(for: .piCLI)?.version, "1.2.3")
        }
    }
}
