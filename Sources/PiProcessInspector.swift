import Darwin
import Foundation

// MARK: - Pi 运行进程保护（GitHub #21）
//
// 本文件只回答一个问题：“现在有没有正在运行的 Pi CLI 进程，以及我能不能确定？”
// 边界：
// - 只读：枚举 PID 用 `proc_listpids`，单个进程的事实用 `proc_pidinfo` /
//   `proc_pidpath` 与 `sysctl KERN_PROCARGS2`（Apple 系统框架以内）；
// - 读取面收窄（GitHub #61）：先用 `proc_pidinfo` / `proc_pidpath` 取便宜的身份
//   事实，只有候选进程（镜像路径或内核进程名的可执行基名是 `pi`，或是已知的 JS
//   运行时）才用 `sysctl KERN_PROCARGS2` 读 argv；系统守护进程、编译器、编辑器
//   等非候选进程不读命令行。候选判定只是读取优化，不是安全判断：镜像路径解析
//   失败、权限不足、枚举失败仍然按“不确定”处理（不自动更新）；
// - 绝不向任何进程发送信号：本文件不调用 `kill`/`killpg`，也不使用
//   `Process`；它连 `Process` 都不 import（只有 `Darwin`/`Foundation`）；
// - 只按“可执行名”判定，不做 argv 子串匹配：真实镜像路径（`proc_pidpath`）的
//   文件名、内核进程名（`pbi_comm`）或 JS 运行时报告的脚本路径/进程标题必须
//   恰好等于 `pi`；`pi-web`、`pip`、`pi-helper`、编辑器里的 `pi` 文件路径都
//   因此不会命中；
// - 三态：`noProcesses` / `runningProcesses` / `unknown`。任何不确定（枚举失败、
//   镜像路径与进程名都不可读、解释器进程的 argv 不可读、名为 `pi` 的脚本路径
//   无法确认）都返回 `unknown`，由更新决策按“不安全”处理；
// - 命令摘要只保留脱敏后的文本：原始 argv 不离开本文件，摘要先按 token 边界
//   处理 `--token=…` / `--password …` / `-p<值>` 这类凭据、已知凭据前缀（`sk-` /
//   `ghp_` / `xoxb-` 等）与长不透明串（疑似 base64/十六进制），再经 `LogRedactor`
//   整体处理（Home 路径 → `~`、查询串/其它键值 → 占位符），并丢掉 `KEY=VALUE`
//   形状的环境变量片段；长度有上限。遮罩是模式化的：不符合已知形状的自由文本
//   可能保留（已知边界，见 `docs/privacy.md`），因此不要把秘密放进命令行。

// MARK: - 原始事实（探针输出）

/// 读取单个进程时遇到的失败。进程名与镜像路径都读不到时，调用方只能按
/// “不确定”处理；`processGone` 例外：它表示进程已经不存在。
enum PiProcessReadFailure: Equatable {
    /// 进程在枚举与读取之间退出（正常竞态，不是不确定）。
    case processGone
    /// 没有权限读取这个进程（例如其它用户或受保护的系统进程）。
    case permissionDenied
    /// 其它读取失败（解析失败、缓冲区不足等）。
    case unreadable

    var text: String {
        switch self {
        case .processGone: return "进程已退出"
        case .permissionDenied: return "权限不足"
        case .unreadable: return "读取失败"
        }
    }
}

/// 一个进程的原始事实。**任何字段都可能缺失**：缺失表示“没读到”，绝不表示
/// 空值语义，调用方不得用猜测补齐。
struct PiProcessSnapshot: Equatable {
    var pid: pid_t
    /// 父进程 PID；未读到时为 nil。
    var parentPID: pid_t?
    /// 进程启动时间（`pbi_start_tvsec` + `pbi_start_tvusec`）；未读到时为 nil。
    var startedAt: Date?
    /// `proc_pidpath` 报告的真实镜像路径；nil 表示不可得（权限不足 / 已退出）。
    var imagePath: String?
    /// 内核进程名（`pbi_comm`，最多 16 字节；为空时回退 `pbi_name`）。
    var executableName: String?
    /// 完整 argv（只含真实参数，不含环境变量）。空数组表示没有读到。
    ///
    /// 生产快照只携带便宜的身份事实（`LibprocPiProcessProbe.snapshot` 不读 argv）；
    /// argv 由 `PiProcessProbing.arguments` 单独读取，并且只有候选进程会被读，
    /// 读到的值再由 `PiProcessInspector.inspect` 补进快照。
    var arguments: [String]
    /// 读取失败的原因；nil 表示这一组事实读取成功。
    var readFailure: PiProcessReadFailure?
}

/// 一次 PID 枚举的结果。
enum PiProcessPidListing: Equatable {
    case pids([pid_t])
    /// `proc_listpids` 失败（缓冲区反复不足或系统调用失败）。
    case failed
}

/// 一个 PID 的快照结果。
enum PiProcessSnapshotOutcome: Equatable {
    case snapshot(PiProcessSnapshot)
    /// 进程在枚举与读取之间退出：跳过这个 PID，不算“不确定”。
    case processGone
}

