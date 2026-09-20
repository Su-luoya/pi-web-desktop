/// Single check result, its trigger and the aggregated summary.

import Foundation

/// 一个对象的用户可见结论。只包含版本、状态与固定文案，不含路径、请求细节或
/// 诊断内容。`ignoredVersion` 记录用户为该分类忽略、因而本次不再提示的版本。
struct UpdateCheckResult: Equatable {
    var target: UpdateCheckTarget
    var status: UpdateCheckStatus
    var installedVersion: String?
    var latestVersion: String?
    /// 上游版本经过预期端点 + 可解析结构验证时为 `verified`；否则 `unknown`。
    var confidence: DetectionConfidence
    var freshness: UpdateResultFreshness
    var failure: UpdateCheckFailure?
    var httpStatusCode: Int?
    var checkedAt: Date?
    var lastSuccessAt: Date?
    /// 本次结论对应的版本被用户忽略时，这里是那个版本（等于 `latestVersion`）。
    var ignoredVersion: String? = nil
    /// 结论来源。默认值是最安全的一档（不可用）：漏传时绝不会退化成“允许自动安装”。
    var origin: UpdateCheckOrigin = .unavailable
    /// `origin == .cachedFallback` 时缓存条目的写入时间；其余情况为 nil。
    var cacheWrittenAt: Date? = nil

    var failureText: String {
        guard let failure else { return "未知原因" }
        switch failure {
        case .rateLimited, .serverError, .httpError, .unexpectedRedirect:
            let code = httpStatusCode.map { "（HTTP \($0)）" } ?? ""
            return failure.text + code
        default:
            return failure.text
        }
    }

    var displayText: String {
        var text: String
        switch status {
        case .updateAvailable:
            text = "\(target.displayName)：上游有新版本 \(latestVersion ?? "未知")，本机 \(installedVersion ?? "未知")。只提示，不自动安装。"
            if let latestVersion, ignoredVersion == latestVersion {
                text += "该版本已被忽略，上游发布更高版本时会再次提示。"
            }
        case .upToDate:
            text = "\(target.displayName)：已是最新（本机 \(installedVersion ?? "未知")，上游 \(latestVersion ?? "未知")）。"
        case .unknown:
            text = "\(target.displayName)：无法确定\(installedVersion.map { "（本机 \($0)）" } ?? "")。"
        }
        if failure != nil {
            if freshness == .cached, let latestVersion {
                text += " 本次未验证成功：\(failureText)；保留上次成功结果：\(latestVersion)。"
            } else {
                text += " 原因：\(failureText)。"
            }
        }
        if let annotation = cacheOriginAnnotation {
            text += annotation
        }
        return text
    }

    /// 缓存回退的固定来源标注：包含“缓存”与缓存写入时间，并说明它只用于提示。
    /// 不写“已验证”“官方”之类会让用户以为本次已由上游确认的措辞。
    var cacheOriginAnnotation: String? {
        guard origin == .cachedFallback else { return nil }
        let stamp = cacheWrittenAt.map { "，写入于 \(UpdateCheckTimestamp.text($0))" } ?? "，写入时间未知"
        return "（来源：本机缓存\(stamp)；缓存不是可信输入，只用于提示，不用于自动安装。）"
    }
}

/// 触发来源。只用于状态文案与测试断言，不改变检查对象的范围。
enum UpdateCheckTrigger: String, Equatable {
    case launch
    case scheduled
    case manual

    var displayName: String {
        switch self {
        case .launch: return "启动"
        case .scheduled: return "周期"
        case .manual: return "手动"
        }
    }
}

/// 一次检查（或一次“没有可检查对象”的判定）的汇总。`categoryStatuses` 是四类
/// 组件的状态快照（最近检查 / 结果 / 忽略版本 / 下次检查），由检查器在主线程
/// 发布，供诊断页与偏好窗口渲染。
struct UpdateCheckSummary: Equatable {
    var results: [UpdateCheckResult]
    var checkedAt: Date?
    var trigger: UpdateCheckTrigger
    /// 本次运行中处于开启状态的分类；全部关闭时 `results` 必然为空。
    var enabledCategories: [UpdateCheckCategory]
    var categoryStatuses: [UpdateCategoryStatus]

    static let empty = UpdateCheckSummary(
        results: [],
        checkedAt: nil,
        trigger: .manual,
        enabledCategories: UpdateCheckCategory.allCases,
        categoryStatuses: []
    )

    init(
        results: [UpdateCheckResult],
        checkedAt: Date?,
        trigger: UpdateCheckTrigger,
        enabledCategories: [UpdateCheckCategory],
        categoryStatuses: [UpdateCategoryStatus] = []
    ) {
        self.results = results
        self.checkedAt = checkedAt
        self.trigger = trigger
        self.enabledCategories = enabledCategories
        self.categoryStatuses = categoryStatuses
    }

    var allDisabled: Bool { enabledCategories.isEmpty }

    var updateAvailableCount: Int { results.filter { $0.status == .updateAvailable }.count }
    var unknownCount: Int { results.filter { $0.status == .unknown }.count }

    func result(for targetID: String) -> UpdateCheckResult? {
        results.first { $0.target.id == targetID }
    }

    /// 菜单状态行。
    var statusLine: String {
        if allDisabled { return "更新检查：已全部关闭" }
        guard !results.isEmpty else { return "更新检查：尚未检查" }
        if updateAvailableCount > 0 {
            return "更新检查：发现 \(updateAvailableCount) 项可用更新"
        }
        if unknownCount > 0 {
            return "更新检查：有 \(unknownCount) 项无法确定"
        }
        return "更新检查：全部已是最新"
    }

    /// 提示文案：只讲检查结果、上游范围与“不安装”，不做任何要求用户操作的诱导。
    var detailText: String {
        if allDisabled {
            return "四类更新检查都已关闭，应用不会向上游发起任何版本请求。"
                + "可以在“服务 → 更新检查设置”里重新打开；应用只检查、不安装。"
        }
        guard !results.isEmpty else {
            return "本次没有需要检查的对象（本机版本未知，或还没有到期）。"
        }
        var lines = results.map(\.displayText)
        if updateAvailableCount > 0 {
            lines.append("")
            lines.append("发现 \(updateAvailableCount) 项可用更新。应用只提示版本，不会自动下载或安装。")
        }
        return lines.joined(separator: "\n")
    }
}
