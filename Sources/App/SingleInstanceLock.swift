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

    init(pidRecordURL: URL, lockFileURL: URL, processInspector: ProcessInspector) {
        self.pidRecordURL = pidRecordURL
        self.lockFileURL = lockFileURL
        self.processInspector = processInspector
    }

    /// 尝试取得互斥。
    ///
    /// 顺序约束：PID 记录指向存活进程时**必须先失败**，不得触碰锁文件
    ///（旧实现在这里删除重建锁文件，破坏了在运行实例的锁）。锁文件用
    /// `open(O_CREAT)` 打开已存在路径时保持同一 inode。
    func acquire() -> Bool {
        let existingPID = (try? String(contentsOf: pidRecordURL, encoding: .utf8))
            .flatMap { ProcessInspector.parsePIDRecord($0) }
        if let existingPID, processInspector.isProcessAlive(existingPID) {
            return false
        }
        let descriptor = open(lockFileURL.path, O_RDWR | O_CREAT, 0o600)
        guard descriptor >= 0 else { return false }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            return false
        }
        handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        return true
    }

    /// 释放互斥：关闭句柄，内核随之释放 `flock`。幂等。
    func release() {
        handle = nil
    }
}