/// 进程事实的注入点。
///
/// 生产实现是 `LibprocPiProcessProbe`；unhosted 测试注入假进程表，因此测试
/// **绝不枚举、也绝不操作真实用户进程**。接口里没有任何发送信号、终止或修改
/// 进程的方法：这条路径在类型层面就不具备向 Pi 进程发信号的能力。
///
/// 读取分成两步，这样“哪个 PID 被读过 argv”本身就是可注入、可断言的事实：
/// 1. `snapshot(_:)` 只取便宜的身份事实（父 PID、启动时间、镜像路径、内核进程名）；
/// 2. `arguments(_:)` 才读 argv（`KERN_PROCARGS2`），并且**只对候选进程调用**
///    （见 `PiProcessInspector.isCandidate`）。测试注入一个记录调用的闭包，就能
///    断言非候选进程没有触发 argv 读取，而不需要任何真实进程。
struct PiProcessProbing {
    var listProcessIdentifiers: () -> PiProcessPidListing
    var snapshot: (pid_t) -> PiProcessSnapshotOutcome
    /// 读取 argv；读不到（权限、已退出、解析失败）时返回空数组。
    var arguments: (pid_t) -> [String]

    static let libproc = PiProcessProbing(
        listProcessIdentifiers: LibprocPiProcessProbe.listProcessIdentifiers,
        snapshot: LibprocPiProcessProbe.snapshot(of:),
        arguments: LibprocPiProcessProbe.arguments(of:)
    )

    /// 固定进程表（测试与诊断 fixture 用）。`snapshots` 里没有的 PID 视为已退出。
    ///
    /// `snapshot` 返回的进程事实**不含 argv**：argv 只通过 `arguments` 提供，因此
    /// “非候选进程不读 argv”的断言不会被 fixture 自己绕过（fixture 只有在被调用时
    /// 才交出 argv）。
    static func fixture(_ snapshots: [PiProcessSnapshot]) -> PiProcessProbing {
        let table = Dictionary(uniqueKeysWithValues: snapshots.map { ($0.pid, $0) })
        return PiProcessProbing(
            listProcessIdentifiers: { .pids(snapshots.map(\.pid)) },
            snapshot: { pid in
                guard var snapshot = table[pid] else { return .processGone }
                snapshot.arguments = []
                return .snapshot(snapshot)
            },
            arguments: { pid in table[pid]?.arguments ?? [] }
        )
    }
}

// MARK: - libproc 探针（生产实现）

/// 只读的 libproc 探针。
///
/// 全部函数都是静态的纯读取：没有信号、没有写操作，失败只返回缺失字段。
enum LibprocPiProcessProbe {
    /// `proc_listpids(PROC_ALL_PIDS)`。缓冲区不足时按倍数重试，最多
    /// `maximumListingAttempts` 次；仍不足则返回 `.failed`（调用方按不确定处理）。
    static let maximumListingAttempts = 6
    static let initialListingCapacity = 1024
    /// `argv` 的条目上限：防御异常进程报告的超大 argc。
    static let maximumArgumentCount: Int32 = 4096

    static func listProcessIdentifiers() -> PiProcessPidListing {
        var capacity = initialListingCapacity
        for _ in 0..<maximumListingAttempts {
            var buffer = [pid_t](repeating: 0, count: capacity)
            let byteCount = proc_listpids(
                UInt32(PROC_ALL_PIDS),
                0,
                &buffer,
                Int32(capacity * MemoryLayout<pid_t>.size)
            )
            guard byteCount > 0 else { return .failed }
            let count = Int(byteCount) / MemoryLayout<pid_t>.size
            if count < capacity {
                return .pids(buffer[0..<count].filter { $0 > 1 })
            }
            capacity *= 2
        }
        return .failed
    }

    static func snapshot(of pid: pid_t) -> PiProcessSnapshotOutcome {
        guard pid > 1 else { return .processGone }

        var info = proc_bsdinfo()
        let infoSize = Int32(MemoryLayout<proc_bsdinfo>.size)
        let infoBytes = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, infoSize)
        if infoBytes != infoSize {
            let failure = classify(errno)
            if failure == .processGone { return .processGone }
            return .snapshot(PiProcessSnapshot(
                pid: pid,
                parentPID: nil,
                startedAt: nil,
                imagePath: imagePath(of: pid),
                executableName: nil,
                arguments: [],
                readFailure: failure
            ))
        }

        errno = 0
        let path = imagePath(of: pid)
        let pathFailure: PiProcessReadFailure? = path == nil ? classify(errno) : nil
        if pathFailure == .processGone { return .processGone }

        let startedAt: Date? = info.pbi_start_tvsec > 0
            ? Date(
                timeIntervalSince1970: TimeInterval(info.pbi_start_tvsec)
                    + TimeInterval(info.pbi_start_tvusec) / 1_000_000
            )
            : nil

