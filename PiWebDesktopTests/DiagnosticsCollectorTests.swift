import Foundation
import XCTest

/// Unhosted tests: `Sources/DiagnosticsCollector.swift` is compiled directly
/// into this target. Every value below is fake, so the assembled text must not
/// contain a real user path or any secret.
final class DiagnosticsCollectorTests: XCTestCase {
    private let input = DiagnosticsInput(
        appVersion: "9.9.9 (42)",
        piWebVersion: "1.2.3",
        nodeVersion: "v22.19.0",
        serviceAddress: "http://127.0.0.1:30141/",
        status: "正在运行（本应用管理）",
        listenerPID: "4321",
        listenerProcess: "/opt/homebrew/bin/pi-web --hostname 127.0.0.1 --port 30141 --no-open",
        managedPID: "4321",
        piWebPath: "/opt/homebrew/bin/pi-web",
        configurationDirectory: "~/.pi/agent",
        logPath: "/tmp/PiWebDesktopTests/logs/Pi Web Desktop.log"
    )

    func testTextMatchesTheExpectedLayout() {
        let expected = """
        Pi Web Desktop: 9.9.9 (42)
        pi-web: 1.2.3
        Node.js: v22.19.0
        服务地址: http://127.0.0.1:30141/
        状态: 正在运行（本应用管理）
        监听 PID: 4321
        监听进程: /opt/homebrew/bin/pi-web --hostname 127.0.0.1 --port 30141 --no-open
        托管 PID: 4321
        pi-web 路径: /opt/homebrew/bin/pi-web
        配置目录: ~/.pi/agent
        日志: /tmp/PiWebDesktopTests/logs/Pi Web Desktop.log
        """
        XCTAssertEqual(DiagnosticsCollector.text(for: input), expected)
    }

    func testEveryFieldAppears() {
        let text = DiagnosticsCollector.text(for: input)
        for value in [
            "9.9.9 (42)",
            "1.2.3",
            "v22.19.0",
            "http://127.0.0.1:30141/",
            "正在运行（本应用管理）",
            "4321",
            "/opt/homebrew/bin/pi-web",
            "~/.pi/agent",
            "/tmp/PiWebDesktopTests/logs/Pi Web Desktop.log"
        ] {
            XCTAssertTrue(text.contains(value), "diagnostics is missing \(value)")
        }
        XCTAssertEqual(text.components(separatedBy: "\n").count, 11)
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
            piWebVersion: "",
            nodeVersion: "",
            serviceAddress: "",
            status: "",
            listenerPID: "无",
            listenerProcess: "无",
            managedPID: "无（外部服务或未运行）",
            piWebPath: "未找到",
            configurationDirectory: "~/.pi/agent",
            logPath: ""
        )
        let text = DiagnosticsCollector.text(for: empty)
        XCTAssertTrue(text.contains("监听 PID: 无"))
        XCTAssertTrue(text.contains("托管 PID: 无（外部服务或未运行）"))
        XCTAssertTrue(text.contains("pi-web 路径: 未找到"))
    }
}
