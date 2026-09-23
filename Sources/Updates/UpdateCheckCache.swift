/// On-disk cache of the last check results and its file store.

import Foundation

// MARK: - 缓存

/// 缓存里的一个条目。
///
/// 只保存时间戳、条件请求字段与结果本身：**不含**凭据、cookie、会话、URL、
/// 响应体、错误文本或诊断内容。删除该文件不会影响应用与服务。
struct UpdateCacheEntry: Codable, Equatable {
    var targetID: String
    var category: String
    var packageName: String?
    var lastAttemptAt: Date?
    var lastSuccessAt: Date?
    var etag: String?
    var lastModified: String?
    var latestVersion: String?
    /// GitHub Release 的原始 tag；安装前必须再次从网络获取该 tag 的资产，缓存 tag 只用于提示。
    var upstreamTag: String? = nil
    /// 写下这条结论时的本机版本（GitHub #74）。缓存里的 `status` 只对写下它的
    /// 那个本机版本成立，因此复用任何结论字段前都要先与当前本机版本核对；
    /// 旧缓存（schema 1）没有这个字段，读取后一律按“结论不可判定”处理。
    var installedVersion: String?
    var status: String?
    var confidence: String?
    var failure: String?
    var httpStatusCode: Int?

    init(
        targetID: String,
        category: String,
        packageName: String? = nil,
        lastAttemptAt: Date? = nil,
        lastSuccessAt: Date? = nil,
        etag: String? = nil,
        lastModified: String? = nil,
        latestVersion: String? = nil,
        upstreamTag: String? = nil,
        installedVersion: String? = nil,
        status: String? = nil,
        confidence: String? = nil,
        failure: String? = nil,
        httpStatusCode: Int? = nil
    ) {
        self.targetID = targetID
        self.category = category
        self.packageName = packageName
        self.lastAttemptAt = lastAttemptAt
        self.lastSuccessAt = lastSuccessAt
        self.etag = etag
        self.lastModified = lastModified
        self.latestVersion = latestVersion
        self.upstreamTag = upstreamTag
        self.installedVersion = installedVersion
        self.status = status
        self.confidence = confidence
        self.failure = failure
        self.httpStatusCode = httpStatusCode
    }

    var decodedConfidence: DetectionConfidence? { confidence.flatMap(DetectionConfidence.init(rawValue:)) }

    /// 上次成功结果是否仍可沿用：有版本、有成功时间，且没有超过该分类的 TTL。
    func isReusable(at date: Date, ttl: TimeInterval) -> Bool {
        guard latestVersion != nil, let lastSuccessAt else { return false }
        return date.timeIntervalSince(lastSuccessAt) <= ttl
    }
}

/// 缓存文件结构。`schemaVersion` 不在 `supportedSchemaVersions` 内时整份缓存
/// 视为不可用（返回空缓存），因此未来格式变化不会让旧数据以错误语义被读入；
/// 已知的旧版本按当前结构读入，缺少 `installedVersion` 的旧条目由检查器降级为
/// 不可判定（见 `cachedFallback`）。
struct UpdateCheckCacheFile: Codable, Equatable {
    static let currentSchemaVersion = 2
    /// 兼容读取的旧版本（GitHub #74 之前写入）：条目没有 `installedVersion`，
    /// 无法判断缓存里的结论是否适用于当前本机版本，因此不参与结论复用。
    static let legacySchemaVersion = 1
    /// 可读取的 schema 版本。旧版本读入后按当前版本处理，不部分采用。
    static let supportedSchemaVersions: [Int] = [legacySchemaVersion, currentSchemaVersion]
    /// 条目上限：包名列表长期变化时避免文件无限增长。
    static let maximumEntries = 200
    /// 文件大小上限：超过它的缓存文件不解析、不部分采用，直接丢弃。
    /// 上限比满额缓存（200 条 × 各字段上限）更大，因此合法缓存不会被它拒绝。
    static let maximumFileBytes = 1024 * 1024
    /// 单个版本字符串的长度上限（版本值还必须是规范化的语义化版本）。
    static let maximumVersionLength = 64
    /// 条件请求字段（`etag` / `lastModified`）的长度上限。
    static let maximumConditionalHeaderLength = 512
    /// 目标 id 的长度上限。
    static let maximumTargetIDLength = 256
    /// 允许的时钟偏移（秒）：比“未来”宽松一点点，但不改变“未来时间戳不可信”。
    static let futureTimestampTolerance: TimeInterval = 300

    var schemaVersion: Int
    var entries: [UpdateCacheEntry]

    init(schemaVersion: Int = UpdateCheckCacheFile.currentSchemaVersion, entries: [UpdateCacheEntry] = []) {
        self.schemaVersion = schemaVersion
        self.entries = entries
    }

    static let empty = UpdateCheckCacheFile()

    func entry(for targetID: String) -> UpdateCacheEntry? {
        entries.first { $0.targetID == targetID }
    }

    mutating func upsert(_ entry: UpdateCacheEntry) {
        if let index = entries.firstIndex(where: { $0.targetID == entry.targetID }) {
            entries[index] = entry
        } else {
            entries.append(entry)
        }
    }