        return .snapshot(PiProcessSnapshot(
            pid: pid,
            parentPID: pid_t(info.pbi_ppid),
            startedAt: startedAt,
            imagePath: path,
            executableName: fixedString(bytes: info.pbi_comm) ?? fixedString(bytes: info.pbi_name),
            arguments: [],
            readFailure: pathFailure
        ))
    }

    /// `proc_pidpath`：真实可执行镜像路径。失败时返回 nil，`errno` 由调用方读取。
    private static func imagePath(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        let bytes = buffer[0..<Int(length)].map { UInt8(bitPattern: $0) }
        let path = String(decoding: bytes, as: UTF8.self)
        return path.isEmpty ? nil : path
    }

    /// `sysctl KERN_PROCARGS2`：读取真实 argv。只读取 argv 的前 `argc` 项，
    /// 停在 argv 边界，因此不会把 envp 当成参数；读取失败（其它用户的进程、
    /// 权限不足）返回空数组。
    ///
    /// 这是唯一会读命令行的路径，调用方（`PiProcessInspector.inspect`）只对候选
    /// 进程调用它；`snapshot(of:)` 自己不再读 argv。
    static func arguments(of pid: pid_t) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0,
              size > MemoryLayout<Int32>.size,
              size <= 1024 * 1024 else { return [] }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return [] }

        var argumentCount: Int32 = 0
        withUnsafeMutableBytes(of: &argumentCount) { destination in
            buffer.withUnsafeBytes { source in
                guard let base = source.baseAddress, let target = destination.baseAddress else { return }
                memcpy(target, base, min(destination.count, source.count))
            }
        }
        guard argumentCount > 0, argumentCount <= maximumArgumentCount else { return [] }

        var offset = MemoryLayout<Int32>.size
        // 跳过 exec_path：一个 NUL 结尾的字符串，之后是补齐到 argv[0] 的 NUL 串。
        while offset < size, buffer[offset] != 0 { offset += 1 }
        while offset < size, buffer[offset] == 0 { offset += 1 }

        var result: [String] = []
        var index: Int32 = 0
        while index < argumentCount, offset < size {
            let start = offset
            while offset < size, buffer[offset] != 0 { offset += 1 }
            let bytes = buffer[start..<offset].map { UInt8(bitPattern: $0) }
            result.append(String(decoding: bytes, as: UTF8.self))
            offset += 1
            index += 1
        }
        return result
    }

    /// 固定长度的 C 字符数组（`pbi_comm` / `pbi_name`）→ 字符串；全零返回 nil。
    private static func fixedString<T>(bytes: T) -> String? {
        var copy = bytes
        let text = withUnsafeBytes(of: &copy) { raw -> String in
            guard !raw.isEmpty else { return "" }
            let bytes = raw.bindMemory(to: UInt8.self)
            let end = bytes.firstIndex(of: 0) ?? bytes.count
            return String(decoding: bytes[0..<end], as: UTF8.self)
        }
        return text.isEmpty ? nil : text
    }

    private static func classify(_ code: Int32) -> PiProcessReadFailure {
        switch code {
        case ESRCH, ENOENT: return .processGone
        case EPERM, EACCES: return .permissionDenied
        default: return .unreadable
        }
    }
}

// MARK: - 命中证据与进程记录

/// 一个进程被判定为 Pi CLI 的证据来源。四种都是“可执行名恰好等于 `pi`”，
/// 区别只在证据从哪来。
enum PiProcessMatchSource: String, Equatable {
    /// 真实镜像路径（`proc_pidpath`）的文件名是 `pi`。
    case imagePath
    /// 内核进程名（`pbi_comm`/`pbi_name`）是 `pi`。
    case executableName
    /// JS 运行时（`node`/`bun`/`deno` 等）报告的脚本路径是 `pi`。
    case interpreterScript
    /// JS 运行时的 `argv[0]` 被设为 `pi`（Pi CLI 会改写进程标题）。
    case processTitle

    var text: String {
        switch self {
        case .imagePath: return "真实镜像路径的可执行文件名是 pi"
        case .executableName: return "内核进程名是 pi"
        case .interpreterScript: return "JS 运行时报告的脚本路径文件名是 pi"
        case .processTitle: return "JS 运行时的 argv[0]（进程标题）是 pi"
        }
    }
}

/// 一个运行中的 Pi 进程的**已脱敏**记录。
///
/// 原始 argv 从不进入记录：命令摘要在构造时就经过 `LogRedactor` 并丢掉
/// `KEY=VALUE` 环境片段。路径字段同样是脱敏后的文本（Home 前缀 → `~`），
/// 因此记录可以安全地写进日志、诊断导出与确认框。
struct PiProcessRecord: Equatable {
    /// 命令摘要的长度上限（字符）。
    static let commandSummaryLimit = 200

    var pid: pid_t
    var parentPID: pid_t?
    /// 已按注入的格式器渲染的启动时间；未读到时为 nil。
    var startedAtText: String?
    /// 真实镜像路径（`proc_pidpath`，已脱敏）；不可得时为 nil。
    var executablePath: String?
    /// JS 运行时代理执行的脚本路径（已脱敏）；只有证据来自脚本路径时非 nil。
    var scriptPath: String?
    /// 判定为 Pi 的依据。
    var matchSource: PiProcessMatchSource
    /// 已脱敏、有界的命令摘要。
    var commandSummary: String

    /// 单行摘要（已脱敏）：`PID 1234（父进程 1200，真实镜像 .…）`。
    var shortText: String {
        var parts = ["PID \(pid)"]
        if let parentPID { parts.append("父进程 \(parentPID)") }
        if let startedAtText { parts.append("启动于 \(startedAtText)") }
        return parts.joined(separator: "，")
    }

    /// 手动更新确认框与诊断文本共用的多行描述。
    var displayLines: [String] {
        var lines = ["进程 PID：\(pid)"]
        lines.append("父进程 PID：\(parentPID.map(String.init) ?? "未知")")
        lines.append("启动时间：\(startedAtText ?? "未知")")
        lines.append("判定依据：\(matchSource.text)")
        lines.append("真实镜像路径：\(executablePath ?? "不可读")")
        if let scriptPath {
            lines.append("脚本路径：\(scriptPath)")
        }
        lines.append("命令摘要：\(commandSummary)")
        return lines
    }
}

// MARK: - 检查结果（三态）

/// 不确定的原因。全部是固定文案 + PID：不携带原始 argv、环境变量或未脱敏路径
/// （`scriptPathUnconfirmed` 里的路径在构造前已经过 `LogRedactor`）。
enum PiProcessInspectionUnknown: Equatable {
    /// `proc_listpids` 失败：连有哪些进程都不知道。
    case enumerationFailed
    /// 镜像路径与进程名都不可读（权限不足、受保护进程，或进程正在退出）。
    case identityUnavailable(pid: pid_t, failure: PiProcessReadFailure?)
    /// 进程确实由 JS 运行时承载，但 argv 不可读，因此无法排除它是 Pi。
    case argumentsUnavailable(pid: pid_t, interpreter: String)
    /// argv 里出现了名为 `pi` 的脚本路径，但无法确认它是可执行文件（可能是普通
    /// 文件、相对路径，或符号链接断裂无法解析）。
    case scriptPathUnconfirmed(pid: pid_t, path: String)

