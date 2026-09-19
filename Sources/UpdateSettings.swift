import CoreFoundation
import Foundation

// MARK: - 检查策略（GitHub #18）

/// 一类组件的更新检查策略。
///
/// 桌面应用 / Pi CLI / Pi Web 只允许 `off` / `daily` / `weekly`；Pi 扩展包只允许
/// `off` / `checkAndNotify` / `askBeforeUpdate`。允许集合只有 `allowed(for:)`
/// 一份定义，界面选项、写入校验与 UserDefaults 迁移都读它。
enum UpdateCheckPolicy: String, CaseIterable, Equatable {
    /// 关闭：不调度、不请求、不提示。
    case off
    /// 每日复查。
    case daily
    /// 每周复查。
    case weekly
    /// 扩展包默认：按 7 天节奏复查，发现可用更新时提示。
    case checkAndNotify = "check-and-notify"
    /// 扩展包：按 7 天节奏复查，发现可用更新时询问用户；安装流程见后续版本。
    case askBeforeUpdate = "ask-before-update"

    var title: String {
        switch self {
        case .off: return "关闭"
        case .daily: return "每日"
        case .weekly: return "每周"
        case .checkAndNotify: return "检查并通知"
        case .askBeforeUpdate: return "询问后更新"
        }
    }

    var isEnabled: Bool { self != .off }

    /// 该分类允许的策略。界面只展示这一组，`setPolicy` 也只接受这一组。
    static func allowed(for category: UpdateCheckCategory) -> [UpdateCheckPolicy] {
        switch category {
        case .desktopApp, .piCLI, .piWeb:
            return [.off, .daily, .weekly]
        case .piPackages:
            return [.off, .checkAndNotify, .askBeforeUpdate]
        }
    }

    /// 出厂默认策略；与 `docs/privacy.md` / `docs/releasing.md` 的默认值一致。
    static func defaultValue(for category: UpdateCheckCategory) -> UpdateCheckPolicy {
        switch category {
        case .desktopApp, .piCLI, .piWeb:
            return .daily
        case .piPackages:
            return .checkAndNotify
        }
    }

    func isAllowed(for category: UpdateCheckCategory) -> Bool {
        Self.allowed(for: category).contains(self)
    }
}

// MARK: - UserDefaults 键

/// 更新检查设置使用的全部 UserDefaults 键（GitHub #18）。
///
/// 键名分三层：`updateChecks.<组件>.policy`（新，策略字符串）、
/// `updateChecks.<组件>.enabled`（GitHub #17 的旧开关，只读兼容）、
/// `updateChecks.<组件>.ignoredVersion` / `.ignoredVersionAt`（忽略版本）。
/// 这里不定义任何其它键：设置里不会出现路径、包名、来源或凭据。
enum UpdateSettingKeys {
    /// 启动前自动更新 Pi Web（GitHub #20）。
    static let autoUpdatePiWebBeforeLaunch = "updateChecks.piWeb.autoUpdateBeforeLaunch"

    /// 最近一次失败的受限自动更新的持久记录（GitHub #20）。只含类别、旧/新/目标
    /// 版本、固定原因文案与时间戳；不含路径、环境变量值、凭据或子进程输出。
    static let piWebUpdateWarningKind = "updateChecks.piWeb.lastUpdateWarning.kind"
    static let piWebUpdateWarningOldVersion = "updateChecks.piWeb.lastUpdateWarning.oldVersion"
    static let piWebUpdateWarningNewVersion = "updateChecks.piWeb.lastUpdateWarning.newVersion"
    static let piWebUpdateWarningTargetVersion = "updateChecks.piWeb.lastUpdateWarning.targetVersion"
    static let piWebUpdateWarningReason = "updateChecks.piWeb.lastUpdateWarning.reason"
    static let piWebUpdateWarningRecordedAt = "updateChecks.piWeb.lastUpdateWarning.recordedAt"

