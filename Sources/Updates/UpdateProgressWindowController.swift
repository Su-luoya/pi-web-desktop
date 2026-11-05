import Cocoa

/// “更新进度”窗口（GitHub #219）。
///
/// 只渲染 `AppDelegate` 推过来的 `UpdateProgressSession` 快照：不联网、不执行命令、
/// 不读写配置、不读设置，也不决定什么时候开始或结束一次更新。所有文本（阶段原因、
/// 日志行）都由 `AppDelegate` 侧的固定文案与已脱敏结果组成。
///
/// 窗口本身只做三件自己的事：把快照画出来、走一个 1 秒的计时器刷新“已用时长”、
/// 以及把「复制诊断」「关闭」两个按钮转给 `AppDelegate`。
///
/// 版式：标题 + 状态 → 进度条 → 阶段列表 → 日志面板 → 底栏。
/// 阶段列表是普通的行视图（不再用 `NSTableView`）：它的列宽会把说明文字裁掉，
/// 而且 4 行内容还要套一层滚动条。多出来的竖直空间全部给日志面板，窗口里不留白。

/// Update progress window controller.

final class UpdateProgressWindowController: NSWindowController, NSWindowDelegate {
    /// 由 `AppDelegate` 注入：复用现有脱敏诊断导出。窗口不采集任何内容。
    var onCopyDiagnostics: (() -> Void)?
    /// 窗口关闭（自动关闭或用户点关闭）后回调，让 `AppDelegate` 释放引用。
    var onClose: (() -> Void)?

    private let titleLabel = NSTextField(labelWithString: "更新进度")
    private let statusLabel = NSTextField(labelWithString: "")
    private let progressBar = NSProgressIndicator()
    private let stepsStack = NSStackView()
    private let logCaption = NSTextField(labelWithString: "过程日志（已脱敏）")
    private let logTextView = NSTextView()
    private let logScrollView = NSScrollView()
    private let elapsedLabel = NSTextField(labelWithString: "")
    private let copyButton = NSButton(title: "复制诊断", target: nil, action: nil)
    private let closeButton = NSButton(title: "关闭", target: nil, action: nil)

    private var session: UpdateProgressSession?
    /// 1 秒计时器：只在有未结束的会话时存在，窗口关闭或会话结束时必须停掉。
    private var elapsedTimer: Timer?

