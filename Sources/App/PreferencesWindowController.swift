import Cocoa

/// 设置窗口。AppKit 控件手写布局，不用 XIB。
///
/// 表单分四块：服务、网络、更新检查、行为。每块只放需要用户决定的字段，
/// 说明文字压到一行；需要展开解释的内容放在诊断窗口，不堆在设置里。
/// 表单与滚动/底部按钮的结构和更新检查偏好设置窗口一致（见 `SettingsFormViews`）。
final class PreferencesWindowController: NSWindowController, NSTextFieldDelegate {
    var onSave: ((ServiceConfiguration) -> Void)?

    private let pathField = NSTextField()
    private let workspaceField = NSTextField()
    private let hostnameField = NSTextField()
    private let portField = NSTextField()
    private let allowedHostsField = NSTextField()
    private let httpProxyField = NSTextField()
    private let httpsProxyField = NSTextField()
    private let noProxyField = NSTextField()
    private let remoteAccessHintLabel = WrappingLabel(labelWithString: "")
    private let workspaceHintLabel = WrappingLabel(labelWithString: "")
    private let autoStartButton = NSButton(checkboxWithTitle: "启动应用时自动启动服务", target: nil, action: nil)
    private let quitBehaviorPopup = NSPopUpButton()
    private let errorLabel = WrappingLabel(labelWithString: "")

    private var configuration: ServiceConfiguration
    /// 默认工作目录（`~/Library/Application Support/Pi Web Desktop/Workspace`）。
    private let defaultWorkspaceDirectory: String
    /// 工作目录探针；测试/预览可注入。
    let workspaceProbe: WorkspaceDirectoryProbe

