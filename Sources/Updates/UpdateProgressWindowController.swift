import Cocoa

/// “更新进度”窗口（GitHub #219）。
///
/// 只渲染 `AppDelegate` 推过来的 `UpdateProgressSession` 快照：不联网、不执行命令、
/// 不读写配置、不读设置，也不决定什么时候开始或结束一次更新。所有文本（阶段原因、
/// 日志行）都由 `AppDelegate` 侧的固定文案与已脱敏结果组成。
///
/// 窗口本身只做三件自己的事：把快照画出来、走一个 1 秒的计时器刷新“已用时长”、
/// 以及把「复制诊断」「关闭」两个按钮转给 `AppDelegate`。

/// Update progress window controller.

final class UpdateProgressWindowController: NSWindowController, NSWindowDelegate,
    NSTableViewDataSource, NSTableViewDelegate {
    private enum Column: String, CaseIterable {
        case symbol
        case stage
        case detail

        var title: String {
            switch self {
            case .symbol: return ""
            case .stage: return "阶段"
            case .detail: return "说明"
            }
        }

        var width: CGFloat {
            switch self {
            case .symbol: return 26
            case .stage: return 96
            case .detail: return 380
            }
        }

        var identifier: NSUserInterfaceItemIdentifier { NSUserInterfaceItemIdentifier(rawValue) }
    }

    /// 由 `AppDelegate` 注入：复用现有脱敏诊断导出。窗口不采集任何内容。
    var onCopyDiagnostics: (() -> Void)?
    /// 窗口关闭（自动关闭或用户点关闭）后回调，让 `AppDelegate` 释放引用。
    var onClose: (() -> Void)?

    private let titleLabel = NSTextField(labelWithString: "更新进度")
    private let statusLabel = NSTextField(labelWithString: "")
    private let tableView = NSTableView()
    private let stepsScrollView = NSScrollView()
    private let logTextView = NSTextView()
    private let logScrollView = NSScrollView()
    private let elapsedLabel = NSTextField(labelWithString: "")
    private let copyButton = NSButton(title: "复制诊断", target: nil, action: nil)
    private let closeButton = NSButton(title: "关闭", target: nil, action: nil)

    private var session: UpdateProgressSession?
    /// 1 秒计时器：只在有未结束的会话时存在，窗口关闭或会话结束时必须停掉。
    private var elapsedTimer: Timer?

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 560),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "更新进度"
        window.minSize = NSSize(width: 520, height: 420)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        buildContent()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        elapsedTimer?.invalidate()
    }

    // MARK: - 对外接口

    /// 渲染一份快照。nil 表示清空（没有进行中也没有最近一次更新）。
    func render(_ session: UpdateProgressSession?) {
        self.session = session
        guard let session else {
            titleLabel.stringValue = "更新进度"
            statusLabel.stringValue = "当前没有进行中的更新。"
            tableView.reloadData()
            logTextView.string = ""
            elapsedLabel.stringValue = ""
            stopTimer()
            return
        }
        titleLabel.stringValue = session.title
        statusLabel.stringValue = Self.statusText(for: session)
        tableView.reloadData()
        renderLog(session)
        elapsedLabel.stringValue = session.statusLine(at: Date())
        if session.isFinished {
            stopTimer()
        } else {
            startTimer()
        }
    }

    /// 把窗口提到最前并显示。已经显示时只提到最前，不重建窗口。
    func present(activating: Bool) {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        if activating, !NSApp.isActive {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    /// 结束会话后延迟自动关闭（成功路径）。失败时调用方不会调它。
    func closeAfterDelay(_ delay: TimeInterval) {
        let expected = session
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, let current = self.session, current == expected, current.isFinished else { return }
            self.window?.performClose(nil)
        }
    }

    // MARK: - 界面

    private func buildContent() {
        guard let contentView = window?.contentView else { return }
        contentView.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.font = NSFont.systemFont(ofSize: 16, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail

        statusLabel.font = NSFont.systemFont(ofSize: 12)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.maximumNumberOfLines = 2
        statusLabel.lineBreakMode = .byWordWrapping

        for kind in Column.allCases {
            let column = NSTableColumn(identifier: kind.identifier)
            column.title = kind.title
            column.width = kind.width
            column.minWidth = kind == .detail ? 200 : kind.width
            tableView.addTableColumn(column)
        }
        tableView.headerView = nil
        tableView.rowHeight = 22
        tableView.allowsMultipleSelection = false
        tableView.allowsEmptySelection = true
        tableView.dataSource = self
        tableView.delegate = self
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.style = .inset
        stepsScrollView.documentView = tableView
        stepsScrollView.hasVerticalScroller = true
        stepsScrollView.borderType = .bezelBorder
        stepsScrollView.translatesAutoresizingMaskIntoConstraints = false

        logTextView.isEditable = false
        logTextView.isSelectable = true
        logTextView.drawsBackground = false
        logTextView.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        logTextView.textColor = .labelColor
        logTextView.textContainerInset = NSSize(width: 6, height: 6)
        logTextView.autoresizingMask = [.width]
        logTextView.isVerticallyResizable = true
        logTextView.isHorizontallyResizable = false
        logTextView.textContainer?.widthTracksTextView = true
        logScrollView.documentView = logTextView
        logScrollView.hasVerticalScroller = true
        logScrollView.borderType = .bezelBorder
        logScrollView.translatesAutoresizingMaskIntoConstraints = false

        elapsedLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        elapsedLabel.textColor = .secondaryLabelColor

        copyButton.target = self
        copyButton.action = #selector(copyDiagnostics(_:))
        copyButton.bezelStyle = .rounded
        closeButton.target = self
        closeButton.action = #selector(closeWindow(_:))
        closeButton.bezelStyle = .rounded
        closeButton.keyEquivalent = "\r"

        let logCaption = NSTextField(labelWithString: "过程日志（已脱敏）")
        logCaption.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        logCaption.textColor = .secondaryLabelColor

        let footer = NSStackView(views: [elapsedLabel, NSView(), copyButton, closeButton])
        footer.orientation = .horizontal
        footer.spacing = 8
        footer.alignment = .centerY
        footer.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [titleLabel, statusLabel, stepsScrollView, logCaption, logScrollView, footer])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -16),
            stepsScrollView.leadingAnchor.constraint(equalTo: stack.leadingAnchor),
            stepsScrollView.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
            stepsScrollView.heightAnchor.constraint(equalToConstant: 132),
            logScrollView.leadingAnchor.constraint(equalTo: stack.leadingAnchor),
            logScrollView.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
            logScrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 160),
            footer.leadingAnchor.constraint(equalTo: stack.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
            statusLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            logCaption.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor)
        ])
    }

    private func renderLog(_ session: UpdateProgressSession) {
        let text = session.logLines.isEmpty ? "等待过程日志…" : session.logLines.joined(separator: "\n")
        guard logTextView.string != text else { return }
        logTextView.string = text
        logTextView.scrollToEndOfDocument(nil)
    }

    /// 顶部状态行：进行中显示当前阶段，结束显示结论。
    private static func statusText(for session: UpdateProgressSession) -> String {
        if let outcome = session.outcome {
            return outcome.headline
        }
        if let running = session.runningStepTitle {
            return "正在\(running)…"
        }
        return "准备中…"
    }

    // MARK: - 计时器

    private func startTimer() {
        guard elapsedTimer == nil else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            self?.refreshElapsed()
        }
        // .common：sheet、菜单跟踪与拖动窗口期间也继续走（与调度器的取舍一致）。
        RunLoop.main.add(timer, forMode: .common)
        elapsedTimer = timer
    }

    private func stopTimer() {
        elapsedTimer?.invalidate()
        elapsedTimer = nil
    }

    private func refreshElapsed() {
        guard let session else { stopTimer(); return }
        elapsedLabel.stringValue = session.statusLine(at: Date())
        if session.isFinished {
            stopTimer()
        }
    }

    // MARK: - 动作

    @objc private func copyDiagnostics(_ sender: Any?) {
        onCopyDiagnostics?()
    }

    @objc private func closeWindow(_ sender: Any?) {
        window?.performClose(nil)
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        stopTimer()
        onClose?()
    }

    // MARK: - NSTableViewDataSource / Delegate

    func numberOfRows(in tableView: NSTableView) -> Int {
        session?.steps.count ?? 0
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let tableColumn,
              let column = Column(rawValue: tableColumn.identifier.rawValue),
              let step = session?.steps[safe: row] else { return nil }
        let identifier = tableColumn.identifier
        let cell: NSTableCellView
        if let reused = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView,
           let field = reused.textField {
            cell = reused
            field.stringValue = ""
        } else {
            cell = NSTableCellView()
            cell.identifier = identifier
            let field = NSTextField(labelWithString: "")
            field.translatesAutoresizingMaskIntoConstraints = false
            field.lineBreakMode = .byTruncatingTail
            cell.addSubview(field)
            cell.textField = field
            NSLayoutConstraint.activate([
                field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                field.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
            ])
        }
        guard let field = cell.textField else { return cell }
        switch column {
        case .symbol:
            field.stringValue = step.state.symbol
            field.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .semibold)
            field.textColor = Self.color(for: step.state)
        case .stage:
            field.stringValue = step.title
            field.font = NSFont.systemFont(ofSize: 12, weight: step.state == .running ? .semibold : .regular)
            field.textColor = step.state == .pending ? .tertiaryLabelColor : .labelColor
        case .detail:
            field.stringValue = step.detail.isEmpty ? step.state.displayName : step.detail
            field.font = NSFont.systemFont(ofSize: 11)
            field.textColor = step.state == .pending ? .tertiaryLabelColor : .secondaryLabelColor
        }
        return cell
    }

    private static func color(for state: UpdateProgressStepState) -> NSColor {
        switch state {
        case .succeeded: return .systemGreen
        case .failed: return .systemRed
        case .running: return .controlAccentColor
        case .skipped: return .secondaryLabelColor
        case .pending: return .tertiaryLabelColor
        }
    }
}

// MARK: - 测试可见的只读视图

/// 只给测试用的只读投影：断言窗口渲染出来的文本与行数，而不是读私有控件。
extension UpdateProgressWindowController {
    var titleLabelText: String { titleLabel.stringValue }
    var statusLabelText: String { statusLabel.stringValue }
    var elapsedLabelText: String { elapsedLabel.stringValue }
    var stepRowCount: Int { tableView.numberOfRows }
    var logText: String { logTextView.string }
}