    /// 阶段行的固定度量。标题列定宽，说明文字才能对齐；说明用尾部截断，绝不裁半。
    private static let stepRowSpacing: CGFloat = 2
    private static let stepSymbolWidth: CGFloat = 18
    private static let stepTitleWidth: CGFloat = 88

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 440),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "更新进度"
        window.minSize = NSSize(width: 500, height: 380)
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
            renderSteps([])
            progressBar.doubleValue = 0
            logTextView.string = ""
            elapsedLabel.stringValue = ""
            stopTimer()
            return
        }
        titleLabel.stringValue = session.title
        statusLabel.stringValue = Self.statusText(for: session)
        renderSteps(session.steps)
        progressBar.doubleValue = Self.progressFraction(for: session)
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

        titleLabel.font = NSFont.systemFont(ofSize: 16, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        statusLabel.font = NSFont.systemFont(ofSize: 12)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.maximumNumberOfLines = 2
        statusLabel.lineBreakMode = .byWordWrapping
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        progressBar.style = .bar
        progressBar.isIndeterminate = false
        progressBar.minValue = 0
        progressBar.maxValue = 1
        progressBar.doubleValue = 0
        progressBar.controlSize = .small
        progressBar.translatesAutoresizingMaskIntoConstraints = false

        stepsStack.orientation = .vertical
        stepsStack.alignment = .leading
        stepsStack.spacing = Self.stepRowSpacing
        stepsStack.translatesAutoresizingMaskIntoConstraints = false
        // 只有 4–5 行，不需要滚动：内容多时窗口自己够高，别套第二层滚动条。
        stepsStack.setContentHuggingPriority(.defaultHigh, for: .vertical)

        logCaption.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        logCaption.textColor = .secondaryLabelColor
        logCaption.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        logTextView.isEditable = false
        logTextView.isSelectable = true
        logTextView.drawsBackground = false
        logTextView.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        logTextView.textColor = .labelColor
        logTextView.textContainerInset = NSSize(width: 8, height: 8)
        logTextView.autoresizingMask = [.width]
        logTextView.isVerticallyResizable = true
        logTextView.isHorizontallyResizable = false
        logTextView.textContainer?.widthTracksTextView = true

        logScrollView.documentView = logTextView
        logScrollView.hasVerticalScroller = true
        logScrollView.borderType = .noBorder
        logScrollView.drawsBackground = true
        logScrollView.backgroundColor = .textBackgroundColor
        logScrollView.wantsLayer = true
        logScrollView.layer?.cornerRadius = 6
        logScrollView.layer?.masksToBounds = true
        logScrollView.translatesAutoresizingMaskIntoConstraints = false
        // 竖直方向让日志面板吸收所有多余空间：窗口拉高时变长的是日志，不是留白。
        logScrollView.setContentHuggingPriority(.defaultLow, for: .vertical)
        logScrollView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)

        elapsedLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        elapsedLabel.textColor = .secondaryLabelColor

        copyButton.target = self
        copyButton.action = #selector(copyDiagnostics(_:))
        copyButton.bezelStyle = .rounded
        closeButton.target = self
        closeButton.action = #selector(closeWindow(_:))
        closeButton.bezelStyle = .rounded
        closeButton.keyEquivalent = "\r"

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false

        let footer = NSStackView(views: [elapsedLabel, NSView(), copyButton, closeButton])
        footer.orientation = .horizontal
        footer.spacing = 8
        footer.alignment = .centerY
        footer.translatesAutoresizingMaskIntoConstraints = false

        for view in [titleLabel, statusLabel, progressBar, stepsStack, logCaption, logScrollView, separator, footer] {
            view.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(view)
        }

        // 竖直方向手动排：多余的空白全给日志面板，不能被均匀分到各个间距里
        // （NSStackView 的 .fill 会把伸缩量摊到多个可伸缩视图上，窗口就散开了）。
        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            titleLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            titleLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 16),

            statusLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            statusLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            statusLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),

            progressBar.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            progressBar.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            progressBar.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 12),

            stepsStack.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            stepsStack.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            stepsStack.topAnchor.constraint(equalTo: progressBar.bottomAnchor, constant: 14),

            logCaption.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            logCaption.topAnchor.constraint(equalTo: stepsStack.bottomAnchor, constant: 16),

            logScrollView.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            logScrollView.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            logScrollView.topAnchor.constraint(equalTo: logCaption.bottomAnchor, constant: 6),
            logScrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 120),

            separator.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -10),
            logScrollView.bottomAnchor.constraint(equalTo: separator.topAnchor, constant: -12),

            footer.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -16)
        ])
    }

    /// 重建阶段行。行数最多 5，重建比复用视图更简单，也不会残留上一份快照的文案。
    private func renderSteps(_ steps: [UpdateProgressStep]) {
        for view in stepsStack.arrangedSubviews {
            stepsStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        for step in steps {
            let row = makeStepRow(step)
            stepsStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stepsStack.widthAnchor).isActive = true
        }
    }

    private func makeStepRow(_ step: UpdateProgressStep) -> NSView {
        let symbol = NSTextField(labelWithString: step.state.symbol)
        symbol.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .semibold)
        symbol.textColor = Self.color(for: step.state)
        symbol.alignment = .center
        symbol.translatesAutoresizingMaskIntoConstraints = false
        symbol.widthAnchor.constraint(equalToConstant: Self.stepSymbolWidth).isActive = true

        let title = NSTextField(labelWithString: step.title)
        title.font = NSFont.systemFont(ofSize: 12, weight: step.state == .running ? .semibold : .regular)
        title.textColor = step.state == .pending ? .tertiaryLabelColor : .labelColor
        title.lineBreakMode = .byTruncatingTail
        title.translatesAutoresizingMaskIntoConstraints = false
        title.widthAnchor.constraint(equalToConstant: Self.stepTitleWidth).isActive = true

        let detail = NSTextField(labelWithString: step.detail)
        detail.font = NSFont.systemFont(ofSize: 11)
        detail.textColor = step.state == .pending ? .tertiaryLabelColor : .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingTail
        // 说明常常是一整句长原因：截断显示，完整文本靠悬停提示。
        detail.toolTip = step.detail.isEmpty ? nil : step.detail
        detail.setContentHuggingPriority(.defaultLow, for: .horizontal)
        detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let row = NSStackView(views: [symbol, title, detail])
        row.orientation = .horizontal
        row.spacing = 8
        row.alignment = .firstBaseline
        row.distribution = .fill
        return row
    }

    private func renderLog(_ session: UpdateProgressSession) {
        let text = session.logLines.isEmpty ? "等待过程日志…" : session.logLines.joined(separator: "\n")
        guard logTextView.string != text else { return }
        logTextView.string = text
        // 占位行用次要色：空面板上的一行提示不该看着像一条真日志。
        logTextView.textColor = session.logLines.isEmpty ? .tertiaryLabelColor : .labelColor
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

    /// 进度条的取值：成功的阶段占比；成功的会话收尾时补满（末尾的“跳过”行不是失败）。
    private static func progressFraction(for session: UpdateProgressSession) -> Double {
        if session.outcome?.isSuccess == true { return 1 }
        guard !session.steps.isEmpty else { return 0 }
        let done = session.steps.filter { $0.state == .succeeded }.count
        return Double(done) / Double(session.steps.count)
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
    var stepRowCount: Int { stepsStack.arrangedSubviews.count }
    var stepTexts: [String] {
        stepsStack.arrangedSubviews.compactMap { row in
            (row as? NSStackView)?.arrangedSubviews.compactMap { ($0 as? NSTextField)?.stringValue }
                .joined(separator: "|")
        }
    }
    var progressBarFraction: Double { progressBar.doubleValue }
    var logText: String { logTextView.string }
}