    init(
        configuration: ServiceConfiguration,
        defaultWorkspaceDirectory: String = "",
        workspaceProbe: WorkspaceDirectoryProbe = .live()
    ) {
        self.configuration = configuration
        self.defaultWorkspaceDirectory = defaultWorkspaceDirectory
        self.workspaceProbe = workspaceProbe
        super.init(window: nil)
        buildWindow()
        loadValues()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: - 布局

    private func buildWindow() {
        let content = FlippedDocumentView()
        content.translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(labelWithString: "设置")
        title.font = NSFont.systemFont(ofSize: 22, weight: .semibold)

        let serviceHeader = sectionHeader("服务")
        let networkHeader = sectionHeader("网络")
        let behaviorHeader = sectionHeader("行为")

        let pathPicker = NSButton(title: "选择…", target: self, action: #selector(selectPiWebPath(_:)))
        let workspacePicker = NSButton(title: "选择…", target: self, action: #selector(selectWorkspaceDirectory(_:)))
        let workspaceDefaultButton = NSButton(title: "默认目录", target: self, action: #selector(useDefaultWorkspaceDirectory(_:)))
        let resetButton = NSButton(title: "恢复默认", target: self, action: #selector(resetDefaults(_:)))
        let cancelButton = NSButton(title: "取消", target: self, action: #selector(cancel(_:)))
        let saveButton = NSButton(title: "保存", target: self, action: #selector(save(_:)))
        saveButton.keyEquivalent = "\r"
        cancelButton.keyEquivalent = "\u{1b}"

        let pathRow = row(label: "pi-web 路径", field: pathField, trailing: pathPicker)
        workspaceField.placeholderString = defaultWorkspaceDirectory
        workspaceField.delegate = self
        let workspaceButtons = NSStackView(views: [workspacePicker, workspaceDefaultButton])
        workspaceButtons.orientation = .horizontal
        workspaceButtons.spacing = 8
        workspaceButtons.alignment = .centerY
        let workspaceRow = row(label: "工作目录", field: workspaceField, trailing: workspaceButtons)
        let portRow = row(label: "端口", field: portField)
        hostnameField.delegate = self
        let hostnameRow = row(label: "监听地址", field: hostnameField)
        let allowedHostsRow = row(label: "允许的主机名", field: allowedHostsField)
        let httpProxyRow = row(label: "HTTP 代理", field: httpProxyField)
        let httpsProxyRow = row(label: "HTTPS 代理", field: httpsProxyField)
        let noProxyRow = row(label: "不使用代理", field: noProxyField)

        quitBehaviorPopup.addItems(withTitles: ServiceConfiguration.QuitBehavior.allCases.map(\.title))
        let quitRow = row(label: "退出时", field: quitBehaviorPopup)
        autoStartButton.target = self
        autoStartButton.action = #selector(autoStartChanged(_:))

        for hint in [remoteAccessHintLabel, workspaceHintLabel] {
            SettingsFormMetrics.configureHint(hint)
        }
        SettingsFormMetrics.configureHint(errorLabel, color: .systemRed)
        errorLabel.isHidden = true

        let buttons = NSStackView(views: [resetButton, NSView(), cancelButton, saveButton])
        buttons.orientation = .horizontal
        buttons.spacing = 8
        buttons.alignment = .centerY

        let stack = NSStackView(views: [
            title,
            serviceHeader, pathRow, workspaceRow, workspaceHintLabel, portRow,
            networkHeader, hostnameRow, remoteAccessHintLabel, allowedHostsRow,
            httpProxyRow, httpsProxyRow, noProxyRow,
            behaviorHeader, autoStartButton, quitRow
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)

        stack.widthAnchor.constraint(
            greaterThanOrEqualToConstant: SettingsFormMetrics.minimumWidth
        ).isActive = true
        for rowView in [
            pathRow, workspaceRow, portRow, hostnameRow, allowedHostsRow,
            httpProxyRow, httpsProxyRow, noProxyRow, quitRow
        ] {
            rowView.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        for fullWidth in [workspaceHintLabel, remoteAccessHintLabel, autoStartButton] {
            fullWidth.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: SettingsFormMetrics.inset),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -SettingsFormMetrics.inset),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: SettingsFormMetrics.inset),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -SettingsFormMetrics.inset),
            title.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])

        // 错误提示与底部按钮固定在窗口底部：窗口缩得很矮时表单在中间滚动，
        // 取消/保存始终看得见。
        let footer = NSStackView(views: [errorLabel, buttons])
        footer.orientation = .vertical
        footer.alignment = .leading
        footer.spacing = 12
        footer.translatesAutoresizingMaskIntoConstraints = false
        buttons.widthAnchor.constraint(equalTo: footer.widthAnchor).isActive = true
        errorLabel.widthAnchor.constraint(equalTo: footer.widthAnchor).isActive = true

        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.horizontalScrollElasticity = .none
        scrollView.documentView = content
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.addSubview(scrollView)
        container.addSubview(footer)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 568, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "设置"
        window.contentView = container
        window.isReleasedWhenClosed = false
        window.contentMinSize = SettingsFormMetrics.minimumContentSize
        // 记住用户调整过的尺寸；第一次打开时才居中。
        if !window.setFrameUsingName(Self.frameAutosaveName) {
            window.center()
        }
        window.setFrameAutosaveName(Self.frameAutosaveName)
        self.window = window

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: container.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -12),
            footer.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: SettingsFormMetrics.inset),
            footer.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -SettingsFormMetrics.inset),
            footer.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -SettingsFormMetrics.inset),
            content.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            content.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            content.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor)
        ])
    }

    /// 记录用户调整过的窗口尺寸与位置（NSWindow 自动保存到用户默认值）。
    private static let frameAutosaveName = "PiWebDesktopPreferencesWindow"

    private func sectionHeader(_ title: String) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        label.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        return label
    }

    private func row(label: String, field: NSView, trailing: NSView? = nil) -> NSView {
        let labelView = NSTextField(labelWithString: label)
        labelView.alignment = .right
        labelView.widthAnchor.constraint(equalToConstant: 100).isActive = true
        let row = NSStackView(views: trailing.map { [labelView, field, $0] } ?? [labelView, field])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        if let textField = field as? NSTextField {
            textField.isEditable = true
            textField.translatesAutoresizingMaskIntoConstraints = false
            textField.widthAnchor.constraint(
                greaterThanOrEqualToConstant: SettingsFormMetrics.fieldMinimumWidth
            ).isActive = true
            textField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        } else if let popup = field as? NSPopUpButton {
            popup.widthAnchor.constraint(
                greaterThanOrEqualToConstant: SettingsFormMetrics.fieldMinimumWidth
            ).isActive = true
            popup.setContentHuggingPriority(.defaultLow, for: .horizontal)
        }
        return row
    }

    // MARK: - 数据流

    /// 用当前生效配置整体重置控件（打开前/关闭后使用）。
    ///
    /// 设置窗口是单例：重复打开复用同一个控制器/窗口，因此每次展示前都要把控件
    /// 重置为已保存的值，上一次被取消的输入不会残留。
    func update(configuration: ServiceConfiguration) {
        apply(configuration: configuration, reloadControls: true)
    }

    /// 窗口可见时收到外部配置变更。
    ///
    /// - Returns: 是否刷新了控件。`false` 表示用户已有未保存的编辑，控件保持
    ///   原样，避免抹掉正在输入的内容。
    @discardableResult
    func refreshIfUnedited(configuration: ServiceConfiguration) -> Bool {
        let shouldReload = PreferencesRefreshPolicy.shouldReload(
            currentValues: controlValues(),
            loadedValues: loadedControlValues
        )
        apply(configuration: configuration, reloadControls: shouldReload)
        return shouldReload
    }

    /// 控件当前值的快照：只包含用户可编辑的字段。
    private func controlValues() -> [String] {
        [
            pathField.stringValue,
            workspaceField.stringValue,
            hostnameField.stringValue,
            portField.stringValue,
            allowedHostsField.stringValue,
            httpProxyField.stringValue,
            httpsProxyField.stringValue,
            noProxyField.stringValue,
            autoStartButton.state == .on ? "1" : "0",
            String(quitBehaviorPopup.indexOfSelectedItem)
        ]
    }

    /// 同步进控件的那一份快照：下一次判断“用户是否编辑过”的基线。
    private var loadedControlValues: [String] {
        [
            configuration.piWebPath,
            // 工作目录留空表示跟随默认目录；空串与窗口里的空值等价。
            configuration.workspacePath,
            configuration.hostname,
            String(configuration.port),
            configuration.allowedHosts,
            configuration.httpProxy,
            configuration.httpsProxy,
            configuration.noProxy,
            configuration.autoStart ? "1" : "0",
            String(ServiceConfiguration.QuitBehavior.allCases.firstIndex(of: configuration.quitBehavior) ?? 0)
        ]
    }

    /// 必须先写 `configuration` 再决定是否 `loadValues()`，这样快照与控件值
    /// 始终来自同一个配置。
    private func apply(configuration: ServiceConfiguration, reloadControls: Bool) {
        self.configuration = configuration
        errorLabel.isHidden = true
        // 无论是否整体重载，工作目录提示与远程访问提示都跟着最新配置走：
        // 它们只是说明，不承载用户输入。
        if reloadControls {
            loadValues()
        } else {
            refreshWorkspaceHint()
            refreshRemoteAccessHint()
        }
    }

    private func loadValues() {
        pathField.stringValue = configuration.piWebPath
        workspaceField.stringValue = configuration.workspacePath
        refreshWorkspaceHint()
        hostnameField.stringValue = configuration.hostname
        portField.stringValue = String(configuration.port)
        allowedHostsField.stringValue = configuration.allowedHosts
        httpProxyField.stringValue = configuration.httpProxy
        httpsProxyField.stringValue = configuration.httpsProxy
        noProxyField.stringValue = configuration.noProxy
        autoStartButton.state = configuration.autoStart ? .on : .off
        quitBehaviorPopup.selectItem(
            at: ServiceConfiguration.QuitBehavior.allCases.firstIndex(of: configuration.quitBehavior) ?? 0
        )
        refreshRemoteAccessHint()
    }

    /// 工作目录提示：留空 = 默认目录；自选目录必须存在且可写。
    private func refreshWorkspaceHint() {
        let configured = workspaceField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        workspaceHintLabel.stringValue = configured.isEmpty
            ? "默认位置：\(defaultWorkspaceDirectory)"
            : "pi-web 会在该目录写入运行文件，目录必须存在且可写。"
    }

    /// 远程访问提示。只有一行，且只在“非 loopback”时说明后果。
    ///
    /// 本应用不再管理访问密码：远程监听只要地址合法就会启动，因此这里必须
    /// 明确说出“没有认证”，而不是让用户以为密码还在。
    private func refreshRemoteAccessHint() {
        let hostname = RemoteAccessPolicy.normalizedHostname(hostnameField.stringValue)
        remoteAccessHintLabel.stringValue = RemoteAccessPolicy.isLoopbackHostname(hostname)
            ? "只监听本机，不需要认证。"
            : "监听非本机地址时，同一网络内的访问者无需认证即可完全控制 pi-web。"
    }

    // MARK: - 动作

    @objc private func selectPiWebPath(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.unixExecutable]
        guard let host = sheetParentWindow() else { return }
        panel.beginSheetModal(for: host) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.pathField.stringValue = url.path
        }
    }

    /// 工作目录面板：只允许目录，选定后立即校验“存在 + 可写”，不通过时
    /// 只显示可读错误，字段与配置都不变。
    @objc private func selectWorkspaceDirectory(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.prompt = "选择"
        guard let host = sheetParentWindow() else { return }
        panel.beginSheetModal(for: host) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            switch WorkspaceDirectory.validate(path: url.path, probe: self.workspaceProbe) {
            case .usable:
                self.workspaceField.stringValue = url.path
                self.errorLabel.isHidden = true
            case .unusable(let problem, let path):
                self.showError("无法使用该目录（\(problem.title)）：\(path)")
            }
            self.refreshWorkspaceHint()
        }
    }

    @objc private func useDefaultWorkspaceDirectory(_ sender: Any?) {
        workspaceField.stringValue = ""
        errorLabel.isHidden = true
        refreshWorkspaceHint()
    }

    @objc private func resetDefaults(_ sender: Any?) {
        configuration = .default
        loadValues()
        errorLabel.isHidden = true
    }

    @objc private func autoStartChanged(_ sender: Any?) {
        // 控件值在点击“保存”时读取，这里无需处理。
    }

    @objc private func cancel(_ sender: Any?) {
        close()
    }

    @objc private func save(_ sender: Any?) {
        guard let port = Int(portField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)),
              (1...65535).contains(port) else {
            showError("端口必须是 1 到 65535 之间的整数。")
            return
        }
        let hostname = hostnameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if let message = RemoteAccessPolicy.hostnameValidationMessage(hostname) {
            showError(message)
            return
        }
        // IPv6 字面量统一保存为不带方括号的形式（`::1`）：`--hostname` 参数和端口
        // 探测都用这个形式，只有 URL 主机需要方括号（`http://[::1]:端口/`）。
        let normalizedHostname = RemoteAccessPolicy.normalizedHostname(hostname)
        let urlHost = RemoteAccessPolicy.urlHost(for: normalizedHostname)
        guard let url = URL(string: "http://\(urlHost):\(port)/"), url.host != nil, url.port == port else {
            showError("监听地址无效。")
            return
        }

        let requested = ServiceConfiguration(
            hostname: normalizedHostname,
            port: port,
            piWebPath: pathField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
            allowedHosts: allowedHostsField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
            httpProxy: httpProxyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
            httpsProxy: httpsProxyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
            noProxy: noProxyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
            autoStart: autoStartButton.state == .on,
            quitBehavior: ServiceConfiguration.QuitBehavior.allCases[quitBehaviorPopup.indexOfSelectedItem],
            workspacePath: configuration.workspacePath
        )
        // 工作目录只接受已存在且可写的绝对路径；留空表示跟随默认目录。
        let workspaceSelection = WorkspaceDirectory.Selection.apply(
            selectedPath: workspaceField.stringValue,
            configuration: requested,
            defaultPath: defaultWorkspaceDirectory,
            probe: workspaceProbe
        )
        if let error = workspaceSelection.error {
            showError(error)
            return
        }
        configuration = workspaceSelection.configuration
        // 配置由 AppDelegate 通过 AppConfiguration 写入 UserDefaults，
        // UserDefaults 访问保持集中在一处。
        onSave?(workspaceSelection.configuration)
        close()
    }

    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else { return }
        if field === hostnameField {
            refreshRemoteAccessHint()
        } else if field === workspaceField {
            refreshWorkspaceHint()
        }
    }

    /// 弹出 panel 的宿主窗口。
    ///
    /// 两个打开面板只可能由窗口里的按钮触发，因此 `window` 一定存在；但用
    /// `guard let` 代替强解包：真出现“无窗口却发消息”时，宁可不弹面板。
    private func sheetParentWindow() -> NSWindow? {
        guard let window else {
            showError("窗口未就绪，无法打开文件选择器。")
            return nil
        }
        return window
    }

    private func showError(_ message: String) {
        errorLabel.stringValue = message
        errorLabel.isHidden = false
    }
}
