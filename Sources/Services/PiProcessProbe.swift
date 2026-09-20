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

/// Raw libproc process facts and the read-only Pi process probe.

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