    static var allPiWebUpdateWarningKeys: [String] {
        [
            piWebUpdateWarningKind,
            piWebUpdateWarningOldVersion,
            piWebUpdateWarningNewVersion,
            piWebUpdateWarningTargetVersion,
            piWebUpdateWarningReason,
            piWebUpdateWarningRecordedAt
        ]
    }

    static func stem(for category: UpdateCheckCategory) -> String {
        switch category {
        case .desktopApp: return "updateChecks.desktopApp"
        case .piCLI: return "updateChecks.pi"
        case .piWeb: return "updateChecks.piWeb"
        case .piPackages: return "updateChecks.piPackages"
        }
    }

    static func policy(for category: UpdateCheckCategory) -> String { stem(for: category) + ".policy" }
    /// GitHub #17 写入的布尔开关；只用于迁移读取。
    static func legacyEnabled(for category: UpdateCheckCategory) -> String { stem(for: category) + ".enabled" }
    static func ignoredVersion(for category: UpdateCheckCategory) -> String { stem(for: category) + ".ignoredVersion" }
    static func ignoredVersionAt(for category: UpdateCheckCategory) -> String { stem(for: category) + ".ignoredVersionAt" }

    static var allPreferencesKeys: [String] {
        writtenPreferencesKeys + legacyPreferenceKeys
    }

    /// `UpdateCheckPreferences.save` 实际写入的键（策略 + 启动前自动更新开关）。
    static var writtenPreferencesKeys: [String] {
        UpdateCheckCategory.allCases.map { policy(for: $0) } + [autoUpdatePiWebBeforeLaunch]
    }

    /// GitHub #17 的旧布尔键：只读兼容，保存新设置时删除。
    static var legacyPreferenceKeys: [String] {
        UpdateCheckCategory.allCases.map { legacyEnabled(for: $0) }
    }

    static var allIgnoredVersionKeys: [String] {
        UpdateCheckCategory.allCases.flatMap { [ignoredVersion(for: $0), ignoredVersionAt(for: $0)] }
    }

    /// 更新检查会写入的全部键（测试用它断言 UserDefaults 里没有额外数据）。
    /// 警告键由 `PiWebUpdateWarningStore` 单独读写：保存策略不会清掉警告。
    static var allKeys: [String] { allPreferencesKeys + allIgnoredVersionKeys + allPiWebUpdateWarningKeys }
}

// MARK: - 设置模型

/// 四类组件的更新检查设置（GitHub #18）。
///
/// 默认值与文档一致：桌面应用 / Pi CLI / Pi Web 每日，Pi 扩展包检查并通知；
/// 启动前自动更新 Pi Web 默认关闭（GitHub #20 起生效，但只对已验证的 npm
/// 全局安装生效）。该结构只包含策略与一个布尔值，
/// 不包含版本、路径、来源或任何凭据。
struct UpdateCheckPreferences: Equatable {
    /// 设置位已生效（GitHub #20）：打开它只对“来源为已验证的 npm 全局安装”的
    /// Pi Web 启用启动前受限自动安装；其它来源仍只显示命令，绝不自动安装。
    static let autoUpdateBeforeLaunchIsEffective = true
    static let defaultAutoUpdatePiWebBeforeLaunch = false

    /// 四类组件各自的策略。字典始终包含 `UpdateCheckCategory.allCases`，
    /// 不合法的组合在写入时被拒绝（`setPolicy`）。
    private(set) var policies: [UpdateCheckCategory: UpdateCheckPolicy]

    /// alpha.3 预留：启动前自动更新（Pi Web 范围）。alpha.2 只保存值。
    var autoUpdatePiWebBeforeLaunch: Bool

    init(
        policies: [UpdateCheckCategory: UpdateCheckPolicy] = [:],
        autoUpdatePiWebBeforeLaunch: Bool = UpdateCheckPreferences.defaultAutoUpdatePiWebBeforeLaunch
    ) {
        var normalized: [UpdateCheckCategory: UpdateCheckPolicy] = [:]
        for category in UpdateCheckCategory.allCases {
            let requested = policies[category]
            normalized[category] = requested.flatMap { $0.isAllowed(for: category) ? $0 : nil }
                ?? Self.defaultPolicy(for: category)
        }
        self.policies = normalized
        self.autoUpdatePiWebBeforeLaunch = autoUpdatePiWebBeforeLaunch
    }

