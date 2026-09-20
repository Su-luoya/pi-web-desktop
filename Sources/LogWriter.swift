import Darwin
import Foundation

/// 日志轮转策略（GitHub #10）。
///
/// 默认值与文档一致：单文件上限 10 MB，保留 5 份轮转文件；阈值与份数都可注入，
/// 因此单元测试用很小的阈值就能反复演练真实的轮转路径。
struct LogRotationPolicy: Equatable {
    static let defaultMaximumBytes = 10 * 1024 * 1024
    static let defaultRetainedFileCount = 5

    /// 单个日志文件达到该字节数后轮转。
    var maximumBytes: Int
    /// 保留的轮转文件份数（`Pi Web Desktop.1.log` … `Pi Web Desktop.N.log`）。
    var retainedFileCount: Int

    static let standard = LogRotationPolicy()

    init(
        maximumBytes: Int = LogRotationPolicy.defaultMaximumBytes,
        retainedFileCount: Int = LogRotationPolicy.defaultRetainedFileCount
    ) {
        self.maximumBytes = max(1, maximumBytes)
        self.retainedFileCount = max(1, retainedFileCount)
    }
}

/// 统一日志写入器（GitHub #10、#73）。
///
/// 位置来自 #9 的 `AppPaths`（`~/Library/Logs/Pi Web Desktop/`），本类不自己拼路径：
/// 调用方传入 `appConfiguration.logURL`，测试传入临时目录。
///
/// 职责：
/// - 按大小轮转（`Pi Web Desktop.log` → `.1.log`，依次后移，超出保留份数的丢弃）；
/// - 应用侧写入的每一行都经过注入的 `LogRedactor`（同一个实例贯穿日志、诊断、
///   错误消息与环境变量/命令行展示）；
/// - 子进程的 stdout/stderr 接在**管道**上（不是日志文件），由应用侧在专用队列上
///   读管道 → 脱敏 → 追加写文件。轮转只改名/新建应用侧打开的文件，子进程持有的
///   是一个与文件无关的管道写端，因此轮转后子进程的输出不会写进旧 inode；
/// - 所有写入都经 `O_APPEND` 的同一个句柄（单一串行写入队列），不存在
///   `seekToEnd` 与应用/子进程两侧互相覆盖的窗口；
/// - 打开子进程日志句柄前，把已存在的日志就地脱敏一次（历史残留的秘密不会因为
///   “这一轮没打印”而留在文件里）；这一步在后台队列上完成，不阻塞启动路径；
/// - 任何写入/轮转/打开失败都只记录在 `failureDescription` 里，绝不抛出到调用方
///   之外、绝不崩溃；`openChildOutput()` 例外，它把错误抛给启动路径，由启动路径
///   给出可读失败提示（日志位置不可用的子进程不该被启动）。
///
/// 线程安全：所有文件 I/O（写入、轮转、脱敏、句柄管理）都在一个串行队列上，
/// 应用侧可以从任意线程调用；读取子进程管道的线程只做“读取 + 脱敏 + 入队”。
final class LogWriter {
    /// 一次失败的记录（已经过脱敏）。诊断导出读取它，用于说明“日志写入是否正常”。
    struct Failure: Equatable {
        var message: String
        var occurredAt: String
    }

    enum WriterError: LocalizedError, Equatable {
        case cannotCreateLogDirectory(String)
        case cannotCreateLogFile(String)
        case cannotOpenLogFile(String)
        case cannotCreateChildOutputPipe(Int32)
        case cannotStartChildOutputDrainer(Int32)

        var errorDescription: String? {
            switch self {
            case .cannotCreateLogDirectory(let path): return "无法创建日志目录：\(path)"
            case .cannotCreateLogFile(let path): return "无法创建日志文件：\(path)"
            case .cannotOpenLogFile(let path): return "无法打开日志文件：\(path)"
            case .cannotCreateChildOutputPipe(let code): return "无法创建子进程输出管道（错误码 \(code)）"
            case .cannotStartChildOutputDrainer(let code):
                return "无法启动子进程输出排空进程 /bin/cat（错误码 \(code)）"
            }
        }
    }

    let logFileURL: URL
    let policy: LogRotationPolicy
    let redactor: LogRedactor

    private let fileManager: FileManager
    private let now: () -> Date

    /// 唯一的日志 I/O 队列：追加、轮转、脱敏、打开/关闭句柄都排在这里，写入之间
    /// 不存在并发，也就没有“两个偏移互相覆盖”的可能。
    private let queue: DispatchQueue
    private let queueKey = DispatchSpecificKey<UInt8>()
    /// 每个子进程输出管道自己的读取队列键：避免在读取队列上重入同步读取（自死锁）。
    private let readerQueueKey = DispatchSpecificKey<UInt8>()

