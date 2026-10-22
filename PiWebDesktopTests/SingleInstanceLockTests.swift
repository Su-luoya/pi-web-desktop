import XCTest

/// 单实例互斥的真实行为回归（生产实证 bug）。
///
/// 旧实现有两个复合缺陷：
/// 1. 锁文件是「`removeItem` + `createFile` 重建」，而 `createFile` 会**替换
///    inode**：在运行实例持着已删除 inode 的句柄，后续实例在新 inode 上拿到
///    互斥物 → 双实例并行；
/// 2. 第二实例因单实例检查退出时，`applicationWillTerminate` 无条件删除
///    `app.pid`，连带清掉正在运行实例的记录，让下一次启动的 PID 检查形同
///    虚设（实测生产实例 1278 的记录被第二实例退出时删除）。
///
/// 修复后的语义由这里的用例锁定：同一 inode 上的 `flock` 是权威互斥物、
/// 锁文件永不删除/重建、PID 记录只有写入者才删除。行为用例直接作用于
/// `SingleInstanceLock`（AppDelegate 家族不在测试 target 内，AppDelegate
/// 只做转发，转发接线由源码结构断言锁定）。
final class SingleInstanceLockTests: XCTestCase {
    private var supportURL: URL!
    private var logsRootURL: URL!

