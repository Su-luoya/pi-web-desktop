import Cocoa

/// “更新检查偏好设置”窗口（GitHub #18）。
///
/// 只负责展示 `UpdateCategoryStatus` 与收集用户选择：读取设置、写 UserDefaults、
/// 记录忽略版本、让调度器读取新值都由 `AppDelegate` 完成。窗口自身不联网、
/// 不安装、不读写 UserDefaults、不读 Keychain，日期格式只影响显示。
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

    private var policyPopups: [UpdateCheckCategory: NSPopUpButton] = [:]
    private var statusLabels: [UpdateCheckCategory: NSTextField] = [:]
    private var ignoreButtons: [UpdateCheckCategory: NSButton] = [:]
    private let autoUpdateButton = NSButton(
        checkboxWithTitle: "启动前自动更新 Pi Web（仅限已验证的 npm 全局安装）",
        target: nil,
        action: nil
    )
    private let autoUpdateHintLabel = NSTextField(labelWithString: UpdateAutomationBoundary.restrictedExplanation)
    private let autoUpdatePiCLIButton = NSButton(
        checkboxWithTitle: "启动前自动更新 Pi CLI（有运行中的 Pi 进程时自动推迟）",
        target: nil,
        action: nil
    )
    private let autoUpdatePiCLIHintLabel = NSTextField(labelWithString:
        "只调用 Pi 官方命令 pi update --self（参数数组，不使用 shell、不调用 sudo）；"
        + "检测到运行中的 Pi 进程或进程状态不确定时，自动更新会推迟到下一次判定，"
        + "应用不会结束、暂停或接管任何 Pi 进程与会话。手动更新入口在菜单“服务 → 更新检查设置 → 立即更新 Pi CLI…”。")
    private let piCLIStatusLabel = NSTextField(labelWithString: "")
    private let piPackageHintLabel = NSTextField(labelWithString:
        "Pi 扩展包只允许三种策略（关闭 / 检查并通知 / 询问后更新），不做无人值守更新："
        + "“检查并通知”只提示版本；“询问后更新”只对来源为已验证的 npm 全局安装提供执行入口，"
        + "并在菜单“服务 → 更新检查设置 → 查看 Pi 扩展包更新…”里显示包名、当前/目标版本、"
        + "完整参数数组与风险说明，取消是默认按钮；只调用 Pi 官方命令 pi update npm:<包名>。"
        + "检测到运行中的 Pi 进程或进程状态不确定时拒绝执行；应用不会结束或信号任何 Pi 进程。")
    private let piPackageStatusLabel = NSTextField(labelWithString: "")
    /// 「已放弃」记录（GitHub #62）：超时/放弃等待之后可能仍在运行的命令。
    private let abandonedStatusLabel = NSTextField(labelWithString: "")

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
        for category in UpdateCheckCategory.allCases {
            let policy = preferences.policy(for: category)
            let popup = policyPopups[category]
            let allowed = UpdateCheckPolicy.allowed(for: category)
            popup?.selectItem(at: allowed.firstIndex(of: policy) ?? 0)
            statusLabels[category]?.stringValue = UpdateStatusPresenter.line(
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
        let content = NSView()

        let title = NSTextField(labelWithString: "更新检查偏好设置")
        title.font = NSFont.systemFont(ofSize: 22, weight: .semibold)

        let intro = NSTextField(labelWithString:
            "更新检查只做只读的版本查询：不下载、不安装、不修改任何组件。关闭某一类后，"
            + "应用不再为该类发起请求，也不安排复查；应用退出后不检查（不安装 LaunchAgent）。"
            + "发现可用更新时使用应用内提示框（不使用系统通知中心），提示内容只含组件名与版本。"
            + "扩展包更新不做无人值守更新：只有在菜单里显式确认后才会执行一次官方命令。")
        intro.lineBreakMode = .byWordWrapping
        intro.maximumNumberOfLines = 0
        intro.textColor = .secondaryLabelColor

        var rows: [NSView] = [title, intro]
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
        }

        autoUpdateButton.target = self
        autoUpdateButton.action = #selector(autoUpdateChanged(_:))
        autoUpdateHintLabel.lineBreakMode = .byWordWrapping
        autoUpdateHintLabel.maximumNumberOfLines = 0
        autoUpdateHintLabel.textColor = .secondaryLabelColor
        autoUpdateHintLabel.font = NSFont.systemFont(ofSize: 11)

        autoUpdatePiCLIButton.target = self
        autoUpdatePiCLIButton.action = #selector(autoUpdatePiCLIChanged(_:))
        autoUpdatePiCLIHintLabel.lineBreakMode = .byWordWrapping
        autoUpdatePiCLIHintLabel.maximumNumberOfLines = 0
        autoUpdatePiCLIHintLabel.textColor = .secondaryLabelColor
        autoUpdatePiCLIHintLabel.font = NSFont.systemFont(ofSize: 11)
        piCLIStatusLabel.lineBreakMode = .byWordWrapping
        piCLIStatusLabel.maximumNumberOfLines = 0
        piCLIStatusLabel.textColor = .secondaryLabelColor
        piCLIStatusLabel.font = NSFont.systemFont(ofSize: 11)
        piPackageHintLabel.lineBreakMode = .byWordWrapping
        piPackageHintLabel.maximumNumberOfLines = 0
        piPackageHintLabel.textColor = .secondaryLabelColor
        piPackageHintLabel.font = NSFont.systemFont(ofSize: 11)
        piPackageStatusLabel.lineBreakMode = .byWordWrapping
        piPackageStatusLabel.maximumNumberOfLines = 0
        piPackageStatusLabel.textColor = .secondaryLabelColor
        piPackageStatusLabel.font = NSFont.systemFont(ofSize: 11)
        abandonedStatusLabel.lineBreakMode = .byWordWrapping
        abandonedStatusLabel.maximumNumberOfLines = 0
        abandonedStatusLabel.textColor = .secondaryLabelColor
        abandonedStatusLabel.font = NSFont.systemFont(ofSize: 11)

        let reservedHeader = NSTextField(labelWithString: "启动前自动更新（受限）")
        reservedHeader.font = NSFont.systemFont(ofSize: 13, weight: .semibold)

        let piPackageHeader = NSTextField(labelWithString: "Pi 扩展包更新（不做无人值守更新）")
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

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -24),
            title.widthAnchor.constraint(equalTo: stack.widthAnchor),
            intro.widthAnchor.constraint(equalToConstant: 620),
            autoUpdateHintLabel.widthAnchor.constraint(equalToConstant: 620),
            autoUpdatePiCLIHintLabel.widthAnchor.constraint(equalToConstant: 620),
            piCLIStatusLabel.widthAnchor.constraint(equalToConstant: 620),
            piPackageHintLabel.widthAnchor.constraint(equalToConstant: 620),
            piPackageStatusLabel.widthAnchor.constraint(equalToConstant: 620),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        for category in UpdateCheckCategory.allCases {
            statusLabels[category]?.widthAnchor.constraint(equalToConstant: 620).isActive = true
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 668, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "更新检查偏好设置"
        window.contentView = content
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 668, height: 620)
        window.center()
        self.window = window
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
            piPackageStatus: piPackageStatusText
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
            piPackageStatus: piPackageStatusText
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
            piPackageStatus: piPackageStatusText
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