    /// 出厂默认设置。
    static let factoryDefaults = UpdateCheckPreferences()

    static func defaultPolicy(for category: UpdateCheckCategory) -> UpdateCheckPolicy {
        UpdateCheckPolicy.defaultValue(for: category)
    }

    func policy(for category: UpdateCheckCategory) -> UpdateCheckPolicy {
        policies[category] ?? Self.defaultPolicy(for: category)
    }

    func isEnabled(_ category: UpdateCheckCategory) -> Bool { policy(for: category).isEnabled }

    /// 菜单快捷开关语义：打开 = 该分类的默认策略，关闭 = `off`。
    /// 完整策略（每日 / 每周 / 询问后更新）在“更新检查偏好设置”窗口里选择。
    mutating func setEnabled(_ enabled: Bool, for category: UpdateCheckCategory) {
        setPolicy(enabled ? Self.defaultPolicy(for: category) : .off, for: category)
    }

    /// 写入策略；组合不属于该分类时拒绝写入并返回 false。
    @discardableResult
    mutating func setPolicy(_ policy: UpdateCheckPolicy, for category: UpdateCheckCategory) -> Bool {
        guard policy.isAllowed(for: category) else { return false }
        policies[category] = policy
        return true
    }

    var enabledCategories: [UpdateCheckCategory] {
        UpdateCheckCategory.allCases.filter { isEnabled($0) }
    }

    var allDisabled: Bool { enabledCategories.isEmpty }

    // MARK: 读写

    static func load(
        from defaults: UserDefaults,
        diagnostics: ((String) -> Void)? = nil
    ) -> UpdateCheckPreferences {
        var values: [String: Any] = [:]
        for key in UpdateSettingKeys.allPreferencesKeys {
            if let value = defaults.object(forKey: key) { values[key] = value }
        }
        return UpdateCheckSettingsMigration.resolve(values: values, report: diagnostics).preferences
    }

    /// 写入策略；旧版（GitHub #17）的布尔键同时删除，避免两套值并存。
    func save(to defaults: UserDefaults) {
        for category in UpdateCheckCategory.allCases {
            defaults.set(policy(for: category).rawValue, forKey: UpdateSettingKeys.policy(for: category))
            defaults.removeObject(forKey: UpdateSettingKeys.legacyEnabled(for: category))
        }
        defaults.set(autoUpdatePiWebBeforeLaunch, forKey: UpdateSettingKeys.autoUpdatePiWebBeforeLaunch)
    }
}

// MARK: - 迁移

/// 设置读取与迁移（GitHub #18 第 5 项）。
///
/// 纯函数：输入是“键 → UserDefaults 原始值”的字典（缺键 = 不在字典里），输出是
/// 规范化设置 + 诊断行。因此迁移可以直接用字典断言，不写任何东西到真实
/// UserDefaults。
///
/// 规则：
/// - 新键存在且是合法策略字符串 → 使用；
/// - 新键存在但值无法识别（旧版本写下的未知值、错误类型、越界策略）→ 该分类
///   回退到出厂默认，并记录一条诊断；
/// - 新键缺失、旧布尔键存在 → `true` = 默认策略，`false` = 关闭；旧键不是布尔
///   （例如整数或字符串）同样按默认处理并记录诊断；
/// - 两个键都缺失 → 出厂默认（升级与首次启动都走这条）；
/// - 预留设置位只接受布尔值，其它类型回退“关闭”并记录诊断。
///
/// 诊断行只包含键名与结论，不回显原始值，避免把用户数据带进日志。
enum UpdateCheckSettingsMigration {
    struct Outcome: Equatable {
        var preferences: UpdateCheckPreferences
        var diagnostics: [String]
    }

