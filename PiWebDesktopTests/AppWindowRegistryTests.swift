import XCTest

/// 多窗口登记表的无宿主单元测试（GitHub #168）。
///
/// `Sources/App/AppWindowRegistry.swift` 直接编译进测试目标，而且刻意不依赖 AppKit
/// 或 `ServiceManager`：这里用最小的替身类覆盖「新建后可查找到、关闭后移除、最近使用
/// 顺序、启动主窗口（primary）与最近使用相互独立、多窗口并存互不影响」五条契约，
/// 不需要真实窗口、WebView 或服务。
final class AppWindowRegistryTests: XCTestCase {
    /// 替身窗口/控制器：登记表只按对象身份（`===`）识别它们，不需要 AppKit 类型。
    private final class FakeWindow {}
    private final class FakeController {}

    private typealias Registry = AppWindowRegistry<FakeWindow, FakeController>

    // MARK: - 新建后可查找到

    func testEmptyRegistryHasNoMainWindowAndNoControllers() {
        let registry = Registry()

        XCTAssertTrue(registry.isEmpty)
        XCTAssertEqual(registry.count, 0)
        XCTAssertNil(registry.mainWindow)
        XCTAssertNil(registry.mainController)
        XCTAssertNil(registry.primaryWindow)
        XCTAssertNil(registry.primaryController)
        XCTAssertFalse(registry.isPrimaryWindow(FakeWindow()))
        XCTAssertTrue(registry.windows.isEmpty)
        XCTAssertTrue(registry.controllers.isEmpty)
    }

    func testRegisteredWindowIsFindableAsMainWindowAndMainController() {
        var registry = Registry()
        let window = FakeWindow()
        let controller = FakeController()

        registry.register(window: window, controller: controller)

        XCTAssertFalse(registry.isEmpty)
        XCTAssertEqual(registry.count, 1)
        XCTAssertTrue(registry.mainWindow === window)
        XCTAssertTrue(registry.mainController === controller)
        XCTAssertTrue(registry.controller(for: window) === controller)
        XCTAssertTrue(registry.window(for: controller) === window)
        XCTAssertTrue(registry.isMainWindow(window))
        // 登记只决定「最近使用」，启动主窗口（primary）需要显式标记，
        // 由 `AppDelegate.createWindow()` 完成。
        XCTAssertNil(registry.primaryWindow)
        XCTAssertFalse(registry.isPrimaryWindow(window))
    }

    /// 重复登记同一个窗口（例如窗口重建时复用登记路径）只更新记录，不产生第二条。
    func testDuplicateRegistrationOfTheSameWindowKeepsASingleEntry() {
        var registry = Registry()
        let window = FakeWindow()
        let firstController = FakeController()
        let secondController = FakeController()

        registry.register(window: window, controller: firstController)
        registry.register(window: window, controller: secondController)

        XCTAssertEqual(registry.count, 1)
        XCTAssertTrue(registry.mainWindow === window)
        XCTAssertTrue(registry.controller(for: window) === secondController)
        XCTAssertTrue(registry.mainController === secondController)
    }

    /// 查找按对象身份进行：两个内容相同但对象不同的窗口不会互相命中。
    func testLookupIsIdentityBasedAndUnaffectedByOtherRegistrations() {
        var registry = Registry()
        let firstWindow = FakeWindow()
        let secondWindow = FakeWindow()
        let firstController = FakeController()
        let secondController = FakeController()

        registry.register(window: firstWindow, controller: firstController)
        registry.register(window: secondWindow, controller: secondController)

        XCTAssertTrue(registry.controller(for: firstWindow) === firstController)
        XCTAssertTrue(registry.controller(for: secondWindow) === secondController)
        XCTAssertTrue(registry.window(for: firstController) === firstWindow)
        XCTAssertTrue(registry.window(for: secondController) === secondWindow)
        XCTAssertNil(registry.controller(for: FakeWindow()))
        XCTAssertNil(registry.window(for: FakeController()))
    }

