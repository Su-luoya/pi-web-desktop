/// Presentation text for dependency reports and installation hints.

import Darwin
import Foundation

// MARK: - 纯文本呈现（无 AppKit）

/// 诊断结果的纯文本呈现，供诊断窗口和测试共用。
///
/// 只消费已经脱敏的 `DependencyReport`，URL 只从静态清单读取并去掉 userinfo、
/// query 与 fragment，因此文本里不会出现真实用户名、Home 绝对路径、凭据、
/// token 或查询参数。
enum DependencyReportPresenter {
    struct Row: Equatable {
        let title: String
        let status: String
        let path: String
        let version: String
        let source: String
        let confidence: String
        /// 命令探测失败时的可读原因（GitHub #89）；没有失败时是空串。
        var note: String = ""
    }

    static func title(for kind: DependencyFinding.Kind) -> String {
        switch kind {
        case .system: return "系统"
        case .node: return "Node.js"
        case .piCLI: return "Pi CLI"
        case .piWeb: return "Pi Web"
        case .port: return "默认端口"
        case .piConfigDirectory: return "Pi 配置目录"
        }
    }

    static func statusText(for status: DependencyFinding.Status) -> String {
        switch status {
        case .ok: return "正常"
        case .missing: return "缺失"
        case .outdated: return "版本过旧"
        case .occupied: return "被占用"
        case .unreadable: return "不可读"
        case .unknown: return "无法确定"
        }
    }

    static func sourceText(for source: DependencyInstallSource) -> String {
        switch source {
        case .homebrew: return "Homebrew"
        case .npmGlobal: return "npm 全局"
        case .localPath: return "本地路径"
        case .system: return "系统"
        case .unknown: return "未知"
        }
    }

    /// 路径列文本：没有路径时区分“不适用”（系统/端口/配置目录）与“未找到”（可执行文件）。
    static func pathText(for finding: DependencyFinding) -> String {
        if let path = finding.path { return path }
        switch finding.kind {
        case .system, .port, .piConfigDirectory: return "—"
        case .node, .piCLI, .piWeb: return "未找到"
        }
    }

    /// 版本列文本：端口与配置目录没有版本概念，用“—”而不是“未知”。
    static func versionText(for finding: DependencyFinding) -> String {
        if let version = finding.version { return version }
        switch finding.kind {
        case .system, .node, .piCLI, .piWeb: return "未知"
        case .port, .piConfigDirectory: return "—"
        }
    }

    static func confidenceText(for confidence: DependencyFinding.Confidence) -> String {
        switch confidence {
        case .verified: return "已验证"
        case .inferred: return "推断"
        case .unknown: return "未知"
        }
    }

    // MARK: - 组件安装呈现（GitHub #16）

    /// 组件安装的单行摘要（诊断状态页用）：每项都给出路径、包名、版本、来源、
    /// 可信度与建议命令，缺值用占位符。
    static func componentSummaryLines(for report: DependencyReport) -> [String] {
        report.components.map { "· " + $0.summaryLine }
    }

    /// 组件安装块（诊断窗口用）：路径、包名、版本、来源、可信度、建议命令与证据。
    /// 只消费已经脱敏的 `ComponentInstallation`，不执行任何命令。
    static func componentInstallationsText(for report: DependencyReport) -> String {
        guard !report.components.isEmpty else { return "" }
        var lines = ["组件安装（只展示，应用不会执行更新命令）："]
        for component in report.components {
            lines.append("· \(component.kind.displayName)（\(component.kind.rawValue)）")
            lines.append("  路径：\(component.executablePath ?? "未找到")")
            if let resolved = component.resolvedPath, resolved != component.executablePath {
                lines.append("  真实路径：\(resolved)")
            }
            if component.symlinkChain.count > 1 {
                lines.append("  符号链接链：\(component.symlinkChain.joined(separator: " → "))")
            }
            lines.append("  包名：\(component.packageName ?? "未找到")")
            lines.append("  版本：\(component.version ?? "未知")")
            if let packageJSONPath = component.packageJSONPath {
                lines.append("  package.json：\(packageJSONPath)")
            }
            lines.append("  来源：\(component.source.displayName)（\(component.source.rawValue)）")
            lines.append("  可信度：\(component.confidence.displayName)")
            if let command = component.suggestedCommand {
                lines.append("  建议命令：\(command)")
            } else if let guidance = InstallCommandManifest.updateGuidance(for: component.kind, source: component.source) {
                lines.append("  建议命令：无；\(guidance.note)")
            } else {
                lines.append("  建议命令：无；请按来源文档更新。")
            }
            if !component.evidence.isEmpty {
                lines.append("  证据：")
                lines.append(contentsOf: component.evidence.map { "    - \($0)" })
            }
        }
        return lines.joined(separator: "\n")
    }

