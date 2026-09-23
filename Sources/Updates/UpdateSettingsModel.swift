import CoreFoundation
import Foundation

// MARK: - 检查策略（GitHub #18）

/// 一类组件的更新检查策略。
///
/// 桌面应用 / Pi CLI / Pi Web 只允许 `off` / `daily` / `weekly`；Pi 扩展包只允许
/// `off` / `checkAndNotify` / `askBeforeUpdate`。允许集合只有 `allowed(for:)`
/// 一份定义，界面选项、写入校验与 UserDefaults 迁移都读它。

/// Update check policies, settings keys, preferences, migration and intervals.

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

    /// 启动前自动更新 Pi CLI（GitHub #21）。打开后也只有“没有运行中的 Pi 进程 +
    /// 已验证的 npm/pnpm 全局安装 + 已验证且更高的目标版本”时才自动执行。
    static let autoUpdatePiBeforeLaunch = "updateChecks.pi.autoUpdateBeforeLaunch"

    /// 最近一次失败的 Pi CLI 更新的持久记录（GitHub #21）。字段与 #20 的警告
    /// 同构：只含类别、旧/新/目标版本、固定原因文案与时间戳。
    static let piCLIUpdateWarningKind = "updateChecks.pi.lastUpdateWarning.kind"
    static let piCLIUpdateWarningOldVersion = "updateChecks.pi.lastUpdateWarning.oldVersion"
    static let piCLIUpdateWarningNewVersion = "updateChecks.pi.lastUpdateWarning.newVersion"
    static let piCLIUpdateWarningTargetVersion = "updateChecks.pi.lastUpdateWarning.targetVersion"
    static let piCLIUpdateWarningReason = "updateChecks.pi.lastUpdateWarning.reason"
    static let piCLIUpdateWarningRecordedAt = "updateChecks.pi.lastUpdateWarning.recordedAt"

    static var allPiCLIUpdateWarningKeys: [String] {
        [
            piCLIUpdateWarningKind,
            piCLIUpdateWarningOldVersion,
            piCLIUpdateWarningNewVersion,
            piCLIUpdateWarningTargetVersion,
            piCLIUpdateWarningReason,
            piCLIUpdateWarningRecordedAt
        ]
    }

    /// 最近一次失败的 Pi 扩展包更新的持久记录（GitHub #22）。字段与 #20/#21 的
    /// 警告同构，另外带一个已通过 npm 包名校验的包名；不含路径、环境变量值、
    /// 凭据或子进程输出。
    static let piPackageUpdateWarningKind = "updateChecks.piPackages.lastUpdateWarning.kind"
    static let piPackageUpdateWarningPackage = "updateChecks.piPackages.lastUpdateWarning.package"
    static let piPackageUpdateWarningOldVersion = "updateChecks.piPackages.lastUpdateWarning.oldVersion"
    static let piPackageUpdateWarningNewVersion = "updateChecks.piPackages.lastUpdateWarning.newVersion"
    static let piPackageUpdateWarningTargetVersion = "updateChecks.piPackages.lastUpdateWarning.targetVersion"
    static let piPackageUpdateWarningReason = "updateChecks.piPackages.lastUpdateWarning.reason"
    static let piPackageUpdateWarningRecordedAt = "updateChecks.piPackages.lastUpdateWarning.recordedAt"

    static var allPiPackageUpdateWarningKeys: [String] {
        [
            piPackageUpdateWarningKind,
            piPackageUpdateWarningPackage,
            piPackageUpdateWarningOldVersion,
            piPackageUpdateWarningNewVersion,
            piPackageUpdateWarningTargetVersion,
            piPackageUpdateWarningReason,
            piPackageUpdateWarningRecordedAt
        ]
    }

    /// 统一更新历史（GitHub #23）。单键 JSON：时间、组件、来源、从/到版本、
    /// 阶段结果与失败原因（脱敏）。不含路径、环境变量值、凭据或子进程输出。
    static let updateHistory = "updateChecks.updateHistory"

    /// 「已放弃」记录（GitHub #62）：超时或放弃等待之后“启动过但已停止等待”的
    /// 命令。与更新历史同一类存储（单键 JSON、显式字段、读回校验），但使用独立
    /// 键：Pi Web / Pi CLI 各一个槽位，扩展包一个按包名去重的数组槽位。内容只含
    /// 组件、脱敏后的命令摘要、来源、时间与固定文案，不含路径、凭据或子进程输出。
    static let piWebAbandonedAttempt = "updateChecks.piWeb.abandonedAttempt"
    static let piCLIAbandonedAttempt = "updateChecks.pi.abandonedAttempt"
    static let piPackageAbandonedAttempts = "updateChecks.piPackages.abandonedAttempts"

    static var allAbandonedAttemptKeys: [String] {
        [piWebAbandonedAttempt, piCLIAbandonedAttempt, piPackageAbandonedAttempts]
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

    /// `UpdateCheckPreferences.save` 实际写入的键（策略 + 两个启动前自动更新开关）。
    static var writtenPreferencesKeys: [String] {
        UpdateCheckCategory.allCases.map { policy(for: $0) }
            + [autoUpdatePiWebBeforeLaunch, autoUpdatePiBeforeLaunch]
    }

    /// GitHub #17 的旧布尔键：只读兼容，保存新设置时删除。
    static var legacyPreferenceKeys: [String] {
        UpdateCheckCategory.allCases.map { legacyEnabled(for: $0) }
    }

    static var allIgnoredVersionKeys: [String] {
        UpdateCheckCategory.allCases.flatMap { [ignoredVersion(for: $0), ignoredVersionAt(for: $0)] }
    }

    /// 更新检查会写入的全部键（测试用它断言 UserDefaults 里没有额外数据）。
    /// 警告键由 `PiWebUpdateWarningStore` / `PiCLIUpdateWarningStore` 单独读写：
    /// 保存策略不会清掉警告。
    static var allKeys: [String] {
        allPreferencesKeys + allIgnoredVersionKeys + allPiWebUpdateWarningKeys + allPiCLIUpdateWarningKeys
            + allPiPackageUpdateWarningKeys + [updateHistory] + allAbandonedAttemptKeys
    }
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
    static let defaultAutoUpdatePiBeforeLaunch = false

    /// 四类组件各自的策略。字典始终包含 `UpdateCheckCategory.allCases`，
    /// 不合法的组合在写入时被拒绝（`setPolicy`）。
    private(set) var policies: [UpdateCheckCategory: UpdateCheckPolicy]

    /// alpha.3 预留：启动前自动更新（Pi Web 范围）。alpha.2 只保存值。
    var autoUpdatePiWebBeforeLaunch: Bool

    /// 启动前自动更新 Pi CLI（GitHub #18 预留、GitHub #21 生效）。
    /// 默认关闭；打开后也受进程保护与来源/可信度前置条件约束。
    var autoUpdatePiBeforeLaunch: Bool

    init(
        policies: [UpdateCheckCategory: UpdateCheckPolicy] = [:],
        autoUpdatePiWebBeforeLaunch: Bool = UpdateCheckPreferences.defaultAutoUpdatePiWebBeforeLaunch,
        autoUpdatePiBeforeLaunch: Bool = UpdateCheckPreferences.defaultAutoUpdatePiBeforeLaunch
    ) {
        var normalized: [UpdateCheckCategory: UpdateCheckPolicy] = [:]
        for category in UpdateCheckCategory.allCases {
            let requested = policies[category]
            normalized[category] = requested.flatMap { $0.isAllowed(for: category) ? $0 : nil }
                ?? Self.defaultPolicy(for: category)
        }
        self.policies = normalized
        self.autoUpdatePiWebBeforeLaunch = autoUpdatePiWebBeforeLaunch
        self.autoUpdatePiBeforeLaunch = autoUpdatePiBeforeLaunch
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
        defaults.set(autoUpdatePiBeforeLaunch, forKey: UpdateSettingKeys.autoUpdatePiBeforeLaunch)
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

        if let raw = values[UpdateSettingKeys.autoUpdatePiBeforeLaunch] {
            if let enabled = booleanValue(raw) {
                preferences.autoUpdatePiBeforeLaunch = enabled
            } else {
                note(UpdateSettingKeys.autoUpdatePiBeforeLaunch, "已回退到关闭")
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
