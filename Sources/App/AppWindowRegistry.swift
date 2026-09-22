/// Window-to-WebView registration for multi-window browsing (GitHub #168).

import Foundation

/// 多窗口登记表（GitHub #168）：维护「窗口 ↔ WebView 控制器」的对应关系、启动主窗口
/// 标识与最近使用顺序。
///
/// 这里刻意不 import AppKit、也不触碰 `ServiceManager`：登记表只回答「哪个窗口
/// 对应哪个控制器」「谁是启动主窗口（primary）」「谁是最近使用的窗口」「关掉一个
/// 窗口之后剩下什么」这几个问题，因此可以在无宿主（unhosted）的单元测试里用替身
/// 对象覆盖。开窗、关窗与服务生命周期完全无关：服务只由共享的 `ServiceManager`
/// 管理，这里不会启动、停止或重启任何东西。
///
/// 两个相互独立的角色（不要混用）：
/// - **启动主窗口（primary）**：`createWindow()` 创建的启动窗口。只有**真正关闭**
///   （`remove(window:)`）才会被清除；因为 `windowShouldClose` 对 primary 只隐藏
///   不关闭（GitHub #158 语义），正常运行时它一直存在。Dock 恢复、「显示 Pi Web」
///   与关闭语义都以 `primaryWindow` 为准。
/// - **最近使用的窗口（most recently used）**：`register` 与 `noteUsage(of:)` 都把
///   窗口放到列表最前面；`mainWindow`/`mainController` 始终表示**最近使用**的窗口，
///   而不是 primary，也不是「启动窗口」。菜单/页面动作在没有 key window 时回落到
///   它。最近使用顺序的变化不会改变 primary。
///
/// 其余契约：
/// - **关闭即移除**：窗口真正关闭时调用 `remove(window:)`；被移除的如果是 primary，
///   `primaryWindow` 回到 nil（下一次 `showMainWindow()` 补建窗口并登记新的 primary）；
///   被移除的如果是最近使用窗口，`mainWindow` 由下一个最近使用窗口接任。
/// - **互不影响**：一个窗口的登记/使用/移除都不会改变其它窗口与它们的控制器。
struct AppWindowRegistry<Window: AnyObject, Controller: AnyObject> {
    private struct Entry {
        let window: Window
        let controller: Controller
    }

    /// 最近使用在最前。
    private var entries: [Entry] = []
    /// 启动主窗口（primary）：与最近使用顺序相互独立，只有真正关闭才清除。
    private var primaryEntry: Entry?

    var isEmpty: Bool { entries.isEmpty }

    var count: Int { entries.count }

    /// 最近使用的窗口。**不是**启动主窗口：它只用于菜单/页面动作的默认目标窗口，
    /// 以及「回落到最近使用」的场景；启动主窗口见 `primaryWindow`。
    var mainWindow: Window? { entries.first?.window }

    /// 最近使用窗口对应的 WebView 控制器。
    var mainController: Controller? { entries.first?.controller }

    /// 启动主窗口（primary）。Dock 恢复、「显示 Pi Web」与 `windowShouldClose` 的
    /// 隐藏语义都以它为准；只有真正关闭才会被清除。
    var primaryWindow: Window? { primaryEntry?.window }

    /// 启动主窗口对应的 WebView 控制器。
    var primaryController: Controller? { primaryEntry?.controller }

    /// 最近使用优先的窗口快照（最近使用在最前）。
    var windows: [Window] { entries.map(\.window) }

    /// 最近使用优先的控制器快照（最近使用在最前）；批量更新服务地址/重新加载时用。
    var controllers: [Controller] { entries.map(\.controller) }

    /// 窗口对应的控制器；未登记返回 nil。
    func controller(for window: Window) -> Controller? {
        entries.first { $0.window === window }?.controller
    }

    /// 控制器对应的窗口；未登记返回 nil。
    func window(for controller: Controller) -> Window? {
        entries.first { $0.controller === controller }?.window
    }

    /// 是否是最近使用的窗口（与 `mainWindow` 的身份比较）。
    func isMainWindow(_ window: Window) -> Bool {
        guard let mainWindow else { return false }
        return mainWindow === window
    }

    /// 是否是启动主窗口（`windowShouldClose` 靠它区分「只隐藏」与「真正关闭」）。
    func isPrimaryWindow(_ window: Window) -> Bool {
        guard let primaryWindow else { return false }
        return primaryWindow === window
    }

    /// 登记新窗口并把它记为最近使用。重复登记同一个窗口只更新控制器与顺序，
    /// 不会产生两条记录；若该窗口是 primary，primary 的控制器一并更新。
    mutating func register(window: Window, controller: Controller) {
        entries.removeAll { $0.window === window }
        entries.insert(Entry(window: window, controller: controller), at: 0)
        if primaryEntry?.window === window {
            primaryEntry = Entry(window: window, controller: controller)
        }
    }

    /// 把**已登记**的窗口标记为启动主窗口（`createWindow()` 的启动路径用）。
    /// 已有 primary 时被替换（同一时刻只有一个 primary）；窗口未登记则不改变任何
    /// 状态并返回 false。
    @discardableResult
    mutating func markPrimary(window: Window) -> Bool {
        guard let entry = entries.first(where: { $0.window === window }) else { return false }
        primaryEntry = entry
        return true
    }

    /// 窗口成为 key 窗口：移到最近使用位置。返回它是否已登记；未登记时不做任何
    /// 改变（例如设置窗口、面板或临时窗口不进入登记表）。**不改变 primary**。
    @discardableResult
    mutating func noteUsage(of window: Window) -> Bool {
        guard let index = entries.firstIndex(where: { $0.window === window }) else { return false }
        guard index != 0 else { return true }
        let entry = entries.remove(at: index)
        entries.insert(entry, at: 0)
        return true
    }

    /// 窗口真正关闭后移除，并返回它的控制器（调用方可据此做收尾）。未登记返回 nil。
    /// 被移除的如果是 primary，`primaryWindow` 回到 nil；其它窗口与它们的顺序不变。
    @discardableResult
    mutating func remove(window: Window) -> Controller? {
        guard let index = entries.firstIndex(where: { $0.window === window }) else { return nil }
        let entry = entries.remove(at: index)
        if primaryEntry?.window === window {
            primaryEntry = nil
        }
        return entry.controller
    }

    /// 清空登记表（应用收尾用；不触发任何服务动作）。primary 一并清除。
    mutating func removeAll() {
        entries.removeAll()
        primaryEntry = nil
    }
}
