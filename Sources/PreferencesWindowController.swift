import Cocoa

final class PreferencesWindowController: NSWindowController, NSTextFieldDelegate {
    var onSave: ((ServiceConfiguration) -> Void)?
    var onCancel: (() -> Void)?
    /// 密码在 Keychain 中被设置或删除后触发。
    ///
    /// 调用方负责持久化可能被改写的配置（删除密码会关闭远程模式并回到默认
    /// loopback）以及让正在运行的远程服务重启，使新的 `PI_WEB_PASSWORD` 生效。
    /// 回调只传配置，不传密码。
    var onRemoteAccessCredentialsChanged: ((ServiceConfiguration) -> Void)?

    private let pathField = NSTextField()
    private let workspaceField = NSTextField()
    private let hostnameField = NSTextField()
    private let portField = NSTextField()
    private let allowedHostsField = NSTextField()
    private let httpProxyField = NSTextField()
    private let httpsProxyField = NSTextField()
    private let noProxyField = NSTextField()
    private let passwordStatusLabel = NSTextField(labelWithString: "")
    private let newPasswordField = NSSecureTextField()
    private let savePasswordButton = NSButton(title: "保存密码", target: nil, action: nil)
    private let generatePasswordButton = NSButton(title: "生成高强度密码", target: nil, action: nil)
    private let deletePasswordButton = NSButton(title: "删除密码", target: nil, action: nil)
    private let remoteAccessHintLabel = NSTextField(labelWithString: "")
    private let autoStartButton = NSButton(checkboxWithTitle: "应用启动时自动启动服务", target: nil, action: nil)
    private let quitBehaviorPopup = NSPopUpButton()
    private let errorLabel = NSTextField(labelWithString: "")

    private var configuration: ServiceConfiguration
    private let keychain: KeychainStoring
    /// 只保留“已设置/未设置”的结论：已保存的密码永远不会被读回并显示。
    private var hasStoredPassword: Bool
    /// 默认工作目录（`~/Library/Application Support/Pi Web Desktop/Workspace`）。
    private let defaultWorkspaceDirectory: String
    /// 工作目录探针；测试/预览可注入。
    private let workspaceProbe: WorkspaceDirectoryProbe

