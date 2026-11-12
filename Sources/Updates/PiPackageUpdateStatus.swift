/// Pi package confirmation, status text and persistent update warnings.

import Foundation

/// 诊断页/设置页用的状态文本（纯函数；输入都是已经脱敏或可安全展示的值）。
///
/// `inspection` 为 nil 表示本次运行还没有做过进程检查（smoke 启动不会枚举真实
/// 进程），此时只展示策略与拒绝原因，不展示进程结论。
enum PiPackageUpdateStatusPresenter {
    /// 更新失败告警的展示文本（跨启动保留）。
    /// `compact` 为真时进程状态只报数量（设置页用）。
    static func lines(
        policy: UpdateCheckPolicy,
        planSet: PiPackageUpdatePlanSet?,
        inspection: PiProcessInspection?,
        warning: PiPackageUpdateWarning?,
        compact: Bool = false
    ) -> [String] {
        var lines: [String] = []
        let mapped = PiPackageUpdatePolicy(policy)
        lines.append("Pi 扩展包更新：策略 \(mapped?.title ?? "\(policy.title)（不属于扩展包允许集合）")"
            + "；不做无人值守更新（执行入口必须经用户确认）")
        let processStatus = inspection.map { compact ? $0.compactStatusText : $0.statusText }
        lines.append("Pi 扩展包进程保护：\(processStatus ?? "尚未检查（本次运行还没有枚举本机进程）")")
        if let planSet {
            lines.append("本次规划：已检查 \(planSet.didCheck ? "是" : "否")；包数量 \(planSet.packageCount)；"
                + "待确认计划 \(planSet.executablePlans.count)；只提示 \(planSet.notices.count)")
            for plan in planSet.executablePlans {
                lines.append("待确认：\(plan.packageName) \(plan.installedVersion) → \(plan.targetVersion ?? "由官方命令决定")"
                    + "（参数数组 \(PiPackageUpdateArgumentPolicy.displayText(for: plan.arguments))）")
            }
            for plan in planSet.allPlans where planSet.executablePlans.allSatisfy({ $0.packageName != plan.packageName }) {
                lines.append("已就绪但被拒绝执行：\(plan.packageName)（原因见下面的拒绝记录）")
            }
            // 「已放弃」记录（GitHub #62）：这些包必须先看到记录再确认，未确认前不执行。
            if !planSet.abandonedConfirmationPlans.isEmpty {
                let names = planSet.abandonedConfirmationPlans.map(\.packageName).joined(separator: "、")
                lines.append(
                    "需先看「已放弃」记录再确认：\(names)"
                        + "（开始时间与超时上限见下面的记录；结束时间未知；确认后才执行一次）"
                )
            }
            for notice in planSet.notices {
                lines.append("只提示：\(notice.packageName) \(notice.installedVersion ?? "未知") → \(notice.targetVersion ?? "未知")")
            }
            for record in planSet.refusalRecords {
                lines.append("拒绝记录：\(record.logLine)")
            }
        }
        if let warning {
            lines.append(warning.text)
        }
        lines.append("手动入口：菜单“更新 → 查看 Pi 扩展包更新…”（策略为“关闭”时不检查、不提示、不执行）")
        return lines
    }
}

// MARK: - 持久警告

/// 一次失败的扩展包更新的持久记录。
///
/// 只保存类别、包名（已通过 npm 包名校验）、旧/新/目标版本、固定原因文案与
/// 时间：不含路径、环境变量值、凭据或子进程输出。警告在界面与诊断文本里持续
/// 显示，直到下一次成功更新或用户清除。
struct PiPackageUpdateWarning: Equatable {
    enum Kind: String, Equatable {
        case commandFailed
        case versionUnchanged
    }

    var kind: Kind
    var packageName: String
    var oldVersion: String?
    var newVersion: String?
    var targetVersion: String?
    var reason: String
    var recordedAt: Date