    /// 按最后尝试时间保留最近的条目（nil 视为最旧），超出上限的丢弃。
    mutating func pruneToMaximumEntries() {
        guard entries.count > Self.maximumEntries else { return }
        let sorted = entries.sorted { left, right in
            (left.lastAttemptAt ?? .distantPast) > (right.lastAttemptAt ?? .distantPast)
        }
        entries = Array(sorted.prefix(Self.maximumEntries))
    }
}

/// 缓存被丢弃的原因。全部是固定文案：不回显缓存文件里的任何内容，因此损坏或
/// 被改写的文件不能把任意文本带进日志与诊断。
enum UpdateCheckCacheRejection: Equatable {
    /// 文件存在但读不出来。
    case unreadable
    /// 文件超过大小上限（在解析前就拒绝）。
    case tooLarge(bytes: Int)
    /// 结构无法解析（JSON 损坏、字段类型不对）。
    case malformedStructure
    /// `schemaVersion` 不是当前版本。
    case unsupportedSchemaVersion(Int)
    /// 条目数超过上限。
    case tooManyEntries(Int)
    /// 条目字段不合法（分类、包名、状态、目标 id 或条件请求字段）。
    case invalidEntry
    /// 版本字符串不是规范化的语义化版本。
    case invalidVersionShape
    /// 时间戳落在未来（超过允许的时钟偏移）。
    case timestampInTheFuture

    var text: String {
        switch self {
        case .unreadable:
            return "缓存文件无法读取"
        case .tooLarge(let bytes):
            return "缓存文件超过大小上限（\(bytes) 字节 > \(UpdateCheckCacheFile.maximumFileBytes) 字节）"
        case .malformedStructure:
            return "缓存结构无法解析（字段类型或形状不合法）"
        case .unsupportedSchemaVersion(let version):
            return "缓存 schema 版本不受支持（\(version) ≠ \(UpdateCheckCacheFile.currentSchemaVersion)）"
        case .tooManyEntries(let count):
            return "缓存条目数超过上限（\(count) > \(UpdateCheckCacheFile.maximumEntries)）"
        case .invalidEntry:
            return "缓存条目字段不合法（分类、包名、目标 id、状态或条件请求字段）"
        case .invalidVersionShape:
            return "缓存里的版本字符串不是规范化的语义化版本"
        case .timestampInTheFuture:
            return "缓存时间戳落在未来"
        }
    }

    /// 完整日志行：固定文案 + 结论（只影响提示，不参与自动安装判定）。
    var logLine: String {
        "更新检查缓存已丢弃（\(text)）；本次按“没有可用缓存”处理：只影响提示，不参与自动安装判定。"
    }
}

// MARK: - 缓存校验

/// 单条缓存条目的结构校验。返回 nil 表示合法。
///
/// 校验只看形状与一致性：分类/包名/目标 id 互相对得上、枚举值是已知取值、版本
/// 字符串是规范化的语义化版本、时间戳不落在未来。任何一项不满足都丢弃整份缓存
/// （不部分采用），因为一个被改写的条目与其余条目的可信度无法区分。
extension UpdateCacheEntry {
    func validationRejection(at now: Date) -> UpdateCheckCacheRejection? {
        guard !targetID.isEmpty,
              targetID.count <= UpdateCheckCacheFile.maximumTargetIDLength else { return .invalidEntry }
        guard let category = UpdateCheckCategory(rawValue: category) else { return .invalidEntry }
        if let packageName {
            guard ComponentInstallationDetector.isPackageName(packageName) else { return .invalidEntry }
        }
        if category != .piPackages, packageName != nil { return .invalidEntry }
        guard targetID == UpdateCheckTarget(category: category, packageName: packageName).id else {
            return .invalidEntry
        }
        if let status, UpdateCheckStatus(rawValue: status) == nil { return .invalidEntry }
        if let confidence, DetectionConfidence(rawValue: confidence) == nil { return .invalidEntry }
        if let failure, UpdateCheckFailure(rawValue: failure) == nil { return .invalidEntry }
        if let httpStatusCode, !(100...599).contains(httpStatusCode) { return .invalidEntry }
        if let etag, etag.count > UpdateCheckCacheFile.maximumConditionalHeaderLength { return .invalidEntry }
        if let lastModified, lastModified.count > UpdateCheckCacheFile.maximumConditionalHeaderLength {
            return .invalidEntry
        }
        if let latestVersion {
            guard latestVersion.count <= UpdateCheckCacheFile.maximumVersionLength,
                  let parsed = SemanticVersion(latestVersion),
                  parsed.description == latestVersion else { return .invalidVersionShape }
        }
        if let upstreamTag {
            guard upstreamTag.count <= UpdateCheckCacheFile.maximumVersionLength,
                  !upstreamTag.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
                return .invalidEntry
            }
        }
        // 写入结论时的本机版本不必是规范化的语义化版本（本机安装元数据可以是
        // `dev-build` 这类值），但必须是有限长度、不含控制字符的字符串：它只
        // 用于与当前本机版本核对，不进入界面。
        if let installedVersion {
            guard !installedVersion.isEmpty,
                  installedVersion.count <= UpdateCheckCacheFile.maximumVersionLength,
                  !installedVersion.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) else {
                return .invalidEntry
            }
        }
        // 时间戳不能落在未来；允许小幅时钟偏移，但偏移必须小于容差。
        for timestamp in [lastAttemptAt, lastSuccessAt].compactMap({ $0 }) where
            timestamp.timeIntervalSince(now) > UpdateCheckCacheFile.futureTimestampTolerance {
            return .timestampInTheFuture
        }
        return nil
    }
}