    // MARK: - 最近使用窗口（`mainWindow`）的选择

    func testMainWindowFollowsTheMostRecentlyUsedWindow() {
        var registry = Registry()
        let firstWindow = FakeWindow()
        let secondWindow = FakeWindow()
        registry.register(window: firstWindow, controller: FakeController())
        registry.register(window: secondWindow, controller: FakeController())

        XCTAssertTrue(registry.mainWindow === secondWindow)

        XCTAssertTrue(registry.noteUsage(of: firstWindow))

        XCTAssertTrue(registry.mainWindow === firstWindow)
        XCTAssertEqual(registry.count, 2)
    }

    /// `noteUsage` 对未登记的窗口（设置窗口、面板等）不产生任何改变。
    func testNoteUsageOfUnknownWindowIsIgnoredWithoutReordering() {
        var registry = Registry()
        let window = FakeWindow()
        registry.register(window: window, controller: FakeController())

        XCTAssertFalse(registry.noteUsage(of: FakeWindow()))

        XCTAssertEqual(registry.count, 1)
        XCTAssertTrue(registry.mainWindow === window)
    }

    /// 已经是主窗口时重复记使用不改变任何东西（返回 true 表示窗口已登记）。
    func testNoteUsageOfCurrentMainWindowIsIdempotent() {
        var registry = Registry()
        let window = FakeWindow()
        let controller = FakeController()
        registry.register(window: window, controller: controller)

        XCTAssertTrue(registry.noteUsage(of: window))

        XCTAssertEqual(registry.count, 1)
        XCTAssertTrue(registry.mainWindow === window)
        XCTAssertTrue(registry.controller(for: window) === controller)
    }

    // MARK: - 关闭后移除

    func testRemovedWindowIsNoLongerFindable() {
        var registry = Registry()
        let window = FakeWindow()
        let controller = FakeController()
        registry.register(window: window, controller: controller)

        let removedController = registry.remove(window: window)

        XCTAssertTrue(removedController === controller)
        XCTAssertTrue(registry.isEmpty)
        XCTAssertNil(registry.mainWindow)
        XCTAssertNil(registry.controller(for: window))
        XCTAssertNil(registry.window(for: controller))
        XCTAssertFalse(registry.isMainWindow(window))
    }

    /// 移除未知窗口是空操作：返回 nil，不改变现有主窗口与顺序。
    func testRemovingUnknownWindowIsANoOp() {
        var registry = Registry()
        let window = FakeWindow()
        registry.register(window: window, controller: FakeController())

        XCTAssertNil(registry.remove(window: FakeWindow()))
        XCTAssertEqual(registry.count, 1)
        XCTAssertTrue(registry.mainWindow === window)
    }

    /// 最近使用的窗口被移除后由下一个最近使用的窗口接任（`mainWindow` 始终表示
    /// 最近使用，与 primary 无关）。
    func testRemovingMainWindowPromotesTheMostRecentlyUsedRemainingWindow() {
        var registry = Registry()
        let firstWindow = FakeWindow()
        let secondWindow = FakeWindow()
        let thirdWindow = FakeWindow()
        let thirdController = FakeController()
        registry.register(window: firstWindow, controller: FakeController())
        registry.register(window: secondWindow, controller: FakeController())
        registry.register(window: thirdWindow, controller: thirdController)
        // 最近使用顺序：third → first → second。
        XCTAssertTrue(registry.noteUsage(of: firstWindow))

        registry.remove(window: thirdWindow)

        XCTAssertTrue(registry.mainWindow === firstWindow)
        XCTAssertTrue(registry.mainController === registry.controller(for: firstWindow))
        XCTAssertEqual(registry.count, 2)
    }

    // MARK: - 多窗口并存互不影响