    var text: String {
        switch self {
        case .enumerationFailed:
            return "无法枚举本机进程（proc_listpids 失败）"
        case .identityUnavailable(let pid, let failure):
            let reason = failure.map { "：\($0.text)" } ?? ""
            return "PID \(pid) 的镜像路径与进程名都不可读\(reason)"
        case .argumentsUnavailable(let pid, let interpreter):
            return "PID \(pid) 由 \(interpreter) 承载，但无法读取它的参数，不能排除它是 Pi"
        case .scriptPathUnconfirmed(let pid, let path):
            return "PID \(pid) 的参数里出现了名为 pi 的脚本路径 \(path)，但无法确认它是可执行文件（普通文件、相对路径或无法解析的符号链接）"
        }
    }
}

/// Pi 进程检查的三态结果。
///
/// `unknown` 与 `runningProcesses` 在更新决策里同样按“不安全”处理：只有
/// `noProcesses` 才允许自动执行 `pi update --self`。
enum PiProcessInspection: Equatable {
    case noProcesses
    case runningProcesses([PiProcessRecord])
    case unknown(PiProcessInspectionUnknown)

    /// 只有确认“没有 Pi 进程”时才是安全的。
    var allowsAutomaticUpdate: Bool {
        if case .noProcesses = self { return true }
        return false
    }

    var records: [PiProcessRecord] {
        if case .runningProcesses(let records) = self { return records }
        return []
    }

    var unknownReason: PiProcessInspectionUnknown? {
        if case .unknown(let reason) = self { return reason }
        return nil
    }

    /// 单行状态（诊断页/设置页用）。
    var statusText: String {
        switch self {
        case .noProcesses:
            return "没有检测到运行中的 Pi 进程"
        case .runningProcesses(let records):
            let summary = records.map(\.shortText).joined(separator: "；")
            return "检测到 \(records.count) 个运行中的 Pi 进程：\(summary)"
        case .unknown(let reason):
            return "无法确认 Pi 进程状态：\(reason.text)"
        }
    }

    /// 更新决策使用的推迟原因文案。
    var deferralText: String {
        switch self {
        case .noProcesses:
            return "没有运行中的 Pi 进程"
        case .runningProcesses(let records):
            return "有 \(records.count) 个运行中的 Pi 进程；更新会让正在进行的会话读到被替换的文件，因此本次不自动更新"
        case .unknown(let reason):
            return "无法确定 Pi 进程状态（\(reason.text)）；按不安全处理，不自动更新"
        }
    }
}

// MARK: - 检查器

/// Pi 运行进程检查器（GitHub #21）。
///
/// 输入全部注入：进程表（`PiProcessProbing`）、可执行位探针
/// （`DependencyFileSystemProbing`）、脱敏器与时间格式器。因此 unhosted 测试
/// 只构造假进程事实，不会枚举真实进程、不会读取真实磁盘、也不会写任何东西。
struct PiProcessInspector {
    /// 判定为“JS 运行时”的可执行文件名（小写比较）。Pi CLI 以 `#!/usr/bin/env node`
    /// 脚本形式发行，内核报告的镜像路径是 Node 本身，所以必须结合 argv 判定。
    static let interpreterExecutableNames: Set<String> = ["node", "nodejs", "bun", "deno", "tsx", "ts-node"]
    /// Pi CLI 的可执行文件名：精确匹配，不做前缀/子串匹配。
    static let piExecutableName = "pi"

    var probe: PiProcessProbing
    var fileSystem: DependencyFileSystemProbing
    var redactor: LogRedactor
    /// 启动时间格式器（诊断页/确认框显示用；测试注入固定值）。
    var formatStartTime: (Date) -> String

    init(
        probe: PiProcessProbing = .libproc,
        fileSystem: DependencyFileSystemProbing = SystemDependencyFileSystemProbe(),
        redactor: LogRedactor = LogRedactor(),
        formatStartTime: @escaping (Date) -> String = PiProcessInspector.defaultStartTimeFormat
    ) {
        self.probe = probe
        self.fileSystem = fileSystem
        self.redactor = redactor
        self.formatStartTime = formatStartTime
    }

    static let defaultStartTimeFormat: (Date) -> String = { date in
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }

    /// 枚举并判定。只有确认没有任何 Pi 进程时才返回 `.noProcesses`；
    /// 只要确认存在 Pi 进程就返回 `.runningProcesses`（同时存在无法判定的
    /// 进程时仍然以“已经确认在运行”为结论，理由见 `PiProcessInspection`）；
    /// 其余情况返回 `.unknown`。
    func inspect() -> PiProcessInspection {
        switch probe.listProcessIdentifiers() {
        case .failed:
            return .unknown(.enumerationFailed)
        case .pids(let pids):
            var records: [PiProcessRecord] = []
            var unknown: PiProcessInspectionUnknown?
            for pid in Set(pids).sorted() where pid > 1 {
                switch probe.snapshot(pid) {
                case .processGone:
                    continue
                case .snapshot(let identity):
                    // 便宜筛选：非候选进程不读 argv，分类也不会看 argv；候选进程
                    // 读到的 argv 只是补全快照，不确定语义不变（读不到仍按空处理，
                    // 由 classify 归入 unknown）。
                    let snapshot: PiProcessSnapshot
                    if Self.isCandidate(identity) {
                        var candidate = identity
                        candidate.arguments = probe.arguments(identity.pid)
                        snapshot = candidate
                    } else {
                        snapshot = identity
                    }
                    switch classify(snapshot) {
                    case .pi(let record):
                        records.append(record)
                    case .notPi:
                        continue
                    case .unknown(let reason):
                        if unknown == nil { unknown = reason }
                    }
                }
            }
            if !records.isEmpty {
                return .runningProcesses(records)
            }
            if let unknown {
                return .unknown(unknown)
            }
            return .noProcesses
        }
    }