    /// 待处理的工作项数量。队列空闲时 `append`/`record` 同步提交（调用返回时已经
    /// 落盘，既有调用方与测试的语义不变）；队列繁忙（后台历史脱敏、轮转或大量
    /// 子进程输出）时异步排队，调用方（含主线程）绝不被后台工作阻塞。
    private let counterLock = NSLock()
    private var pendingWork = 0

    /// 失败记录。用独立的小锁保护：诊断随时可读，不会被慢 I/O 挡住。
    private let failureLock = NSLock()
    private var lastFailure: Failure?

    /// 当前子进程输出管道（如果有）。读端在读取队列上自行收尾，这里的引用只用于
    /// 下一次打开时取消上一个管道，因此用独立锁保护。`childOutputFinished` 表示
    /// 最近一个管道已经读到 EOF/失败并且读端已排空（测试与诊断的同步点）。
    private let pipeLock = NSLock()
    private var childPipe: ChildOutputPipe?
    private var childOutputFinished = true

    // MARK: - 只在 `queue` 上访问的状态

    /// 当前日志文件的 `O_APPEND` 写句柄。轮转/外部替换后失效，下一次写入重新打开。
    private var writerHandle: FileHandle?
    private var writerIdentity: FileIdentity?
    /// 当前日志开头那条“日志已轮转”说明的字节数：它不计入大小上限，避免用极小
    /// 阈值轮转时说明行本身把新文件立刻推过阈值。
    private var rotationNoteBytes = 0
    /// 本实例是否还需要对当前日志做一次历史脱敏。首次打开子进程句柄时做一次；
    /// 此后写进这个文件（以及轮转出的新文件）的每一行都由本实例脱敏过。
    private var needsHistoricalScrub = true

    /// 每个读取块的上限，同时是“没有换行的超长行”的强制切块阈值。
    private static let childReadChunkBytes = 64 * 1024
    /// 子进程输出在写入队列里最多排队的块数。读端超过它就停下来等，管道随后对
    /// 子进程形成背压；内存占用因此有上限（约 4 MB），而不是随输出无限增长。
    private static let childPipeCapacityChunks = 64
    /// 历史脱敏的流式读取块。
    private static let scrubChunkBytes = 256 * 1024

    init(
        logFileURL: URL,
        policy: LogRotationPolicy = .standard,
        fileManager: FileManager = .default,
        redactor: LogRedactor = LogRedactor(),
        now: @escaping () -> Date = Date.init
    ) {
        self.logFileURL = logFileURL
        self.policy = policy
        self.fileManager = fileManager
        self.redactor = redactor
        self.now = now
        self.queue = DispatchQueue(
            label: "io.github.su-luoya.pi-web-desktop.log-writer",
            qos: .utility
        )
        queue.setSpecific(key: queueKey, value: 1)
    }

    deinit {
        // 队列上的工作项都强引用 self，因此这里不会有排队项还在等状态。
        stopCurrentChildPipe()
        closeWriterHandle()
    }

    /// 第 `index` 份轮转文件（`index >= 1`）。
    static func rotatedFileURL(for logFileURL: URL, index: Int) -> URL {
        let directory = logFileURL.deletingLastPathComponent()
        let base = logFileURL.deletingPathExtension().lastPathComponent
        let pathExtension = logFileURL.pathExtension
        let name = pathExtension.isEmpty ? "\(base).\(index)" : "\(base).\(index).\(pathExtension)"
        return directory.appendingPathComponent(name)
    }

    /// `yyyy-MM-dd HH:mm:ss`（本地时区）。时间源可注入，测试断言固定时钟。
    static func timestamp(for date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }

    /// 上次写入/轮转失败的可读描述；nil 表示没有失败记录。诊断导出使用它。
    var failureDescription: String? {
        failureLock.lock()
        defer { failureLock.unlock() }
        return lastFailure.map { "\($0.occurredAt) \($0.message)" }
    }

    /// 最近一次子进程输出是否已经读到 EOF（或读取失败）并排空。调用方看到 true 后
    /// 再 `flush()` 就能保证管道里的内容已经进入日志，不必靠 sleep。
    var childOutputIsDrained: Bool {
        pipeLock.lock()
        defer { pipeLock.unlock() }
        return childOutputFinished
    }

    /// 诊断文本里的“日志写入”一行的值。
    var writeStatusDescription: String {
        failureDescription.map { "写入失败（\($0)）" } ?? "正常"
    }

    /// 追加文本（可多行）。逐行脱敏后写入。
    ///
    /// 返回值表示“是否已接受写入”：空输入返回 `true` 且不写文件；后台队列繁忙时
    /// 写入会排队执行，实际结果（含磁盘满、权限错误、轮转失败）记录在
    /// `failureDescription` 里，绝不静默。
    @discardableResult
    func append(_ text: String) -> Bool {
        guard !text.isEmpty else { return true }
        // 脱敏在调用线程完成：写入队列只做文件 I/O，队列长度不会放大单次写入成本。
        let payload = Data(redactor.redact(text).utf8)
        submit(synchronousWhenIdle: true) { self.writeOnQueue(payload) }
        return true
    }

