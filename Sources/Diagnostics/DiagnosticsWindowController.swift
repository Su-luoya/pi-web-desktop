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
    /// 由 `AppDelegate` 注入：手动“检查更新…”入口（GitHub #21）。
    /// 窗口不执行命令：确认框、进程信息与执行都由 `AppDelegate` 负责。
    var onUpdatePiCLI: (() -> Void)?

    private let tableView = NSTableView()
    private let detailLabel = WrappingLabel(labelWithString: "")
    private let hintLabel = WrappingLabel(labelWithString: "")
    private let componentsTextView = NSTextView()
    private let commandsTextView = NSTextView()
    private let updateStatusTextView = NSTextView()
    private let copyButton = NSButton(title: "复制安装命令", target: nil, action: nil)
    private let copyDiagnosticsButton = NSButton(title: "复制诊断", target: nil, action: nil)
    private let continueButton = NSButton(title: "开始使用 Pi Web", target: nil, action: nil)
    private let updatePiCLIButton = NSButton(title: "检查更新…", target: nil, action: nil)
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

    /// 只负责“拼装”：把标签、表格、三个代码框、四个按钮行按顺序放进文档视图，
    /// 再套上窗口外壳。每个部件自己怎么配置，看下面各自的小函数。
    private func buildWindow() {
        configureLabels()
        configureCommandButtons()

        let tableScroll = makeResultsTableScrollView()
        let componentsScroll = makeCodeScrollView(for: componentsTextView, accessibilityLabel: "组件安装信息")
        let updateStatusScroll = makeCodeScrollView(for: updateStatusTextView, accessibilityLabel: "更新检查状态")
        let commandsScroll = makeCodeScrollView(for: commandsTextView, accessibilityLabel: "待手动执行的安装命令")

        let repairRow = makeActionRow([
            NSButton(title: "选择 pi-web 路径…", target: self, action: #selector(selectPiWebPath(_:))),
            NSButton(title: "重新检测", target: self, action: #selector(recheck(_:))),
            NSView()
        ])
        let updateRow = makeActionRow([makeSectionHeader("更新检查"), NSView(), updatePiCLIButton])
        let commandRow = makeActionRow([makeSectionHeader("安装命令"), NSView(), copyButton])

        let closeButton = NSButton(title: "关闭", target: self, action: #selector(closeWindow(_:)))
        closeButton.keyEquivalent = "\u{1b}"
        let footerRow = makeActionRow([copyDiagnosticsButton, NSView(), closeButton, continueButton])

        let commandsHint = WrappingLabel(labelWithString: "以下命令仅供复制，请在终端中自行执行。应用不会执行这些命令。")
        SettingsFormMetrics.configureHint(commandsHint)
        commandsHint.font = NSFont.systemFont(ofSize: 12)

        let title = NSTextField(labelWithString: "依赖与环境诊断")
        title.font = NSFont.systemFont(ofSize: 22, weight: .semibold)

        let document = makeDocumentScrollView(
            arrangedSubviews: [
                title, detailLabel, hintLabel, repairRow, tableScroll,
                makeSectionHeader("组件安装"), componentsScroll, updateRow, updateStatusScroll,
                commandRow, commandsHint, commandsScroll
            ],
            fixedHeights: [
                (tableScroll, 180),
                (componentsScroll, 150),
                (updateStatusScroll, 112),
                (commandsScroll, 132)
            ]
        )

        self.window = makeWindow(document: document, footerRow: footerRow)
    }

    private func configureLabels() {
        SettingsFormMetrics.configureHint(detailLabel, color: .labelColor)
        SettingsFormMetrics.configureHint(hintLabel, color: .systemRed)
        hintLabel.isHidden = true
    }

    private func configureCommandButtons() {
        copyButton.target = self
        copyButton.action = #selector(copyInstallCommands(_:))
        copyDiagnosticsButton.target = self
        copyDiagnosticsButton.action = #selector(copyDiagnostics(_:))
        continueButton.target = self
        continueButton.action = #selector(continueToService(_:))
        continueButton.keyEquivalent = "\r"
        updatePiCLIButton.target = self
        updatePiCLIButton.action = #selector(updatePiCLI(_:))
        updatePiCLIButton.toolTip = "执行前显示计划、运行中的 Pi 进程与风险说明，并要求确认；只调用 pi update --self"
    }

    private func makeSectionHeader(_ title: String) -> NSTextField {
        let header = NSTextField(labelWithString: title)
        header.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        return header
    }

    /// 横向操作行：左侧标题/按钮、中间弹性空白、右侧按钮。四个行共用同一套
    /// 间距与对齐，按钮统一用 `.rounded` 样式。
    private func makeActionRow(_ views: [NSView]) -> NSStackView {
        for case let button as NSButton in views {
            button.bezelStyle = .rounded
        }
        let row = NSStackView(views: views)
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        return row
    }

    /// 三个等宽代码视图（组件安装 / 更新检查 / 安装命令）的公共配置：
    /// 只读可选中、等宽 12 号、纵向可伸缩、宽度跟随容器。
    private func configureCodeTextView(_ textView: NSTextView, accessibilityLabel: String) {
        textView.isEditable = false
        textView.isSelectable = true
        textView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.setAccessibilityLabel(accessibilityLabel)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.textContainer?.widthTracksTextView = true
    }

    private func makeCodeScrollView(for textView: NSTextView, accessibilityLabel: String) -> NSScrollView {
        configureCodeTextView(textView, accessibilityLabel: accessibilityLabel)
        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        return scrollView
    }

    private func makeResultsTableScrollView() -> NSScrollView {
        for column in Column.allCases {
            let tableColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(column.rawValue))
            tableColumn.title = column.title
            tableColumn.width = column.width
            tableColumn.minWidth = min(column.width, 80)
            tableView.addTableColumn(tableColumn)
        }
        tableView.dataSource = self
        tableView.delegate = self
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsMultipleSelection = false
        tableView.rowHeight = 28
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        tableView.setAccessibilityLabel("依赖与环境检查结果")

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        return scrollView
    }

    /// 把纵向排列的各个区块装进一个可滚动文档视图。`fixedHeights` 里每一项既是
    /// 固定高度的代码框/表格，也是需要额外 20 点留白的段落边界。
    private func makeDocumentScrollView(
        arrangedSubviews: [NSView],
        fixedHeights: [(view: NSScrollView, height: CGFloat)]
    ) -> (scrollView: NSScrollView, content: NSView) {
        let content = FlippedDocumentView()
        content.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: arrangedSubviews)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        for entry in fixedHeights {
            stack.setCustomSpacing(20, after: entry.view)
            entry.view.heightAnchor.constraint(equalToConstant: entry.height).isActive = true
        }
        content.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -24)
        ])
        for view in stack.arrangedSubviews {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }

        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.horizontalScrollElasticity = .none
        scrollView.documentView = content
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        return (scrollView, content)
    }

    /// 窗口外壳：可滚动文档区 + 分隔线 + 底部操作行。
    private func makeWindow(
        document: (scrollView: NSScrollView, content: NSView),
        footerRow: NSStackView
    ) -> NSWindow {
        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.addSubview(document.scrollView)
        container.addSubview(separator)
        container.addSubview(footerRow)
        NSLayoutConstraint.activate([
            document.scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            document.scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            document.scrollView.topAnchor.constraint(equalTo: container.topAnchor),
            document.scrollView.bottomAnchor.constraint(equalTo: separator.topAnchor, constant: -12),
            separator.leadingAnchor.constraint(equalTo: footerRow.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: footerRow.trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: footerRow.topAnchor, constant: -12),
            footerRow.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 24),
            footerRow.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -24),
            footerRow.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -24),
            document.content.leadingAnchor.constraint(equalTo: document.scrollView.contentView.leadingAnchor),
            document.content.topAnchor.constraint(equalTo: document.scrollView.contentView.topAnchor),
            document.content.widthAnchor.constraint(equalTo: document.scrollView.contentView.widthAnchor)
        ])

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 860, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Pi Web Desktop 依赖与环境诊断"
        window.contentView = container
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 680, height: 480)
        window.center()
        return window
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
        panel.allowedContentTypes = [.unixExecutable]
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
        if !DiagnosticsClipboard.copy(commands) {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "复制失败"
            alert.informativeText = "安装命令未能写入剪贴板，请再试一次。"
            if let window, window.isVisible {
                alert.beginSheetModal(for: window, completionHandler: nil)
            } else {
                alert.runModal()
            }
        }
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