    static func resolve(values: [String: Any], report: ((String) -> Void)? = nil) -> Outcome {
        var preferences = UpdateCheckPreferences()
        var diagnostics: [String] = []

        func note(_ key: String, _ conclusion: String) {
            diagnostics.append("更新检查设置：\(key) 的值无法识别，\(conclusion)。")
        }

        for category in UpdateCheckCategory.allCases {
            let policyKey = UpdateSettingKeys.policy(for: category)
            if let raw = values[policyKey] {
                if let text = raw as? String,
                   let policy = UpdateCheckPolicy(rawValue: text),
                   policy.isAllowed(for: category) {
                    preferences.setPolicy(policy, for: category)
                } else {
                    note(policyKey, "已回退到默认策略 \(Self.defaultPolicy(for: category).title)")
                }
                continue
            }
            let legacyKey = UpdateSettingKeys.legacyEnabled(for: category)
            if let raw = values[legacyKey] {
                if let enabled = booleanValue(raw) {
                    preferences.setPolicy(
                        enabled ? Self.defaultPolicy(for: category) : .off,
                        for: category
                    )
                } else {
                    note(legacyKey, "已按默认策略 \(Self.defaultPolicy(for: category).title) 处理")
                }
            }
        }

        if let raw = values[UpdateSettingKeys.autoUpdatePiWebBeforeLaunch] {
            if let enabled = booleanValue(raw) {
                preferences.autoUpdatePiWebBeforeLaunch = enabled
            } else {
                note(UpdateSettingKeys.autoUpdatePiWebBeforeLaunch, "已回退到关闭")
            }
        }

        for line in diagnostics { report?(line) }
        return Outcome(preferences: preferences, diagnostics: diagnostics)
    }

    private static func defaultPolicy(for category: UpdateCheckCategory) -> UpdateCheckPolicy {
        UpdateCheckPreferences.defaultPolicy(for: category)
    }

    /// 只有真正的布尔值算布尔。`UserDefaults` 会把整数 1/0 也桥接成 `Bool`，
    /// 这里用 `CFBoolean` 类型判定区分，未知类型一律返回 nil（回退默认）。
    static func booleanValue(_ value: Any) -> Bool? {
        guard let number = value as? NSNumber else { return value as? Bool }
        return CFGetTypeID(number) == CFBooleanGetTypeID() ? number.boolValue : nil
    }
}

// MARK: - 忽略版本

/// 一个被用户忽略的版本。
///
/// 只保存版本字符串与忽略时间：不含组件来源、安装路径、包名或其它身份信息，
/// 因此同一个版本无论来自 npm、Homebrew 还是本地路径，忽略语义都相同。
struct UpdateIgnoredVersion: Equatable {
    var version: String
    var ignoredAt: Date?
}

/// 四类组件各自的“忽略版本”记录（GitHub #18 第 2 项）。
///
/// 忽略只抑制这一个具体版本：上游出现更高版本时重新提示。应用不实现任意版本
/// 锁定，也不实现降级；清除忽略只需删除对应键或在界面里重新检查。
struct UpdateIgnoredVersions: Equatable {
    private(set) var entries: [UpdateCheckCategory: UpdateIgnoredVersion]

    init(entries: [UpdateCheckCategory: UpdateIgnoredVersion] = [:]) {
        var filtered: [UpdateCheckCategory: UpdateIgnoredVersion] = [:]
        for (category, entry) in entries where SemanticVersion(entry.version) != nil {
            filtered[category] = UpdateIgnoredVersion(version: entry.version, ignoredAt: entry.ignoredAt)
        }
        self.entries = filtered
    }

    static let empty = UpdateIgnoredVersions()

    func ignored(for category: UpdateCheckCategory) -> UpdateIgnoredVersion? { entries[category] }

    func isIgnored(_ version: String, for category: UpdateCheckCategory) -> Bool {
        entries[category]?.version == version
    }

    /// 记录忽略。无法解析为语义化版本的字符串不会被写入。
    mutating func ignore(_ version: String, for category: UpdateCheckCategory, at date: Date) {
        guard SemanticVersion(version) != nil else { return }
        entries[category] = UpdateIgnoredVersion(version: version, ignoredAt: date)
    }

