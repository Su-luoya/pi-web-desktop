import XCTest

/// App 层菜单与声明卫生（outD-6 / outD-次要 1–3）。
///
/// `AppDelegate` 及其扩展刻意不编译进测试目标（需要真实 `NSApplication` 与服务
/// 管理器），因此这些契约用源码级断言固定：它们都是“某个声明/绑定只能存在一次、
/// 必须成规模覆盖”这类结构性质，源码断言能精确表达，且不依赖运行 App。
final class AppMenuHygieneTests: XCTestCase {
    // MARK: - outD-6：⌃⌘F 只能有一个绑定点

    func testFullScreenShortcutIsBoundExactlyOnce() throws {
        let source = SourceScan.codeText(of: try SourceScan.text(named: "AppDelegate+Menus.swift"))
        // 菜单里 `keyEquivalent: "f"` 的每一项都要看修饰键：显示菜单与窗口菜单
        // 同时绑 ⌃⌘F 时，系统只会让其中一个响应（另一个看起来“失效”）。
        var controlCommandFullScreen: [String] = []
        for line in source.split(separator: "\n", omittingEmptySubsequences: false) {
            guard line.contains("keyEquivalent: \"f\""), line.contains("toggleFullScreen") else { continue }
            controlCommandFullScreen.append(String(line))
        }
        XCTAssertEqual(
            controlCommandFullScreen.count,
            1,
            "只允许一个菜单项带 ⌃⌘F：\(controlCommandFullScreen)"
        )
        // 唯一绑定必须真的是 ⌃⌘F（否则快捷键整体丢失）。
        XCTAssertTrue(source.contains("windowFullScreenItem.keyEquivalentModifierMask = [.command, .control]"))
        // 另一个全屏幕菜单项必须不带快捷键。
        let viewMenuFullScreen = try XCTUnwrap(
            source.split(separator: "\n").first { $0.contains("\"进入全屏幕\"") }.map(String.init)
        )
        XCTAssertTrue(viewMenuFullScreen.contains("keyEquivalent: \"\""), viewMenuFullScreen)
    }

    // MARK: - outD-次要-1：正式声明 NSMenuItemValidation

    func testAppDelegateFormallyConformsToMenuItemValidation() throws {
        let source = SourceScan.codeText(of: try SourceScan.text(named: "AppDelegate.swift"))
        XCTAssertTrue(
            source.contains("NSMenuItemValidation"),
            "`validateMenuItem` 依赖非正式协议生效太脆弱：应声明 NSMenuItemValidation"
        )
        // 声明与实现必须成对存在。
        XCTAssertTrue(source.contains("func validateMenuItem("))
    }

    // MARK: - outD-次要-2：重建菜单前清空所有缓存引用

    func testMenuRebuildClearsEveryCachedMenuItem() throws {
        let appDelegate = SourceScan.codeText(of: try SourceScan.text(named: "AppDelegate.swift"))
        let menus = SourceScan.codeText(of: try SourceScan.text(named: "AppDelegate+Menus.swift"))

        // 从 AppDelegate 里收集所有“缓存的菜单项/子菜单”属性名。
        let cached = try cachedMenuReferenceNames(in: appDelegate)
        XCTAssertFalse(cached.isEmpty, "应能识别出菜单缓存属性")

        // 清空函数体内必须逐个安排到 nil / removeAll。
        let reset = try XCTUnwrap(
            menus.range(of: "private func resetCachedMenuReferences()"),
            "应当有统一的菜单引用清空函数"
        )
        let resetBody = String(menus[reset.upperBound...].prefix(1800))
        for name in cached {
            let cleared = resetBody.contains("\(name) = nil") || resetBody.contains("\(name).removeAll()")
            XCTAssertTrue(cleared, "菜单重建会换掉整棵 NSMenu 树，`\(name)` 必须被清空")
        }

        // 重建入口必须调用它（而不是各清各的）。
        let install = try XCTUnwrap(menus.range(of: "func installMainMenu()"))
        let installBody = String(menus[install.upperBound...].prefix(600))
        XCTAssertTrue(
            installBody.contains("resetCachedMenuReferences()"),
            "installMainMenu 必须先清空全部缓存引用"
        )
        // 旧写法（只清两个数组）已被统一入口取代。
        XCTAssertFalse(
            installBody.contains("serviceControlMenuItems.removeAll()"),
            "不应在 installMainMenu 内散落清理：集中到 resetCachedMenuReferences"
        )
    }

