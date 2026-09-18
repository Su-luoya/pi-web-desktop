import Cocoa

final class PreferencesWindowController: NSWindowController {
    var onSave: ((ServiceConfiguration) -> Void)?
    var onCancel: (() -> Void)?

    private let pathField = NSTextField()
    private let hostnameField = NSTextField(labelWithString: "127.0.0.1")
    private let portField = NSTextField()
    private let allowedHostsField = NSTextField()
    private let httpProxyField = NSTextField()
    private let httpsProxyField = NSTextField()
    private let noProxyField = NSTextField()
    private let autoStartButton = NSButton(checkboxWithTitle: "应用启动时自动启动服务", target: nil, action: nil)
    private let quitBehaviorPopup = NSPopUpButton()
    private let errorLabel = NSTextField(labelWithString: "")

    private var configuration: ServiceConfiguration

    init(configuration: ServiceConfiguration) {
        self.configuration = configuration
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
        let networkHeader = NSTextField(labelWithString: "网络与代理")
        networkHeader.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        let behaviorHeader = NSTextField(labelWithString: "行为")
        behaviorHeader.font = NSFont.systemFont(ofSize: 13, weight: .semibold)

        let pathPicker = NSButton(title: "选择…", target: self, action: #selector(selectPiWebPath(_:)))
        let resetButton = NSButton(title: "恢复默认", target: self, action: #selector(resetDefaults(_:)))
        let cancelButton = NSButton(title: "取消", target: self, action: #selector(cancel(_:)))
        let saveButton = NSButton(title: "保存", target: self, action: #selector(save(_:)))
        saveButton.keyEquivalent = "\r"
        cancelButton.keyEquivalent = "\u{1b}"

        let pathRow = row(label: "pi-web 路径", field: pathField, trailing: pathPicker)
        let hostnameRow = row(label: "监听地址（仅本机）", field: hostnameField)
        let portRow = row(label: "端口", field: portField)
        let allowedHostsRow = row(label: "允许的主机名", field: allowedHostsField)
        let httpProxyRow = row(label: "HTTP 代理", field: httpProxyField)
        let httpsProxyRow = row(label: "HTTPS 代理", field: httpsProxyField)
        let noProxyRow = row(label: "不使用代理", field: noProxyField)

        quitBehaviorPopup.addItems(withTitles: ServiceConfiguration.QuitBehavior.allCases.map(\.title))
        let quitRow = row(label: "退出行为", field: quitBehaviorPopup)
        autoStartButton.target = self
        autoStartButton.action = #selector(autoStartChanged(_:))

        errorLabel.textColor = .systemRed
        errorLabel.isHidden = true
        errorLabel.lineBreakMode = .byWordWrapping

        let buttons = NSStackView(views: [resetButton, NSView(), cancelButton, saveButton])
        buttons.orientation = .horizontal
        buttons.spacing = 8
        buttons.alignment = .centerY

        let stack = NSStackView(views: [
            title, serviceHeader, pathRow, hostnameRow, portRow,
            networkHeader, allowedHostsRow, httpProxyRow, httpsProxyRow, noProxyRow,
            behaviorHeader, autoStartButton, quitRow, errorLabel, buttons
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)

        for rowView in [pathRow, hostnameRow, portRow, allowedHostsRow, httpProxyRow, httpsProxyRow, noProxyRow, quitRow] {
            rowView.widthAnchor.constraint(equalToConstant: 520).isActive = true
        }
        buttons.widthAnchor.constraint(equalToConstant: 520).isActive = true
        errorLabel.widthAnchor.constraint(equalToConstant: 520).isActive = true

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -24),
            title.widthAnchor.constraint(equalTo: stack.widthAnchor),
            autoStartButton.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 568, height: 500), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Pi Web Desktop 设置"
        window.contentView = content
        window.isReleasedWhenClosed = false
        window.center()
        self.window = window
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
            textField.widthAnchor.constraint(equalToConstant: 300).isActive = true
        } else if let popup = field as? NSPopUpButton {
            popup.widthAnchor.constraint(equalToConstant: 300).isActive = true
        }
        return row
    }

    private func loadValues() {
        pathField.stringValue = configuration.piWebPath
        hostnameField.stringValue = ServiceConfiguration.defaultHostname
        hostnameField.isEditable = false
        hostnameField.isEnabled = false
        portField.stringValue = String(configuration.port)
        allowedHostsField.stringValue = configuration.allowedHosts
        httpProxyField.stringValue = configuration.httpProxy
        httpsProxyField.stringValue = configuration.httpsProxy
        noProxyField.stringValue = configuration.noProxy
        autoStartButton.state = configuration.autoStart ? .on : .off
        quitBehaviorPopup.selectItem(at: ServiceConfiguration.QuitBehavior.allCases.firstIndex(of: configuration.quitBehavior) ?? 0)
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

    @objc private func resetDefaults(_ sender: Any?) {
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

    @objc private func save(_ sender: Any?) {
        guard let port = Int(portField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)), (1...65535).contains(port) else {
            showError("端口必须是 1 到 65535 之间的整数。")
            return
        }
        let hostname = ServiceConfiguration.defaultHostname
        guard hostname == "127.0.0.1" else {
            showError("当前版本只允许本机访问。")
            return
        }
        let url = URL(string: "http://\(hostname):\(port)/")
        guard let url, url.host == hostname, url.port == port else {
            showError("监听地址无效。")
            return
        }

        let newConfiguration = ServiceConfiguration(
            hostname: hostname,
            port: port,
            piWebPath: pathField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
            allowedHosts: allowedHostsField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
            httpProxy: httpProxyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
            httpsProxy: httpsProxyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
            noProxy: noProxyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
            autoStart: autoStartButton.state == .on,
            quitBehavior: ServiceConfiguration.QuitBehavior.allCases[quitBehaviorPopup.indexOfSelectedItem]
        )
        configuration = newConfiguration
        // Persisted by AppDelegate through AppConfiguration so UserDefaults
        // access stays in one place.
        onSave?(newConfiguration)
        close()
    }

    private func showError(_ message: String) {
        errorLabel.stringValue = message
        errorLabel.isHidden = false
    }
}
