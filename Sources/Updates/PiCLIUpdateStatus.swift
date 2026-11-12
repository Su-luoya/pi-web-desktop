/// Pi CLI manual confirmation, status text and persistent update warnings.

import Foundation

// MARK: - 手动更新的确认文案

/// 手动更新确认框的纯文本构造（诊断页与确认框共用；不含任何未脱敏内容）。
enum PiCLIManualUpdateConfirmation {
    static func text(
        plan: PiCLIUpdatePlan?,
        commandText: String?,
        inspection: PiProcessInspection,
        abandonedAttempt: UpdateAbandonedAttempt? = nil,
        redactingWith redactor: LogRedactor
    ) -> String {
        var lines: [String] = []
        if let plan {
            lines.append(contentsOf: plan.displayLines(redactingWith: redactor))
        } else if let commandText {
            lines.append("将执行的命令：\(redactor.redact(commandText))")
        } else {
            lines.append("没有可用的 Pi CLI 更新命令。")
        }
        if let abandonedAttempt {
            lines.append("")
            lines.append(UpdateAbandonedAttemptPresenter.confirmationBlock(for: abandonedAttempt))
        }
        lines.append("")
        lines.append("当前 Pi 进程状态：\(inspection.records.isEmpty ? inspection.statusText : "检测到 \(inspection.records.count) 个运行中的 Pi 进程（详情如下）")")
        for record in inspection.records {
            lines.append(contentsOf: record.displayLines)
            lines.append("")
        }
        lines.append("风险说明：更新会替换 Pi CLI 的可执行文件。")
        lines.append("· 正在进行或稍后恢复的 Pi 会话可能读到更新后的文件，行为可能与会话开始时不同；")
        lines.append("· 应用不会结束、暂停或接管任何 Pi 进程与会话，也不会向它们发送任何信号；")
        lines.append("· 更新是否成功取决于上游命令本身，应用只负责执行并重新检测版本，不保证成功，也不做回滚。")
        return lines.joined(separator: "\n")
    }
}

// MARK: - 状态展示

/// 诊断页/设置页用的状态文本（纯函数；输入都是已经脱敏的值）。
/// `inspection` 为 nil 表示本次运行还没有做过进程检查（smoke 启动不会枚举真实
/// 进程），此时只展示设置与手动入口，不展示决策结果。
/// `compact` 为真时进程状态只报数量（设置页用），不影响诊断页的完整展开。
enum PiCLIUpdateStatusPresenter {
    static func lines(
        preferences: UpdateCheckPreferences,
        inspection: PiProcessInspection?,
        decision: PiCLIUpdateDecision?,
        warning: PiCLIUpdateWarning?,
        compact: Bool = false
    ) -> [String] {
        var lines: [String] = []
        let processStatus = inspection.map { compact ? $0.compactStatusText : $0.statusText }
        lines.append("Pi CLI 进程保护：\(processStatus ?? "尚未检查（本次运行还没有枚举本机进程）")")
        lines.append(
            "Pi CLI 启动前自动更新："
                + (preferences.autoUpdatePiBeforeLaunch ? "已开启" : "已关闭")
                + (decision.map { "；本次决策：\($0.statusLine)" } ?? "")
        )
        if let deferral = decision?.deferral {
            lines.append("推迟原因：\(deferral.text)")
        }
        if let warning {
            lines.append(warning.text)
        }
        lines.append("手动更新入口：菜单“更新 → 立即更新 Pi CLI…”（执行前显示进程信息并要求确认）")
        return lines
    }
}

// MARK: - 持久警告

/// 一次失败的 Pi CLI 更新的持久记录。
///
/// 只保存类别、旧/新/目标版本、固定原因文案与时间：不含路径、环境变量值、
/// 凭据或子进程输出。警告在界面与诊断文本里持续显示，直到下一次成功更新。
struct PiCLIUpdateWarning: Equatable {
    enum Kind: String, Equatable {
        case commandFailed
        case versionUnchanged
    }

    var kind: Kind
    var oldVersion: String?
    var newVersion: String?
    var targetVersion: String?
    var reason: String
    var recordedAt: Date

    init(
        kind: Kind,
        oldVersion: String? = nil,
        newVersion: String? = nil,
        targetVersion: String? = nil,
        reason: String,
        recordedAt: Date = Date()
    ) {
        self.kind = kind
        self.oldVersion = oldVersion
        self.newVersion = newVersion
        self.targetVersion = targetVersion
        self.reason = reason
        self.recordedAt = recordedAt
    }

    /// 用户可见的持久警告：明确说明旧版本语义保持不变、没有回滚这回事。
    var text: String {
        var parts: [String] = []
        parts.append("Pi CLI 更新未完成：\(reason)。")
        parts.append("当前版本：\(oldVersion ?? "未知")；目标版本：\(targetVersion ?? "未知")"
            + (newVersion.map { "；重新检测到的版本：\($0)" } ?? "") + "。")
        parts.append("旧版本语义保持不变：应用不会自动回滚已替换的文件，也不声称更新成功；"
            + "请查看日志与诊断结果后手动处理。")
        return parts.joined(separator: " ")
    }

    /// 菜单/状态行用的单行摘要。
    var shortText: String {
        "Pi CLI 更新告警：\(reason)（当前 \(oldVersion ?? "未知") → 目标 \(targetVersion ?? "未知")）"
    }
}

/// 持久警告的 UserDefaults 存取（只经 `AppConfiguration` 调用）。
/// 读写本身在 `UpdateWarningStore` 里只实现一份（三类告警同构）。
enum PiCLIUpdateWarningStore {
    private static let keys = UpdateWarningKeys(
        kind: UpdateSettingKeys.piCLIUpdateWarningKind,
        oldVersion: UpdateSettingKeys.piCLIUpdateWarningOldVersion,
        newVersion: UpdateSettingKeys.piCLIUpdateWarningNewVersion,
        targetVersion: UpdateSettingKeys.piCLIUpdateWarningTargetVersion,
        reason: UpdateSettingKeys.piCLIUpdateWarningReason,
        recordedAt: UpdateSettingKeys.piCLIUpdateWarningRecordedAt,
        all: UpdateSettingKeys.allPiCLIUpdateWarningKeys
    )

    static func load(from defaults: UserDefaults) -> PiCLIUpdateWarning? {
        guard let stored = UpdateWarningStore.load(keys, from: defaults),
              let kind = PiCLIUpdateWarning.Kind(rawValue: stored.kind) else { return nil }
        return PiCLIUpdateWarning(
            kind: kind,
            oldVersion: stored.oldVersion,
            newVersion: stored.newVersion,
            targetVersion: stored.targetVersion,
            reason: stored.reason,
            recordedAt: stored.recordedAt
        )
    }

    static func save(_ warning: PiCLIUpdateWarning?, to defaults: UserDefaults) {
        UpdateWarningStore.save(warning.map { stored(from: $0) }, keys: keys, to: defaults)
    }

    private static func stored(from warning: PiCLIUpdateWarning) -> StoredUpdateWarning {
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
