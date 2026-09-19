import Foundation

/// 工作目录不可用的原因（GitHub #9）。
///
/// 不可用的工作目录必须阻止服务启动：pi-web 会在工作目录里写入运行文件，
/// 目录不存在或不可写时启动只会得到难以理解的失败。应用把这种情况呈现为
/// 诊断状态（复用 #6/#7 的诊断页）并给出可读的修复提示。
enum WorkspaceDirectoryProblem: Equatable {
    /// 目录不存在。
    case missing
    /// 路径存在但不是目录（例如同名文件）。
    case notDirectory
    /// 存在但当前用户没有写权限。
    case notWritable

    /// 诊断项状态词。
    var title: String {
        switch self {
        case .missing: return "不存在"
        case .notDirectory: return "不是目录"
        case .notWritable: return "不可写"
        }
    }

    /// 状态页/诊断窗口里的可读修复提示。
    ///
    /// `isDefaultLocation` 区分应用默认工作目录与用户自选目录：默认目录缺失时
    /// 应用会尝试重新创建，提示因此先指向“重新检测/改选目录”。
    func message(path: String, isDefaultLocation: Bool) -> String {
        let location = isDefaultLocation ? "默认工作目录" : "工作目录"
        let nextStep = "修复后点击“重新检测”，或在菜单“设置…”里改选一个可写目录。"
        switch self {
        case .missing:
            let creationHint = isDefaultLocation
                ? "应用会尝试创建它；"
                : "自选目录不会被自动创建，请先手动创建；"
            return "\(location)不存在：\(path)。\(creationHint)\(nextStep)"
        case .notDirectory:
            return "\(location)的路径不是目录：\(path)。请改选一个目录。\(nextStep)"
        case .notWritable:
            return "\(location)不可写：\(path)。pi-web 需要在该目录写入运行文件，请修改目录权限或改选其他目录。\(nextStep)"
        }
    }
}

/// 工作目录的只读探针（可注入）。
///
/// 生产实现只使用 `FileManager`；测试注入闭包，因此不会触碰真实用户目录。
struct WorkspaceDirectoryProbe {
    /// 路径存在（文件或目录都算）。
    var pathExists: (String) -> Bool
    /// 路径存在且是目录。
    var isDirectory: (String) -> Bool
    /// 目录可写（`FileManager.isWritableFile`）。
    var isWritable: (String) -> Bool
    /// 创建目录（含中间目录）；失败抛出。
    var createDirectory: (String) throws -> Void

    static func live(fileManager: FileManager = .default) -> WorkspaceDirectoryProbe {
        WorkspaceDirectoryProbe(
            pathExists: { fileManager.fileExists(atPath: $0) },
            isDirectory: { path in
                var isDirectory: ObjCBool = false
                return fileManager.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
            },
            isWritable: { fileManager.isWritableFile(atPath: $0) },
            createDirectory: { path in
                try fileManager.createDirectory(
                    at: URL(fileURLWithPath: path, isDirectory: true),
                    withIntermediateDirectories: true
                )
            }
        )
    }
}

/// 工作目录校验结果。
enum WorkspaceDirectoryValidation: Equatable {
    case usable(path: String)
    case unusable(problem: WorkspaceDirectoryProblem, path: String)

    var path: String {
        switch self {
        case .usable(let path): return path
        case .unusable(_, let path): return path
        }
    }

    var problem: WorkspaceDirectoryProblem? {
        guard case .unusable(let problem, _) = self else { return nil }
        return problem
    }

    var isUsable: Bool { problem == nil }
}

/// 工作目录的解析、校验与选择逻辑（GitHub #9）。
///
/// 纯逻辑 + 注入探针，不依赖 AppKit：unhosted 测试可以直接断言
/// “不存在/不可写 → 阻止启动并给出修复提示”，也不需要真实目录。
enum WorkspaceDirectory {
    /// 生效的工作目录：配置里的绝对路径优先，空字符串表示默认目录。
    static func resolvedPath(configured: String, defaultPath: String) -> String {
        configured.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? defaultPath : configured
    }

    /// 配置是否显式选择了目录（而不是“跟随默认目录”）。
    static func usesDefaultLocation(configured: String) -> Bool {
        configured.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 只校验：存在、是目录、可写。
    static func validate(path: String, probe: WorkspaceDirectoryProbe) -> WorkspaceDirectoryValidation {
        guard probe.isDirectory(path) else {
            return .unusable(problem: probe.pathExists(path) ? .notDirectory : .missing, path: path)
        }
        guard probe.isWritable(path) else {
            return .unusable(problem: .notWritable, path: path)
        }
        return .usable(path: path)
    }

    /// 首次使用默认工作目录时创建它，然后校验。
    ///
    /// 只创建默认目录：自选目录是用户通过面板挑选的（必须是已存在且可写的
    /// 目录），被删除或改权限后按诊断状态处理，而不是静默重建。
    static func prepare(
        configuredPath: String,
        defaultPath: String,
        probe: WorkspaceDirectoryProbe
    ) -> WorkspaceDirectoryValidation {
        let path = resolvedPath(configured: configuredPath, defaultPath: defaultPath)
        if usesDefaultLocation(configured: configuredPath), !probe.isDirectory(path) {
            try? probe.createDirectory(path)
        }
        return validate(path: path, probe: probe)
    }

    /// 状态页文本：把不可用原因与修复提示拼成可读正文。
    static func statusPageText(
        _ validation: WorkspaceDirectoryValidation,
        defaultPath: String
    ) -> String {
        guard let problem = validation.problem else {
            return "工作目录可用：\(validation.path)"
        }
        let isDefault = validation.path == defaultPath
        return [
            "工作目录不可用，已暂停启动 Pi Web 服务。",
            "",
            problem.message(path: validation.path, isDefaultLocation: isDefault),
            "",
            "当前工作目录：\(validation.path)",
            "默认工作目录：\(defaultPath)"
        ].joined(separator: "\n")
    }

    /// 设置窗口“选择目录…”的校验与应用逻辑。
    ///
    /// 与 `PiWebPathSelection` 同一风格：只有校验通过才会返回改写后的配置；
    /// 失败时返回可读错误，调用方因此不可能在失败路径上写入 UserDefaults。
    /// 空字符串表示“跟随默认目录”。
    enum Selection {
        struct Result: Equatable {
            /// 接受时是写入 `workspacePath` 后的配置；拒绝时与输入完全相同。
            var configuration: ServiceConfiguration
            /// 可读错误信息；nil 表示已接受。
            var error: String?
        }

        static func apply(
            selectedPath: String,
            configuration: ServiceConfiguration,
            defaultPath: String,
            probe: WorkspaceDirectoryProbe
        ) -> Result {
            let trimmed = selectedPath.trimmingCharacters(in: .whitespacesAndNewlines)
            var updated = configuration
            guard !trimmed.isEmpty else {
                updated.workspacePath = ""
                return Result(configuration: updated, error: nil)
            }
            guard (trimmed as NSString).isAbsolutePath else {
                return Result(
                    configuration: configuration,
                    error: "工作目录必须是绝对路径，设置未保存：\(trimmed)"
                )
            }
            switch validate(path: trimmed, probe: probe) {
            case .usable:
                updated.workspacePath = trimmed
                return Result(configuration: updated, error: nil)
            case .unusable(let problem, let path):
                return Result(
                    configuration: configuration,
                    error: "无法使用该工作目录（\(problem.title)）：\(path)。请改选一个可写目录，或在“工作目录”里留空以使用默认目录。"
                )
            }
        }
    }
}
