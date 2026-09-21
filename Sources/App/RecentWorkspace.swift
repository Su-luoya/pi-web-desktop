import Foundation

/// UserDefaults-backed list of recently used workspace directories.
///
/// Paths are normalized to standard absolute paths, kept most-recent-first,
/// de-duplicated, and capped so the Service menu stays small.

/// Recently used workspace directories plus the pure workspace switch decision.

struct RecentWorkspaceStore {
    static let maximumCount = 10
    static let storageKey = "workspace.recentPaths"

    /// 归一化后允许的最长路径（UTF-8 字节）。macOS 的 PATH_MAX 是 1024 字节
    /// （含结尾 NUL），超过它的路径无法被打开或写入菜单，也没有任何合法用途，
    /// 因此这里按同一个上限提前拒绝（GitHub #135 F4）。
    static let maximumPathLength = 1024

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> [String] {
        normalizedPaths(defaults.stringArray(forKey: Self.storageKey) ?? [])
    }

    @discardableResult
    func record(path: String) -> [String] {
        let updated = normalizedPaths([path] + load())
        defaults.set(updated, forKey: Self.storageKey)
        return updated
    }

    func clear() {
        defaults.removeObject(forKey: Self.storageKey)
    }

    private func normalizedPaths(_ paths: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for path in paths {
            guard let normalized = Self.normalizedPath(path), seen.insert(normalized).inserted else { continue }
            result.append(normalized)
            if result.count == Self.maximumCount { break }
        }
        return result
    }

    /// 归一化一个工作目录路径：失败返回 nil，调用方丢弃它。
    ///
    /// GitHub #135 F4：这些值只进 UserDefaults、菜单标题和 `NSWorkspace.open`，
    /// 不是安全边界，所以只要把输入收紧到“一定是可用的绝对目录路径”即可，
    /// 不引入新的存储结构：
    /// - 去掉首尾空白后为空、或含控制字符（菜单里不可见/可注入换行）→ 拒绝；
    /// - 展开 `~`（`~/work`、`~user/work`），否则会得到一个字面目录名叫 `~` 的路径；
    /// - 相对路径与根目录 `/`（含 `/..`）→ 拒绝：根目录不是工作目录，
    ///   选中它等于让 pi-web 往 `/` 写运行文件；
    /// - 解析符号链接并标准化（`..`、多余斜杠、结尾斜杠），使同一目录只有一种
    ///   存储形式，菜单去重与“当前目录”比较才能命中；
    /// - 超过 `maximumPathLength` 的最终路径 → 拒绝。
    static func normalizedPath(_ path: String) -> String? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else { return nil }
        let expanded = (trimmed as NSString).expandingTildeInPath
        guard (expanded as NSString).isAbsolutePath else { return nil }
        let resolved = URL(fileURLWithPath: expanded, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
        guard resolved != "/", resolved.utf8.count <= maximumPathLength else { return nil }
        return resolved
    }
}

/// Pure decision used by every workspace switch entry point.
enum WorkspaceSwitchDecision: Equatable {
    case unchanged
    case reject(WorkspaceDirectoryValidation)
    case confirm(path: String)

    static func decide(
        requestedPath: String,
        currentPath: String,
        probe: WorkspaceDirectoryProbe
    ) -> WorkspaceSwitchDecision {
        guard let requested = RecentWorkspaceStore.normalizedPath(requestedPath),
              (requestedPath.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).isAbsolutePath else {
            return .reject(.unusable(problem: .missing, path: requestedPath))
        }
        if requested == RecentWorkspaceStore.normalizedPath(currentPath) {
            return .unchanged
        }
        let validation = WorkspaceDirectory.validate(path: requested, probe: probe)
        guard validation.isUsable else { return .reject(validation) }
        return .confirm(path: requested)
    }
}
