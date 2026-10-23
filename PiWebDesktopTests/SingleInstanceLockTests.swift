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

    /// 真实进程活体检测（`kill(pid, 0)`）。已退出的 `sleep 0` 子进程必然死亡。
    /// 可执行镜像路径可注入：生产语义要求“存活 + 镜像 identical”两项都成立，
    /// 测试用假探针覆盖各种组合，不去启动真实实例。
    private func makeInspector(executablePath: String? = nil) -> ProcessInspector {
        ProcessInspector(
            runner: NeverRunningCommandRunner(),
            processExecutablePath: { _ in executablePath }
        )
    }

    private func makeLock(executablePath: String? = nil) -> SingleInstanceLock {
        SingleInstanceLock(
            pidRecordURL: pidURL,
            lockFileURL: lockURL,
            processInspector: makeInspector(executablePath: executablePath)
        )
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

    /// PID 记录不是身份证据：崩溃残留 + PID 复用会让文件里那个 PID 被无关进程
    /// 复用。旧实现在 `flock` 之前就凭它权威拒绝，结果是用户永久无法启动。
    /// 现在只有“存活 + 镜像与本应用相同”两项都成立才当作已有实例；拿不到镜像
    /// 证据就交给 `flock`——那才是权威互斥物。
    func testLivePidRecordOnlyBlocksWhenTheImageMatchesThisApplication() throws {
        FileManager.default.createFile(atPath: lockPath, contents: nil)
        let lockInode = try XCTUnwrap(inode(at: lockPath))
        // 用真实存活的子进程 PID（不是本进程）：本进程 PID 在记录里会被当作
        // “可能是我自己”并让给 flock，不能用来验证镜像比对分支。
        let liveChild = try spawnLiveProcess()
        defer { liveChild.terminate() }
        try writePIDRecord(liveChild.processIdentifier)

        // 镜像与本应用不同：不得凭 PID 记录拒绝，交给 flock。
        let foreign = makeLock(executablePath: "/usr/libexec/foreign-binary")
        XCTAssertTrue(foreign.acquire(), "镜像不匹配的 PID 记录不是身份证据，必须交给 flock 判定")
        foreign.release()
        XCTAssertEqual(inode(at: lockPath), lockInode, "获取不得动锁文件")

        // 镜像与本应用相同：这才是“另一个本应用实例”，可以快速拒绝。
        let own = makeLock(executablePath: SingleInstanceLock.currentExecutablePath)
        XCTAssertFalse(own.acquire(), "镜像相同的存活进程必须被识别为已有实例")
        XCTAssertNil(own.handle, "快速路径失败不得持有句柄")
        XCTAssertEqual(own.failure, .alreadyRunning)
        XCTAssertEqual(inode(at: lockPath), lockInode, "失败的获取不得动锁文件")
    }

    /// 一个真实在跑的短命子进程（`/bin/sleep 30`），测试结束时终止。
    private func spawnLiveProcess() throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["30"]
        try process.run()
        return process
    }

    /// 拿不到镜像路径时不认记录（宁可多试一次内核锁，也不要把用户挡在外面）。
    func testUnverifiablePidRecordFallsBackToFlock() throws {
        FileManager.default.createFile(atPath: lockPath, contents: nil)
        try writePIDRecord(ProcessInfo.processInfo.processIdentifier)

        let unverifiable = makeLock(executablePath: nil)
        XCTAssertTrue(unverifiable.acquire(), "拿不到镜像证据时必须交给 flock")
    }

    /// 真实持有的 flock 仍然权威：记录无法验证也不得双实例并行。
    func testFlockStillRefusesWhenThePidRecordIsUnverifiable() throws {
        let first = makeLock(executablePath: nil)
        XCTAssertTrue(first.acquire(), "首个实例拿到锁")
        XCTAssertTrue(first.isAcquired)

        try writePIDRecord(ProcessInfo.processInfo.processIdentifier)
        let second = makeLock(executablePath: nil)
        XCTAssertFalse(second.acquire(), "内核锁被持有时第二实例必须失败")
        XCTAssertEqual(second.failure, .alreadyRunning, "EWOULDBLOCK 是正常互斥，不是环境故障")
    }

    /// 锁文件打不开是环境故障，必须与“另一个实例在跑”区分开。
    ///
    /// 旧实现两者都返回 `false`，AppDelegate 于是对前者也静默退出：support
    /// 目录只读/被同名文件占据时，双击无任何提示，用户只能重装。
    func testUnopenableLockFileReportsAnEnvironmentalFailure() throws {
        // 用目录占据锁文件路径：open(O_RDWR) 必然失败（EISDIR）。
        try FileManager.default.createDirectory(at: lockURL, withIntermediateDirectories: true)

        let lock = makeLock()
        XCTAssertFalse(lock.acquire())
        guard case .lockUnavailable(let detail) = lock.failure else {
            return XCTFail("必须报环境故障，实际：\(String(describing: lock.failure))")
        }
        XCTAssertTrue(detail.contains("errno"), "原因里必须带 errno 便于支持排查：\(detail)")
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