    static func rows(for report: DependencyReport) -> [Row] {
        report.findings.map { finding in
            Row(
                title: title(for: finding.kind),
                status: statusText(for: finding.status),
                path: pathText(for: finding),
                version: versionText(for: finding),
                source: sourceText(for: finding.installSource),
                confidence: confidenceText(for: finding.confidence),
                note: finding.detail ?? ""
            )
        }
    }

    /// 命令探测失败原因块（GitHub #85 / #89）；每行都只来自
    /// `DependencyFinding.detail`，只含静态文案与工具名，不含路径、凭据或 URL。
    /// 没有原因时返回空串。
    static func diagnosisText(for report: DependencyReport) -> String {
        let lines = report.findings.compactMap { finding -> String? in
            guard let detail = finding.detail, !detail.isEmpty else { return nil }
            return "· \(title(for: finding.kind))：\(detail)"
        }
        guard !lines.isEmpty else { return "" }
        return (["命令探测的原因（只读探测，不会安装任何东西）："] + lines).joined(separator: "\n")
    }

    static func summaryText(for report: DependencyReport) -> String {
        var lines = [report.canStartService ? "结论：可以启动 Pi Web 服务。" : "结论：缺少硬性前置，服务启动已暂停。"]
        for finding in report.findings {
            lines.append("")
            lines.append("\(title(for: finding.kind))：\(statusText(for: finding.status))")
            if let path = finding.path {
                lines.append("  路径：\(path)")
            }
            if let resolvedPath = finding.resolvedPath, resolvedPath != finding.path {
                lines.append("  真实路径：\(resolvedPath)")
            }
            if let symlinkTarget = finding.symlinkTarget {
                lines.append("  符号链接目标：\(symlinkTarget)")
            }
            lines.append("  版本：\(versionText(for: finding))")
            lines.append("  安装来源：\(sourceText(for: finding.installSource))")
            lines.append("  可信度：\(confidenceText(for: finding.confidence))")
            if let detail = finding.detail, !detail.isEmpty {
                lines.append("  原因：\(detail)")
            }
            if finding.kind == .piWeb {
                if let name = finding.packageName {
                    let version = finding.packageVersion.map { "@\($0)" } ?? ""
                    lines.append("  package.json：\(name)\(version)")
                } else {
                    lines.append("  package.json：未找到")
                }
            }
            if let remediationID = finding.remediationID,
               let entry = InstallCommandManifest.entry(withID: remediationID) {
                lines.append("  修复：\(entry.title)（\(sanitize(url: entry.documentationURL))）")
            }
            if let nextStep = nextStepText(for: finding) {
                lines.append("  下一步：\(nextStep)")
            }
        }
        return lines.joined(separator: "\n")
    }

    /// 单个诊断项的下一步操作提示；不需要提示时返回 nil。
    ///
    /// 端口与 Pi 配置目录永远返回 nil 到“修复命令”路径：它们不阻塞启动，
    /// 文本里只给可读说明，不会让应用去安装、创建或读取任何东西。
    static func nextStepText(for finding: DependencyFinding) -> String? {
        // 探针超时是可读原因，优先于“缺失/版本无法解析”的常规建议：先让用户知道
        // 是探测没有返回，而不是环境真的缺件。
        if finding.status != .ok, let detail = finding.detail {
            return "\(detail)。请检查登录 shell（~/.zprofile 等）是否会阻塞命令，然后点击“重新检测”。"
        }
        switch finding.kind {
        case .system:
            return finding.status == .ok ? nil : "系统项只做提示，不阻塞启动。"
        case .node:
            return finding.status == .ok ? nil : "安装或升级 Node.js 到最低版本，然后点击“重新检测”。"
        case .piCLI:
            guard finding.status != .ok else { return nil }
            return "安装 Pi CLI（命令见诊断窗口的“复制安装命令”），然后点击“重新检测”。"
        case .piWeb:
            switch finding.status {
            case .ok:
                return nil
            case .missing:
                return "安装 Pi Web，或在诊断窗口点击“选择 pi-web 路径…”指定已安装的可执行文件。"
            default:
                return "已找到 pi-web，但版本无法解析；不影响启动。"
            }
        case .port:
            switch finding.status {
            case .occupied:
                return "端口被占用不会阻塞启动；如果占用者是已有的 Pi Web 服务，应用会直接使用它，否则请在“设置”里更换端口。"
            case .unknown:
                return "无法确认端口占用情况，不影响启动。"
            default:
                return nil
            }
        case .piConfigDirectory:
            switch finding.status {
            case .missing:
                return "尚未创建 Pi 配置目录（~/\(DependencyChecker.piConfigurationDirectoryRelativePath)）：先运行一次 Pi CLI；应用不会创建该目录，也不会读取其中的认证文件。"
            case .unreadable, .unknown:
                return "无法确认 Pi 配置目录的存在与可读性；不影响启动，应用不会读取目录内容。"
            default:
                return nil
            }
        }
    }

