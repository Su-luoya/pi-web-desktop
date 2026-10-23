/// Single-instance mutex: authoritative mutual exclusion via a kernel `flock`
/// on one stable lock-file inode.

import Darwin
import Foundation

/// 单实例互斥（真实内核锁）：PID 记录只用于错误信息与快速路径，权威互斥靠
/// 同一 inode 上的 `flock`（进程死亡时由内核自动释放，含 SIGKILL）。
///
/// 独立成类型的原因：这段逻辑挂在 `AppDelegate` 上时无法被测试 target 覆盖
///（AppDelegate 家族被有意排除在 Test Sources 之外）。抽出后行为用例直接
/// 作用于本类型，AppDelegate 只做转发。
///
/// 历史 bug（生产实证）：旧实现用 `FileManager.createFile` 重建锁文件——
/// 它会**替换 inode**（同理，先 `removeItem` 再重建也一样），在运行实例于是
/// 持着已删除 inode 的锁；后续实例在新 inode 上拿到锁、形成双实例。现在
/// `open(O_CREAT)` 对已存在文件只打开同一 inode，永不替换；配合 `flock`
/// 后，即使 PID 记录被竞态或外部破坏，互斥仍然成立。
final class SingleInstanceLock {
    private let pidRecordURL: URL
    private let lockFileURL: URL
    private let processInspector: ProcessInspector

    /// `flock` 成功后由本对象持有的句柄；`closeOnDealloc` 保证句柄释放时
    /// fd 被关闭、内核随之释放锁。`release`/置 nil 即释放。
    private(set) var handle: FileHandle?

    /// 锁是否被本对象持有。
    var isAcquired: Bool { handle != nil }

    /// 上一次 `acquire()` 失败的具体原因（成功时为 nil）。
    ///
    /// 调用方必须能区分“另一个实例在跑”（正常拒绝）与“锁文件打不开”（环境
    /// 故障）：旧实现两者都返回 `false`，AppDelegate 于是对后者也静默退出——
    /// support 目录只读/被同名文件占据时，双击无任何提示，用户只能重装。
    private(set) var failure: Failure?

    enum Failure: Equatable {
        /// 已有一个本应用实例持有互斥。
        case alreadyRunning
        /// 锁文件无法打开（权限、目录被文件占据等），或内核拒绝加锁。
        case lockUnavailable(detail: String)
    }

    init(pidRecordURL: URL, lockFileURL: URL, processInspector: ProcessInspector) {
        self.pidRecordURL = pidRecordURL
        self.lockFileURL = lockFileURL
        self.processInspector = processInspector
    }

    /// 尝试取得互斥。
    ///
    /// 顺序约束：PID 记录指向**本应用**的存活进程时先失败，不碰锁文件（旧实现
    /// 在这里删除重建锁文件，破坏了在运行实例的锁）。锁文件用 `open(O_CREAT)`
    /// 打开已存在路径时保持同一 inode。
    ///
    /// PID 记录不是身份证据（崩溃残留 + PID 复用 → 永久无法启动：文件里那个
    /// PID 可能早已被任意无关进程复用，旧实现在 `flock` 之前就凭它权威拒绝）。
    /// 因此这里只在记录**同时**通过两项校验时才当作“已有实例”：进程存活 +
    /// 可执行镜像与本应用相同。任一项拿不到证据就交给 `flock` 判定——那才是
    /// 权威互斥物，且在进程死亡（含 SIGKILL）时由内核自动释放。
    func acquire() -> Bool {
        if let existingPID = recordedPID(), isThisApplication(existingPID) {
            failure = .alreadyRunning
            return false
        }
        let descriptor = open(lockFileURL.path, O_RDWR | O_CREAT, 0o600)
        guard descriptor >= 0 else {
            failure = .lockUnavailable(detail: "无法打开锁文件（errno \(errno)）：\(lockFileURL.path)")
            return false
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            close(descriptor)
            // EWOULDBLOCK 是“已有实例持有锁”的正常互相斥，其余 errno 是环境故障。
            failure = code == EWOULDBLOCK
                ? .alreadyRunning
                : .lockUnavailable(detail: "无法取得文件锁（errno \(code)）：\(lockFileURL.path)")
            return false
        }
        handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        failure = nil
        return true
    }

    /// PID 记录里的 PID（文件缺失/为空/不可解析时为 nil）。
    private func recordedPID() -> pid_t? {
        (try? String(contentsOf: pidRecordURL, encoding: .utf8))
            .flatMap { ProcessInspector.parsePIDRecord($0) }
    }

    /// 该 PID 是否能证明“它就是本应用的另一个实例”。
    ///
    /// 要求存活 **且** 可执行镜像与本进程相同（`proc_pidpath` 对当前用户的进程
    /// 有效）。拿不到镜像路径时不认（交给 `flock`）：宁可多试一次内核锁，也不要
    /// 因无法验证的旧记录把用户永久挡在应用外。
    private func isThisApplication(_ pid: pid_t) -> Bool {
        // 本进程 PID 出现在记录里不代表“另一个实例”（可能是崩溃残留 + PID 复用，
        // 也可能是本进程自己写的），交给 `flock` 判定。
        guard pid > 1, pid != ProcessInfo.processInfo.processIdentifier else { return false }
        guard processInspector.isProcessAlive(pid) else { return false }
        return processInspector.executablePath(of: pid) == Self.currentExecutablePath
    }

    /// 本进程的可执行镜像路径（用于与 PID 记录比对）。
    ///
    /// 暴露成 static 是为了测试能注入“同镜像的活进程”而不用拿本进程 PID
    /// （本进程 PID 在记录里意味着“就是我自己”，快速路径应当让给 `flock`）。
    static var currentExecutablePath: String? {
        if let bundlePath = Bundle.main.executableURL?.resolvingSymlinksInPath().path {
            return bundlePath
        }
        return ProcessInfo.processInfo.arguments.first.map {
            URL(fileURLWithPath: $0).resolvingSymlinksInPath().path
        }
    }

    /// 释放互斥：关闭句柄，内核随之释放 `flock`。幂等。
    func release() {
        handle = nil
    }
}
