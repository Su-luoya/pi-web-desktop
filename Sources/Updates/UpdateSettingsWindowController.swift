import Cocoa

/// “更新检查偏好设置”窗口（GitHub #18）。
///
/// 只负责展示 `UpdateCategoryStatus` 与收集用户选择：读取设置、写 UserDefaults、
/// 记录忽略版本、让调度器读取新值都由 `AppDelegate` 完成。窗口自身不联网、
/// 不安装、不读写 UserDefaults、不读 Keychain，日期格式只影响显示。

/// Update check preferences window controller.

final class UpdateSettingsWindowController: NSWindowController {
    /// 策略或启动前自动更新开关发生变化；调用方负责持久化并让调度器读取。
    var onPreferencesChanged: ((UpdateCheckPreferences) -> Void)?
    /// 忽略某个分类当前提示的版本；返回 false 表示没有可忽略的版本。
    var onIgnoreCurrentVersion: ((UpdateCheckCategory) -> Bool)?
    /// “更新检查说明…”（与菜单同一个提示框）。
    var onShowExplanation: (() -> Void)?

    private var preferences: UpdateCheckPreferences = .factoryDefaults
    private var statuses: [UpdateCategoryStatus] = []
    private var ignorableVersions: [UpdateCheckCategory: String] = [:]
    private var piCLIStatusText = ""
    private var piPackageStatusText = ""
    /// 最近一次外部推送的放弃状态文本；内部动作触发的局部刷新用它回填，
    /// 不再依赖外部“恰好会再同步一次”（审计次要）。
    private var abandonedStatusText = ""