    mutating func clear(_ category: UpdateCheckCategory) {
        entries[category] = nil
    }

    static func load(
        from defaults: UserDefaults,
        diagnostics: ((String) -> Void)? = nil
    ) -> UpdateIgnoredVersions {
        var entries: [UpdateCheckCategory: UpdateIgnoredVersion] = [:]
        for category in UpdateCheckCategory.allCases {
            let versionKey = UpdateSettingKeys.ignoredVersion(for: category)
            guard let raw = defaults.object(forKey: versionKey) else { continue }
            guard let text = raw as? String, SemanticVersion(text) != nil else {
                diagnostics?("更新检查设置：\(versionKey) 不是可比较的版本字符串，已忽略这条忽略记录。")
                continue
            }
            let atKey = UpdateSettingKeys.ignoredVersionAt(for: category)
            if defaults.object(forKey: atKey) != nil, timestamp(defaults.object(forKey: atKey)) == nil {
                diagnostics?("更新检查设置：\(atKey) 的时间戳无法识别，已保留忽略版本但丢弃时间。")
            }
            entries[category] = UpdateIgnoredVersion(
                version: text,
                ignoredAt: timestamp(defaults.object(forKey: atKey))
            )
        }
        return UpdateIgnoredVersions(entries: entries)
    }

    func save(to defaults: UserDefaults) {
        for category in UpdateCheckCategory.allCases {
            let versionKey = UpdateSettingKeys.ignoredVersion(for: category)
            let atKey = UpdateSettingKeys.ignoredVersionAt(for: category)
            guard let entry = entries[category] else {
                defaults.removeObject(forKey: versionKey)
                defaults.removeObject(forKey: atKey)
                continue
            }
            defaults.set(entry.version, forKey: versionKey)
            if let ignoredAt = entry.ignoredAt {
                defaults.set(ignoredAt.timeIntervalSince1970, forKey: atKey)
            } else {
                defaults.removeObject(forKey: atKey)
            }
        }
    }

    /// 时间戳接受 `Date` 或 Unix 秒（数值）；其它类型返回 nil。
    static func timestamp(_ value: Any?) -> Date? {
        if let date = value as? Date { return date }
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return Date(timeIntervalSince1970: number.doubleValue)
    }
}

// MARK: - 复查间隔

/// 策略对应的复查间隔（秒）。
///
/// 默认值与默认策略一致：每日 = 24 小时、每周 = 7 天、扩展包 = 7 天。测试注入
/// 更短的值并用假时钟推进，不需要 sleep。
struct UpdateCheckIntervals: Equatable {
    static let day: TimeInterval = 24 * 60 * 60
    static let week: TimeInterval = 7 * 24 * 60 * 60

    var daily: TimeInterval
    var weekly: TimeInterval
    var packageCheck: TimeInterval

    init(
        daily: TimeInterval = UpdateCheckIntervals.day,
        weekly: TimeInterval = UpdateCheckIntervals.week,
        packageCheck: TimeInterval = UpdateCheckIntervals.week
    ) {
        self.daily = daily
        self.weekly = weekly
        self.packageCheck = packageCheck
    }

    static let standard = UpdateCheckIntervals()

    /// 策略对应的间隔；`off` 返回 nil（不调度、不请求）。
    func interval(for policy: UpdateCheckPolicy) -> TimeInterval? {
        switch policy {
        case .off: return nil
        case .daily: return daily
        case .weekly: return weekly
        case .checkAndNotify, .askBeforeUpdate: return packageCheck
        }
    }

    func interval(for category: UpdateCheckCategory, policy: UpdateCheckPolicy) -> TimeInterval? {
        interval(for: policy)
    }

    /// 缓存 TTL 使用该分类的默认策略间隔（与当前策略无关，避免关闭后旧缓存
    /// 立刻失效导致界面跳变）。
    func ttl(for category: UpdateCheckCategory) -> TimeInterval {
        interval(for: UpdateCheckPreferences.defaultPolicy(for: category)) ?? daily
    }
}

