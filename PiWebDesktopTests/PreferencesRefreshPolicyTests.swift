import XCTest

/// outD-3：设置窗口可见时被外部配置改动追上。
///
/// 修复前 `showPreferences` 只在窗口**不可见**时调 `update(configuration:)`；
/// 打开的窗口在菜单切换监听地址/工作目录后仍持有旧快照，用户随后点“保存”
/// 会把旧配置写回并重启服务。修复后外部写入路径立即调
/// `refreshIfUnedited(configuration:)`：用户没编辑过就刷新控件，编辑过则保留输入。
final class PreferencesRefreshPolicyTests: XCTestCase {
    private let baseline = [
        "/usr/local/bin/pi-web",
        "",
        "127.0.0.1",
        "30141",
        "",
        "",
        "",
        "",
        "1",
        "0"
    ]

    func testUneditedWindowIsReloaded() {
        // 控件值仍等于上次同步进控件的快照 → 没有任何用户输入需要保护。
        XCTAssertTrue(PreferencesRefreshPolicy.shouldReload(currentValues: baseline, loadedValues: baseline))
    }

    func testEditedWindowKeepsUserInput() {
        var edited = baseline
        edited[2] = "100.64.0.7" // 用户正在把监听地址改成 VPN 地址，还没保存
        XCTAssertFalse(
            PreferencesRefreshPolicy.shouldReload(currentValues: edited, loadedValues: baseline),
            "有未保存编辑时刷新控件会抹掉用户输入"
        )
    }

    func testAnySingleFieldEditBlocksReload() {
        // 逐字段覆盖：任何一个可编辑字段被改动都必须拦住刷新。
        for index in baseline.indices {
            var edited = baseline
            edited[index] = baseline[index] + "-changed"
            XCTAssertFalse(
                PreferencesRefreshPolicy.shouldReload(currentValues: edited, loadedValues: baseline),
                "第 \(index) 个字段被编辑时不应刷新"
            )
        }
    }

    func testFieldCountMismatchIsTreatedAsEdited() {
        // 快照长度不同（字段被增删）时不能判定为“未编辑”：那样会静默刷新。
        XCTAssertFalse(
            PreferencesRefreshPolicy.shouldReload(currentValues: baseline + [""], loadedValues: baseline)
        )
        XCTAssertFalse(
            PreferencesRefreshPolicy.shouldReload(currentValues: baseline, loadedValues: Array(baseline.dropLast()))
        )
    }

    // MARK: - 接线（源码级：PreferencesWindowController 不在测试 target 内）

    /// 外部写入路径必须主动追平可见窗口，而不是等用户重新打开设置。
    func testApplyPreferencesConfigurationRefreshesOpenPreferencesWindow() throws {
        let source = SourceScan.codeText(of: try SourceScan.text(named: "AppDelegate+Service.swift"))
        XCTAssertTrue(
            source.contains("preferencesWindowStore.stored?.refreshIfUnedited(configuration: newConfiguration)"),
            "applyPreferencesConfiguration 必须先追平打开的设置窗口"
        )
        // 追平必须发生在写盘之后（写盘之后配置才算生效）。
        let save = try XCTUnwrap(source.range(of: "appConfiguration.save(newConfiguration)"))
        let refresh = try XCTUnwrap(source.range(of: "refreshIfUnedited(configuration: newConfiguration)"))
        XCTAssertLessThan(
            source.distance(from: source.startIndex, to: save.lowerBound),
            source.distance(from: source.startIndex, to: refresh.lowerBound)
        )
    }

    /// 窗口可见时不得再整体重置控件（那会抹掉未保存输入）。
    func testShowPreferencesOnlyFullyReloadsWhenHidden() throws {
        let source = SourceScan.codeText(of: try SourceScan.text(named: "AppDelegate+Service.swift"))
        let show = try XCTUnwrap(source.range(of: "func showPreferences("))
        let body = String(source[show.lowerBound...].prefix(900))
        XCTAssertTrue(body.contains("if controller.window?.isVisible != true {"), "不可见时才整体重置")
        XCTAssertTrue(body.contains("controller.refreshIfUnedited(configuration:"), "可见时必须走 diff 刷新")
    }

    /// 控制器侧：`refreshIfUnedited` 的返回语义与快照计算必须来自同一份配置。
    func testControllerWiresRefreshPolicyToControlSnapshot() throws {
        let source = SourceScan.codeText(of: try SourceScan.text(named: "PreferencesWindowController.swift"))
        XCTAssertTrue(source.contains("PreferencesRefreshPolicy.shouldReload("))
        XCTAssertTrue(source.contains("currentValues: controlValues()"))
        XCTAssertTrue(source.contains("loadedValues: loadedControlValues"))
        // 未编辑分支里不能调 `loadValues()`：那正是会覆盖用户输入的调用。
        let refresh = try XCTUnwrap(source.range(of: "func refreshIfUnedited("))
        let body = String(source[refresh.lowerBound...].prefix(700))
        XCTAssertFalse(body.contains("loadValues()"))
        // 工作目录的“留空 = 默认目录”必须两边都是空串，否则空字段会被误判为编辑过。
        XCTAssertTrue(source.contains("configuration.workspacePath,\n"), "快照必须直接用 workspacePath，不能规范化成默认目录")
    }
}