    /// 追加一条带时间戳的应用事件行，例如“服务已启动：PID 4321”。
    @discardableResult
    func record(_ event: String) -> Bool {
        guard !event.isEmpty else { return true }
        return append("[\(Self.timestamp(for: now()))] \(event)")
    }

    /// 等写入队列排空。测试与需要落盘屏障的调用方使用；不能从写入队列内部调用。
    func flush() {
        guard DispatchQueue.getSpecific(key: queueKey) == nil else { return }
        queue.sync {}
    }

    /// 为子进程的 stdout/stderr 准备输出通道：建目录、确认日志文件可打开、创建
    /// 管道并启动读取端，然后返回**管道写端**（调用方把它交给子进程，并负责关闭）。
    ///
    /// 启动路径只做 O(1) 的目录/文件检查与管道创建，**不等写入队列**：历史日志
    /// 脱敏与大小轮转排在队列上稍后执行，它们在调用返回后、任何后续写入之前完成，
    /// 因此 10 MB 级的重写不会阻塞启动（GitHub #73 / M5）。
    func openChildOutput() throws -> FileHandle {
        do {
            try createLogDirectory()
        } catch {
            recordFailure(operation: "创建日志目录失败", error: error)
            throw WriterError.cannotCreateLogDirectory(logFileURL.deletingLastPathComponent().path)
        }
        do {
            try verifyLogFileIsWritable()
        } catch {
            recordFailure(operation: Self.operationName(for: error), error: error)
            throw (error as? WriterError) ?? WriterError.cannotOpenLogFile(logFileURL.path)
        }
        let writeHandle: FileHandle
        do {
            writeHandle = try makeChildOutputPipe()
        } catch {
            recordFailure(operation: "创建子进程输出管道失败", error: error)
            throw (error as? WriterError) ?? WriterError.cannotOpenLogFile(logFileURL.path)
        }
        // 历史脱敏 → 轮转 → 之后的写入，三者在同一个串行队列上按顺序发生。
        enqueue { self.prepareLogOnQueue() }
        return writeHandle
    }

    /// 就地脱敏已存在的日志文件（分块读取、逐行脱敏、临时文件 + 改名）。非 UTF-8
    /// 内容不做猜测，保持原样。失败只记录。返回值语义与 `append` 相同：队列空闲时
    /// 同步执行并返回真实结果，排队时返回“已接受”。
    @discardableResult
    func scrubExistingLog() -> Bool {
        var result = true
        submit(synchronousWhenIdle: true) { result = self.scrubOnQueue() }
        return result
    }

    // MARK: - 队列调度

