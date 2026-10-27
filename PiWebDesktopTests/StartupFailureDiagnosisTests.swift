import Foundation
import XCTest

/// 启动失败归因：日志尾行 → 可读原因。
final class StartupFailureDiagnosisTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("StartupFailureDiagnosisTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func writeLog(_ text: String, name: String = "app.log") throws -> URL {
        let url = root.appendingPathComponent(name)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// 真实生产日志的形态：EADDRINUSE 之后还跟着一行 Next.js 退出。
    func testPortInUseIsNamedBeforeTheLogPath() throws {
        let url = try writeLog("""
        启动 pi-web：/usr/local/bin/pi-web --hostname 127.0.0.1 --port 30141
        Error: listen EADDRINUSE: address already in use 127.0.0.1:30141
            at Server.setupListenHandle (node:net:1908:16)
            code: 'EADDRINUSE',
          errno: -48,
          syscall: 'listen',
          address: '127.0.0.1',
          port: 30141
        [pi-web] Next.js exited unexpectedly (code 1)
        """)

        let message = StartupFailureDiagnosis.message(logURL: url)
        XCTAssertTrue(message.contains("端口已被其它程序占用"), message)
        XCTAssertTrue(message.contains(url.path), "日志路径必须仍然保留")
        XCTAssertFalse(message.hasPrefix("pi-web 进程已退出"), "原因要排在通用文案前面")
    }

    /// 地址不在本机：即便地址回落已经处理了这种情况，日志归因也要认得出。
    func testMissingAddressIsNamed() throws {
        let url = try writeLog("""
          code: 'EADDRNOTAVAIL',
          errno: -49,
          syscall: 'listen'
        """)
        let message = StartupFailureDiagnosis.message(logURL: url)
        XCTAssertTrue(message.contains("不在本机"), message)
    }

    func testMissingModuleSuggestsReinstall() {
        let summary = StartupFailureDiagnosis.summarize(logTail: "Error: Cannot find module '/opt/homebrew/lib/node_modules/@agegr/pi-web/dist/cli.js'")
        XCTAssertEqual(
            summary,
            "pi-web 依赖缺失或安装损坏。请重新执行 npm install -g @agegr/pi-web@latest。"
        )
    }

    /// 认不出的失败不猜：保留原通用文案。
    func testUnknownFailureKeepsTheGenericMessage() throws {
        let url = try writeLog("something entirely unexpected happened")
        let message = StartupFailureDiagnosis.message(logURL: url)
        XCTAssertEqual(message, "pi-web 进程已退出。请查看日志：\(url.path)")
    }

    /// 日志不存在（例如无法创建）时不崩，也不猜原因。
    func testMissingLogFileFallsBackToTheGenericMessage() {
        let url = root.appendingPathComponent("does-not-exist.log")
        let message = StartupFailureDiagnosis.message(logURL: url)
        XCTAssertEqual(message, "pi-web 进程已退出。请查看日志：\(url.path)")
    }

    /// 只读末尾若干字节：真实日志可能有几 MB，启动失败路径不该整份读入。
    func testOnlyTheTailIsRead() throws {
        let padding = String(repeating: "x", count: 8 * 1024)
        let url = try writeLog(padding + "\nError: listen EADDRINUSE: address already in use\n")
        let tail = try XCTUnwrap(StartupFailureDiagnosis.readTail(of: url, maxBytes: 1024))
        XCTAssertTrue(tail.contains("EADDRINUSE"))
        XCTAssertLessThan(tail.count, 2048)
    }

    /// 末尾多字节字符被截断时不能崩（UTF-8 解码失败 → nil，而不是崩溃）。
    func testTruncatedMultiByteTailDoesNotCrash() throws {
        let padding = String(repeating: "日", count: 4096)
        let url = try writeLog(padding)
        _ = StartupFailureDiagnosis.readTail(of: url, maxBytes: 1001)
        _ = StartupFailureDiagnosis.message(logURL: url)
    }
}
