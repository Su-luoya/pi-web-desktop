/// Category status, notification planning and presenter text for update settings.

import CoreFoundation
import Foundation

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
    /// 结论来源（GitHub #59）：`.cachedFallback` 时界面与诊断必须标注“本机缓存”
    /// 与缓存写入时间，避免把缓存回退读成本次已验证的上游确认。
    var origin: UpdateCheckOrigin = .unavailable
    /// 结论来源为缓存回退时的缓存写入时间；其余情况为 nil。
    var cacheWrittenAt: Date?

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
            // 没有本次结果时，缓存条目里的旧结论不能直接展示（GitHub #74）：用
            // 条目记录的本机版本与缓存里的上游版本现算，缺字段或任一侧不可解析
            // 时降级为 unknown，因此不会出现“已是最新 / 可更新”与版本自相矛盾。
            status = UpdateVersionVerdict.status(
                installed: entryWithVersion.installedVersion,
                upstream: entryWithVersion.latestVersion
            ) ?? .unknown
            if status == .unknown {
                failure = entryWithVersion.failure.flatMap(UpdateCheckFailure.init(rawValue:))
            }
        }

        var nextCheckAt: Date?
        if let lastAttemptAt, let interval = intervals.interval(for: category, policy: policy) {
            nextCheckAt = lastAttemptAt.addingTimeInterval(interval)
        }

        // 来源只反映本次运行的结果；没有结果但缓存里还有可展示版本时，结论本身
        // 就来自缓存（只用于提示）。
        let origin: UpdateCheckOrigin
        let cacheWrittenAt: Date?
        if let chosenResult {
            origin = chosenResult.origin
            cacheWrittenAt = chosenResult.cacheWrittenAt
        } else if let entryWithVersion {
            origin = .cachedFallback
            cacheWrittenAt = entryWithVersion.lastSuccessAt ?? entryWithVersion.lastAttemptAt
        } else {
            origin = .unavailable
            cacheWrittenAt = nil
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
            nextCheckAt: nextCheckAt,
            origin: origin,
            cacheWrittenAt: cacheWrittenAt
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
        // 缓存回退必须标注来源与缓存写入时间：它只用于提示，不参与自动安装判定。
        if status.origin == .cachedFallback {
            let stamp = status.cacheWrittenAt.map(format) ?? "未知"
            parts.append("来源：本机缓存（写入于 \(stamp)；缓存不是可信输入，只用于提示，不用于自动安装）")
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
/// 不进入名单。名单只消费 `UpdateChecker` 重建过的结果（status 按当前本机
/// 版本现算，GitHub #74），本函数自己不读缓存、也不沿用缓存里的结论。
/// 通知走应用内提示框（见 `docs/privacy.md` 的取舍说明），这里只
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
                    + "是否更新由你决定：应用不做无人值守扩展包更新，只在你确认后才用参数数组"
                    + "执行一次 Pi 官方更新命令（菜单“服务 → 更新检查设置 → 查看 Pi 扩展包更新…”）。"
            }
            return "\(entry.target.displayName)：本机 \(installed)，上游 \(entry.latestVersion)。"
        }
        if autoInstallDeferredToNextLaunch.isEmpty {
            lines.append("应用只提示版本，不会自动下载或安装（扩展包也必须在菜单里确认后才执行一次官方更新命令）。"
                + "忽略某个版本后不会再提示它，只有上游发布更高版本时才会再次提示。")
        } else {
            lines.append("应用不会在本次运行中自动下载或安装；启动前自动更新只对已验证的 npm 全局安装生效，"
                + "扩展包必须在菜单里确认后才执行一次官方更新命令。"
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
