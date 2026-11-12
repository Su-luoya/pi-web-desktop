import Foundation

/// 日志轮转策略（GitHub #10）。
///
/// 默认值与文档一致：单文件上限 10 MB，保留 5 份轮转文件；阈值与份数都可注入，
/// 因此单元测试用很小的阈值就能反复演练真实的轮转路径。

/// Size-rotated log writing and log rotation policy.

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
