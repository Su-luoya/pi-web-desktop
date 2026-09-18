import Cocoa

/// 首次依赖诊断窗口（GitHub #6 的最小可用版本，供 #7 扩展）。
///
/// 窗口只做两件事：展示已经算好的 `DependencyReport`，以及把
/// `InstallCommandManifest` 里的静态命令复制到剪贴板。“重新检测”只是请
/// `AppDelegate` 再跑一次 `DependencyChecker`；窗口自身不执行任何安装命令、
/// 不调用 `sudo`、不联网，也不读取认证内容。
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

    private let tableView = NSTableView()
    private let detailLabel = NSTextField(labelWithString: "")
    private let commandsTextView = NSTextView()
    private let copyButton = NSButton(title: "复制安装命令", target: nil, action: nil)
    private var report: DependencyReport

    init(report: DependencyReport) {
        self.report = report
        super.init(window: nil)
        buildWindow()
        update(report: report)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// 用新的诊断结果刷新表格和安装命令；窗口本身不重新执行检查。
    func update(report: DependencyReport) {
        self.report = report
        tableView.reloadData()
        let commands = DependencyReportPresenter.installCommandsText(for: report)
        commandsTextView.string = commands.isEmpty ? "当前没有需要修复的依赖。" : commands
        copyButton.isEnabled = !commands.isEmpty
        detailLabel.stringValue = report.canStartService
            ? "未发现阻塞启动的依赖问题。安装命令只供复制，应用不会执行。"
            : "缺少硬性前置，服务启动已暂停。请复制下面的命令自行安装或升级，然后点击“重新检测”。"
    }

    // MARK: - 界面

    private func buildWindow() {
        let content = NSView()

        let title = NSTextField(labelWithString: "依赖与环境诊断")
        title.font = NSFont.systemFont(ofSize: 22, weight: .semibold)

        detailLabel.lineBreakMode = .byWordWrapping
        detailLabel.maximumNumberOfLines = 3

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
        let recheckButton = NSButton(title: "重新检测", target: self, action: #selector(recheck(_:)))
        let closeButton = NSButton(title: "关闭", target: self, action: #selector(closeWindow(_:)))
        closeButton.keyEquivalent = "\u{1b}"

        let buttons = NSStackView(views: [recheckButton, copyButton, NSView(), closeButton])
        buttons.orientation = .horizontal
        buttons.alignment = .centerY
        buttons.spacing = 8
        buttons.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [title, detailLabel, tableScroll, commandsHeader, commandsScroll, buttons])
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
            tableScroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            tableScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 200),
            commandsHeader.widthAnchor.constraint(equalTo: stack.widthAnchor),
            commandsScroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            commandsScroll.heightAnchor.constraint(equalToConstant: 132),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 820, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Pi Web Desktop 依赖与环境诊断"
        window.contentView = content
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 700, height: 460)
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
        case .path: return finding.path ?? (finding.kind == .system ? "—" : "未找到")
        case .version: return finding.version ?? "未知"
        case .source: return DependencyReportPresenter.sourceText(for: finding.installSource)
        case .confidence: return DependencyReportPresenter.confidenceText(for: finding.confidence)
        }
    }

    // MARK: - 动作

    @objc private func recheck(_ sender: Any?) {
        onRecheck?()
    }

    @objc private func copyInstallCommands(_ sender: Any?) {
        let commands = DependencyReportPresenter.installCommandsText(for: report)
        guard !commands.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(commands, forType: .string)
    }

    @objc private func closeWindow(_ sender: Any?) {
        close()
    }
}