extension UpdateCheckCacheFile {
    /// 读取时的整体校验。任何不合法都返回整份 `.empty` 与拒绝原因：不崩溃、
    /// 不部分采用，调用方按 `unavailable` 处理。
    static func validated(
        _ data: Data,
        now: Date
    ) -> (file: UpdateCheckCacheFile, rejection: UpdateCheckCacheRejection?) {
        guard data.count <= maximumFileBytes else {
            return (.empty, .tooLarge(bytes: data.count))
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let file = try? decoder.decode(UpdateCheckCacheFile.self, from: data) else {
            return (.empty, .malformedStructure)
        }
        guard supportedSchemaVersions.contains(file.schemaVersion) else {
            return (.empty, .unsupportedSchemaVersion(file.schemaVersion))
        }
        // 旧 schema 按当前结构使用（GitHub #74）：条目里缺少 `installedVersion`
        // 时结论不可判定，由 `cachedFallback` 降级为 unknown，不沿用旧结论。
        let normalized = UpdateCheckCacheFile(schemaVersion: currentSchemaVersion, entries: file.entries)
        guard normalized.entries.count <= maximumEntries else {
            return (.empty, .tooManyEntries(normalized.entries.count))
        }
        for entry in normalized.entries {
            if let rejection = entry.validationRejection(at: now) {
                return (.empty, rejection)
            }
        }
        return (normalized, nil)
    }
}

/// 缓存读写接口（可注入）。测试用内存替身，不写真实 Application Support。
protocol UpdateCacheStoring: AnyObject {
    func load() -> UpdateCheckCacheFile
    func save(_ file: UpdateCheckCacheFile)
    /// 最近一次 `load()` 丢弃整份缓存的原因；nil 表示读到合法缓存或本来就没有文件。
    var lastLoadRejection: UpdateCheckCacheRejection? { get }
}

extension UpdateCacheStoring {
    /// 默认没有拒绝原因：内存替身不必实现它。
    var lastLoadRejection: UpdateCheckCacheRejection? { nil }
}

/// 生产实现：Application Support 下的独立 JSON 文件。
///
/// 读失败（文件不存在、损坏、schema 不匹配）返回空缓存；写失败静默——更新
/// 检查的任何问题都不得影响应用或正在运行的服务。
final class UpdateCheckCacheFileStore: UpdateCacheStoring {
    let fileURL: URL
    private let fileManager: FileManager
    private let clock: UpdateClock

    /// 最近一次读取丢弃整份缓存的原因（供调用方记录固定文案）。
    private(set) var lastLoadRejection: UpdateCheckCacheRejection?

    init(fileURL: URL, fileManager: FileManager = .default, clock: UpdateClock = .system) {
        self.fileURL = fileURL
        self.fileManager = fileManager
        self.clock = clock
    }

    func load() -> UpdateCheckCacheFile {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            lastLoadRejection = nil
            return .empty
        }
        guard let attributes = try? fileManager.attributesOfItem(atPath: fileURL.path),
              let size = (attributes[.size] as? NSNumber)?.intValue else {
            lastLoadRejection = .unreadable
            return .empty
        }
        // 先看大小再读内容：超大文件不进入内存，也不进入 JSON 解析。
        guard size <= UpdateCheckCacheFile.maximumFileBytes else {
            lastLoadRejection = .tooLarge(bytes: size)
            return .empty
        }
        guard let data = try? Data(contentsOf: fileURL) else {
            lastLoadRejection = .unreadable
            return .empty
        }
        let outcome = UpdateCheckCacheFile.validated(data, now: clock.now())
        lastLoadRejection = outcome.rejection
        return outcome.file
    }

    func save(_ file: UpdateCheckCacheFile) {
        var file = file
        // 写盘一律用当前 schema：旧版本读入的缓存会在下一次保存时自动升级。
        file.schemaVersion = UpdateCheckCacheFile.currentSchemaVersion
        file.pruneToMaximumEntries()
        do {
            try fileManager.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
            let data = try encoder.encode(file)
            // 不写自己会拒绝读取的文件（正常情况下远小于上限）。
            guard data.count <= UpdateCheckCacheFile.maximumFileBytes else { return }
            try data.write(to: fileURL, options: [.atomic])
        } catch {
            // 静默：缓存写入失败不影响检查结果、服务或退出路径。
        }
    }
}