    /// 单个进程的分类。
    func classify(_ snapshot: PiProcessSnapshot) -> PiProcessClassification {
        let imageName = Self.baseName(snapshot.imagePath)
        let kernelName = Self.baseName(snapshot.executableName)

        // 1. 真实镜像路径的文件名就是 pi。
        if let imageName, Self.isPiExecutableName(imageName) {
            return .pi(makeRecord(snapshot, matchSource: .imagePath, scriptPath: nil))
        }

        // 2. 镜像路径不可得，但内核进程名就是 pi（其它用户或受保护进程也能读到
        //    的、仍然是“可执行名匹配”的证据）。
        if snapshot.imagePath == nil, let kernelName, Self.isPiExecutableName(kernelName) {
            return .pi(makeRecord(snapshot, matchSource: .executableName, scriptPath: nil))
        }

        // 3. 镜像路径或进程名表明这是 JS 运行时：Pi CLI 以内核看不到的脚本形式
        //    运行，只有 argv 能证明“脚本/进程标题恰好是 pi”。
        let interpreter = Self.interpreterName(imageName) ?? Self.interpreterName(kernelName)
        if let interpreter {
            if snapshot.imagePath == nil, kernelName == nil {
                return .unknown(.identityUnavailable(pid: snapshot.pid, failure: snapshot.readFailure))
            }
            return classifyInterpreterProcess(snapshot, interpreter: interpreter)
        }

        // 4. 镜像路径可读、文件名既不是 pi 也不是 JS 运行时：确定不是 Pi。
        if imageName != nil { return .notPi }

        // 5. 镜像路径不可得，但内核进程名可读且明确不是 pi：确定不是 Pi。
        if let kernelName, !kernelName.isEmpty { return .notPi }

        // 6. 两个可执行身份都不可读：不确定。
        return .unknown(.identityUnavailable(pid: snapshot.pid, failure: snapshot.readFailure))
    }

    /// JS 运行时进程：只有 argv 里“恰好等于 pi”的脚本路径或进程标题才算命中。
    ///
    /// - `argv[0]` 恰好是 `pi` 时按进程标题命中：Pi CLI 会把进程标题改写成
    ///   `pi`，此时原始脚本路径已经不可见；普通 JS 应用的 `argv[0]` 是运行时
    ///   自己的名字（例如 `node`），不会命中；这是**唯一**接受的非绝对路径形态；
    /// - 其它位置的参数必须既是**绝对路径**、文件名又恰好是 `pi`，并且能解析出
    ///   可执行文件（可执行位，或符号链接能解析到存在的目标）；`node /tmp/notes/pi`
    ///   这类普通文件、符号链接断裂与相对路径因此不会命中；
    /// - 相对路径（`./pi`、`../bin/pi`、解释器的第一个位置参数 `pi`）一律按
    ///   `unknown` 处理：无法确认它相对哪个工作目录解析，不确定即按不安全处理
    ///   （返回 `notPi` 会是漏判方向）；
    /// - 数据参数里的 `pi`（例如 `node app.js pi`、`vim pi`）不会命中：既不是
    ///   `argv[0]`，也不是脚本路径位置。
    private func classifyInterpreterProcess(
        _ snapshot: PiProcessSnapshot,
        interpreter: String
    ) -> PiProcessClassification {
        guard !snapshot.arguments.isEmpty else {
            return .unknown(.argumentsUnavailable(pid: snapshot.pid, interpreter: interpreter))
        }
        var unconfirmed: PiProcessInspectionUnknown?
        func recordUnconfirmed(_ path: String) {
            guard unconfirmed == nil else { return }
            unconfirmed = .scriptPathUnconfirmed(pid: snapshot.pid, path: redactor.redact(path))
        }
        for (index, argument) in snapshot.arguments.enumerated() where !argument.isEmpty {
            guard Self.baseName(argument) == Self.piExecutableName else { continue }
            if argument.hasPrefix("-") { continue }
            if index == 0, !argument.contains("/") {
                return .pi(makeRecord(snapshot, matchSource: .processTitle, scriptPath: nil))
            }
            // 脚本路径候选：含路径分隔符的参数，或解释器的第一个位置参数（index 1
            // 的裸名）。其余位置的裸 `pi` 是数据参数，不读磁盘也不改变判定。
            let looksLikePath = argument.contains("/")
            let isInterpreterScriptPosition = index == 1 && !looksLikePath
            guard looksLikePath || isInterpreterScriptPosition else { continue }
            guard argument.hasPrefix("/") else {
                // 相对路径：无法确认它相对哪个工作目录解析，按不确定处理。
                recordUnconfirmed(argument)
                continue
            }
            if fileSystem.isExecutableFile(atPath: argument) {
                return .pi(makeRecord(
                    snapshot,
                    matchSource: .interpreterScript,
                    scriptPath: redactor.redact(argument)
                ))
            }
            // 符号链接要能解析到存在的目标才算命中；断裂的符号链接按不确定处理
            // （它既不能证明脚本存在，也不能证明它不存在）。
            if fileSystem.symlinkDestination(atPath: argument) != nil,
               fileSystem.resolvedPath(atPath: argument) != nil {
                return .pi(makeRecord(
                    snapshot,
                    matchSource: .interpreterScript,
                    scriptPath: redactor.redact(argument)
                ))
            }
            recordUnconfirmed(argument)
        }
        if let unconfirmed { return .unknown(unconfirmed) }
        return .notPi
    }