    override func setUpWithError() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("piwd-single-instance-\(UUID().uuidString)", isDirectory: true)
        supportURL = root.appendingPathComponent("Support", isDirectory: true)
        logsRootURL = root.appendingPathComponent("Logs", isDirectory: true)
        try FileManager.default.createDirectory(at: supportURL, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: supportURL.deletingLastPathComponent())
    }

    // MARK: - Fixtures

    private var pidURL: URL { supportURL.appendingPathComponent("app.pid") }
    private var lockURL: URL { supportURL.appendingPathComponent("instance.lock") }
    private var lockPath: String { lockURL.path }
    private var pidPath: String { pidURL.path }

    /// 真实进程活体检测（`kill(pid, 0)`）。本进程对自己必然存活；已退出的
    /// `sleep 0` 子进程必然死亡——两者覆盖默认探针的两条分支，不需要注入。
    private func makeInspector() -> ProcessInspector {
        ProcessInspector(runner: NeverRunningCommandRunner())
    }

    private func makeLock() -> SingleInstanceLock {
        SingleInstanceLock(pidRecordURL: pidURL, lockFileURL: lockURL, processInspector: makeInspector())
    }

    private func inode(at path: String) -> UInt64? {
        var status = stat()
        guard lstat(path, &status) == 0 else { return nil }
        return status.st_ino
    }

    /// 真实结束过的进程 PID：`kill(pid, 0)` 必定失败（僵尸已被回收）。
    private func deadProcessPID() throws -> pid_t {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["0"]
        try process.run()
        process.waitUntilExit()
        return process.processIdentifier
    }

    private func writePIDRecord(_ pid: pid_t) throws {
        try "\(pid)\n".write(toFile: pidPath, atomically: true, encoding: .utf8)
    }

    // MARK: - 内核互斥

    func testSecondAcquireFailsWhileFirstInstanceHoldsTheLock() throws {
        let first = makeLock()
        XCTAssertTrue(first.acquire(), "首个实例应当拿到锁")
        XCTAssertTrue(first.isAcquired)

        // 写入者负责记录 PID（生产里是 AppDelegate+PackageUpdates）。
        try writePIDRecord(ProcessInfo.processInfo.processIdentifier)

        let second = makeLock()
        XCTAssertFalse(second.acquire(), "flock 被首实例持有时，第二实例必须失败")
        XCTAssertFalse(second.isAcquired)
        XCTAssertNil(second.handle)

        // 首实例的记录不被第二实例破坏。
        XCTAssertEqual(try String(contentsOfFile: pidPath, encoding: .utf8),
                       "\(ProcessInfo.processInfo.processIdentifier)\n")
        XCTAssertTrue(FileManager.default.fileExists(atPath: lockPath))
    }

    func testReleasedLockIsReacquirable() {
        let first = makeLock()
        XCTAssertTrue(first.acquire())
        // 释放（等价于退出路径把句柄置 nil，内核随之释放 flock）。
        first.release()
        XCTAssertFalse(first.isAcquired)

        let second = makeLock()
        XCTAssertTrue(second.acquire(), "锁释放后新实例必须能拿到")
    }

    func testExistingLockFileKeepsItsInodeAcrossAcquisition() throws {
        // 预置一个历史锁文件：修复前的 createFile 重建会替换 inode。
        FileManager.default.createFile(atPath: lockPath, contents: nil)
        let originalInode = try XCTUnwrap(inode(at: lockPath))

        let lock = makeLock()
        XCTAssertTrue(lock.acquire())
        XCTAssertEqual(inode(at: lockPath), originalInode,
                       "锁文件必须保持同一 inode：flock 的互斥性依赖它")
    }

    // MARK: - PID 记录与锁的关系

    func testLivePidRecordBlocksAcquisitionBeforeTouchingTheLock() throws {
        FileManager.default.createFile(atPath: lockPath, contents: nil)
        let lockInode = try XCTUnwrap(inode(at: lockPath))
        try writePIDRecord(ProcessInfo.processInfo.processIdentifier)

        let lock = makeLock()
        XCTAssertFalse(lock.acquire(),
                       "PID 记录指向存活进程时必须直接失败")
        XCTAssertNil(lock.handle, "快速路径失败不得持有句柄")
        XCTAssertEqual(inode(at: lockPath), lockInode,
                       "失败的获取不得动锁文件（旧实现在这里删除重建）")
    }

    func testStalePidOfDeadProcessDoesNotBlockAcquisition() throws {
        try writePIDRecord(try deadProcessPID())

        let lock = makeLock()
        XCTAssertTrue(lock.acquire(),
                      "PID 记录指向已退出进程时，锁应当可以获取")
    }

    func testMissingPidRecordAllowsAcquisition() {
        let lock = makeLock()
        XCTAssertTrue(lock.acquire())
    }

    // MARK: - 源码结构断言（防止修复被无意回退）

    func testWillTerminateOnlyRemovesAPidRecordThisProcessWrote() throws {
        let family = SourceScan.codeText(of: try SourceScan.text(ofFamily: "AppDelegate"))
        XCTAssertTrue(family.contains("if ownsPIDRecord {"),
                      "applicationWillTerminate 必须用 ownsPIDRecord 保护 app.pid 的删除")
        XCTAssertFalse(
            family.range(of: "stopHealthMonitor()\\s*\\n\\s*try\\? FileManager\\.default\\.removeItem\\(at: appConfiguration\\.appPIDURL\\)",
                         options: .regularExpression) != nil,
            "不允许恢复「无条件删除 app.pid」的旧实现")

        let packageUpdates = SourceScan.codeText(of: try SourceScan.text(ofFamily: "AppDelegate+PackageUpdates"))
        XCTAssertTrue(packageUpdates.contains("ownsPIDRecord = true"),
                      "写入 app.pid 成功后必须标记 ownsPIDRecord，退出清理才认领这条记录")
    }

    func testLockAcquisitionUsesFlockAndNeverReplacesTheLockFile() throws {
        let quit = SourceScan.codeText(of: try SourceScan.text(ofFamily: "AppDelegate+Quit"))
        XCTAssertTrue(quit.contains("SingleInstanceLock("),
                      "AppDelegate 必须经由 SingleInstanceLock 获取互斥（保持可测试接线）")
        XCTAssertTrue(quit.contains("instanceLockHandle = lock.handle"),
                      "锁句柄必须接入 AppDelegate 的释放路径")
        XCTAssertTrue(quit.contains("hasInstanceLock = true"),
                      "成功后必须标记 hasInstanceLock，退出路径才释放句柄")

        let lockSource = SourceScan.codeText(of: try SourceScan.text(named: "SingleInstanceLock.swift"))
        XCTAssertTrue(lockSource.contains("flock("), "单实例互斥必须依赖内核 flock")
        XCTAssertTrue(lockSource.contains("O_CREAT"), "锁文件必须用 open(O_CREAT) 打开")
        XCTAssertFalse(lockSource.contains("removeItem"), "删除锁文件会让在运行实例持已删除 inode，禁止")
        XCTAssertFalse(lockSource.contains("createFile"), "createFile 会替换 inode（实测），必须用 open(O_CREAT) 打开同一 inode")
    }
}

// MARK: - 测试替身

/// 永不执行命令的 runner：本文件的行为用例不触发任何子进程。
private final class NeverRunningCommandRunner: CommandRunning {
    func run(_ arguments: [String]) -> String? { nil }
}