    init(
        kind: Kind,
        packageName: String,
        oldVersion: String? = nil,
        newVersion: String? = nil,
        targetVersion: String? = nil,
        reason: String,
        recordedAt: Date = Date()
    ) {
        self.kind = kind
        self.packageName = packageName
        self.oldVersion = oldVersion
        self.newVersion = newVersion
        self.targetVersion = targetVersion
        self.reason = reason
        self.recordedAt = recordedAt
    }

    /// 用户可见的持久警告：明确说明没有回滚这回事、也不声称更新成功。
    var text: String {
        var parts: [String] = []
        parts.append("Pi 扩展包更新未完成（\(packageName)）：\(reason)。")
        parts.append("当前版本：\(oldVersion ?? "未知")；目标版本：\(targetVersion ?? "未知")"
            + (newVersion.map { "；重新检测到的版本：\($0)" } ?? "") + "。")
        parts.append("旧版本文件不会被应用回滚，应用也不声称更新成功；"
            + "请查看日志与诊断结果后手动处理，或稍后重新确认更新。")
        return parts.joined(separator: " ")
    }

    /// 菜单/状态行用的单行摘要。
    var shortText: String {
        "Pi 扩展包更新告警（\(packageName)）：\(reason)（当前 \(oldVersion ?? "未知") → 目标 \(targetVersion ?? "未知")）"
    }
}

/// 持久警告的 UserDefaults 存取（只经 `AppConfiguration` 调用）。
/// 读写本身在 `UpdateWarningStore` 里只实现一份（三类告警同构）；包名额外要求
/// 通过 npm 包名校验，写之前与读之后都拒绝非法值。
enum PiPackageUpdateWarningStore {
    private static let keys = UpdateWarningKeys(
        kind: UpdateSettingKeys.piPackageUpdateWarningKind,
        oldVersion: UpdateSettingKeys.piPackageUpdateWarningOldVersion,
        newVersion: UpdateSettingKeys.piPackageUpdateWarningNewVersion,
        targetVersion: UpdateSettingKeys.piPackageUpdateWarningTargetVersion,
        reason: UpdateSettingKeys.piPackageUpdateWarningReason,
        recordedAt: UpdateSettingKeys.piPackageUpdateWarningRecordedAt,
        all: UpdateSettingKeys.allPiPackageUpdateWarningKeys
    )

    static func load(from defaults: UserDefaults) -> PiPackageUpdateWarning? {
        guard let stored = UpdateWarningStore.load(keys, from: defaults),
              let kind = PiPackageUpdateWarning.Kind(rawValue: stored.kind) else { return nil }
        guard let packageName = defaults.string(forKey: UpdateSettingKeys.piPackageUpdateWarningPackage),
              ComponentInstallationDetector.isPackageName(packageName) else { return nil }
        return PiPackageUpdateWarning(
            kind: kind,
            packageName: packageName,
            oldVersion: stored.oldVersion,
            newVersion: stored.newVersion,
            targetVersion: stored.targetVersion,
            reason: stored.reason,
            recordedAt: stored.recordedAt
        )
    }

    static func save(_ warning: PiPackageUpdateWarning?, to defaults: UserDefaults) {
        guard let warning,
              ComponentInstallationDetector.isPackageName(warning.packageName) else {
            UpdateWarningStore.save(nil, keys: keys, to: defaults)
            return
        }
        defaults.set(warning.packageName, forKey: UpdateSettingKeys.piPackageUpdateWarningPackage)
        UpdateWarningStore.save(stored(from: warning), keys: keys, to: defaults)
    }

    private static func stored(from warning: PiPackageUpdateWarning) -> StoredUpdateWarning {
        StoredUpdateWarning(
            kind: warning.kind.rawValue,
            oldVersion: warning.oldVersion,
            newVersion: warning.newVersion,
            targetVersion: warning.targetVersion,
            reason: warning.reason,
            recordedAt: warning.recordedAt
        )
    }
}
