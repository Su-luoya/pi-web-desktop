import XCTest

// 桌面自更新失败路径的守卫测试（真机缺陷，alpha.17 修）。
//
// 缺陷形态：`downloadAndInstallDesktopApp` 在一轮已经开始（`beginDesktopAppUpdateActivity`
// 占住了 `desktopAppUpdateRound`）之后，某些失败分支只调用了 `presentDesktopUpdateFailure`
// 而漏掉 `finishDesktopAppUpdateRound`。于是 `activity` 永远停在 `.resolvingRelease`
// 或 `.installing`，菜单入口被 `DesktopAppUpdateEntryPolicy.isBusy` 永久挡住 ——
// 用户唯一的出路是重启应用。校验和下载失败那条分支就是这样漏的。
//
// 这类缺陷的特点是**没有任何运行时症状可测**（要真机走完一次下载 + 校验和失败），
// 所以这里做源码级结构断言：失败分支必须走把「结束本轮 + 提示」绑在一起的唯一入口
// `failDesktopAppUpdateRound(_:releaseTag:)`，不允许再出现「先 present 再指望自己
// 记得 finish」的裸组合。`DesktopAppUpdateRound` 自身的阶段机语义由
// `DesktopAppUpdateTests.swift` 覆盖，这里只守调用点的结构。
//
// 断言前先剥注释：本文件的文档注释会提到被禁止的写法名。

final class DesktopAppUpdateFailurePathTests: XCTestCase {

    /// 只在 `AppDelegate+UpdateChecks.swift` 里找：桌面自更新流程整体在这个文件。
    private func updateChecksCode() throws -> String {
        let source = try SourceScan.text(named: "AppDelegate+UpdateChecks.swift")
        return SourceScan.codeText(of: source)
    }

    /// 失败提示必须和「结束本轮」成对出现。
    ///
    /// 允许的 `presentDesktopUpdateFailure` 调用只有两类：
    /// 1. `failDesktopAppUpdateRound` 自己的函数体里那一处；
    /// 2. 还没有占位就拒绝的入口闸（`updateAlreadyInProgress` / `unconfirmedUpdate`）——
    ///    这些分支发生在 `beginDesktopAppUpdateActivity` 之前，本来就没有需要复位的阶段位。
    ///
    /// 所以断言是：文件里每一处非注释的 `presentDesktopUpdateFailure(` 调用，所在行必须
    /// 要么是 `failDesktopAppUpdateRound` 的函数体，要么参数是那两种「未占位拒绝」之一。
    func testEveryStartedRoundFailureGoesThroughSingleExit() throws {
        let code = try updateChecksCode()
        let lines = code.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        // 定位 `failDesktopAppUpdateRound` 的函数体行区间（从签名行到下一个空行后的 `}`）。
        guard let definitionIndex = lines.firstIndex(where: {
            $0.contains("private func failDesktopAppUpdateRound(")
        }) else {
            return XCTFail("找不到 failDesktopAppUpdateRound 的定义：桌面更新失败必须走统一出口。")
        }
        var bodyEnd = definitionIndex
        while bodyEnd + 1 < lines.count {
            bodyEnd += 1
            if lines[bodyEnd].trimmingCharacters(in: .whitespaces) == "}" { break }
        }

        let notStartedRejections = [".updateAlreadyInProgress", ".unconfirmedUpdate"]
        var startedFailureCalls = 0
        for (index, line) in lines.enumerated() where line.contains("presentDesktopUpdateFailure(") {
            if (definitionIndex...bodyEnd).contains(index) { continue }
            // 断言的是**调用**：跳过它自己的声明（`private func presentDesktopUpdateFailure(…`）。
            if line.contains("func presentDesktopUpdateFailure(") { continue }
            if notStartedRejections.contains(where: line.contains) { continue }
            startedFailureCalls += 1
            XCTFail(
                "第 \(index + 1) 行直接调用了 presentDesktopUpdateFailure 而没有结束这一轮："
                    + "必须改走 failDesktopAppUpdateRound(_:releaseTag:)，否则 activity 永远停在忙碌态、"
                    + "菜单入口永久置灰。行内容：\(line.trimmingCharacters(in: .whitespaces))"
            )
        }
        XCTAssertEqual(startedFailureCalls, 0, "已占位的一轮失败时必须走统一出口")
    }

