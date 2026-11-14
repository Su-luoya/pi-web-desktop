/// 统一更新流程的模型：一次检查得到的全部可执行更新项。
///
/// 之前四类组件各有各的入口、各弹各的框：菜单里 4 个「立即更新 X…」、4 个告警项、
/// 7 个策略勾选框，而「检查更新…」自己只弹一句“发现 N 项可用更新”就结束。这里把
/// 四类折算成同一份计划，由同一个确认框一次问完、按固定顺序执行。
///
/// 顺序是有理由的，不是随便排的：Pi Web 更新要先停服务，桌面应用更新会让应用退出
/// 并重启，所以它必须最后做。
enum UpdateFlowComponent: String, CaseIterable, Equatable {
    case piCLI
    case piPackages
    case piWeb
    case desktopApp

    /// 执行顺序：命令行工具 → 扩展包 → Pi Web（停服）→ 桌面应用（重启）。
    static let executionOrder: [UpdateFlowComponent] = [.piCLI, .piPackages, .piWeb, .desktopApp]

    var title: String {
        switch self {
        case .piCLI: return "Pi CLI"
        case .piPackages: return "Pi 扩展包"
        case .piWeb: return "Pi Web"
        case .desktopApp: return "桌面应用"
        }
    }

    var checkCategory: UpdateCheckCategory {
        switch self {
        case .piCLI: return .piCLI
        case .piPackages: return .piPackages
        case .piWeb: return .piWeb
        case .desktopApp: return .desktopApp
        }
    }
}

/// 一条可执行更新：展示用的文案 + 真正要执行的计划。
struct UpdateFlowEntry {
    let component: UpdateFlowComponent
    /// 一行说明，例如 `Pi CLI 0.63.2 → 0.63.3`。
    let summary: String
    /// 这一项会给用户带来的副作用（停服、重启应用、需要重启会话）。
    let note: String?
    let step: UpdateFlowStep
}

/// 各组件的执行载荷：都是既有编排器接受的计划类型。
enum UpdateFlowStep {
    case piCLI(PiCLIUpdatePlan)
    case piPackages([PiPackageUpdatePlan])
    case piWeb(PiWebUpdateInstallPlan)
    case desktopApp(DesktopAppUpdateInstallTarget)

    /// 这一步装完后本机应有的版本（扩展包为空：它的已装版本会被重新检测）。
    var targetVersion: String? {
        switch self {
        case .piCLI(let plan): return plan.targetVersion
        case .piPackages: return nil
        case .piWeb(let plan): return plan.targetVersion
        case .desktopApp(let target): return target.version
        }
    }
}

/// 一次统一更新的计划：要执行的项目与被跳过的项目（含原因）。
struct UpdateFlowPlan {
    var entries: [UpdateFlowEntry] = []
    /// 发现了更新但这次不执行的原因，例如“来源不是本次网络结果”。
    var skipped: [String] = []

    var isEmpty: Bool { entries.isEmpty }

    var components: [UpdateFlowComponent] { entries.map(\.component) }

    var packageCount: Int {
        entries.reduce(0) { count, entry in
            if case .piPackages(let plans) = entry.step { return count + plans.count }
            return count
        }
    }
}

enum UpdateFlowPlanner {
    /// 按固定顺序排列条目，并合并同类条目（多个扩展包算一项）。
    static func plan(
        entries: [UpdateFlowEntry],
        skipped: [String] = []
    ) -> UpdateFlowPlan {
        let ordered = UpdateFlowComponent.executionOrder.compactMap { component in
            entries.first { $0.component == component }
        }
        return UpdateFlowPlan(entries: ordered, skipped: skipped)
    }
}

/// 确认框与结果框的文案。只拼文本，不碰界面。
enum UpdateFlowText {
    static func title(for plan: UpdateFlowPlan) -> String {
        "发现 \(plan.entries.count) 项更新"
    }

    static func body(for plan: UpdateFlowPlan) -> String {
        var lines: [String] = ["将按下面的顺序执行："]
        for (index, entry) in plan.entries.enumerated() {
            var line = "\(index + 1). \(entry.summary)"
            if let note = entry.note { line += "（\(note)）" }
            lines.append(line)
        }
        if !plan.skipped.isEmpty {
            lines.append("")
            lines.append("这次不更新的项目：")
            for reason in plan.skipped { lines.append("· \(reason)") }
        }
        lines.append("")
        lines.append("更新命令只使用参数数组，不经过 shell，也不调用 sudo。")
        return lines.joined(separator: "\n")
    }

    /// 没有可执行项时的说明：手动检查要能说清“为什么没有更新”。
    static func nothingToDoBody(skipped: [String]) -> String {
        let hint = "检查策略与检查时机可以在「更新 → 更新设置…」里调整。"
        guard !skipped.isEmpty else { return "全部已是最新。\n\n" + hint }
        return (["这次没有可执行的更新。"] + [""] + skipped.map { "· \($0)" } + ["", hint])
            .joined(separator: "\n")
    }

    static func resultTitle(succeeded: Int, failed: Int) -> String {
        if failed == 0 { return "更新完成" }
        if succeeded == 0 { return "更新未完成" }
        return "更新部分完成"
    }

    static func resultBody(_ lines: [String]) -> String {
        lines.joined(separator: "\n")
    }
}