    /// 找出 `var xxx: NSMenuItem?` / `var xxx: NSMenu?` / `var xxx: [NSMenuItem]` /
    /// `var xxx: [NSMenu]` / `var xxx: [UpdateCheckCategory: NSMenuItem]` 这类缓存属性名。
    /// 只按“类型里出现 NSMenuItem/NSMenu”判定：`notifiedVersions: [UpdateCheckTarget: String]`
    /// 那种普通状态字典不是菜单引用，不应参与清空。
    private func cachedMenuReferenceNames(in source: String) throws -> [String] {
        let pattern = #"var\s+([A-Za-z_][A-Za-z0-9_]*)\s*:\s*([^=\n]+)"#
        let regex = try NSRegularExpression(pattern: pattern)
        let range = NSRange(source.startIndex..<source.endIndex, in: source)
        return regex.matches(in: source, range: range).compactMap { match in
            guard
                let nameRange = Range(match.range(at: 1), in: source),
                let typeRange = Range(match.range(at: 2), in: source)
            else { return nil }
            let type = source[typeRange]
            guard type.contains("NSMenuItem") || type.contains("NSMenu") else { return nil }
            return String(source[nameRange])
        }
    }

    // MARK: - outD-次要-3：不得再有 IUO 强解包窗口

    func testPreferencesPanelsNeverForceUnwrapTheWindow() throws {
        let source = SourceScan.codeText(of: try SourceScan.text(named: "PreferencesWindowController.swift"))
        XCTAssertFalse(
            source.contains("window!"),
            "`window!` 会在窗口缺失时直接崩溃：用 guard 后跳过面板"
        )
        // 两个打开面板都必须走同一个守卫入口。
        XCTAssertEqual(
            source.components(separatedBy: "sheetParentWindow()").count - 1,
            3,
            "sheetParentWindow() 应有一处定义 + 两处调用"
        )
    }

    // MARK: - outD-次要-4：onCancel 死代码已删除

    func testPreferencesControllerHasNoUnwiredCancelHook() throws {
        let source = SourceScan.codeText(of: try SourceScan.text(named: "PreferencesWindowController.swift"))
        XCTAssertFalse(source.contains("onCancel"), "`onCancel` 从未被赋值：删除而不是留着死钩子")
        // 取消按钮本身必须仍在（只是不再走那个钩子）。
        XCTAssertTrue(source.contains("NSButton(title: \"取消\""))
    }

    // MARK: - outD-次要-5：健康探测复用同一个 URLSession

    func testServiceProbeReusesASingleSession() throws {
        let source = SourceScan.codeText(of: try SourceScan.text(named: "ServiceScheduling.swift"))
        XCTAssertFalse(
            source.contains("finishTasksAndInvalidate"),
            "每次探测都新建并销毁会话是浪费：URLSession 本就为复用设计"
        )
        XCTAssertFalse(source.contains("let session = URLSession("), "会话应在 init 里建一次")
        XCTAssertTrue(source.contains("self.session = URLSession(configuration: sessionConfiguration)"))
        // 逐请求超时仍由 URLRequest 指定（会话级超时留默认，避免截短调用方超时）。
        XCTAssertTrue(source.contains("request.timeoutInterval = timeout"))
        XCTAssertFalse(source.contains("sessionConfiguration.timeoutIntervalForRequest = timeout"))
        // GitHub #157 的“强制直连”不能因为复用而丢失。
        XCTAssertTrue(source.contains("sessionConfiguration.connectionProxyDictionary = [:]"))
    }
}
