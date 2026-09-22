/// Window-to-WebView registration for multi-window browsing (GitHub #168).

import Foundation

/// 多窗口登记表（GitHub #168）：维护「窗口 ↔ WebView 控制器」的对应关系与最近
/// 使用顺序。
///
/// 这里刻意不 import AppKit、也不触碰 `ServiceManager`：登记表只回答「哪个窗口
/// 对应哪个控制器」「谁是最近使用的窗口」「关掉一个窗口之后剩下什么」这三个问题，
/// 因此可以在无宿主（unhosted）的单元测试里用替身对象覆盖。开窗、关窗与服务
/// 生命周期完全无关：服务只由共享的 `ServiceManager` 管理，这里不会启动、停止
/// 或重启任何东西。
///
/// 语义：
/// - **最近使用优先**：`register` 与 `noteUsage(of:)` 都把窗口放到列表最前面；
///   `mainWindow` 始终是最近使用的那个窗口，Dock 点击与「显示 Pi Web」恢复的就是它。
/// - **关闭即移除**：窗口真正关闭时调用 `remove(window:)`；被移除的如果是主窗口，
///   由剩下的最近使用窗口接任，列表清空后 `mainWindow` 回到 nil，下一次
///   `showMainWindow()` 会补建窗口。
/// - **互不影响**：一个窗口的登记/使用/移除都不会改变其它窗口与它们的控制器。
struct AppWindowRegistry<Window: AnyObject, Controller: AnyObject> {
    private struct Entry {
        let window: Window
        let controller: Controller
    }

    /// 最近使用在最前。
    private var entries: [Entry] = []

    var isEmpty: Bool { entries.isEmpty }

    var count: Int { entries.count }

    /// 最近使用的窗口（主窗口语义：Dock 恢复、菜单动作的默认目标）。
    var mainWindow: Window? { entries.first?.window }

    /// 主窗口对应的 WebView 控制器。
    var mainController: Controller? { entries.first?.controller }

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

    /// 是否是当前主窗口（`windowShouldClose` 靠它区分「只隐藏」与「真正关闭」）。
    func isMainWindow(_ window: Window) -> Bool {
        guard let mainWindow else { return false }
        return mainWindow === window
    }

    /// 登记新窗口并把它记为最近使用。重复登记同一个窗口只更新控制器与顺序，
    /// 不会产生两条记录。
    mutating func register(window: Window, controller: Controller) {
        entries.removeAll { $0.window === window }
        entries.insert(Entry(window: window, controller: controller), at: 0)
    }

    /// 窗口成为 key 窗口：移到最近使用位置。返回它是否已登记；未登记时不做任何
    /// 改变（例如设置窗口、面板或临时窗口不进入登记表）。
    @discardableResult
    mutating func noteUsage(of window: Window) -> Bool {
        guard let index = entries.firstIndex(where: { $0.window === window }) else { return false }
        guard index != 0 else { return true }
        let entry = entries.remove(at: index)
        entries.insert(entry, at: 0)
        return true
    }

    /// 窗口真正关闭后移除，并返回它的控制器（调用方可据此做收尾）。未登记返回 nil。
    @discardableResult
    mutating func remove(window: Window) -> Controller? {
        guard let index = entries.firstIndex(where: { $0.window === window }) else { return nil }
        return entries.remove(at: index).controller
    }

    /// 清空登记表（应用收尾用；不触发任何服务动作）。
    mutating func removeAll() {
        entries.removeAll()
    }
}