    private var policyPopups: [UpdateCheckCategory: NSPopUpButton] = [:]
    private var statusLabels: [UpdateCheckCategory: NSTextField] = [:]
    private var ignoreButtons: [UpdateCheckCategory: NSButton] = [:]
    private let autoUpdateButton = NSButton(
        checkboxWithTitle: "启动前自动更新 Pi Web",
        target: nil,
        action: nil
    )
    private let autoUpdateHintLabel = NSTextField(labelWithString:
        "仅对已验证的 npm 全局安装生效；其它来源只提示，不安装。")
    private let autoUpdatePiCLIButton = NSButton(
        checkboxWithTitle: "启动前自动更新 Pi CLI",
        target: nil,
        action: nil
    )
    private let autoUpdatePiCLIHintLabel = NSTextField(labelWithString:
        "有运行中的 Pi 进程时推迟，并在下次检查时重试。")
    private let piCLIStatusLabel = NSTextField(labelWithString: "")
    private let piPackageHintLabel = NSTextField(labelWithString:
        "确认后只执行官方更新命令一次，不做无人值守更新。")
    /// internal：布局回归测试需要对照其他长文本 label 的约束（M11）。
    let piPackageStatusLabel = WrappingLabel(labelWithString: "")
    /// 「已放弃」记录（GitHub #62）：超时/放弃等待之后可能仍在运行的命令。
    /// internal：回归测试需要检查它的宽度约束（M11）。
    let abandonedStatusLabel = WrappingLabel(labelWithString: "")

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter
    }()

    init() {
        super.init(window: nil)
        buildWindow()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// 刷新设置与每类组件状态。`ignorableVersions` 是当前可以“忽略”的版本；
    /// 没有可忽略版本的分类按钮置灰。`piCLIStatus` 是 Pi CLI 进程保护与自动更新
    /// 决策的状态文本（由 `AppDelegate` 用同一份检查结果生成）。
    func update(
        preferences: UpdateCheckPreferences,
        statuses: [UpdateCategoryStatus],
        ignorableVersions: [UpdateCheckCategory: String] = [:],
        piCLIStatus: String = "",
        piPackageStatus: String = "",
        abandonedStatus: String = ""
    ) {
        self.preferences = preferences
        self.statuses = statuses
        self.ignorableVersions = ignorableVersions
        self.piCLIStatusText = piCLIStatus
        self.piPackageStatusText = piPackageStatus
        self.abandonedStatusText = abandonedStatus
        for category in UpdateCheckCategory.allCases {
            let policy = preferences.policy(for: category)
            let popup = policyPopups[category]
            let allowed = UpdateCheckPolicy.allowed(for: category)
            popup?.selectItem(at: allowed.firstIndex(of: policy) ?? 0)
            statusLabels[category]?.stringValue = UpdateStatusPresenter.shortLine(
                for: status(for: category),
                policy: policy,
                format: { Self.timestampFormatter.string(from: $0) }
            )
            let hasCandidate = ignorableVersions[category] != nil
            ignoreButtons[category]?.isEnabled = hasCandidate
            ignoreButtons[category]?.title = hasCandidate ? "忽略此版本" : "无可忽略版本"
        }
        autoUpdateButton.state = preferences.autoUpdatePiWebBeforeLaunch ? .on : .off
        autoUpdatePiCLIButton.state = preferences.autoUpdatePiBeforeLaunch ? .on : .off
        piCLIStatusLabel.stringValue = piCLIStatus
        piPackageStatusLabel.stringValue = piPackageStatus
        abandonedStatusLabel.stringValue = abandonedStatus
    }

    private func status(for category: UpdateCheckCategory) -> UpdateCategoryStatus {
        statuses.first { $0.category == category } ?? UpdateCategoryStatus(category: category)
    }

    // MARK: - 界面

    private func buildWindow() {
        let content = FlippedDocumentView()
        content.translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(labelWithString: "更新检查偏好设置")
        title.font = NSFont.systemFont(ofSize: 22, weight: .semibold)

        let intro = NSTextField(labelWithString: "只查版本，不下载也不安装；关闭后不为该组件发请求。")
        SettingsFormMetrics.configureHint(intro)

        var rows: [NSView] = [title, intro]
        var categoryRows: [NSStackView] = []
        for (index, category) in UpdateCheckCategory.allCases.enumerated() {
            let header = NSTextField(labelWithString: category.displayName)
            header.font = NSFont.systemFont(ofSize: 13, weight: .semibold)

            let popup = NSPopUpButton()
            for policy in UpdateCheckPolicy.allowed(for: category) {
                popup.addItem(withTitle: policy.title)
            }
            popup.target = self
            popup.action = #selector(policyChanged(_:))
            // `NSControl` 没有 `representedObject`；用固定顺序的 tag 回查分类。
            popup.tag = index
            popup.widthAnchor.constraint(equalToConstant: 160).isActive = true
            policyPopups[category] = popup

            let ignoreButton = NSButton(title: "忽略此版本", target: self, action: #selector(ignoreCurrentVersion(_:)))
            ignoreButton.tag = index
            ignoreButtons[category] = ignoreButton

            let controls = NSStackView(views: [popup, ignoreButton, NSView()])
            controls.orientation = .horizontal
            controls.spacing = 8
            controls.alignment = .centerY

            // 状态只留一句话：结论 + 最近检查。时间、忽略版本、缓存来源这些
            // 细节归诊断页，设置窗口里堆满它们只会让每行都读不完。
            let statusLabel = NSTextField(labelWithString: "")
            statusLabel.lineBreakMode = .byWordWrapping
            statusLabel.maximumNumberOfLines = 0
            statusLabel.font = NSFont.systemFont(ofSize: 11)
            statusLabel.textColor = .secondaryLabelColor
            statusLabels[category] = statusLabel

            let row = NSStackView(views: [header, controls, statusLabel])
            row.orientation = .vertical
            row.alignment = .leading
            row.spacing = 4
            rows.append(row)
            categoryRows.append(row)
        }

        autoUpdateButton.target = self
        autoUpdateButton.action = #selector(autoUpdateChanged(_:))
        // 两个「启动前自动更新」开关必须各自接到自己的 action：漏接只会表现为
        // 点不动，不会有编译错误。
        autoUpdatePiCLIButton.target = self
        autoUpdatePiCLIButton.action = #selector(autoUpdatePiCLIChanged(_:))
        for hint in [
            autoUpdateHintLabel, autoUpdatePiCLIHintLabel, piCLIStatusLabel,
            piPackageHintLabel, piPackageStatusLabel, abandonedStatusLabel
        ] {
            SettingsFormMetrics.configureHint(hint)
            hint.font = NSFont.systemFont(ofSize: 11)
        }

        let reservedHeader = NSTextField(labelWithString: "启动前自动更新")
        reservedHeader.font = NSFont.systemFont(ofSize: 13, weight: .semibold)

        let piPackageHeader = NSTextField(labelWithString: "Pi 扩展包")
        piPackageHeader.font = NSFont.systemFont(ofSize: 13, weight: .semibold)

        let explanationButton = NSButton(title: "更新检查说明…", target: self, action: #selector(showExplanation(_:)))
        let closeButton = NSButton(title: "完成", target: self, action: #selector(closeWindow(_:)))
        closeButton.keyEquivalent = "\r"
        let buttons = NSStackView(views: [explanationButton, NSView(), closeButton])
        buttons.orientation = .horizontal
        buttons.spacing = 8
        buttons.alignment = .centerY

        rows.append(contentsOf: [
            reservedHeader,
            autoUpdateButton,
            autoUpdateHintLabel,
            autoUpdatePiCLIButton,
            autoUpdatePiCLIHintLabel,
            piCLIStatusLabel,
            piPackageHeader,
            piPackageHintLabel,
            piPackageStatusLabel,
            abandonedStatusLabel,
            buttons
        ])

        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)

        stack.widthAnchor.constraint(
            greaterThanOrEqualToConstant: SettingsFormMetrics.minimumWidth
        ).isActive = true
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: SettingsFormMetrics.inset),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -SettingsFormMetrics.inset),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: SettingsFormMetrics.inset),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -SettingsFormMetrics.inset),
            title.widthAnchor.constraint(equalTo: stack.widthAnchor),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        // 说明与状态文本跟着窗口宽度重新折行：不再写死 620pt，窗口因此可以
        // 自由缩放，变宽时文字也跟着变宽（旧的固定宽度会让右边永远留白，并把
        // minSize 钉死在同一个数值上）。
        for view in [
            intro, autoUpdateHintLabel, autoUpdatePiCLIHintLabel, piCLIStatusLabel,
            piPackageHintLabel, piPackageStatusLabel, abandonedStatusLabel
        ] {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        // 每个分类的整块（标题 + 策略 + 状态行）也撑满宽度，状态文本才能跟着折行。
        for categoryStack in categoryRows {
            categoryStack.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        for (_, label) in statusLabels {
            label.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }

        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.horizontalScrollElasticity = .none
        scrollView.documentView = content
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.addSubview(scrollView)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 568, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "更新检查"
        window.contentView = container
        window.isReleasedWhenClosed = false
        // 与设置窗口同一套最小尺寸：表单列最小 520pt，窗口缩得再矮也只是滚动，
        // 不会裁掉内容，也不需要按文案长度现算高度。
        window.contentMinSize = SettingsFormMetrics.minimumContentSize
        window.center()
        self.window = window

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: container.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            content.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            content.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor)
        ])
    }

    // MARK: - 动作

    @objc private func policyChanged(_ sender: NSPopUpButton) {
        guard UpdateCheckCategory.allCases.indices.contains(sender.tag) else { return }
        let category = UpdateCheckCategory.allCases[sender.tag]
        let allowed = UpdateCheckPolicy.allowed(for: category)
        let index = sender.indexOfSelectedItem
        guard allowed.indices.contains(index) else { return }
        var updated = preferences
        guard updated.setPolicy(allowed[index], for: category) else { return }
        // 先同步本地状态，避免连续点击时用旧值覆盖。
        update(
            preferences: updated,
            statuses: statuses,
            ignorableVersions: ignorableVersions,
            piCLIStatus: piCLIStatusText,
            piPackageStatus: piPackageStatusText,
            abandonedStatus: abandonedStatusText
        )
        onPreferencesChanged?(updated)
    }

    @objc private func autoUpdateChanged(_ sender: NSButton) {
        var updated = preferences
        // 只写入值；是否真的自动安装由 `PiWebUpdatePlanner` 的前置条件与来源
        // 判定决定（只有已验证的 npm 全局安装才会执行）。
        updated.autoUpdatePiWebBeforeLaunch = sender.state == .on
        update(
            preferences: updated,
            statuses: statuses,
            ignorableVersions: ignorableVersions,
            piCLIStatus: piCLIStatusText,
            piPackageStatus: piPackageStatusText,
            abandonedStatus: abandonedStatusText
        )
        onPreferencesChanged?(updated)
    }

    @objc private func autoUpdatePiCLIChanged(_ sender: NSButton) {
        var updated = preferences
        // 只写入值；是否真的执行由 `PiCLIUpdatePlanner` 的前置条件与进程保护决定
        // （只有“没有运行中的 Pi 进程 + 已验证的 npm/pnpm 全局安装 + 已验证的目标
        // 版本”同时成立才会执行 pi update --self）。
        updated.autoUpdatePiBeforeLaunch = sender.state == .on
        update(
            preferences: updated,
            statuses: statuses,
            ignorableVersions: ignorableVersions,
            piCLIStatus: piCLIStatusText,
            piPackageStatus: piPackageStatusText,
            abandonedStatus: abandonedStatusText
        )
        onPreferencesChanged?(updated)
    }

    @objc private func ignoreCurrentVersion(_ sender: NSButton) {
        guard UpdateCheckCategory.allCases.indices.contains(sender.tag) else { return }
        let category = UpdateCheckCategory.allCases[sender.tag]
        _ = onIgnoreCurrentVersion?(category)
    }

    @objc private func showExplanation(_ sender: Any?) {
        onShowExplanation?()
    }

    @objc private func closeWindow(_ sender: Any?) {
        close()
    }
}