// MARK: - 每类组件的状态

/// 一类组件的检查状态快照（诊断页与偏好窗口共用）。
struct UpdateCategoryStatus: Equatable {
    var category: UpdateCheckCategory
    /// 最近一次实际发起请求的时间（nil = 本次运行与缓存里都没有检查记录）。
    var lastAttemptAt: Date?
    var lastSuccessAt: Date?
    /// nil = 尚未检查。
    var status: UpdateCheckStatus?
    var failure: UpdateCheckFailure?
    var installedVersion: String?
    var latestVersion: String?
    /// 用户为该分类记录的被忽略版本（可能已经低于上游最新版本）。
    var ignoredVersion: String?
    /// 下一次检查时间；关闭或尚未检查时为 nil。
    var nextCheckAt: Date?

    /// 结果文案：最新 / 可更新 / 未知 / 失败 / 尚未检查。
    var resultTitle: String {
        guard let status else { return "尚未检查" }
        switch status {
        case .upToDate:
            return "最新"
        case .updateAvailable:
            let base = latestVersion.map { "可更新 \($0)" } ?? "可更新"
            if let latestVersion, ignoredVersion == latestVersion {
                return base + "（已忽略此版本）"
            }
            return base
        case .unknown:
            return failure == nil ? "未知" : "失败"
        }
    }
}

/// 状态快照与文案的纯函数集合。
///
/// 输入全部来自注入的缓存、运行时结果与设置，因此 unhosted 测试可以用固定
/// 时间与固定格式化闭包断言，不依赖真实 UserDefaults、网络或界面。
enum UpdateCategoryStatusBuilder {
    /// 四类组件的状态；顺序与 `UpdateCheckCategory.allCases` 一致。
    static func statuses(
        preferences: UpdateCheckPreferences,
        intervals: UpdateCheckIntervals,
        cache: UpdateCheckCacheFile,
        ignoredVersions: UpdateIgnoredVersions,
        results: [UpdateCheckResult] = []
    ) -> [UpdateCategoryStatus] {
        UpdateCheckCategory.allCases.map { category in
            status(
                for: category,
                preferences: preferences,
                intervals: intervals,
                cache: cache,
                ignoredVersions: ignoredVersions,
                results: results
            )
        }
    }

    private static func status(
        for category: UpdateCheckCategory,
        preferences: UpdateCheckPreferences,
        intervals: UpdateCheckIntervals,
        cache: UpdateCheckCacheFile,
        ignoredVersions: UpdateIgnoredVersions,
        results: [UpdateCheckResult]
    ) -> UpdateCategoryStatus {
        let policy = preferences.policy(for: category)
        let categoryResults = results.filter { $0.target.category == category }
        let categoryEntries = cache.entries.filter { $0.category == category.rawValue }

        let lastAttemptAt = (categoryEntries.compactMap(\.lastAttemptAt) + categoryResults.compactMap(\.checkedAt)).max()
        let lastSuccessAt = (categoryEntries.compactMap(\.lastSuccessAt) + categoryResults.compactMap(\.lastSuccessAt)).max()

        let chosenResult = choose(categoryResults)
        let entryWithVersion = categoryEntries
            .filter { $0.latestVersion != nil }
            .max { lhs, rhs in
                (lhs.lastSuccessAt ?? lhs.lastAttemptAt ?? .distantPast)
                    < (rhs.lastSuccessAt ?? rhs.lastAttemptAt ?? .distantPast)
            }

        var status: UpdateCheckStatus?
        var failure: UpdateCheckFailure?
        if let chosenResult {
            status = chosenResult.status
            failure = chosenResult.failure
        } else if let entryWithVersion {
            status = entryWithVersion.decodedStatus
            if status == .unknown {
                failure = entryWithVersion.failure.flatMap(UpdateCheckFailure.init(rawValue:))
            }
        }

        var nextCheckAt: Date?
        if let lastAttemptAt, let interval = intervals.interval(for: category, policy: policy) {
            nextCheckAt = lastAttemptAt.addingTimeInterval(interval)
        }

        return UpdateCategoryStatus(
            category: category,
            lastAttemptAt: lastAttemptAt,
            lastSuccessAt: lastSuccessAt,
            status: status,
            failure: failure,
            installedVersion: chosenResult?.installedVersion,
            latestVersion: chosenResult?.latestVersion ?? entryWithVersion?.latestVersion,
            ignoredVersion: ignoredVersions.ignored(for: category)?.version,
            nextCheckAt: nextCheckAt
        )
    }

