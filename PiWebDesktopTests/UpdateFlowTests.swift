import XCTest

/// 统一更新流程的纯函数部分：执行顺序、确认文案、结果文案。
///
/// 条目里的执行步骤在这里只作为占位（同一类 payload 即可）：判定“下一步做什么”
/// 由各组件的 Coordinator 负责，这里不重复测它们。
final class UpdateFlowTests: XCTestCase {
    private func entry(
        _ component: UpdateFlowComponent,
        _ summary: String,
        note: String? = nil
    ) -> UpdateFlowEntry {
        UpdateFlowEntry(component: component, summary: summary, note: note, step: .piPackages([]))
    }

    func testPlanRunsComponentsInFixedOrder() {
        let plan = UpdateFlowPlanner.plan(
            entries: [
                entry(.desktopApp, "桌面应用 1.0 → 2.0"),
                entry(.piWeb, "Pi Web 0.15.0 → 0.16.0"),
                entry(.piPackages, "Pi 扩展包 1 个：a 1.0 → 1.1"),
                entry(.piCLI, "Pi CLI 0.4.0 → 0.4.1")
            ],
            skipped: ["Pi CLI：没有可用的目标版本"]
        )
        XCTAssertEqual(plan.entries.map(\.component), [.piCLI, .piPackages, .piWeb, .desktopApp])
        XCTAssertFalse(plan.isEmpty)
        XCTAssertEqual(plan.skipped, ["Pi CLI：没有可用的目标版本"])
    }

    func testPlanWithNothingExecutableIsEmpty() {
        let plan = UpdateFlowPlanner.plan(entries: [], skipped: ["Pi Web：没有可用的目标版本"])
        XCTAssertTrue(plan.isEmpty)
    }

    func testConfirmationListsEveryEntryAndSkipReason() {
        let plan = UpdateFlowPlanner.plan(
            entries: [
                entry(.piCLI, "Pi CLI 0.4.0 → 0.4.1"),
                entry(.piPackages, "Pi 扩展包 1 个：a 1.0 → 1.1", note: "已运行的 Pi 会话需要重启后才使用新版本")
            ],
            skipped: ["桌面应用：这次检查的版本没能核实，暂时不下载"]
        )
        XCTAssertEqual(UpdateFlowText.title(for: plan), "发现 2 项更新")
        let body = UpdateFlowText.body(for: plan)
        XCTAssertTrue(body.contains("1. Pi CLI 0.4.0 → 0.4.1"), body)
        XCTAssertTrue(body.contains("2. Pi 扩展包 1 个：a 1.0 → 1.1（已运行的 Pi 会话需要重启后才使用新版本）"), body)
        XCTAssertTrue(body.contains("· 桌面应用：这次检查的版本没能核实，暂时不下载"), body)
        XCTAssertTrue(body.contains("不经过 shell"), body)
    }

    func testNothingToDoExplainsWhyAndPointsAtSettings() {
        let allCurrent = UpdateFlowText.nothingToDoBody(skipped: [])
        XCTAssertTrue(allCurrent.contains("全部已是最新"), allCurrent)
        XCTAssertTrue(allCurrent.contains("更新 → 更新设置"), allCurrent)

        let blocked = UpdateFlowText.nothingToDoBody(skipped: ["Pi CLI：安装来源无法验证"])
        XCTAssertTrue(blocked.contains("· Pi CLI：安装来源无法验证"), blocked)
        XCTAssertTrue(blocked.contains("更新 → 更新设置"), blocked)
    }

    func testResultTitleSeparatesTotalAndPartialFailure() {
        XCTAssertEqual(UpdateFlowText.resultTitle(succeeded: 2, failed: 0), "更新完成")
        XCTAssertEqual(UpdateFlowText.resultTitle(succeeded: 2, failed: 1), "更新部分完成")
        XCTAssertEqual(UpdateFlowText.resultTitle(succeeded: 0, failed: 1), "更新未完成")
    }

    /// 刚装上的版本不能在下一次网络检查前被再次列成“可更新”。
    func testJustInstalledVersionsAreNotListedAgain() throws {
        let source = SourceScan.codeText(of: try SourceScan.text(named: "AppDelegate+UpdateFlow.swift"))
        XCTAssertTrue(source.contains("installedUpdateFlowVersions[entry.component.checkCategory] == version"))
        XCTAssertTrue(source.contains("self.installedUpdateFlowVersions[entry.component.checkCategory] = installedVersion"))
    }

    /// 检查说“已是最新”时不能把 Pi CLI 排进队列：那只会白跑一次 `pi update --self`。
    func testPiCLIIsOnlyQueuedWhenTheCheckReportsAnUpdate() throws {
        let source = SourceScan.codeText(of: try SourceScan.text(named: "AppDelegate+UpdateFlow.swift"))
        let start = try XCTUnwrap(source.range(of: "private func piCLIUpdateFlowEntry()"))
        let body = String(source[start.lowerBound...].prefix(400))
        XCTAssertTrue(body.contains("guard piCLICheckReportsUpdate() else { return nil }"), body)
    }

    /// 「检查说没有更新」的组件根本不该进执行队列：否则点开就看到一条
    /// 1.5.2 → 最新版本 的空更新。
    func testUpToDateComponentsAreNotQueued() throws {
        let source = SourceScan.codeText(of: try SourceScan.text(named: "AppDelegate+UpdateFlow.swift"))
        for entry in ["piCLIUpdateFlowEntry", "piWebUpdateFlowEntry"] {
            let start = try XCTUnwrap(source.range(of: "private func \(entry)"))
            let body = String(source[start.lowerBound...].prefix(400))
            XCTAssertTrue(
                body.contains("guard piCLICheckReportsUpdate()") || body.contains("guard piWebCheckReportsUpdate()"),
                "\(entry) 没有先以检查结论为准就排队"
            )
        }
    }
}