    /// 构造已脱敏记录。原始 argv 到这里为止：摘要只保留脱敏后的文本。
    private func makeRecord(
        _ snapshot: PiProcessSnapshot,
        matchSource: PiProcessMatchSource,
        scriptPath: String?
    ) -> PiProcessRecord {
        PiProcessRecord(
            pid: snapshot.pid,
            parentPID: snapshot.parentPID,
            startedAtText: snapshot.startedAt.map(formatStartTime),
            executablePath: snapshot.imagePath.map { redactor.redact($0) },
            scriptPath: scriptPath,
            matchSource: matchSource,
            commandSummary: Self.commandSummary(arguments: snapshot.arguments, redactor: redactor)
        )
    }

    // MARK: - 纯函数

    /// 可执行文件名是否恰好是 `pi`。**精确匹配**：`pi-web`、`pip`、`pi-helper`
    /// 都不命中。
    static func isPiExecutableName(_ name: String) -> Bool {
        name == piExecutableName
    }

    /// JS 运行时的候选名字前缀（GitHub #61）。
    ///
    /// 候选判定故意比分类宽松：`node24`、`npm-cli` 这类带版本或包装后缀的名字也
    /// 按运行时处理。放宽只可能多读一个进程的 argv，不可能漏读，也不可能改变
    /// 分类结论（`classify` 仍然只认 `interpreterExecutableNames` 的精确名字）。
    static let runtimeNamePrefixes: Set<String> = [
        "node", "npm", "npx", "bun", "deno", "tsx", "ts-node"
    ]

    /// 名字是否像已知的 JS 运行时（精确名或已知前缀）。
    static func isRuntimeLikeName(_ name: String?) -> Bool {
        guard let name, !name.isEmpty else { return false }
        let lowered = name.lowercased()
        if interpreterExecutableNames.contains(lowered) { return true }
        return runtimeNamePrefixes.contains { lowered.hasPrefix($0) }
    }

    /// 便宜的候选判定：只用镜像路径与内核进程名，**不读 argv**。
    ///
    /// 只有候选进程的 argv 可能改变判定结果：`pi` 的可执行名（镜像或内核进程名）
    /// 需要 argv 生成命令摘要；JS 运行时（Pi CLI 的 `#!/usr/bin/env node` 形态、
    /// npm/pnpm 全局前缀下的入口脚本都由 `node` 承载）需要 argv 才能看到脚本路径
    /// 与进程标题。系统守护进程、编译器、编辑器的 argv 与判定无关，因此不读。
    ///
    /// 候选判定是读取优化，不是安全判断：它不把任何“不确定”变成“确定”，
    /// 两个可执行身份都读不到的进程仍然走 `unknown`。
    static func isCandidate(imagePath: String?, executableName: String?) -> Bool {
        let imageName = baseName(imagePath)
        let kernelName = baseName(executableName)
        if let imageName, isPiExecutableName(imageName) { return true }
        if let kernelName, isPiExecutableName(kernelName) { return true }
        if isRuntimeLikeName(imageName) { return true }
        if isRuntimeLikeName(kernelName) { return true }
        return false
    }

    /// `PiProcessSnapshot` 版本的候选判定。
    static func isCandidate(_ snapshot: PiProcessSnapshot) -> Bool {
        isCandidate(imagePath: snapshot.imagePath, executableName: snapshot.executableName)
    }

    /// 路径（或裸名）的最后一段；空值返回 nil。
    static func baseName(_ path: String?) -> String? {
        guard let path, !path.isEmpty else { return nil }
        let base = (path as NSString).lastPathComponent
        return base.isEmpty ? nil : base
    }

    /// 可执行文件名是否是已知 JS 运行时（小写比较；macOS 上 `Node` 也可能出现）。
    static func interpreterName(_ name: String?) -> String? {
        guard let name, !name.isEmpty else { return nil }
        let lowered = name.lowercased()
        return interpreterExecutableNames.contains(lowered) ? lowered : nil
    }