    /// 把工作交给写入队列并计数。`synchronousWhenIdle` 为 true 且队列空闲时同步
    /// 执行（调用返回时结果已产生），否则异步排队，调用方立即返回。
    private func submit(synchronousWhenIdle: Bool, _ work: @escaping () -> Void) {
        counterLock.lock()
        pendingWork += 1
        let wasIdle = pendingWork == 1
        counterLock.unlock()
        let run = {
            work()
            self.counterLock.lock()
            self.pendingWork -= 1
            self.counterLock.unlock()
        }
        // 已经在写入队列上（将来若有内部调用走公共 API）直接执行，避免自死锁。
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            run()
        } else if synchronousWhenIdle && wasIdle {
            queue.sync(execute: run)
        } else {
            queue.async(execute: run)
        }
    }

    /// 排到写入队列后面执行，调用方不等。
    private func enqueue(_ work: @escaping () -> Void) {
        submit(synchronousWhenIdle: false, work)
    }

    // MARK: - 写入队列内部实现

    private func prepareLogOnQueue() {
        if needsHistoricalScrub {
            _ = scrubOnQueue()
        }
        rotateIfNeededOnQueue()
    }

    private func writeOnQueue(_ data: Data) {
        do {
            try createLogDirectory()
        } catch {
            recordFailure(operation: "创建日志目录失败", error: error)
            return
        }
        // 轮转失败不阻断写入：文件可能超出上限，但这一行仍然要落下。
        rotateIfNeededOnQueue()
        do {
            let handle = try writerHandleOnQueue()
            try handle.write(contentsOf: data)
        } catch {
            closeWriterHandle()
            recordFailure(operation: Self.operationName(for: error), error: error)
        }
    }

    /// 失败记录里的操作名：错误类型决定可读的“哪一步失败了”。
    private static func operationName(for error: Error) -> String {
        guard let writerError = error as? WriterError else { return "写入日志失败" }
        switch writerError {
        case .cannotCreateLogDirectory: return "创建日志目录失败"
        case .cannotCreateLogFile: return "创建日志文件失败"
        case .cannotOpenLogFile: return "打开日志文件失败"
        case .cannotCreateChildOutputPipe: return "创建子进程输出管道失败"
        case .cannotStartChildOutputDrainer: return "启动子进程输出排空进程失败"
        }
    }

    private func createLogDirectory() throws {
        try fileManager.createDirectory(
            at: logFileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
    }

    /// 启动路径上的可写性检查：日志文件不存在就创建，不开通就报可读错误。不缓存
    /// 句柄（真正的 `O_APPEND` 句柄在写入队列上惰性打开），因此不依赖队列状态。
    private func verifyLogFileIsWritable() throws {
        let path = logFileURL.path
        if !fileManager.fileExists(atPath: path),
           !fileManager.createFile(atPath: path, contents: nil) {
            throw WriterError.cannotCreateLogFile(path)
        }
        let descriptor = open(path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0o644)
        guard descriptor >= 0 else { throw WriterError.cannotOpenLogFile(path) }
        close(descriptor)
    }

    /// 当前日志文件的 `O_APPEND` 句柄。路径被改名/删除/替换（例如轮转、外部清理）
    /// 时旧句柄会指向别的 inode，这里按 inode 校验并重新打开，避免继续写进一个
    /// 已经不可见的旧文件。
    private func writerHandleOnQueue() throws -> FileHandle {
        if let handle = writerHandle, writerHandleIsCurrent(handle) {
            return handle
        }
        closeWriterHandle()
        let path = logFileURL.path
        if !fileManager.fileExists(atPath: path),
           !fileManager.createFile(atPath: path, contents: nil) {
            throw WriterError.cannotCreateLogFile(path)
        }
        // O_APPEND：追加位置由内核维护，多个写入方（应用侧各线程与应用侧唯一的
        // 写入队列）永远不会互相覆盖或丢行，也不需要 seekToEnd。
        let descriptor = open(path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0o644)
        guard descriptor >= 0 else { throw WriterError.cannotOpenLogFile(path) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        writerHandle = handle
        writerIdentity = Self.fileIdentity(ofDescriptor: descriptor)
        return handle
    }

    private func closeWriterHandle() {
        try? writerHandle?.close()
        writerHandle = nil
        writerIdentity = nil
    }

    private func writerHandleIsCurrent(_ handle: FileHandle) -> Bool {
        guard let known = writerIdentity, let current = pathIdentity() else { return false }
        return current == known
    }

    private func currentFileSizeOnQueue() -> Int {
        guard let attributes = try? fileManager.attributesOfItem(atPath: logFileURL.path),
              let size = attributes[.size] as? NSNumber else { return 0 }
        return size.intValue
    }

    /// 按大小轮转：当前日志 → `.1`，`.1` → `.2`，…，超出保留份数的删除，然后新建
    /// 空文件并在新文件里写一条“日志已轮转”说明（轮转在日志里可见）。
    ///
    /// 轮转只影响应用侧打开的句柄：子进程的 stdout/stderr 是管道，与文件无关，
    /// 所以这里改名/删除不会让任何输出落进旧 inode。失败只记录：日志继续追加到
    /// 当前（超限的）文件，写入不中断。
    private func rotateIfNeededOnQueue() {
        let size = currentFileSizeOnQueue()
        guard size - rotationNoteBytes >= policy.maximumBytes else { return }
        do {
            if policy.retainedFileCount >= 2 {
                for index in stride(from: policy.retainedFileCount, through: 2, by: -1) {
                    let source = Self.rotatedFileURL(for: logFileURL, index: index - 1)
                    guard fileManager.fileExists(atPath: source.path) else { continue }
                    let destination = Self.rotatedFileURL(for: logFileURL, index: index)
                    if fileManager.fileExists(atPath: destination.path) {
                        try fileManager.removeItem(at: destination)
                    }
                    try fileManager.moveItem(at: source, to: destination)
                }
            }
            let first = Self.rotatedFileURL(for: logFileURL, index: 1)
            if fileManager.fileExists(atPath: first.path) {
                try fileManager.removeItem(at: first)
            }
            // 句柄即将跟着文件名走：先关上，下一次写入按新路径重新打开。
            closeWriterHandle()
            try fileManager.moveItem(at: logFileURL, to: first)
            if !fileManager.createFile(atPath: logFileURL.path, contents: nil) {
                throw WriterError.cannotCreateLogFile(logFileURL.path)
            }
            rotationNoteBytes = 0
            writeRotationNoteOnQueue(to: first)
        } catch {
            closeWriterHandle()
            recordFailure(operation: "轮转日志失败", error: error)
        }
    }

    /// 在新日志开头写下轮转说明。直接写（不再检查轮转），它自身不计入大小上限。
    private func writeRotationNoteOnQueue(to rotatedFileURL: URL) {
        let note = "[\(Self.timestamp(for: now()))] 日志已轮转："
            + "\(logFileURL.lastPathComponent) → \(rotatedFileURL.lastPathComponent)"
            + "（保留 \(policy.retainedFileCount) 份）\n"
        let data = Data(redactor.redact(note).utf8)
        do {
            let handle = try writerHandleOnQueue()
            try handle.write(contentsOf: data)
            rotationNoteBytes = data.count
        } catch {
            closeWriterHandle()
            recordFailure(operation: "写入日志失败", error: error)
        }
    }

    /// 流式就地脱敏：分块读、按行脱敏、写同目录临时文件，最后改名覆盖。整份日志
    /// 不会被一次性读进内存；非 UTF-8 内容保持原样。返回 false 表示这次没有完成
    /// （已记录失败），调用方可以下次重试。
    private func scrubOnQueue() -> Bool {
        let path = logFileURL.path
        guard let attributes = try? fileManager.attributesOfItem(atPath: path),
              let size = (attributes[.size] as? NSNumber)?.intValue, size > 0 else {
            needsHistoricalScrub = false
            return true
        }
        needsHistoricalScrub = false
        let temporaryURL = logFileURL.deletingLastPathComponent()
            .appendingPathComponent(".\(logFileURL.lastPathComponent).scrub-\(UUID().uuidString)")
        guard fileManager.createFile(atPath: temporaryURL.path, contents: nil) else {
            needsHistoricalScrub = true
            recordFailure(
                operation: "脱敏历史日志失败",
                error: WriterError.cannotCreateLogFile(temporaryURL.path)
            )
            return false
        }
        defer { try? fileManager.removeItem(at: temporaryURL) }
        guard let input = try? FileHandle(forReadingFrom: logFileURL),
              let output = try? FileHandle(forWritingTo: temporaryURL) else {
            needsHistoricalScrub = true
            recordFailure(
                operation: "脱敏历史日志失败",
                error: WriterError.cannotOpenLogFile(path)
            )
            return false
        }
        defer {
            try? input.close()
            try? output.close()
        }

        var changed = false
        var pending = Data()
        do {
            while true {
                let chunk = try input.read(upToCount: Self.scrubChunkBytes) ?? Data()
                if chunk.isEmpty { break }
                pending.append(chunk)
                guard let newline = pending.lastIndex(of: UInt8(ascii: "\n")) else { continue }
                let end = pending.index(after: newline)
                let complete = Data(pending[..<end])
                pending = Data(pending[end...])
                guard let text = String(data: complete, encoding: .utf8) else {
                    // 非 UTF-8：不猜测、不重写，保持原样（与旧实现一致）。
                    return true
                }
                let redacted = redactor.redact(text)
                if redacted != text { changed = true }
                try output.write(contentsOf: Data(redacted.utf8))
            }
            if !pending.isEmpty {
                guard let text = String(data: pending, encoding: .utf8) else { return true }
                let redacted = redactor.redact(text)
                if redacted != text { changed = true }
                try output.write(contentsOf: Data(redacted.utf8))
            }
            try output.synchronize()
        } catch {
            needsHistoricalScrub = true
            recordFailure(operation: "脱敏历史日志失败", error: error)
            return false
        }
        guard changed else {
            // 没有需要替换的内容：不动原文件（mtime 不变）。
            return true
        }
        do {
            closeWriterHandle()
            if fileManager.fileExists(atPath: path) {
                try fileManager.removeItem(at: logFileURL)
            }
            try fileManager.moveItem(at: temporaryURL, to: logFileURL)
            return true
        } catch {
            needsHistoricalScrub = true
            recordFailure(operation: "脱敏历史日志失败", error: error)
            return false
        }
    }

    // MARK: - 子进程输出管道

    /// 子进程 stdout/stderr 的管道（GitHub #73）。
    ///
    /// 写端交给子进程（经 `dup2` 成为它的 1/2），读端由 `LogWriter` 在专用串行队列
    /// 上排空：读取 → 按行切分 → 脱敏 → 交给写入队列。管道与日志文件无关，轮转
    /// （改名 + 新建）永远不会让子进程的输出落到旧 inode。
    private final class ChildOutputPipe {
        let writeHandle: FileHandle
        let readDescriptor: Int32
        let readerQueue: DispatchQueue
        let capacity = DispatchSemaphore(value: LogWriter.childPipeCapacityChunks)
        var source: DispatchSourceRead?
        /// 只在读取队列上访问。
        var pendingLine = Data()

        private let stateLock = NSLock()
        private var stopped = false

        init(writeHandle: FileHandle, readDescriptor: Int32, readerQueue: DispatchQueue) {
            self.writeHandle = writeHandle
            self.readDescriptor = readDescriptor
            self.readerQueue = readerQueue
        }

        /// 取消读取端（幂等）。取消处理器关闭读端 fd；子进程持有的写端不受影响。
        func stop() {
            stateLock.lock()
            let alreadyStopped = stopped
            stopped = true
            stateLock.unlock()
            guard !alreadyStopped else { return }
            source?.cancel()
        }
    }

    /// 接管当前管道：置空、标记已排空（必须先于新管道建立），返回旧管道。
    private func takeCurrentChildPipe() -> ChildOutputPipe? {
        pipeLock.lock()
        defer { pipeLock.unlock() }
        let pipe = childPipe
        childPipe = nil
        childOutputFinished = true
        return pipe
    }

    private func stopCurrentChildPipe() {
        takeCurrentChildPipe()?.stop()
    }

    /// 启动新管道前处理旧管道：先把已经缓冲在管道里的输出同步读干净（在读取队列
    /// 上执行，不会与读取处理器并发），再取消读端。否则“子进程刚写完、应用侧还没
    /// 读”的最后几行会随着取消一起被丢掉（例如健康监控在毫秒级重启服务）。
    private func drainAndStopCurrentChildPipe() {
        guard let pipe = takeCurrentChildPipe() else { return }
        if DispatchQueue.getSpecific(key: readerQueueKey) != nil {
            drainChildOutputOnReaderQueue(pipe)
        } else {
            pipe.readerQueue.sync { self.drainChildOutputOnReaderQueue(pipe) }
        }
        pipe.stop()
    }

    /// 在读取队列上把管道里已经缓冲的数据读尽，并且把尾部的半行也交出去。
    /// 读取队列自己不会因为 `EAGAIN` 丢掉半行，但“不再读取这个管道”时必须交出去，
    /// 否则子进程刚写、还没换行的最后一段会随着取消一起消失。
    private func drainChildOutputOnReaderQueue(_ pipe: ChildOutputPipe) {
        readChildOutput(pipe)
        emitChildOutput(pipe, endOfStream: true)
    }

    private func stopChildPipe(_ pipe: ChildOutputPipe) {
        pipe.stop()
        pipeLock.lock()
        // 只有当前管道收尾才算“已排空”：旧管道被新管道取代后不得覆盖新管道的状态。
        if childPipe === pipe {
            childPipe = nil
            childOutputFinished = true
        }
        pipeLock.unlock()
    }

    /// 创建子进程输出管道并启动读取端，返回管道写端。目录/文件的可写性由
    /// `openChildOutput()` 在调用前保证；这里只做 O(1) 的 fd 操作，不等写入队列。
    private func makeChildOutputPipe() throws -> FileHandle {
        // 上一个管道（如果有）先读干净再取消，避免重启时既丢尾部输出、又留下一个
        // 再也读不到 EOF 的读端。
        drainAndStopCurrentChildPipe()

        var descriptors: [Int32] = [0, 0]
        guard pipe(&descriptors) == 0 else {
            throw WriterError.cannotCreateChildOutputPipe(errno)
        }
        let readDescriptor = descriptors[0]
        let writeDescriptor = descriptors[1]
        // 读端只属于应用：CLOEXEC 保证它不会被任何子进程继承（生产启动器还用
        // POSIX_SPAWN_CLOEXEC_DEFAULT 兜底）。写端的 CLOEXEC 在 dup2 到 1/2 时
        // 由内核清除，因此不影响子进程的 stdout/stderr。
        _ = fcntl(readDescriptor, F_SETFD, FD_CLOEXEC)
        _ = fcntl(writeDescriptor, F_SETFD, FD_CLOEXEC)
        _ = fcntl(readDescriptor, F_SETFL, O_NONBLOCK)

        let readerQueue = DispatchQueue(
            label: "io.github.su-luoya.pi-web-desktop.log-writer.child-output"
        )
        readerQueue.setSpecific(key: readerQueueKey, value: 1)
        let pipe = ChildOutputPipe(
            writeHandle: FileHandle(fileDescriptor: writeDescriptor, closeOnDealloc: false),
            readDescriptor: readDescriptor,
            readerQueue: readerQueue
        )
        let source = DispatchSource.makeReadSource(fileDescriptor: readDescriptor, queue: readerQueue)
        source.setEventHandler { [weak self, weak pipe] in
            guard let self, let pipe else { return }
            self.readChildOutput(pipe)
        }
        source.setCancelHandler { close(readDescriptor) }
        pipe.source = source
        source.resume()

        pipeLock.lock()
        childPipe = pipe
        childOutputFinished = false
        pipeLock.unlock()
        return pipe.writeHandle
    }

    /// 读取队列：排空管道，按行切块交给写入队列。
    private func readChildOutput(_ pipe: ChildOutputPipe) {
        var buffer = [UInt8](repeating: 0, count: Self.childReadChunkBytes)
        while true {
            let count = read(pipe.readDescriptor, &buffer, buffer.count)
            if count > 0 {
                pipe.pendingLine.append(contentsOf: buffer[0..<count])
                emitChildOutput(pipe, endOfStream: false)
                continue
            }
            if count == 0 {
                emitChildOutput(pipe, endOfStream: true)
                stopChildPipe(pipe)
                return
            }
            if errno == EINTR { continue }
            if errno == EAGAIN || errno == EWOULDBLOCK { return }
            let code = errno
            recordFailure(
                operation: "读取子进程输出失败",
                error: POSIXError(POSIXError.Code(rawValue: code) ?? .EIO)
            )
            stopChildPipe(pipe)
            return
        }
    }

    /// 把缓冲区里完整的行（或 EOF 时的尾部、超长行的前一段）交给写入队列。
    private func emitChildOutput(_ pipe: ChildOutputPipe, endOfStream: Bool) {
        while !pipe.pendingLine.isEmpty {
            let end: Data.Index
            if endOfStream {
                end = pipe.pendingLine.endIndex
            } else if let newline = pipe.pendingLine.lastIndex(of: UInt8(ascii: "\n")) {
                end = pipe.pendingLine.index(after: newline)
            } else if pipe.pendingLine.count >= Self.childReadChunkBytes {
                end = pipe.pendingLine.endIndex
            } else {
                return
            }
            let chunk = Data(pipe.pendingLine[..<end])
            pipe.pendingLine = Data(pipe.pendingLine[end...])
            submitChildOutput(pipe, chunk)
        }
    }

    private func submitChildOutput(_ pipe: ChildOutputPipe, _ data: Data) {
        // 按 UTF-8 解码（非法字节替换为 U+FFFD）后脱敏：脱敏不会因为非 UTF-8 输入
        // 被绕过，字节级异常也不会让日志写入失败。
        let redacted = redactor.redact(String(decoding: data, as: UTF8.self))
        let payload = Data(redacted.utf8)
        // 背压：写入队列积压超过上限时先等，管道随即对子进程形成反压，内存有界。
        // 闭包**强引用**管道：它必须活到 `signal()` 执行完，否则信号量会在还有未归还
        // 的许可时被释放（libdispatch 会直接中止进程）。
        pipe.capacity.wait()
        submit(synchronousWhenIdle: false) { [weak self] in
            self?.writeOnQueue(payload)
            pipe.capacity.signal()
        }
    }

    /// 把子进程输出管道的读端交给一个独立的排空进程（`/bin/cat` → `/dev/null`），
    /// 成功返回它的 pid，没有管道或失败返回 nil。
    ///
    /// 用于文档化的退出行为“退出但保持服务运行”：应用退出后读端必须由还活着的
    /// 进程持有，否则托管服务的下一次 stdout/stderr 写入会收到 `EPIPE`——Node 的
    /// `process.stdout` 会把它变成未处理的 `error` 事件并让服务退出。
    ///
    /// 交出之前先把管道里已经缓冲的输出读尽并落盘；此后应用侧不再读这个管道，
    /// 服务后续输出（包括下次启动应用之前的全部输出）被丢弃。排空进程在服务退出
    /// （写端关闭）时读到 EOF 自行退出，不残留常驻进程。
    @discardableResult
    func handOffChildOutputToDrainer() -> pid_t? {
        guard let pipe = takeCurrentChildPipe() else { return nil }
        // dup 必须赶在取消读端之前：读端关闭之后 dup 只会拿到 EBADF。
        let inherited = dup(pipe.readDescriptor)
        let duplicationError = errno
        // 读尽已缓冲的输出（在读取队列上执行，不会与读取处理器并发），再等写入
        // 队列落盘，最后才停止应用侧读取。
        pipe.readerQueue.sync { self.drainChildOutputOnReaderQueue(pipe) }
        flush()
        pipe.stop()
        guard inherited >= 0 else {
            recordFailure(
                operation: "移交子进程输出读端失败",
                error: POSIXError(POSIXError.Code(rawValue: duplicationError) ?? .EIO)
            )
            return nil
        }
        switch Self.startChildOutputDrainer(inheriting: inherited) {
        case .success(let pid):
            return pid
        case .failure(let error):
            recordFailure(operation: Self.operationName(for: error), error: error)
            return nil
        }
    }

    /// 启动 `/bin/cat`：stdin 是管道读端副本，stdout/stderr 是 `/dev/null`。
    /// `POSIX_SPAWN_CLOEXEC_DEFAULT` 保证排空进程不继承应用的其它描述符
    /// （日志文件、管道写端、窗口句柄等）。无论成功与否都关闭 `rawDescriptor`。
    /// 失败时返回导致失败的错误码（`errno` 或 `posix_spawn*` 的返回码）。
    private static func startChildOutputDrainer(inheriting rawDescriptor: Int32) -> Result<pid_t, WriterError> {
        defer { close(rawDescriptor) }

        // 读取端是 O_NONBLOCK（读取队列不能因为管道空就阻塞）；同一个 open file
        // description 上的标志位会让 `cat` 把 EAGAIN 当成错误并立即退出，所以交给
        // 它之前清掉。应用侧这时已经不再读这个读端（调用方先 drain 再 stop）。
        let statusFlags = fcntl(rawDescriptor, F_GETFL)
        if statusFlags >= 0 {
            _ = fcntl(rawDescriptor, F_SETFL, statusFlags & ~O_NONBLOCK)
        }

        var fileActions: posix_spawn_file_actions_t?
        guard posix_spawn_file_actions_init(&fileActions) == 0 else { return .failure(.cannotStartChildOutputDrainer(errno)) }
        defer { posix_spawn_file_actions_destroy(&fileActions) }
        var attributes: posix_spawnattr_t?
        guard posix_spawnattr_init(&attributes) == 0 else { return .failure(.cannotStartChildOutputDrainer(errno)) }
        defer { posix_spawnattr_destroy(&attributes) }
        guard posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT)) == 0 else {
            return .failure(.cannotStartChildOutputDrainer(errno))
        }

        let nullDescriptor = open("/dev/null", O_RDWR)
        guard nullDescriptor >= 0 else { return .failure(.cannotStartChildOutputDrainer(errno)) }
        defer { close(nullDescriptor) }

        // dup2 的源 fd 必须高于 stderr，否则可能被另一个 dup2 覆盖。
        var duplicatedDescriptor: Int32?
        defer { if let duplicatedDescriptor { close(duplicatedDescriptor) } }
        var descriptor = rawDescriptor
        if descriptor <= STDERR_FILENO {
            let duplicate = fcntl(rawDescriptor, F_DUPFD_CLOEXEC, STDERR_FILENO + 1)
            guard duplicate > STDERR_FILENO else {
                return .failure(.cannotStartChildOutputDrainer(errno))
            }
            duplicatedDescriptor = duplicate
            descriptor = duplicate
        }

        let duplicates: [(source: Int32, target: Int32)] = [
            (descriptor, STDIN_FILENO),
            (nullDescriptor, STDOUT_FILENO),
            (nullDescriptor, STDERR_FILENO)
        ]
        for duplicate in duplicates {
            let status = posix_spawn_file_actions_adddup2(
                &fileActions,
                duplicate.source,
                duplicate.target
            )
            guard status == 0 else { return .failure(.cannotStartChildOutputDrainer(status)) }
        }

        guard let argument = strdup("/bin/cat") else { return .failure(.cannotStartChildOutputDrainer(ENOMEM)) }
        defer { free(argument) }
        var arguments: [UnsafeMutablePointer<CChar>?] = [argument, nil]
        var environment: [UnsafeMutablePointer<CChar>?] = [nil]
        var pid: pid_t = 0
        let status = posix_spawn(&pid, "/bin/cat", &fileActions, &attributes, &arguments, &environment)
        guard status == 0 else { return .failure(.cannotStartChildOutputDrainer(status)) }
        guard pid > 1 else { return .failure(.cannotStartChildOutputDrainer(ECHILD)) }
        return .success(pid)
    }

    // MARK: - 失败记录

    /// 失败信息本身也要脱敏：记录里带上日志位置（诊断需要）与底层描述，两者都
    /// 可能包含 Home 路径或命令行。
    private func recordFailure(operation: String, error: Error) {
        let message = redactor.redact(
            "\(operation)：\(error.localizedDescription)（日志文件：\(logFileURL.path)）"
        )
        failureLock.lock()
        lastFailure = Failure(message: message, occurredAt: Self.timestamp(for: now()))
        failureLock.unlock()
    }

    // MARK: - inode 身份

    private struct FileIdentity: Equatable {
        var device: UInt64
        var inode: UInt64
    }

    private static func fileIdentity(ofDescriptor descriptor: Int32) -> FileIdentity? {
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { return nil }
        return FileIdentity(device: UInt64(info.st_dev), inode: UInt64(info.st_ino))
    }

    private func pathIdentity() -> FileIdentity? {
        var info = stat()
        let resolved = logFileURL.withUnsafeFileSystemRepresentation { path -> Bool in
            guard let path else { return false }
            return stat(path, &info) == 0
        }
        guard resolved else { return nil }
        return FileIdentity(device: UInt64(info.st_dev), inode: UInt64(info.st_ino))
    }
}