    /// 一次运行里可能同时有多个包的结果：优先展示未忽略的“可更新”，其次是失败、
    /// 未知，最后是“最新”。
    private static func choose(_ results: [UpdateCheckResult]) -> UpdateCheckResult? {
        func priority(_ result: UpdateCheckResult) -> Int {
            switch result.status {
            case .updateAvailable: return result.ignoredVersion == nil ? 0 : 1
            case .unknown: return result.failure == nil ? 3 : 2
            case .upToDate: return 4
            }
        }
        return results.min { lhs, rhs in
            let lhsPriority = priority(lhs)
            let rhsPriority = priority(rhs)
            if lhsPriority != rhsPriority { return lhsPriority < rhsPriority }
            return (lhs.checkedAt ?? .distantPast) > (rhs.checkedAt ?? .distantPast)
        }
    }
}

/// 状态文案。时间格式由调用方注入（界面用本机时区，测试用固定格式）。
enum UpdateStatusPresenter {
    static func line(
        for status: UpdateCategoryStatus,
        policy: UpdateCheckPolicy,
        format: (Date) -> String
    ) -> String {
        var parts: [String] = []
        parts.append("策略：\(policy.title)")
        parts.append("最近检查：\(status.lastAttemptAt.map(format) ?? "尚未检查")")
        var result = "结果：\(status.resultTitle)"
        if let failure = status.failure, status.status == .unknown {
            result += "（\(failure.text)）"
        }
        parts.append(result)
        parts.append("被忽略版本：\(status.ignoredVersion ?? "无")")
        if let nextCheckAt = status.nextCheckAt {
            parts.append("下次检查：\(format(nextCheckAt))")
        } else {
            parts.append("下次检查：\(policy.isEnabled ? "—" : "已关闭")")
        }
        return parts.joined(separator: "；")
    }

    /// 一行“组件名 + 状态”，供诊断页与偏好窗口直接渲染。
    static func line(
        for status: UpdateCategoryStatus,
        preferences: UpdateCheckPreferences,
        format: (Date) -> String
    ) -> String {
        "\(status.category.displayName)："
            + line(for: status, policy: preferences.policy(for: status.category), format: format)
    }

    static func lines(
        statuses: [UpdateCategoryStatus],
        preferences: UpdateCheckPreferences,
        format: (Date) -> String
    ) -> [String] {
        statuses.map { line(for: $0, preferences: preferences, format: format) }
    }
}

// MARK: - 通知判定与文案

/// 一条需要提示的可用更新。
struct UpdateNotificationEntry: Equatable {
    var category: UpdateCheckCategory
    var target: UpdateCheckTarget
    var installedVersion: String?
    var latestVersion: String
    /// 该分类当时的策略；`askBeforeUpdate` 使用“询问”文案（仍不执行安装）。
    var policy: UpdateCheckPolicy
}

