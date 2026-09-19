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

/// 统一日志写入器（GitHub #10）。
///
/// 位置来自 #9 的 `AppPaths`（`~/Library/Logs/Pi Web Desktop/`），本类不自己拼路径：
/// 调用方传入 `appConfiguration.logURL`，测试传入临时目录。
///
/// 职责：
/// - 按大小轮转（`Pi Web Desktop.log` → `.1.log`，依次后移，超出保留份数的丢弃）；
/// - 应用侧写入的每一行都经过注入的 `LogRedactor`（同一个实例贯穿日志、诊断、
///   错误消息与环境变量/命令行展示）；
/// - 打开子进程日志句柄前，把已存在的日志就地脱敏一次，历史残留的秘密不会因为
///   “这一轮没打印”而留在文件里；
/// - 任何写入/轮转/打开失败都只记录在 `failureDescription` 里，绝不抛出到调用方
///   之外、绝不崩溃；`openChildOutput()` 例外，它把错误抛给启动路径，由启动路径
///   给出可读失败提示（没有日志位置的子进程不该被启动）。
///
/// 线程安全：内部串行化，可从日志写入线程与主线程同时调用。
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

        var errorDescription: String? {
            switch self {
            case .cannotCreateLogDirectory(let path): return "无法创建日志目录：\(path)"
            case .cannotCreateLogFile(let path): return "无法创建日志文件：\(path)"
            case .cannotOpenLogFile(let path): return "无法打开日志文件：\(path)"
            }
        }
    }

    let logFileURL: URL
    let policy: LogRotationPolicy
    let redactor: LogRedactor

    private let fileManager: FileManager
    private let now: () -> Date
    private let lock = NSLock()
    private var lastFailure: Failure?

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
        lock.lock()
        defer { lock.unlock() }
        return lastFailure.map { "\($0.occurredAt) \($0.message)" }
    }

    /// 诊断文本里的“日志写入”一行的值。
    var writeStatusDescription: String {
        failureDescription.map { "写入失败（\($0)）" } ?? "正常"
    }

    /// 追加文本（可多行）。逐行脱敏后写入；失败不抛出、不崩溃，返回是否写入成功。
    @discardableResult
    func append(_ text: String) -> Bool {
        guard !text.isEmpty else { return true }
        lock.lock()
        defer { lock.unlock() }
        return appendLocked(text)
    }

    /// 追加一条带时间戳的应用事件行，例如“服务已启动：PID 4321”。
    @discardableResult
    func record(_ event: String) -> Bool {
        guard !event.isEmpty else { return true }
        return append("[\(Self.timestamp(for: now()))] \(event)")
    }

    /// 为子进程的 stdout/stderr 准备日志文件：建目录、就地脱敏历史日志、按大小
    /// 轮转，然后返回可写句柄（调用方负责关闭）。
    func openChildOutput() throws -> FileHandle {
        lock.lock()
        defer { lock.unlock() }
        do {
            try ensureDirectoryLocked()
        } catch {
            recordFailureLocked(operation: "创建日志目录失败", error: error)
            throw WriterError.cannotCreateLogDirectory(logFileURL.deletingLastPathComponent().path)
        }
        _ = scrubExistingLogLocked()
        rotateIfNeededLocked()
        if !fileManager.fileExists(atPath: logFileURL.path),
           !fileManager.createFile(atPath: logFileURL.path, contents: nil) {
            let error = WriterError.cannotCreateLogFile(logFileURL.path)
            recordFailureLocked(operation: "创建日志文件失败", error: error)
            throw error
        }
        do {
            let handle = try FileHandle(forWritingTo: logFileURL)
            try handle.seekToEnd()
            return handle
        } catch {
            recordFailureLocked(operation: "打开日志文件失败", error: error)
            throw WriterError.cannotOpenLogFile(logFileURL.path)
        }
    }

    /// 就地脱敏已存在的日志文件（整段读取、逐行脱敏、原子写回）。非 UTF-8 内容
    /// 不做猜测，保持原样。失败只记录。
    @discardableResult
    func scrubExistingLog() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return scrubExistingLogLocked()
    }

    // MARK: - 内部实现（调用方必须持有 lock）

    @discardableResult
    private func appendLocked(_ text: String) -> Bool {
        do {
            try ensureDirectoryLocked()
        } catch {
            recordFailureLocked(operation: "创建日志目录失败", error: error)
            return false
        }
        // 轮转失败不阻断写入：文件可能超出上限，但这一行仍然要落下。
        rotateIfNeededLocked()
        if !fileManager.fileExists(atPath: logFileURL.path),
           !fileManager.createFile(atPath: logFileURL.path, contents: nil) {
            recordFailureLocked(
                operation: "创建日志文件失败",
                error: WriterError.cannotCreateLogFile(logFileURL.path)
            )
            return false
        }
        let data = Data(redactor.redact(text).utf8)
        do {
            let handle = try FileHandle(forWritingTo: logFileURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            return true
        } catch {
            recordFailureLocked(operation: "写入日志失败", error: error)
            return false
        }
    }

    private func ensureDirectoryLocked() throws {
        try fileManager.createDirectory(
            at: logFileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
    }

    private func scrubExistingLogLocked() -> Bool {
        guard let data = fileManager.contents(atPath: logFileURL.path), !data.isEmpty else { return true }
        guard let text = String(data: data, encoding: .utf8) else { return true }
        let redacted = redactor.redact(text)
        guard redacted != text else { return true }
        do {
            try Data(redacted.utf8).write(to: logFileURL, options: .atomic)
            return true
        } catch {
            recordFailureLocked(operation: "脱敏历史日志失败", error: error)
            return false
        }
    }

    private func rotateIfNeededLocked() {
        guard currentFileSizeLocked() >= policy.maximumBytes else { return }
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
            try fileManager.moveItem(at: logFileURL, to: first)
            if !fileManager.createFile(atPath: logFileURL.path, contents: nil) {
                throw WriterError.cannotCreateLogFile(logFileURL.path)
            }
        } catch {
            recordFailureLocked(operation: "轮转日志失败", error: error)
        }
    }

    private func currentFileSizeLocked() -> Int {
        guard let attributes = try? fileManager.attributesOfItem(atPath: logFileURL.path),
              let size = attributes[.size] as? NSNumber else { return 0 }
        return size.intValue
    }

    /// 失败信息本身也要脱敏：记录里带上日志位置（诊断需要）与底层描述，两者都
    /// 可能包含 Home 路径或命令行。
    private func recordFailureLocked(operation: String, error: Error) {
        let message = redactor.redact(
            "\(operation)：\(error.localizedDescription)（日志文件：\(logFileURL.path)）"
        )
        lastFailure = Failure(message: message, occurredAt: Self.timestamp(for: now()))
    }
}