    /// 首次启动诊断状态页正文（WebView 与诊断窗口共用）。
    ///
    /// 只输出已脱敏的报告字段和静态文案；不包含 URL 查询参数、凭据或真实
    /// 用户绝对路径。硬性前置缺失时列出缺失项与下一步操作；就绪但首次设置
    /// 尚未完成时说明如何进入主窗口。
    static func statusPageText(for report: DependencyReport, setupIncomplete: Bool) -> String {
        var lines: [String] = []
        if report.canStartService {
            lines.append("结论：硬性前置已满足。")
            if setupIncomplete {
                lines.append("首次设置尚未完成：请点击“开始使用 Pi Web”，或在诊断窗口点击“重新检测”后进入主窗口。")
            } else {
                lines.append("服务可以启动。")
            }
        } else {
            lines.append("结论：缺少硬性前置，服务启动已暂停。应用会保留窗口，不会退出。")
        }

        lines.append("")
        lines.append("诊断结果：")
        for finding in report.findings {
            // 每一项都输出完整的五个字段，缺值用占位符，不因 nil 省略整行。
            var fields = [
                "· \(title(for: finding.kind))：\(statusText(for: finding.status))",
                "路径：\(pathText(for: finding))",
                "版本：\(versionText(for: finding))",
                "来源：\(sourceText(for: finding.installSource))",
                "可信度：\(confidenceText(for: finding.confidence))"
            ]
            // 探测超时是阻塞门控的直接原因，附在行尾（缺省时不输出这一列）。
            if let detail = finding.detail {
                fields.append("原因：\(detail)")
            }
            lines.append(fields.joined(separator: "  "))

        }

        let componentLines = componentSummaryLines(for: report)
        if !componentLines.isEmpty {
            lines.append("")
            lines.append("组件安装（只展示，应用不会执行更新命令）：")
            lines.append(contentsOf: componentLines)
        }

        let hints = report.findings.compactMap { finding -> String? in
            guard let nextStep = nextStepText(for: finding) else { return nil }
            return "· \(title(for: finding.kind))：\(nextStep)"
        }
        if !hints.isEmpty {
            lines.append("")
            lines.append("下一步：")
            lines.append(contentsOf: hints)
        }
        return lines.joined(separator: "\n")
    }

    /// 只包含当前诊断引用到的修复项，保持 `InstallCommandManifest` 的固定顺序。
    static func remediationEntries(for report: DependencyReport) -> [InstallCommandManifest.Entry] {
        var seen = Set<String>()
        var entries: [InstallCommandManifest.Entry] = []
        for finding in report.findings {
            guard let remediationID = finding.remediationID,
                  !seen.contains(remediationID),
                  let entry = InstallCommandManifest.entry(withID: remediationID) else { continue }
            seen.insert(remediationID)
            entries.append(entry)
        }
        return entries
    }

    /// 供“复制安装命令”使用的文本；没有需要修复的条目时返回空串。
    static func installCommandsText(for report: DependencyReport) -> String {
        let entries = remediationEntries(for: report)
        guard !entries.isEmpty else { return "" }
        return entries.map { entry in
            var lines = [entry.title]
            if let command = entry.command {
                lines.append("  \(command)")
            }
            lines.append("  说明：\(entry.note)")
            lines.append("  文档：\(sanitize(url: entry.documentationURL))")
            return lines.joined(separator: "\n")
        }.joined(separator: "\n\n")
    }

    /// 去掉 URL 里的 userinfo、query 和 fragment，避免把凭据或追踪参数带进
    /// 诊断文本。无法解析时原样返回。
    static func sanitize(url text: String) -> String {
        guard var components = URLComponents(string: text) else { return text }
        components.user = nil
        components.password = nil
        components.query = nil
        components.fragment = nil
        return components.string ?? text
    }
}
