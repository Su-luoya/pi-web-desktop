import Cocoa

/// 首次启动诊断窗口（GitHub #6 的最小版本，GitHub #7 扩展为状态页）。
///
/// 窗口展示已经算好的 `DependencyReport`（系统、Node.js、Pi CLI、Pi Web、
/// 默认端口、Pi 配置目录），提供“选择 pi-web 路径…”“复制安装命令”“重新检测”，
/// 并在硬性前置就绪时提供“开始使用 Pi Web”。它只渲染报告和收集用户选择：
/// 重新检测、写入配置和路由都由 `AppDelegate` 完成。窗口自身不执行任何安装命令、
/// 不调用 `sudo`、不联网，也不读取认证内容。

/// First-launch diagnostics window controller.

final class DiagnosticsWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    private enum Column: String, CaseIterable {
        case item
        case status
        case path
        case version
        case source
        case confidence

        var title: String {
            switch self {
            case .item: return "诊断项"
            case .status: return "状态"
            case .path: return "路径"
            case .version: return "版本"
            case .source: return "来源"
            case .confidence: return "可信度"
            }
        }

        var width: CGFloat {
            switch self {
            case .item: return 78
            case .status: return 76
            case .path: return 260
            case .version: return 140
            case .source: return 96
            case .confidence: return 72
            }
        }
    }

    /// 由 `AppDelegate` 注入：请求重新运行诊断。窗口不直接持有 `DependencyChecker`。
    var onRecheck: (() -> Void)?
    /// 首次启动诊断页的“开始使用 Pi Web”动作。
    var onContinue: (() -> Void)?
    /// 用户选择 pi-web 可执行文件后的回调；返回可读错误（nil 表示已写入配置
    /// 并触发了重新检测）。窗口不写配置、不校验可执行性。
    var onSelectPiWebPath: ((String) -> String?)?
    /// 由 `AppDelegate` 注入：诊断导出动作（脱敏提醒 → 后台采集 → 回主线程复制，
    /// W4 M3）。窗口自己不组装字段、不执行命令，也不在同步调用里阻塞主线程。
    var onExportDiagnostics: (() -> Void)?
    /// 由 `AppDelegate` 注入：更新检查状态行（GitHub #18：策略、最近检查、
    /// 结果、忽略版本、下次检查）。窗口只渲染，不读设置、不联网、不安装。
    var updateStatusTextProvider: (() -> String)?
    /// 由 `AppDelegate` 注入：手动“立即更新 Pi CLI…”入口（GitHub #21）。
    /// 窗口不执行命令：确认框、进程信息与执行都由 `AppDelegate` 负责。
    var onUpdatePiCLI: (() -> Void)?

    private let tableView = NSTableView()
    private let detailLabel = NSTextField(labelWithString: "")
    private let hintLabel = NSTextField(labelWithString: "")
    private let componentsTextView = NSTextView()
    private let commandsTextView = NSTextView()
    private let updateStatusTextView = NSTextView()
    private let copyButton = NSButton(title: "复制安装命令", target: nil, action: nil)
    private let copyDiagnosticsButton = NSButton(title: "复制诊断", target: nil, action: nil)
    private let continueButton = NSButton(title: "开始使用 Pi Web", target: nil, action: nil)
    private let updatePiCLIButton = NSButton(title: "立即更新 Pi CLI…", target: nil, action: nil)
    private var report: DependencyReport
    private var firstLaunchSetupIncomplete: Bool
    private var canContinueToService: Bool
    /// 工作目录不可用时的可读修复提示（GitHub #9）；nil 表示目录可用。
    private var workspaceMessage: String?

    init(
        report: DependencyReport,
        firstLaunchSetupIncomplete: Bool,
        canContinueToService: Bool,
        workspaceMessage: String? = nil
    ) {
        self.report = report
        self.firstLaunchSetupIncomplete = firstLaunchSetupIncomplete
        self.canContinueToService = canContinueToService
        self.workspaceMessage = workspaceMessage
        super.init(window: nil)
        buildWindow()
        update(
            report: report,
            firstLaunchSetupIncomplete: firstLaunchSetupIncomplete,
            canContinueToService: canContinueToService,
            workspaceMessage: workspaceMessage
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// 用新的诊断结果刷新表格和安装命令；窗口本身不重新执行检查。
    /// `workspaceMessage` 非 nil 时在详情行里额外给出工作目录的可读修复提示。
    func update(
        report: DependencyReport,
        firstLaunchSetupIncomplete: Bool,
        canContinueToService: Bool,
        workspaceMessage: String? = nil
    ) {
        self.report = report
        self.firstLaunchSetupIncomplete = firstLaunchSetupIncomplete
        self.canContinueToService = canContinueToService
        self.workspaceMessage = workspaceMessage
        tableView.reloadData()
        // 组件安装识别（GitHub #16）：只渲染已经脱敏的报告字段。
        let components = DependencyReportPresenter.componentInstallationsText(for: report)
        componentsTextView.string = components.isEmpty ? "未检测到组件安装信息。" : components
        let commands = DependencyReportPresenter.installCommandsText(for: report)
        commandsTextView.string = commands.isEmpty ? "当前没有需要修复的依赖。" : commands
        copyButton.isEnabled = !commands.isEmpty
        refreshUpdateStatus()
        updateLabels()
    }

    /// 刷新“更新检查”状态块（策略 / 最近检查 / 结果 / 忽略版本 / 下次检查）。
    func refreshUpdateStatus() {
        let text = updateStatusTextProvider?() ?? ""
        updateStatusTextView.string = text.isEmpty ? "更新检查状态不可用。" : text
    }

    private func updateLabels() {
        if let workspaceMessage, !workspaceMessage.isEmpty {
            detailLabel.stringValue = "工作目录不可用，服务与 WebView 已暂停。\(workspaceMessage)"
        } else if canContinueToService {
            detailLabel.stringValue = firstLaunchSetupIncomplete
                ? "硬性前置已满足。点击“开始使用 Pi Web”完成首次设置并进入服务页面。"
                : "未发现阻塞启动的依赖问题。安装命令只供复制，应用不会执行。"
        } else {
            detailLabel.stringValue = "缺少硬性前置，服务与 WebView 已暂停。请复制下面的命令自行安装或升级，或选择 pi-web 路径，然后点击“重新检测”。"
        }
        continueButton.isEnabled = canContinueToService
    }

    /// 路径选择的可读错误（或 nil 清除）；不修改报告和配置。
    private func showPathSelectionError(_ message: String?) {
        hintLabel.stringValue = message ?? ""
        hintLabel.isHidden = message == nil
    }

    // MARK: - 界面

    private func buildWindow() {
        let content = NSView()

        let title = NSTextField(labelWithString: "依赖与环境诊断")
        title.font = NSFont.systemFont(ofSize: 22, weight: .semibold)

        detailLabel.lineBreakMode = .byWordWrapping
        detailLabel.maximumNumberOfLines = 4

        hintLabel.lineBreakMode = .byWordWrapping
        hintLabel.maximumNumberOfLines = 3
        hintLabel.textColor = .systemRed
        hintLabel.isHidden = true

        for column in Column.allCases {
            let tableColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(column.rawValue))
            tableColumn.title = column.title
            tableColumn.width = column.width
            tableView.addTableColumn(tableColumn)
        }
        tableView.dataSource = self
        tableView.delegate = self
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsMultipleSelection = false
        tableView.rowHeight = 24
        tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle

        let tableScroll = NSScrollView()
        tableScroll.documentView = tableView
        tableScroll.hasVerticalScroller = true
        tableScroll.borderType = .bezelBorder
        tableScroll.translatesAutoresizingMaskIntoConstraints = false

        let componentsHeader = NSTextField(labelWithString: "组件安装（路径 / 包名 / 版本 / 来源 / 可信度 / 建议命令；只展示，应用不会执行更新）")
        componentsHeader.font = NSFont.systemFont(ofSize: 13, weight: .semibold)

        let updateHeader = NSTextField(labelWithString: "更新检查（策略 / 最近检查 / 结果 / 忽略版本 / 下次检查；Pi CLI 的启动前自动更新受运行进程保护限制）")
        updateHeader.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        updateStatusTextView.isEditable = false
        updateStatusTextView.isSelectable = true
        updateStatusTextView.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        updateStatusTextView.isVerticallyResizable = true
        updateStatusTextView.isHorizontallyResizable = false
        updateStatusTextView.autoresizingMask = [.width]
        updateStatusTextView.textContainerInset = NSSize(width: 4, height: 4)
        updateStatusTextView.textContainer?.widthTracksTextView = true

        let updateStatusScroll = NSScrollView()
        updateStatusScroll.documentView = updateStatusTextView
        updateStatusScroll.hasVerticalScroller = true
        updateStatusScroll.borderType = .bezelBorder
        updateStatusScroll.translatesAutoresizingMaskIntoConstraints = false

        componentsTextView.isEditable = false
        componentsTextView.isSelectable = true
        componentsTextView.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        componentsTextView.isVerticallyResizable = true
        componentsTextView.isHorizontallyResizable = false
        componentsTextView.autoresizingMask = [.width]
        componentsTextView.textContainerInset = NSSize(width: 4, height: 4)
        componentsTextView.textContainer?.widthTracksTextView = true

        let componentsScroll = NSScrollView()
        componentsScroll.documentView = componentsTextView
        componentsScroll.hasVerticalScroller = true
        componentsScroll.borderType = .bezelBorder
        componentsScroll.translatesAutoresizingMaskIntoConstraints = false

        let commandsHeader = NSTextField(labelWithString: "安装命令（只展示与复制，应用不会执行）")
        commandsHeader.font = NSFont.systemFont(ofSize: 13, weight: .semibold)

        commandsTextView.isEditable = false
        commandsTextView.isSelectable = true
        commandsTextView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        commandsTextView.isVerticallyResizable = true
        commandsTextView.isHorizontallyResizable = false
        commandsTextView.autoresizingMask = [.width]
        commandsTextView.textContainerInset = NSSize(width: 4, height: 4)
        commandsTextView.textContainer?.widthTracksTextView = true

        let commandsScroll = NSScrollView()
        commandsScroll.documentView = commandsTextView
        commandsScroll.hasVerticalScroller = true
        commandsScroll.borderType = .bezelBorder
        commandsScroll.translatesAutoresizingMaskIntoConstraints = false

        copyButton.target = self
        copyButton.action = #selector(copyInstallCommands(_:))
        copyDiagnosticsButton.target = self
        copyDiagnosticsButton.action = #selector(copyDiagnostics(_:))
        continueButton.target = self
        continueButton.action = #selector(continueToService(_:))
        updatePiCLIButton.target = self
        updatePiCLIButton.action = #selector(updatePiCLI(_:))
        updatePiCLIButton.toolTip = "执行前显示计划、运行中的 Pi 进程与风险说明，并要求确认；只调用 pi update --self"
        let selectButton = NSButton(title: "选择 pi-web 路径…", target: self, action: #selector(selectPiWebPath(_:)))
        let recheckButton = NSButton(title: "重新检测", target: self, action: #selector(recheck(_:)))
        let closeButton = NSButton(title: "关闭", target: self, action: #selector(closeWindow(_:)))
        closeButton.keyEquivalent = "\u{1b}"

        let buttons = NSStackView(views: [selectButton, recheckButton, copyButton, copyDiagnosticsButton, updatePiCLIButton, continueButton, NSView(), closeButton])
        buttons.orientation = .horizontal
        buttons.alignment = .centerY
        buttons.spacing = 8
        buttons.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [title, detailLabel, hintLabel, tableScroll, componentsHeader, componentsScroll, updateHeader, updateStatusScroll, commandsHeader, commandsScroll, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
            title.widthAnchor.constraint(equalTo: stack.widthAnchor),
            detailLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            hintLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            tableScroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            tableScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 180),
            componentsHeader.widthAnchor.constraint(equalTo: stack.widthAnchor),
            componentsScroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            componentsScroll.heightAnchor.constraint(equalToConstant: 150),
            updateHeader.widthAnchor.constraint(equalTo: stack.widthAnchor),
            updateStatusScroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            updateStatusScroll.heightAnchor.constraint(equalToConstant: 96),
            commandsHeader.widthAnchor.constraint(equalTo: stack.widthAnchor),
            commandsScroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            commandsScroll.heightAnchor.constraint(equalToConstant: 132),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 860, height: 880),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Pi Web Desktop 依赖与环境诊断"
        window.contentView = content
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 760, height: 680)
        window.center()
        self.window = window
    }

    // MARK: - NSTableViewDataSource / NSTableViewDelegate

    func numberOfRows(in tableView: NSTableView) -> Int {
        report.findings.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let tableColumn,
              let column = Column(rawValue: tableColumn.identifier.rawValue),
              report.findings.indices.contains(row) else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("diagnostics-cell-\(column.rawValue)")
        let cell: NSTextField
        if let reused = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTextField {
            cell = reused
        } else {
            cell = NSTextField(labelWithString: "")
            cell.identifier = identifier
            cell.font = NSFont.systemFont(ofSize: 12)
            cell.lineBreakMode = .byTruncatingMiddle
        }
        let finding = report.findings[row]
        cell.stringValue = value(for: column, finding: finding)
        cell.toolTip = cell.stringValue
        return cell
    }

    private func value(for column: Column, finding: DependencyFinding) -> String {
        switch column {
        case .item: return DependencyReportPresenter.title(for: finding.kind)
        case .status: return DependencyReportPresenter.statusText(for: finding.status)
        case .path: return DependencyReportPresenter.pathText(for: finding)
        case .version: return DependencyReportPresenter.versionText(for: finding)
        case .source: return DependencyReportPresenter.sourceText(for: finding.installSource)
        case .confidence: return DependencyReportPresenter.confidenceText(for: finding.confidence)
        }
    }

    // MARK: - 动作

    @objc private func recheck(_ sender: Any?) {
        showPathSelectionError(nil)
        onRecheck?()
    }

    @objc private func continueToService(_ sender: Any?) {
        guard canContinueToService else { return }
        onContinue?()
    }

    /// 手动更新 Pi CLI 的入口：窗口只转发，确认与执行都在 `AppDelegate` 里。
    @objc private func updatePiCLI(_ sender: Any?) {
        onUpdatePiCLI?()
    }

    /// 面板只负责选择文件；可执行性校验与写入配置由 `AppDelegate` 完成，
    /// 失败时把可读错误显示在窗口里，配置保持不变。
    @objc private func selectPiWebPath(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "选择"
        panel.message = "选择已安装的 pi-web 可执行文件"
        if #available(macOS 12.0, *) {
            panel.allowedContentTypes = [.unixExecutable]
        }
        let complete: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            let error = self.onSelectPiWebPath?(url.path)
            self.showPathSelectionError(error)
        }
        if let window {
            panel.beginSheetModal(for: window, completionHandler: complete)
        } else {
            complete(panel.runModal())
        }
    }

    @objc private func copyInstallCommands(_ sender: Any?) {
        let commands = DependencyReportPresenter.installCommandsText(for: report)
        guard !commands.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(commands, forType: .string)
    }

    /// 与菜单“复制诊断”同一份提醒文本、同一条导出路径（W4 M3）：窗口只转发，
    /// 提醒、后台采集与复制都在 `AppDelegate`。
    @objc func copyDiagnostics(_ sender: Any?) {
        onExportDiagnostics?()
    }

    @objc private func closeWindow(_ sender: Any?) {
        close()
    }
}