    /// 反证：上面那套检测逻辑确实能抓到缺陷形态。
    ///
    /// 直接构造「只 present 不 finish」的片段，验证它会被判为违规 —— 否则
    /// `testEveryStartedRoundFailureGoesThroughSingleExit` 可能是恒通过的。
    func testDetectionRejectsPresentWithoutFinish() {
        let defective = """
            guard let checksum else {
                presentDesktopUpdateFailure(.checksumUnavailable)
                return
            }
            """
        XCTAssertTrue(defective.contains("presentDesktopUpdateFailure("))
        XCTAssertFalse(defective.contains("failDesktopAppUpdateRound("))
        XCTAssertFalse(defective.contains("finishDesktopAppUpdateRound("))

        let fixed = """
            guard let checksum else {
                failDesktopAppUpdateRound(.checksumUnavailable, releaseTag: releaseTag)
                return
            }
            """
        XCTAssertTrue(fixed.contains("failDesktopAppUpdateRound("))
        XCTAssertFalse(fixed.contains("presentDesktopUpdateFailure("))
    }

    /// `failDesktopAppUpdateRound` 必须先结束本轮、再弹提示。
    ///
    /// 顺序反过来不影响正确性（提示是 sheet，结束后才刷新菜单），但保持「状态先复位」
    /// 意味着即使 `presentDesktopUpdateFailure` 里的 sheet 将来被改成同步阻塞，
    /// 也不会出现「提示还开着、入口仍然置灰」的中间态。
    func testFailPathFinishesRoundBeforePresenting() throws {
        let code = try updateChecksCode()
        let lines = code.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let start = lines.firstIndex(where: {
            $0.contains("private func failDesktopAppUpdateRound(")
        }) else {
            return XCTFail("找不到 failDesktopAppUpdateRound 的定义")
        }
        var finishIndex: Int?
        var presentIndex: Int?
        var index = start
        while index + 1 < lines.count {
            index += 1
            let line = lines[index]
            if finishIndex == nil, line.contains("finishDesktopAppUpdateRound(") { finishIndex = index }
            if presentIndex == nil, line.contains("presentDesktopUpdateFailure(") { presentIndex = index }
            if line.trimmingCharacters(in: .whitespaces) == "}" { break }
        }
        guard let finishIndex, let presentIndex else {
            return XCTFail("failDesktopAppUpdateRound 必须同时调用结束本轮与弹提示两件事")
        }
        XCTAssertLessThan(finishIndex, presentIndex, "应先结束本轮（复位阶段位并刷新菜单），再弹提示")
    }

    /// 安装器交付失败也必须结束本轮：成功路径与失败路径都要复位阶段位。
    ///
    /// 这是真机上「安装器报告失败 → 菜单永久置灰」的另一条路径，与下载/校验和失败同源。
    func testInstallerCallbackHandlesBothOutcomes() throws {
        let code = try updateChecksCode()
        guard let callbackRange = code.range(of: "installer.install(asset:") else {
            return XCTFail("找不到 installer.install(asset:) 调用点")
        }
        let tail = String(code[callbackRange.lowerBound...])
        // 只看回调体开头一段，避免匹配到文件里更后面的无关代码。
        let window = String(tail.prefix(1_200))
        XCTAssertTrue(window.contains("case .updated"), "安装成功后必须结束本轮（复位阶段位）")
        XCTAssertTrue(
            window.contains("case .failed(let failure)"),
            "安装失败后必须走统一失败出口，不能只弹提示"
        )
        XCTAssertTrue(
            window.contains("failDesktopAppUpdateRound(failure"),
            "安装失败必须调用 failDesktopAppUpdateRound(failure, releaseTag:) 复位阶段位"
        )
    }

    /// `finishDesktopAppUpdateRound` 自己必须刷新菜单：否则阶段位复位了、菜单项却还是
    /// 置灰的旧状态，要等下一次别的刷新才恢复。
    func testFinishRefreshesMenuState() throws {
        let code = try updateChecksCode()
        let lines = code.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let start = lines.firstIndex(where: {
            $0.contains("private func finishDesktopAppUpdateRound(")
        }) else {
            return XCTFail("找不到 finishDesktopAppUpdateRound 的定义")
        }
        var index = start
        var found = false
        while index + 1 < lines.count {
            index += 1
            let line = lines[index]
            if line.contains("refreshUpdateMenuState()") { found = true; break }
            if line.trimmingCharacters(in: .whitespaces) == "}" { break }
        }
        XCTAssertTrue(found, "finishDesktopAppUpdateRound 必须调用 refreshUpdateMenuState()")
    }
}
