import Foundation

/// UserDefaults-backed list of recently used workspace directories.
///
/// Paths are normalized to standard absolute paths, kept most-recent-first,
/// de-duplicated, and capped so the Service menu stays small.
struct RecentWorkspaceStore {
    static let maximumCount = 10
    static let storageKey = "workspace.recentPaths"

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

    static func normalizedPath(_ path: String) -> String? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return URL(fileURLWithPath: trimmed, isDirectory: true).standardizedFileURL.path
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