    init(
        configuration: ServiceConfiguration,
        keychain: KeychainStoring = KeychainStore(),
        defaultWorkspaceDirectory: String = "",
        workspaceProbe: WorkspaceDirectoryProbe = .live()
    ) {
        self.configuration = configuration
        self.keychain = keychain
        self.hasStoredPassword = RemoteAccessPassword.isSet(in: keychain)
        self.defaultWorkspaceDirectory = defaultWorkspaceDirectory
        self.workspaceProbe = workspaceProbe
        super.init(window: nil)
        buildWindow()
        loadValues()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func buildWindow() {
        let content = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(labelWithString: "Pi Web Desktop 设置")
        title.font = NSFont.systemFont(ofSize: 22, weight: .semibold)

        let serviceHeader = NSTextField(labelWithString: "服务")
        serviceHeader.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        let remoteHeader = NSTextField(labelWithString: "远程访问")
        remoteHeader.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        let networkHeader = NSTextField(labelWithString: "网络与代理")
        networkHeader.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        let behaviorHeader = NSTextField(labelWithString: "行为")
        behaviorHeader.font = NSFont.systemFont(ofSize: 13, weight: .semibold)

        let pathPicker = NSButton(title: "选择…", target: self, action: #selector(selectPiWebPath(_:)))
        let workspacePicker = NSButton(title: "选择…", target: self, action: #selector(selectWorkspaceDirectory(_:)))
        let workspaceDefaultButton = NSButton(title: "使用默认目录", target: self, action: #selector(useDefaultWorkspaceDirectory(_:)))
        let resetButton = NSButton(title: "恢复默认", target: self, action: #selector(resetDefaults(_:)))
        let cancelButton = NSButton(title: "取消", target: self, action: #selector(cancel(_:)))
        let saveButton = NSButton(title: "保存", target: self, action: #selector(save(_:)))
        saveButton.keyEquivalent = "\r"
        cancelButton.keyEquivalent = "\u{1b}"

        savePasswordButton.target = self
        savePasswordButton.action = #selector(savePassword(_:))
        generatePasswordButton.target = self
        generatePasswordButton.action = #selector(generatePassword(_:))
        deletePasswordButton.target = self
        deletePasswordButton.action = #selector(deletePassword(_:))

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
        let passwordStatusRow = row(label: "访问密码", field: passwordStatusLabel, trailing: nil, isReadOnly: true)
        let newPasswordRow = row(label: "新密码", field: newPasswordField, trailing: generatePasswordButton)
        let passwordButtonRow = NSStackView(views: [savePasswordButton, deletePasswordButton, NSView()])
        passwordButtonRow.orientation = .horizontal
        passwordButtonRow.spacing = 8
        passwordButtonRow.alignment = .centerY
        let passwordActionsRow = row(label: "密码操作", field: passwordButtonRow, trailing: nil, isReadOnly: true)
        let allowedHostsRow = row(label: "允许的主机名", field: allowedHostsField)
        let httpProxyRow = row(label: "HTTP 代理", field: httpProxyField)
        let httpsProxyRow = row(label: "HTTPS 代理", field: httpsProxyField)
        let noProxyRow = row(label: "不使用代理", field: noProxyField)

        quitBehaviorPopup.addItems(withTitles: ServiceConfiguration.QuitBehavior.allCases.map(\.title))
        let quitRow = row(label: "退出行为", field: quitBehaviorPopup)
        autoStartButton.target = self
        autoStartButton.action = #selector(autoStartChanged(_:))

        for hint in [remoteAccessHintLabel, passwordHintLabel, workspaceHintLabel] {
            hint.lineBreakMode = .byWordWrapping
            hint.maximumNumberOfLines = 0
            hint.textColor = .secondaryLabelColor
        }
        errorLabel.textColor = .systemRed
        errorLabel.isHidden = true
        errorLabel.lineBreakMode = .byWordWrapping
        errorLabel.maximumNumberOfLines = 0

        let buttons = NSStackView(views: [resetButton, NSView(), cancelButton, saveButton])
        buttons.orientation = .horizontal
        buttons.spacing = 8
        buttons.alignment = .centerY

        let stack = NSStackView(views: [
            title,
            serviceHeader, pathRow, workspaceRow, workspaceHintLabel, portRow,
            remoteHeader, hostnameRow, passwordStatusRow, newPasswordRow, passwordActionsRow,
            passwordHintLabel, remoteAccessHintLabel,
            networkHeader, allowedHostsRow, httpProxyRow, httpsProxyRow, noProxyRow,
            behaviorHeader, autoStartButton, quitRow,
            errorLabel, buttons
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)

        for rowView in [
            pathRow, workspaceRow, portRow, hostnameRow, passwordStatusRow, newPasswordRow, passwordActionsRow,
            allowedHostsRow, httpProxyRow, httpsProxyRow, noProxyRow, quitRow
        ] {
            rowView.widthAnchor.constraint(equalToConstant: 520).isActive = true
        }
        buttons.widthAnchor.constraint(equalToConstant: 520).isActive = true
        errorLabel.widthAnchor.constraint(equalToConstant: 520).isActive = true
        passwordHintLabel.widthAnchor.constraint(equalToConstant: 520).isActive = true
        remoteAccessHintLabel.widthAnchor.constraint(equalToConstant: 520).isActive = true
        workspaceHintLabel.widthAnchor.constraint(equalToConstant: 520).isActive = true

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -24),
            title.widthAnchor.constraint(equalTo: stack.widthAnchor),
            autoStartButton.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])

        // 新增“远程访问”分区后内容变高（密码状态、新密码、密码按钮和两段说明）；
        // 再加入“工作目录”行与说明后，860 覆盖带两行错误提示时的实测高度，
        // 因此固定高度的窗口不会裁掉说明文字或底部按钮。
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 568, height: 860), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Pi Web Desktop 设置"
        window.contentView = content
        window.isReleasedWhenClosed = false
        window.center()
        self.window = window
    }

    /// 远程访问密码与传输加密的区别：界面必须明确说明密码认证不等于加密。
    private let passwordHintLabel = NSTextField(labelWithString:
        "密码认证只验证访问者身份，不等于 HTTPS 或加密隧道。远程访问请自行配置受信任的加密隧道（例如 WireGuard、SSH 端口转发）或 HTTPS 反向代理。")

    /// 工作目录说明：默认目录、首次使用时创建、必须可写。
    private let workspaceHintLabel = NSTextField(labelWithString: "")

    private func row(label: String, field: NSView, trailing: NSView? = nil, isReadOnly: Bool = false) -> NSView {
        let labelView = NSTextField(labelWithString: label)
        labelView.alignment = .right
        labelView.widthAnchor.constraint(equalToConstant: 100).isActive = true
        let row = NSStackView(views: trailing.map { [labelView, field, $0] } ?? [labelView, field])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        if isReadOnly {
            return row
        }
        if let textField = field as? NSTextField {
            textField.isEditable = true
            textField.translatesAutoresizingMaskIntoConstraints = false
            textField.widthAnchor.constraint(equalToConstant: 300).isActive = true
        } else if let popup = field as? NSPopUpButton {
            popup.widthAnchor.constraint(equalToConstant: 300).isActive = true
        }
        return row
    }

    /// 用当前生效配置刷新控件（W4 M2）。
    ///
    /// 设置窗口是单例：重复打开复用同一个控制器/窗口，因此每次展示前都要把控件
    /// 重置为已保存的值——上一次被取消的输入、外部改动与刚输入的新密码都不会
    /// 残留（已保存的密码本来就只以“已设置/未设置”呈现）。
    func update(configuration: ServiceConfiguration) {
        self.configuration = configuration
        newPasswordField.stringValue = ""
        errorLabel.isHidden = true
        loadValues()
    }

    private func loadValues() {
        pathField.stringValue = configuration.piWebPath
        workspaceField.stringValue = configuration.workspacePath
        refreshWorkspaceHint()
        hostnameField.stringValue = configuration.hostname
        hostnameField.isEditable = true
        hostnameField.isEnabled = true
        portField.stringValue = String(configuration.port)
        allowedHostsField.stringValue = configuration.allowedHosts
        httpProxyField.stringValue = configuration.httpProxy
        httpsProxyField.stringValue = configuration.httpsProxy
        noProxyField.stringValue = configuration.noProxy
        autoStartButton.state = configuration.autoStart ? .on : .off
        quitBehaviorPopup.selectItem(at: ServiceConfiguration.QuitBehavior.allCases.firstIndex(of: configuration.quitBehavior) ?? 0)
        refreshRemoteAccessState()
    }

    /// 工作目录提示：留空 = 默认目录；自选目录必须存在且可写。
    private func refreshWorkspaceHint() {
        let configured = workspaceField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if configured.isEmpty {
            workspaceHintLabel.stringValue = "留空时使用默认工作目录（\(defaultWorkspaceDirectory)）。"
                + "首次使用时自动创建；目录不存在或不可写时会暂停启动服务并给出诊断提示。"
        } else {
            workspaceHintLabel.stringValue = "当前工作目录：\(configured)。"
                + "pi-web 会在该目录写入运行文件，目录必须存在且可写。"
        }
    }

    /// 刷新“已设置/未设置”和与 hostname 联动的提示。只读结论来自 Keychain，
    /// 已保存的密码不会出现在任何控件里。
    private func refreshRemoteAccessState() {
        hasStoredPassword = RemoteAccessPassword.isSet(in: keychain)
        passwordStatusLabel.stringValue = RemoteAccessPassword.statusText(isSet: hasStoredPassword)
        deletePasswordButton.isEnabled = hasStoredPassword
        remoteAccessHintLabel.stringValue = remoteAccessHintText()
    }

    private func remoteAccessHintText() -> String {
        let hostname = hostnameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if RemoteAccessPolicy.isLoopbackHostname(hostname) {
            return "当前只监听本机（\(ServiceConfiguration.defaultHostname)），不需要密码。"
                + "改成远程地址前必须先在 Keychain 中保存密码。"
        }
        if hasStoredPassword {
            return "监听地址 \(hostname) 属于远程访问：访问者必须输入访问密码，"
                + "“允许的主机名”只做 Host 校验，不能替代密码认证。"
        }
        return "监听地址 \(hostname) 无法保存也无法启动：请先保存密码，"
            + "或把监听地址改回 \(ServiceConfiguration.defaultHostname)。"
    }

    @objc private func selectPiWebPath(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if #available(macOS 12.0, *) {
            panel.allowedContentTypes = [.unixExecutable]
        }
        panel.beginSheetModal(for: window!) { [weak self] response in
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
        panel.message = "选择 pi-web 的工作目录（必须可写）"
        panel.beginSheetModal(for: window!) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            switch WorkspaceDirectory.validate(path: url.path, probe: self.workspaceProbe) {
            case .usable:
                self.workspaceField.stringValue = url.path
                self.errorLabel.isHidden = true
            case .unusable(let problem, let path):
                self.showError("无法使用该工作目录（\(problem.title)）：\(path)。请改选一个可写目录。")
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
        // 恢复默认只重置普通设置：已保存的密码属于用户在 Keychain 中的秘密，
        // 只能由用户显式点击“删除密码”移除。
        configuration = .default
        loadValues()
        errorLabel.isHidden = true
    }

    @objc private func autoStartChanged(_ sender: Any?) {
        // Keep the control's value live; it is read when Save is pressed.
    }

    @objc private func cancel(_ sender: Any?) {
        onCancel?()
        close()
    }

    @objc private func savePassword(_ sender: Any?) {
        let outcome = RemoteAccessSetup.apply(
            requested: configuration,
            newPassword: newPasswordField.stringValue,
            keychain: keychain
        )
        guard let updated = outcome.configuration else {
            showError(outcome.error ?? "无法保存密码。")
            return
        }
        configuration = updated
        newPasswordField.stringValue = ""
        refreshRemoteAccessState()
        errorLabel.isHidden = true
        onRemoteAccessCredentialsChanged?(configuration)
    }

    @objc private func generatePassword(_ sender: Any?) {
        guard let generated = PasswordGenerator.generate() else {
            showError("无法生成密码：系统随机数不可用。请稍后重试。")
            return
        }
        // 新生成的密码只出现在输入框里，供用户复制后点击“保存密码”；
        // 已保存的密码不会被读回显示。
        newPasswordField.stringValue = generated
        errorLabel.isHidden = true
    }

    @objc private func deletePassword(_ sender: Any?) {
        do {
            try keychain.delete(for: RemoteAccessPassword.account)
        } catch {
            showError("无法删除 Keychain 中的密码：\(RemoteAccessSetup.readableMessage(for: error))")
            return
        }
        // 删除密码自动关闭远程模式并恢复默认 loopback，配置由回调持久化。
        configuration = RemoteAccessPolicy.disablingRemoteAccess(in: configuration)
        hostnameField.stringValue = configuration.hostname
        newPasswordField.stringValue = ""
        refreshRemoteAccessState()
        errorLabel.isHidden = true
        onRemoteAccessCredentialsChanged?(configuration)
    }

    @objc private func save(_ sender: Any?) {
        guard let port = Int(portField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)), (1...65535).contains(port) else {
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
        // 校验失败时返回可读错误，配置不会被保存。
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
        let requestedWithWorkspace = workspaceSelection.configuration
        // 密码只写入 Keychain；配置只通过 onSave 交给 AppDelegate 写入 UserDefaults。
        // 远程 hostname 缺少密码时这一步直接返回可读错误，配置不会被保存。
        let pendingPassword = newPasswordField.stringValue.isEmpty ? nil : newPasswordField.stringValue
        let outcome = RemoteAccessSetup.apply(requested: requestedWithWorkspace, newPassword: pendingPassword, keychain: keychain)
        guard let newConfiguration = outcome.configuration else {
            showError(outcome.error ?? "设置未保存。")
            return
        }
        configuration = newConfiguration
        newPasswordField.stringValue = ""
        // Persisted by AppDelegate through AppConfiguration so UserDefaults
        // access stays in one place.
        onSave?(newConfiguration)
        close()
    }

    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else { return }
        if field === hostnameField {
            remoteAccessHintLabel.stringValue = remoteAccessHintText()
        } else if field === workspaceField {
            refreshWorkspaceHint()
        }
    }

    private func showError(_ message: String) {
        errorLabel.stringValue = message
        errorLabel.isHidden = false
    }
}
