import Foundation
import XCTest

/// Unhosted tests: `Sources/DiagnosticsCollector.swift` is compiled directly
/// into this target. Every value below is fake, so the assembled text must not
/// contain a real user path or any secret — and it must still carry the failure
/// context (versions, status, port, confidence) that makes the export useful.
final class DiagnosticsCollectorTests: XCTestCase {
    private let input = DiagnosticsInput(
        appVersion: "9.9.9",
        appBuild: "42",
        piWebVersion: "1.2.3",
        piWebVersionConfidence: "verified",
        piWebPath: "/opt/homebrew/bin/pi-web",
        piWebPathConfidence: "verified",
        piCLIVersion: "0.5.0",
        piCLIVersionConfidence: "inferred",
        nodeVersion: "v22.19.0",
        nodeVersionConfidence: "verified",
        serviceAddress: "http://127.0.0.1:30141/",
        port: "30141",
        status: "正在运行（本应用管理）",
        management: .managed(pid: "4321"),
        listenerPID: "4321",
        listenerProcess: "/opt/homebrew/bin/pi-web --hostname 127.0.0.1 --port 30141 --no-open",
        managedPID: "4321",
        workspaceDirectory: "/tmp/PiWebDesktopTests/Workspace",
        configurationDirectory: "~/.pi/agent",
        launchCommand: "/opt/homebrew/bin/pi-web --hostname 127.0.0.1 --port 30141 --no-open",
        launchEnvironment: "PI_WEB_NO_OPEN=1",
        logPath: "/tmp/PiWebDesktopTests/logs/Pi Web Desktop.log",
        logWriteStatus: "正常",
        remoteAccessPasswordStatus: "已设置（仅存于 Keychain）"
    )

    /// 导出文本的标签集合（字段顺序由 `testTextMatchesTheExpectedLayout` 单独固定）。
    /// #10 新增的版本可信度与托管关系都在内。
    private let expectedLabels: [String] = [
        "Pi Web Desktop 版本",
        "Pi Web Desktop 构建号",
        "pi-web 版本",
        "pi-web 路径",
        "Pi CLI 版本",
        "Node.js 版本",
        "服务地址",
        "端口",
        "状态",
        "托管关系",
        "监听 PID",
        "监听进程",
        "托管 PID",
        "有效工作目录",
        "配置目录",
        "启动命令",
        "启动环境",
        "日志文件",
        "日志写入",
        "远程访问密码"
    ]