    /// 关闭一个非最近使用的窗口只移除它自己：最近使用的窗口、其它窗口与它们的
    /// 控制器都保持原样。
    func testRemovingSecondaryWindowLeavesMainAndOtherWindowsUntouched() {
        var registry = Registry()
        let mainWindow = FakeWindow()
        let mainController = FakeController()
        let secondaryWindow = FakeWindow()
        let secondaryController = FakeController()
        let thirdWindow = FakeWindow()
        let thirdController = FakeController()
        registry.register(window: mainWindow, controller: mainController)
        registry.register(window: secondaryWindow, controller: secondaryController)
        registry.register(window: thirdWindow, controller: thirdController)

        registry.remove(window: secondaryWindow)

        XCTAssertEqual(registry.count, 2)
        XCTAssertTrue(registry.mainWindow === thirdWindow)
        XCTAssertTrue(registry.mainController === thirdController)
        XCTAssertTrue(registry.controller(for: mainWindow) === mainController)
        XCTAssertTrue(registry.controller(for: thirdWindow) === thirdController)
        XCTAssertNil(registry.controller(for: secondaryWindow))
        XCTAssertTrue(registry.isMainWindow(thirdWindow))
        XCTAssertFalse(registry.isMainWindow(mainWindow))
    }

    /// 最近使用优先的快照：批量更新服务地址/重新加载依赖它覆盖到每个窗口。
    func testSnapshotsListWindowsAndControllersInMostRecentlyUsedOrder() {
        var registry = Registry()
        let firstWindow = FakeWindow()
        let secondWindow = FakeWindow()
        let firstController = FakeController()
        let secondController = FakeController()
        registry.register(window: firstWindow, controller: firstController)
        registry.register(window: secondWindow, controller: secondController)

        XCTAssertTrue(registry.windows[0] === secondWindow)
        XCTAssertTrue(registry.windows[1] === firstWindow)
        XCTAssertTrue(registry.controllers[0] === secondController)
        XCTAssertTrue(registry.controllers[1] === firstController)

        registry.noteUsage(of: firstWindow)

        XCTAssertTrue(registry.windows[0] === firstWindow)
        XCTAssertTrue(registry.windows[1] === secondWindow)
        XCTAssertTrue(registry.controllers[0] === firstController)
        XCTAssertTrue(registry.controllers[1] === secondController)
    }

    /// 一个窗口的登记/使用/移除都是局部操作：另一个窗口的查找结果永远不变。
    func testOperationsOnOneWindowNeverChangeAnotherWindowLookup() {
        var registry = Registry()
        let stableWindow = FakeWindow()
        let stableController = FakeController()
        let otherWindow = FakeWindow()
        let newestWindow = FakeWindow()
        registry.register(window: stableWindow, controller: stableController)
        registry.register(window: otherWindow, controller: FakeController())

        XCTAssertTrue(registry.noteUsage(of: otherWindow))
        registry.remove(window: otherWindow)
        registry.register(window: newestWindow, controller: FakeController())

        XCTAssertTrue(registry.controller(for: stableWindow) === stableController)
        XCTAssertTrue(registry.window(for: stableController) === stableWindow)
        XCTAssertTrue(registry.isMainWindow(newestWindow))
        XCTAssertFalse(registry.isMainWindow(stableWindow))
        XCTAssertEqual(registry.count, 2)
    }

    /// 清空登记表（应用收尾）只丢弃引用，不代表停止服务：登记表本身没有任何服务动作。
    func testRemoveAllDropsEveryEntry() {
        var registry = Registry()
        registry.register(window: FakeWindow(), controller: FakeController())
        registry.register(window: FakeWindow(), controller: FakeController())

        registry.removeAll()

        XCTAssertTrue(registry.isEmpty)
        XCTAssertNil(registry.mainWindow)
        XCTAssertNil(registry.mainController)
    }

    // MARK: - 启动主窗口（primary）与最近使用相互独立（GitHub #168 续作）