/// 通知判定（纯函数）。
///
/// 只挑选“可更新、未被忽略、本次运行尚未为这个版本提示过”的结果，因此：
/// 忽略某个版本后不再提示，上游发布更高版本时会重新进入名单；关闭的分类永远
/// 不进入名单。通知走应用内提示框（见 `docs/privacy.md` 的取舍说明），这里只
/// 决定提示哪些条目。
enum UpdateNotificationPlanner {
    static func plan(
        results: [UpdateCheckResult],
        preferences: UpdateCheckPreferences,
        ignoredVersions: UpdateIgnoredVersions,
        alreadyNotified: [UpdateCheckCategory: String]
    ) -> [UpdateNotificationEntry] {
        results.compactMap { result in
            guard result.status == .updateAvailable, let latestVersion = result.latestVersion else { return nil }
            let category = result.target.category
            let policy = preferences.policy(for: category)
            guard policy.isEnabled else { return nil }
            guard !ignoredVersions.isIgnored(latestVersion, for: category) else { return nil }
            guard alreadyNotified[category] != latestVersion else { return nil }
            return UpdateNotificationEntry(
                category: category,
                target: result.target,
                installedVersion: result.installedVersion,
                latestVersion: latestVersion,
                policy: policy
            )
        }
    }
}

/// 提示框文案。只包含组件名、版本与固定说明：没有本机路径、包名、来源、
/// 凭据或诊断内容。
enum UpdateNotificationText {
    static func title(for entries: [UpdateNotificationEntry]) -> String {
        if entries.contains(where: { $0.policy == .askBeforeUpdate }) {
            return "Pi 扩展包有可用更新"
        }
        return entries.count == 1 ? "发现 1 项可用更新" : "发现 \(entries.count) 项可用更新"
    }

    static func body(
        for entries: [UpdateNotificationEntry],
        autoInstallDeferredToNextLaunch: Set<UpdateCheckCategory> = []
    ) -> String {
        var lines = entries.map { entry -> String in
            let installed = entry.installedVersion ?? "未知"
            if autoInstallDeferredToNextLaunch.contains(entry.category) {
                return "\(entry.target.displayName)：本机 \(installed)，上游 \(entry.latestVersion)。"
                    + "“启动前自动更新 Pi Web”已开启：该更新只安排到下次启动应用时自动安装（本次运行不安装）。"
            }
            if entry.policy == .askBeforeUpdate {
                return "\(entry.target.displayName)：本机 \(installed)，上游 \(entry.latestVersion)。"
                    + "是否更新由你决定；扩展包的自动安装尚未实现，当前只提示、不下载、不安装。"
            }
            return "\(entry.target.displayName)：本机 \(installed)，上游 \(entry.latestVersion)。"
        }
        if autoInstallDeferredToNextLaunch.isEmpty {
            lines.append("应用只提示版本，不会自动下载或安装。忽略某个版本后不会再提示它，"
                + "只有上游发布更高版本时才会再次提示。")
        } else {
            lines.append("应用不会在本次运行中自动下载或安装；启动前自动更新只对已验证的 npm 全局安装生效。"
                + "忽略某个版本后不会再提示它，只有上游发布更高版本时才会再次提示。")
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - 受限自动更新的边界

/// “启动前自动更新 Pi Web”能力的边界说明（GitHub #20 起生效）。
///
/// `autoUpdatePiWebBeforeLaunch` 为 true 时也只对“来源为已验证的 npm 全局安装”
/// 的 Pi Web 产生安装行为；`UpdateChecker` 与调度器都不读它（开关不改变请求与
/// 调度，是否执行由 `PiWebUpdatePlanner` 的前置条件决定）。
enum UpdateAutomationBoundary {
    /// 设置位已生效（GitHub #20）；实际是否安装还要看来源与前置条件。
    static var autoUpdateIsEffective: Bool { UpdateCheckPreferences.autoUpdateBeforeLaunchIsEffective }

    /// 受限自动更新的边界说明（GitHub #20）：设置窗口与文档共用同一组事实。
    static let restrictedExplanation = "只对来源为已验证的 npm 全局安装的 Pi Web 生效：启动时发现已验证的可用版本时，"
        + "用参数数组执行 npm install -g <包名>@<版本>（不使用 shell、不调用 sudo、安装有超时），安装后重新检测版本并做健康检查。"
        + "其它来源（pnpm、Homebrew、nvm/mise、git checkout、本地路径、未知）只显示命令，绝不自动安装；"
        + "应用不承诺所有来源都能回滚。"
}