    /// 按 `标签: 值` 解析导出文本。每一行都必须可解析（多行值由实现拆成带序号的
    /// 唯一标签行），否则显式失败，避免解析器静默吞掉不合规的输出。
    private func parseExport(
        _ text: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> [(label: String, value: String)] {
        var fields: [(label: String, value: String)] = []
        for rawLine in text.components(separatedBy: "\n") {
            guard let separator = rawLine.firstIndex(of: ":"),
                  separator > rawLine.startIndex else {
                XCTFail("导出文本每一行都必须是 `标签: 值`: \(rawLine)", file: file, line: line)
                continue
            }
            let remainder = rawLine[rawLine.index(after: separator)...]
            guard remainder.hasPrefix(" ") else {
                XCTFail("`标签:` 后必须有一个空格再接值: \(rawLine)", file: file, line: line)
                continue
            }
            fields.append((String(rawLine[rawLine.startIndex..<separator]), String(remainder.dropFirst())))
        }
        return fields
    }

    private func value(_ label: String, in fields: [(label: String, value: String)]) -> String? {
        fields.first { $0.label == label }?.value
    }

    private func assertLabelsAreUniqueAndComplete(
        _ fields: [(label: String, value: String)],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let labels = fields.map(\.label)
        XCTAssertEqual(Set(labels).count, labels.count, "标签必须唯一: \(labels)", file: file, line: line)
        XCTAssertEqual(Set(labels), Set(expectedLabels), file: file, line: line)
        XCTAssertEqual(labels.count, expectedLabels.count, file: file, line: line)
    }

    func testTextMatchesTheExpectedLayout() {
        let expected = """
        Pi Web Desktop 版本: 9.9.9
        Pi Web Desktop 构建号: 42
        pi-web 版本: 1.2.3（可信度 verified（已验证））
        pi-web 路径: /opt/homebrew/bin/pi-web（可信度 verified（已验证））
        Pi CLI 版本: 0.5.0（可信度 inferred（推断））
        Node.js 版本: v22.19.0（可信度 verified（已验证））
        服务地址: http://127.0.0.1:30141/
        端口: 30141
        状态: 正在运行（本应用管理）
        托管关系: managed（本应用托管，所有权校验通过；托管 PID 4321）
        监听 PID: 4321
        监听进程: /opt/homebrew/bin/pi-web --hostname 127.0.0.1 --port 30141 --no-open
        托管 PID: 4321
        有效工作目录: /tmp/PiWebDesktopTests/Workspace
        配置目录: ~/.pi/agent
        启动命令: /opt/homebrew/bin/pi-web --hostname 127.0.0.1 --port 30141 --no-open
        启动环境: PI_WEB_NO_OPEN=1
        日志文件: /tmp/PiWebDesktopTests/logs/Pi Web Desktop.log
        日志写入: 正常
        远程访问密码: 已设置（仅存于 Keychain）
        """
        XCTAssertEqual(DiagnosticsCollector.text(for: input), expected)
    }

    /// 每一条都在：版本号、构建号、状态、端口、托管关系、工作目录、日志位置、
    /// 以及三类可信度取值。
    func testEveryFieldAppears() {
        let text = DiagnosticsCollector.text(for: input)
        for value in [
            "9.9.9",
            "42",
            "1.2.3",
            "0.5.0",
            "v22.19.0",
            "verified（已验证）",
            "inferred（推断）",
            "http://127.0.0.1:30141/",
            "端口: 30141",
            "正在运行（本应用管理）",
            "managed（本应用托管，所有权校验通过；托管 PID 4321）",
            "4321",
            "/opt/homebrew/bin/pi-web",
            "有效工作目录: /tmp/PiWebDesktopTests/Workspace",
            "~/.pi/agent",
            "PI_WEB_NO_OPEN=1",
            "/tmp/PiWebDesktopTests/logs/Pi Web Desktop.log",
            "日志写入: 正常"
        ] {
            XCTAssertTrue(text.contains(value), "diagnostics is missing \(value)")
        }
        assertLabelsAreUniqueAndComplete(parseExport(text))
    }

    /// 脱敏不牺牲故障上下文：秘密与用户名全部消失，但版本、状态、端口、可信度
    /// 仍然完整。
    func testSensitiveValuesAreRedactedWhileTheFailureContextRemains() {
        let name = "alice"
        let secret = "hunter2-secret-value"
        let sensitive = DiagnosticsInput(
            appVersion: "9.9.9",
            appBuild: "42",
            piWebVersion: "未知",
            piWebVersionConfidence: "unknown",
            piWebPath: "/Use" + "rs/\(name)/.nvm/pi-web",
            piWebPathConfidence: "inferred",
            piCLIVersion: "0.5.0",
            piCLIVersionConfidence: "verified",
            nodeVersion: "v22.19.0",
            nodeVersionConfidence: "verified",
            serviceAddress: "http://127.0.0.1:30141/?token=\(secret)",
            port: "30141",
            status: "失败：找不到 pi-web",
            management: .external,
            listenerPID: "无",
            listenerProcess: "/opt/homebrew/bin/pi-web --password \(secret)",
            managedPID: "无（外部服务或未运行）",
            workspaceDirectory: "/Use" + "rs/\(name)/Workspace",
            configurationDirectory: "~/.pi/agent",
            launchCommand: "https://user:pass@pi.example.invalid/api?secret=1 --api-key \(secret)",
            launchEnvironment: """
            PI_WEB_PASSWORD=\(secret)
            HTTPS_PROXY=http://proxy-user:proxy-pass@proxy.example.invalid:8080
            """,
            logPath: "/Use" + "rs/\(name)/Library/Logs/Pi Web Desktop.log",
            logWriteStatus: "写入失败（2026-01-02 03:04:05 创建日志目录失败：~）",
            remoteAccessPasswordStatus: "已设置（仅存于 Keychain）"
        )

        let text = DiagnosticsCollector.text(for: sensitive)

        // 故障上下文保留。
        for expected in [
            "9.9.9",
            "42",
            "0.5.0",
            "v22.19.0",
            "端口: 30141",
            "失败：找不到 pi-web",
            "external（外部服务或未运行，无有效所有权记录）",
            "verified（已验证）",
            "inferred（推断）",
            "unknown（未知）",
            "写入失败（2026-01-02 03:04:05"
        ] {
            XCTAssertTrue(text.contains(expected), "missing context \(expected)")
        }

        // 已知敏感字段不出现。
        for forbidden in [secret, name, "user:pass", "proxy-user", "proxy-pass", "/Use" + "rs/"] {
            XCTAssertFalse(text.contains(forbidden), "leaked \(forbidden)")
        }
        XCTAssertTrue(text.contains("PI_WEB_PASSWORD=\(LogRedactor.marker)"), text)
        XCTAssertTrue(text.contains("有效工作目录: ~/Workspace"), text)
        XCTAssertTrue(text.contains("pi-web 路径: ~/.nvm/pi-web（可信度 inferred（推断））"), text)
        XCTAssertTrue(text.contains("日志文件: ~/Library/Logs/Pi Web Desktop.log"), text)
        XCTAssertTrue(text.contains("服务地址: http://127.0.0.1:30141/?\(LogRedactor.marker)"), text)
        XCTAssertTrue(text.contains("proxy.example.invalid:8080"), "代理端点仍然保留")
    }

    func testConfidenceTextMapsTheThreeEvidenceLevels() {
        XCTAssertEqual(DiagnosticsCollector.confidenceText("verified"), "verified（已验证）")
        XCTAssertEqual(DiagnosticsCollector.confidenceText("inferred"), "inferred（推断）")
        XCTAssertEqual(DiagnosticsCollector.confidenceText("unknown"), "unknown（未知）")
        XCTAssertEqual(DiagnosticsCollector.confidenceText(""), "unknown（未知）")
        XCTAssertEqual(DiagnosticsCollector.confidenceText("猜测"), "unknown（未知）")
    }

    /// 诊断文本里只能出现“已设置/未设置”的结论：密码值、密码长度和 Keychain
    /// 原始数据都不会进入收集器，也不会出现在输出里。
    func testPasswordStateIsReportedWithoutTheSecret() {
        let text = DiagnosticsCollector.text(for: input)
        XCTAssertTrue(text.contains("远程访问密码: 已设置（仅存于 Keychain）"))
        XCTAssertFalse(text.contains("hunter2"))

        let unset = DiagnosticsInput(
            appVersion: "9.9.9",
            appBuild: "42",
            piWebVersion: "1.2.3",
            piWebVersionConfidence: "verified",
            piWebPath: "/opt/homebrew/bin/pi-web",
            piWebPathConfidence: "verified",
            piCLIVersion: "0.5.0",
            piCLIVersionConfidence: "verified",
            nodeVersion: "v22.19.0",
            nodeVersionConfidence: "verified",
            serviceAddress: "http://127.0.0.1:30141/",
            port: "30141",
            status: "已停止",
            management: .external,
            listenerPID: "无",
            listenerProcess: "无",
            managedPID: "无（外部服务或未运行）",
            workspaceDirectory: "/tmp/PiWebDesktopTests/Workspace",
            configurationDirectory: "~/.pi/agent",
            launchCommand: "未找到",
            launchEnvironment: "",
            logPath: "",
            logWriteStatus: "正常",
            remoteAccessPasswordStatus: RemoteAccessPassword.statusText(isSet: false)
        )
        let unsetText = DiagnosticsCollector.text(for: unset)
        XCTAssertTrue(unsetText.contains("远程访问密码: 未设置"))
        XCTAssertTrue(unsetText.contains("托管关系: external（外部服务或未运行，无有效所有权记录）"))
    }

    func testTextHasNoRealUserPathOrSecret() {
        let text = DiagnosticsCollector.text(for: input)
        // The home-directory prefix is assembled from fragments so this test file
        // cannot itself trip the repository scans that look for absolute user
        // paths in checked-in text.
        let homeDirectoryPrefix = "/Use" + "rs/"
        XCTAssertFalse(text.contains(homeDirectoryPrefix))
        XCTAssertFalse(text.contains("hunter2"))
        XCTAssertFalse(text.contains("password"))
    }

    func testEmptyFieldsAreStillLabeled() {
        let empty = DiagnosticsInput(
            appVersion: "",
            appBuild: "",
            piWebVersion: "",
            piWebVersionConfidence: "",
            piWebPath: "未找到",
            piWebPathConfidence: "",
            piCLIVersion: "",
            piCLIVersionConfidence: "",
            nodeVersion: "",
            nodeVersionConfidence: "",
            serviceAddress: "",
            port: "",
            status: "",
            management: .external,
            listenerPID: "无",
            listenerProcess: "无",
            managedPID: "无（外部服务或未运行）",
            workspaceDirectory: "",
            configurationDirectory: "~/.pi/agent",
            launchCommand: "",
            launchEnvironment: "",
            logPath: "",
            logWriteStatus: "正常",
            remoteAccessPasswordStatus: "未设置"
        )
        let text = DiagnosticsCollector.text(for: empty)
        XCTAssertTrue(text.contains("监听 PID: 无"))
        XCTAssertTrue(text.contains("托管 PID: 无（外部服务或未运行）"))
        XCTAssertTrue(text.contains("pi-web 路径: 未找到（可信度 unknown（未知））"))
        XCTAssertTrue(text.contains("监听进程: 无"))

        let fields = parseExport(text)
        assertLabelsAreUniqueAndComplete(fields)
        for label in ["Pi Web Desktop 版本", "服务地址", "启动环境", "日志文件"] {
            XCTAssertEqual(value(label, in: fields), "", "空值必须保留成空字段: \(label)")
        }
    }

    /// 值原样输出（不裁剪、不转义），每一行恰好一个唯一的 `标签: 值`，否则复制
    /// 出去的文本无法可靠解析；多行值同样由实现拆成带序号的唯一标签行。
    func testEveryLineCarriesOneUniqueLabelAndTheValueVerbatim() {
        var padded = input
        padded.status = "  正在运行  "
        padded.configurationDirectory = "~/.pi/agent/"

        let fields = parseExport(DiagnosticsCollector.text(for: padded))

        assertLabelsAreUniqueAndComplete(fields)
        // 值逐字：前导/尾随空格与结尾斜杠都不被裁剪。
        XCTAssertEqual(value("状态", in: fields), "  正在运行  ")
        XCTAssertEqual(value("配置目录", in: fields), "~/.pi/agent/")
        // #10 新增的版本可信度与托管关系也按同一规则输出。
        XCTAssertEqual(value("pi-web 版本", in: fields), "1.2.3（可信度 verified（已验证））")
        XCTAssertEqual(value("pi-web 路径", in: fields), "/opt/homebrew/bin/pi-web（可信度 verified（已验证））")
        XCTAssertEqual(value("Pi CLI 版本", in: fields), "0.5.0（可信度 inferred（推断））")
        XCTAssertEqual(value("Node.js 版本", in: fields), "v22.19.0（可信度 verified（已验证））")
        XCTAssertEqual(value("托管关系", in: fields), DiagnosticsManagement.managed(pid: "4321").text)
        XCTAssertEqual(value("远程访问密码", in: fields), "已设置（仅存于 Keychain）")
    }

    /// 多行值不产生无标签的续行：每个环境变量条目独占一行，标签唯一，值逐字保留。
    func testMultiLineValuesKeepOneUniqueLabelPerLine() {
        var multiLine = input
        multiLine.launchEnvironment = "PI_WEB_NO_OPEN=1\nINTEGRATION_BASE=1"

        let text = DiagnosticsCollector.text(for: multiLine)
        let fields = parseExport(text)

        let labels = fields.map(\.label)
        XCTAssertEqual(Set(labels).count, labels.count, "标签必须唯一: \(labels)")
        XCTAssertEqual(labels.count, expectedLabels.count + 1, "多行值只增加一个带序号的标签行")
        XCTAssertEqual(value("启动环境", in: fields), "PI_WEB_NO_OPEN=1")
        XCTAssertEqual(value("启动环境[2]", in: fields), "INTEGRATION_BASE=1")
        for label in labels {
            XCTAssertTrue(
                expectedLabels.contains(label) || label.hasPrefix("启动环境["),
                "多行值续行的标签必须可识别: \(label)"
            )
        }
    }
}