    /// primary 表示启动主窗口，与最近使用顺序无关：⌘N 之后新窗口成为最近使用，
    /// primary 仍是启动窗口，`isPrimaryWindow` 也只对启动窗口为 true。
    func testPrimaryWindowIsIndependentOfMostRecentlyUsedOrder() {
        var registry = Registry()
        let primaryWindow = FakeWindow()
        let primaryController = FakeController()
        let newWindow = FakeWindow()
        let newController = FakeController()
        registry.register(window: primaryWindow, controller: primaryController)
        XCTAssertTrue(registry.markPrimary(window: primaryWindow))

        registry.register(window: newWindow, controller: newController)

        XCTAssertTrue(registry.primaryWindow === primaryWindow)
        XCTAssertTrue(registry.primaryController === primaryController)
        XCTAssertTrue(registry.isPrimaryWindow(primaryWindow))
        XCTAssertFalse(registry.isPrimaryWindow(newWindow))
        // 最近使用顺序独立变化：新窗口在最前，primary 没有跟着变。
        XCTAssertTrue(registry.mainWindow === newWindow)
        XCTAssertTrue(registry.mainController === newController)
    }

    /// 未登记的窗口（设置窗口、面板等）不能被标记为 primary，也不产生任何记录。
    func testMarkingUnregisteredWindowAsPrimaryIsANoOp() {
        var registry = Registry()
        let window = FakeWindow()
        registry.register(window: window, controller: FakeController())

        XCTAssertFalse(registry.markPrimary(window: FakeWindow()))

        XCTAssertNil(registry.primaryWindow)
        XCTAssertFalse(registry.isPrimaryWindow(window))
        XCTAssertEqual(registry.count, 1)
    }

    /// 关闭非 primary 窗口（⌘N 打开的新窗口）只移除它自己：primary 与其它窗口
    /// 的查找结果都保持不变。
    func testRemovingNonPrimaryWindowKeepsPrimaryAndOtherWindows() {
        var registry = Registry()
        let primaryWindow = FakeWindow()
        let primaryController = FakeController()
        let secondaryWindow = FakeWindow()
        let secondaryController = FakeController()
        let thirdWindow = FakeWindow()
        let thirdController = FakeController()
        registry.register(window: primaryWindow, controller: primaryController)
        registry.markPrimary(window: primaryWindow)
        registry.register(window: secondaryWindow, controller: secondaryController)
        registry.register(window: thirdWindow, controller: thirdController)

        XCTAssertTrue(registry.remove(window: secondaryWindow) === secondaryController)

        XCTAssertTrue(registry.primaryWindow === primaryWindow)
        XCTAssertTrue(registry.primaryController === primaryController)
        XCTAssertTrue(registry.isPrimaryWindow(primaryWindow))
        XCTAssertEqual(registry.count, 2)
        XCTAssertNil(registry.controller(for: secondaryWindow))
        XCTAssertNil(registry.window(for: secondaryController))
        XCTAssertTrue(registry.controller(for: primaryWindow) === primaryController)
        XCTAssertTrue(registry.controller(for: thirdWindow) === thirdController)
        XCTAssertFalse(registry.isPrimaryWindow(thirdWindow))
    }

    /// primary 被真正关闭（模拟）：`primaryWindow` 变 nil，剩余窗口的最近使用顺序
    /// 与它们的控制器完全不受影响。
    func testRemovingPrimaryWindowClearsPrimaryAndKeepsRecencyOrder() {
        var registry = Registry()
        let primaryWindow = FakeWindow()
        let primaryController = FakeController()
        let secondWindow = FakeWindow()
        let secondController = FakeController()
        let thirdWindow = FakeWindow()
        let thirdController = FakeController()
        registry.register(window: primaryWindow, controller: primaryController)
        registry.markPrimary(window: primaryWindow)
        registry.register(window: secondWindow, controller: secondController)
        registry.register(window: thirdWindow, controller: thirdController)
        // 最近使用顺序：third → second → primary。
        XCTAssertTrue(registry.noteUsage(of: secondWindow))
        XCTAssertTrue(registry.noteUsage(of: primaryWindow))

        XCTAssertTrue(registry.remove(window: primaryWindow) === primaryController)

        XCTAssertNil(registry.primaryWindow)
        XCTAssertNil(registry.primaryController)
        XCTAssertFalse(registry.isPrimaryWindow(primaryWindow))
        XCTAssertEqual(registry.count, 2)
        XCTAssertTrue(registry.windows[0] === secondWindow)
        XCTAssertTrue(registry.windows[1] === thirdWindow)
        XCTAssertTrue(registry.mainWindow === secondWindow)
        XCTAssertTrue(registry.mainController === secondController)
        XCTAssertTrue(registry.controller(for: secondWindow) === secondController)
        XCTAssertTrue(registry.controller(for: thirdWindow) === thirdController)
    }