    /// `KEY=VALUE` 形状的环境变量片段：不进摘要。
    static func isEnvironmentAssignment(_ token: String) -> Bool {
        guard let separator = token.firstIndex(of: "="), separator != token.startIndex else { return false }
        let key = token[token.startIndex..<separator]
        guard let first = key.first, first.isLetter || first == "_" else { return false }
        return key.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }
    }

    // MARK: - Token 级凭据脱敏

    /// 敏感键名片段（与 `LogRedactor` 的判据同一组：token/password/secret/
    /// api_key…，大小写不敏感）。
    static let sensitiveKeyFragments = [
        "token", "password", "passwd", "secret", "api_key", "apikey",
        "api-key", "private_key", "private-key", "credential"
    ]

    /// 文本里是否含敏感键名片段。
    static func containsSensitiveKeyFragment(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        let lowered = text.lowercased()
        return sensitiveKeyFragments.contains { lowered.contains($0) }
    }

    /// 文本是否以敏感键名片段结尾（`--api-key` 是开关名；`--api-key<值>` 不是）。
    static func endsWithSensitiveKeyFragment(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        let lowered = text.lowercased()
        return sensitiveKeyFragments.contains { lowered.hasSuffix($0) }
    }

    /// 去掉前导 `-`（`--token` → `token`）。
    static func strippingLeadingDashes(_ text: String) -> String {
        var result = text
        while result.hasPrefix("-") { result.removeFirst() }
        return result
    }

    /// `键=值` / `键:值` 形态的分隔符位置；不是键值形态时返回 nil。
    /// `scheme://` 不当作键值分隔符。
    static func keyValueSeparatorIndex(in token: String) -> String.Index? {
        if let index = token.firstIndex(of: "=") { return index }
        guard !token.contains("://") else { return nil }
        return token.firstIndex(of: ":")
    }

    /// 敏感短开关字母：`-p<值>` / `-t<值>` / `-s<值>` 这类单字母短开关紧贴值
    /// （或后面跟一个 token）时按凭据处理。只覆盖凭证习惯用法，不做任意字母猜测。
    /// 匹配大小写不敏感：`-P<值>` / `-T<值>` / `-S<值>` 同样命中。
    static let sensitiveShortSwitchLetters: Set<Character> = ["p", "t", "s"]

    /// 敏感短开关名（不含前导 `-`）：`p`/`t`/`s` 是单字母习惯用法，`pw` 是常见的
    /// 多字母简写。匹配大小写不敏感，并且取**最长**命中（`-pw` 必须识别为 `pw`，
    /// 不能切成 `p` + 值 `w`，否则 `-pw <值>` 会把值留在摘要里）。
    static let sensitiveShortSwitchNames = ["p", "t", "s", "pw"]

    /// 单横线 token 的敏感短开关切分结果。
    struct SensitiveShortSwitchSplit: Equatable {
        /// 命中的开关名，保留原大小写。
        var switchName: String
        /// 开关名之后的剩余文本；可能是空串、以 `=` 开头，或紧贴的值。
        var remainder: String
        /// 剩余文本是否只由敏感短开关字母组成（`-pt`、`-tsp` 这类开关组：每个
        /// 字母都是裸开关，取值同样在下一个 token）。
        var remainderIsSwitchGroup: Bool
    }

    /// 单横线 token 的开关体（已去掉前导 `-`）是否以已知敏感短开关名开头。
    /// 取最长命中，因此 `-pw` 是 `pw` 而不是 `p` + 值 `w`。
    static func splitSensitiveShortSwitch(_ body: String) -> SensitiveShortSwitchSplit? {
        guard !body.isEmpty else { return nil }
        let lowered = body.lowercased()
        guard let match = sensitiveShortSwitchNames
            .filter({ lowered.hasPrefix($0) })
            .max(by: { $0.count < $1.count }) else { return nil }
        let remainder = String(body.dropFirst(match.count))
        let remainderIsSwitchGroup = !remainder.isEmpty && remainder.allSatisfy { character in
            guard let lowered = character.lowercased().first else { return false }
            return sensitiveShortSwitchLetters.contains(lowered)
        }
        return SensitiveShortSwitchSplit(
            switchName: String(body.prefix(match.count)),
            remainder: remainder,
            remainderIsSwitchGroup: remainderIsSwitchGroup
        )
    }

    /// 已知凭据前缀：命中即把整个 token 换成占位符（不保留任何可见片段）。
    /// 与仓库 secret 扫描的高信号形状对齐，但不依赖它。
    static let secretValuePrefixes = [
        "sk-", "sk_live_", "sk_test_", "rk_live_", "rk_test_",
        "ghp_", "gho_", "ghu_", "ghs_", "ghr_", "github_pat_",
        "xoxa-", "xoxb-", "xoxp-", "xoxr-", "xoxs-",
        "glpat-", "npm_", "AKIA"
    ]

    /// 长位置参数的遮罩阈值：长度达到它并且只由 base64/十六进制/不透明标识符
    /// 字符组成时，按“疑似秘密”处理（短于阈值的不遮罩，见 `docs/privacy.md` 的
    /// 已知边界）。
    static let opaqueSecretMinimumLength = 32

    /// token 是否以已知凭据前缀开头。
    static func hasKnownSecretPrefix(_ token: String) -> Bool {
        secretValuePrefixes.contains { token.hasPrefix($0) }
    }

    /// 位置参数形态的疑似秘密：长 base64/十六进制/不透明串。
    ///
    /// 路径与 URL 不算（`/` 开头、`~` 开头或含 `://`）：它们交给 `LogRedactor`
    /// 的 Home 路径与查询串规则，也避免把普通路径整体换成占位符。普通单词、
    /// 版本号与短标识符都不到阈值，因此不会被误遮罩。
    static func isOpaqueSecretToken(_ token: String) -> Bool {
        guard token.count >= opaqueSecretMinimumLength else { return false }
        guard !token.hasPrefix("/"), !token.hasPrefix("~"), !token.contains("://") else {
            return false
        }
        return token.allSatisfy { character in
            guard character.isASCII else { return false }
            return character.isLetter || character.isNumber
                || character == "+" || character == "/" || character == "="
                || character == "-" || character == "_"
        }
    }

    /// Token 级预处理：把 `--token=值`、`token:值` 形态的值换成占位符，
    /// 把 `--password 值` 的下一个 token 换成占位符，把短开关（`-p值`、`-p=值`、
    /// `-p 值`；大小写不敏感，支持 `-pw` 这类多字母名字）的值换成占位符，并把
    /// 已知凭据前缀与长不透明串（疑似 base64/十六进制）整段换成占位符。
    ///
    /// 取值形态的取舍（`docs/privacy.md` 同步说明）：裸开关（`--password`、`-p`）
    /// 后面的 token 不以 `-` 开头时只遮那一个 token（值）；以 `-` 开头时无法可靠
    /// 区分“值”与“下一个开关”，因此连尾巴一起隐藏。代价是 `-p 8080` 这类非秘密
    /// 数值也会被遮成 `-p <占位符>`——宁可少展示，不少脱敏。
    ///
    /// 这一步不能省：`LogRedactor` 的键值规则在同一行里匹配时，未加引号的值会
    /// 贪婪吐掉后面的所有内容（`[^\n,;&]+` 允许空格）。一旦后面的内容里已经出现
    /// 占位符（例如同一行的 URL 查询串先被替换），幂等保护会让整条规则跳过，
    /// 凭据就会原样留在摘要里。按 token 边界先处理，就不依赖匹配顺序。
    ///
    /// 已知边界（如实说明，不夸大）：这是模式化遮罩，不是“凡秘密必被遮”。不符合
    /// 任何已知形状的自由文本（例如短于 `opaqueSecretMinimumLength`、又没有已知
    /// 前缀的位置参数，或与已知键名无关的普通句子）会原样保留；因此不要把秘密
    /// 直接放进命令行。`docs/privacy.md` 与对应测试都把这个保留行为写成断言。
    static func maskSensitiveTokens(_ tokens: [String], marker: String = LogRedactor.marker) -> [String] {
        var masked: [String] = []
        masked.reserveCapacity(tokens.count)
        var index = 0
        while index < tokens.count {
            let token = tokens[index]
            // 1. `键=值` / `键:值`：保留键，只换值。URL（含 `://`）交给
            //    `LogRedactor` 的查询串规则整体处理。
            if !token.contains("://"),
               let separator = keyValueSeparatorIndex(in: token),
               containsSensitiveKeyFragment(String(token[token.startIndex..<separator])) {
                masked.append(String(token[token.startIndex...separator]) + marker)
                index += 1
                continue
            }
            if token.hasPrefix("-") {
                let name = strippingLeadingDashes(token)
                // 2. 敏感键名（长开关与单横线长开关，大小写不敏感）。不含 `=` 的
                //    形态里，`--token` / `--password` 这类裸开关的取值在下一个
                //    token；`--api-key<值>` 这种键名夹值整段替换。
                if !token.contains("=") {
                    if endsWithSensitiveKeyFragment(name) {
                        index = appendSensitiveSwitchValue(
                            switchText: token,
                            tokens: tokens,
                            index: index,
                            masked: &masked,
                            marker: marker
                        )
                        continue
                    }
                    if containsSensitiveKeyFragment(name) {
                        masked.append(marker)
                        index += 1
                        continue
                    }
                }
                // 3. 短开关（大小写不敏感，支持 `-p` / `-t` / `-s` / `-pw`）：
                //    `-p<值>`、`-p=<值>`、`-p <值>` 三种形态都要遮值。单横线
                //    长开关（`-password`）已在第 2 步处理，不会走到这里。
                if !token.hasPrefix("--"), let split = splitSensitiveShortSwitch(name) {
                    if split.remainder.isEmpty || split.remainderIsSwitchGroup {
                        // 裸短开关（或纯短开关字母组成的开关组）：取值在下一个 token。
                        index = appendSensitiveSwitchValue(
                            switchText: token,
                            tokens: tokens,
                            index: index,
                            masked: &masked,
                            marker: marker
                        )
                        continue
                    }
                    if split.remainder.hasPrefix("=") {
                        masked.append("-" + split.switchName + "=" + marker)
                    } else {
                        masked.append("-" + split.switchName + marker)
                    }
                    index += 1
                    continue
                }
            }
            // 4. 位置参数形式的已知凭据前缀（`sk-` / `ghp_` / `xoxb-` …）。
            if hasKnownSecretPrefix(token) {
                masked.append(marker)
                index += 1
                continue
            }
            // 5. 位置参数形式的长不透明串（疑似 base64/十六进制秘密）。
            if isOpaqueSecretToken(token) {
                masked.append(marker)
                index += 1
                continue
            }
            masked.append(token)
            index += 1
        }
        return masked
    }

    /// 裸敏感开关（`--password` / `-p` / `-pw`）的取值处理：下一个 token 不以
    /// `-` 开头时只遮那一个 token（值）；否则无法可靠区分“值”与“下一个开关”，
    /// 连尾巴一起隐藏（宁可少展示，不少脱敏）。返回新的下标。
    private static func appendSensitiveSwitchValue(
        switchText: String,
        tokens: [String],
        index: Int,
        masked: inout [String],
        marker: String
    ) -> Int {
        masked.append(switchText)
        masked.append(marker)
        let next = index + 1
        guard next < tokens.count, !tokens[next].hasPrefix("-") else { return tokens.count }
        return next + 1
    }

    /// 命令摘要：丢掉空参数与环境片段，token 级凭据脱敏，`LogRedactor` 整体脱敏，
    /// 折叠空白，截断到 `PiProcessRecord.commandSummaryLimit`。
    static func commandSummary(arguments: [String], redactor: LogRedactor) -> String {
        let tokens = arguments.filter { !$0.isEmpty && !isEnvironmentAssignment($0) }
        guard !tokens.isEmpty else { return "（无参数）" }
        let joined = maskSensitiveTokens(tokens).joined(separator: " ")
        let redacted = redactor.redact(joined)
        let collapsed = redacted.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        guard collapsed.count > PiProcessRecord.commandSummaryLimit else { return collapsed }
        return String(collapsed.prefix(PiProcessRecord.commandSummaryLimit)) + "…"
    }
}

/// 单个进程的分类结果。
enum PiProcessClassification: Equatable {
    case pi(PiProcessRecord)
    case notPi
    case unknown(PiProcessInspectionUnknown)
}
