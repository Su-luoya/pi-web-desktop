import Foundation

/// npm / pi 由 env 查找 node：优先使用命令所在目录，只传运行所需的非空键。
enum UpdateCommandEnvironment {
    private static let allowedKeys: Set<String> = ["PATH", "HOME", "TMPDIR", "LANG", "LC_ALL", "LC_CTYPE"]

    static func make(base: [String: String], executablePath: String) -> [String: String] {
        var environment = base.filter { allowedKeys.contains($0.key) && !$0.value.isEmpty }
        let builder = ToolPathBuilder(appEnvironment: environment, homeDirectory: environment["HOME"] ?? "")
        environment["PATH"] = builder.path(prioritizing: [(executablePath as NSString).deletingLastPathComponent])
        return environment
    }

    /// 日志只显示键名，不显示值。
    static func keyDescription(_ environment: [String: String]) -> String {
        environment.keys.sorted().joined(separator: ", ")
    }
}