    /// 记使用（最近使用顺序更新）永远不改变 primary，即使成为 key 窗口的不是 primary。
    func testNoteUsageNeverChangesPrimary() {
        var registry = Registry()
        let primaryWindow = FakeWindow()
        let otherWindow = FakeWindow()
        registry.register(window: primaryWindow, controller: FakeController())
        registry.markPrimary(window: primaryWindow)
        registry.register(window: otherWindow, controller: FakeController())

        XCTAssertTrue(registry.noteUsage(of: otherWindow))

        XCTAssertTrue(registry.primaryWindow === primaryWindow)
        XCTAssertTrue(registry.isPrimaryWindow(primaryWindow))
        XCTAssertTrue(registry.mainWindow === otherWindow)

        XCTAssertTrue(registry.noteUsage(of: primaryWindow))

        XCTAssertTrue(registry.primaryWindow === primaryWindow)
        XCTAssertTrue(registry.isPrimaryWindow(primaryWindow))
        XCTAssertTrue(registry.mainWindow === primaryWindow)
    }

    /// 已有 primary 时再标记另一个窗口（primary 缺失后补建启动窗口的防御路径）：
    /// primary 被替换，同一时刻只有一个 primary。
    func testMarkingAnotherWindowAsPrimaryReplacesThePreviousPrimary() {
        var registry = Registry()
        let firstPrimary = FakeWindow()
        let secondPrimary = FakeWindow()
        let secondController = FakeController()
        registry.register(window: firstPrimary, controller: FakeController())
        registry.markPrimary(window: firstPrimary)
        registry.register(window: secondPrimary, controller: secondController)

        XCTAssertTrue(registry.markPrimary(window: secondPrimary))

        XCTAssertTrue(registry.primaryWindow === secondPrimary)
        XCTAssertTrue(registry.primaryController === secondController)
        XCTAssertFalse(registry.isPrimaryWindow(firstPrimary))
        XCTAssertEqual(registry.count, 2)
    }

    /// 重复登记 primary（同一窗口换控制器）时 primary 身份不变、控制器跟随更新；
    /// 重复登记不会产生第二条记录。
    func testReRegisteringPrimaryKeepsPrimaryIdentityWithLatestController() {
        var registry = Registry()
        let primaryWindow = FakeWindow()
        registry.register(window: primaryWindow, controller: FakeController())
        registry.markPrimary(window: primaryWindow)
        let replacementController = FakeController()

        registry.register(window: primaryWindow, controller: replacementController)

        XCTAssertEqual(registry.count, 1)
        XCTAssertTrue(registry.isPrimaryWindow(primaryWindow))
        XCTAssertTrue(registry.primaryController === replacementController)
        XCTAssertTrue(registry.mainController === replacementController)
    }

    /// 应用收尾清空登记表时 primary 一并清除。
    func testRemoveAllClearsPrimary() {
        var registry = Registry()
        let primaryWindow = FakeWindow()
        registry.register(window: primaryWindow, controller: FakeController())
        registry.markPrimary(window: primaryWindow)
        registry.register(window: FakeWindow(), controller: FakeController())

        registry.removeAll()

        XCTAssertTrue(registry.isEmpty)
        XCTAssertNil(registry.primaryWindow)
        XCTAssertNil(registry.primaryController)
        XCTAssertFalse(registry.isPrimaryWindow(primaryWindow))
    }
}
