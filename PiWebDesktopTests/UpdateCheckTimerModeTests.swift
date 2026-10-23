import XCTest

// 周期更新检查计时器的 run loop 模式回归测试（真机缺陷，alpha.17 前修复）。
//
// 缺陷：`DispatchUpdateCheckScheduler.startRepeating` 原先用
// `Timer.scheduledTimer`，只把计时器加入默认 `RunLoop.Mode.default`。菜单跟踪、
// 拖动滑杆、sheet 与 `runModal()` 期间主运行循环跑在 `eventTracking` /
// `modalPanel` 模式，默认模式上的计时器在那段时间完全不触发 —— 每日/每周复查
// 会被用户的交互静默吞掉一次，且没有任何日志。
//
// 实测证据（macOS 27.0.1 / arm64）：在真实 NSApplication 事件循环里，默认模式的
// 计时器在 `eventTracking` 期间触发 0 次，而 `.common` 模式的计时器触发 12 次。
//
// 这个测试不跑真实 run loop（unhosted bundle 里没有 NSApplication），而是断言
// 生产实现把计时器挂到了 `.common` 模式上，并把上面那段结论写进断言消息，避免
// 后人再把 `scheduledTimer` 改回来。

final class UpdateCheckTimerModeTests: XCTestCase {

    private var workingDirectory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        workingDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("UpdateCheckTimerModeTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let workingDirectory {
            try? FileManager.default.removeItem(at: workingDirectory)
        }
        try super.tearDownWithError()
    }

    /// 生产调度器的源码必须把计时器加入 `.common` 模式，且不得再使用只挂默认
    /// 模式的 `Timer.scheduledTimer`。
    ///
    /// 断言前先剥掉注释：这个文件自己的文档注释会提到被禁止的 API 名字，不剥
    /// 就会自证失败。
    func testProductionSchedulerAddsTimerToCommonModes() throws {
        let source = try readSource("Sources/Updates/UpdateCheckScheduling.swift")
        let code = strippingComments(source)

        XCTAssertTrue(
            code.contains("RunLoop.main.add(timer, forMode: .common)"),
            "周期更新检查计时器必须挂在 .common 模式上，否则菜单跟踪 / sheet / "
                + "runModal() 期间主运行循环不服务默认模式，每日/每周复查会被静默吞掉。"
        )
        XCTAssertFalse(
            code.contains("Timer.scheduledTimer"),
            "不能用 Timer.scheduledTimer：它只把计时器加入 RunLoop.Mode.default。"
        )
    }

    /// 反证：把源码改回 `scheduledTimer` 时断言会失败。用一段等价文本验证检测
    /// 逻辑本身有效，防止上面那条断言因为字符串写错而永远通过。
    func testDetectionRejectsScheduledTimerForm() {
        let defective = """
            func startRepeating(interval: TimeInterval, _ work: @escaping () -> Void) -> UpdateTimerToken {
                let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in work() }
                return TimerUpdateToken(timer: timer)
            }
            """
        XCTAssertFalse(defective.contains("forMode: .common"), "缺陷形态不应包含 .common 注册")
        XCTAssertTrue(defective.contains("Timer.scheduledTimer"), "缺陷形态应被 scheduledTimer 检测命中")

        let fixed = """
            func startRepeating(interval: TimeInterval, _ work: @escaping () -> Void) -> UpdateTimerToken {
                let timer = Timer(timeInterval: interval, repeats: true) { _ in work() }
                RunLoop.main.add(timer, forMode: .common)
                return TimerUpdateToken(timer: timer)
            }
            """
        XCTAssertTrue(fixed.contains("RunLoop.main.add(timer, forMode: .common)"))
        XCTAssertFalse(fixed.contains("Timer.scheduledTimer"))
    }

    /// 退出确认框的决策超时计时器早先已有同样的处理，一并锁住，避免有人“统一”
    /// 改回 `scheduledTimer` 而让超时在 sheet 期间失效（那会让退出卡在等待用户
    /// 选择的界面上）。
    func testQuitDecisionTimerAlsoUsesCommonModes() throws {
        let source = try readSource("Sources/App/AppDelegate+Quit.swift")
        XCTAssertTrue(
            source.contains("RunLoop.main.add(timer, forMode: .common)"),
            "退出决策超时计时器必须挂在 .common 模式，否则 sheet 期间超时不触发。"
        )
    }

    // MARK: - 辅助

    /// 去掉 `//` 与 `///` 行内注释，避免文档里提到的 API 名造成自证失败。
    private func strippingComments(_ source: String) -> String {
        source
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> String in
                guard let range = line.range(of: "//") else { return String(line) }
                // 只在整行注释或行内注释处截断；这里不处理字符串字面量里的 "//"，
                // 被测文件里没有这种写法。
                let prefix = line[..<range.lowerBound].trimmingCharacters(in: .whitespaces)
                return prefix.isEmpty ? "" : String(prefix)
            }
            .joined(separator: "\n")
    }

    private func readSource(_ relativePath: String) throws -> String {
        // 测试 bundle 在 DerivedData 深处，用 #filePath 回到仓库根再拼相对路径。
        let thisFile = URL(fileURLWithPath: #filePath)
        let repositoryRoot = thisFile
            .deletingLastPathComponent()   // PiWebDesktopTests
            .deletingLastPathComponent()   // 仓库根
        let url = repositoryRoot.appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }
}
