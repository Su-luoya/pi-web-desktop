import CryptoKit
import Darwin
import Foundation

// MARK: - 更新验证（GitHub #23）
//
// 本文件是 #20（Pi Web）/ #21（Pi CLI）/ #22（Pi 扩展包）三条更新路径共用的
// 验证器。它只回答“实际能验证到的事实”，并把每条检查的结果与能力边界写清楚：
//
//   * 可执行文件存在、可执行、解析后的真实路径可读（文件系统事实）；
//   * 版本能被 #16 识别器重新检测，并且达到目标版本（或相对旧版本发生变化）；
//   * `package.json` 的 `name` 与期望包名一致（防替换攻击）；
//   * 服务启动后的健康检查结果（复用既有健康检查路径，由调用方传入）。
//
// 明确**不**做的验证在 `UpdateVerificationCheck.notVerifiedCapabilities` 里列出：
// 不做代码签名验证、不声称能验证官方签名、不做安装包内容哈希或上游文件比对。
// 没有文件系统探针时，文件层检查记为“未验证”，不会伪装成“通过”。
//
// GitHub #63 起，更新前指纹额外记录 inode、可执行文件内容哈希与 npm 记录的
// `integrity`（有界读取；取不到就标注“未获取”）。这些字段只用于判断“旧文件
// 是否仍然是更新前那一份”，不证明发布时间、发布者或来源可信。

// MARK: - 内容哈希结果

/// 对单个可执行文件做内容哈希的结果。只有 `.hashed` 才是真正的哈希；其余三种
/// 都必须如实标注“未做内容哈希”，不允许退回伪哈希或空字符串冒充。

/// Artifact content hash results and the read-only artifact probe.

enum UpdateArtifactContentHashResult: Equatable {
    case hashed(String)
    /// 文件超过大小上限：不读取内容，只保留元数据。
    case aboveSizeLimit
    /// 文件打不开或读取失败。
    case unreadable
    /// 本次运行没有内容哈希能力（例如未注入探针）。
    case unsupported

    var hash: String? {
        if case .hashed(let value) = self { return value }
        return nil
    }
}

// MARK: - 文件系统探针

/// 更新验证读取文件系统事实的唯一入口。
///
/// 生产实现是 `UpdateArtifactProbe.live`（只用 `FileManager`）；unhosted 测试
/// 注入假探针，绝不触碰真实用户目录、不读取真实安装、不执行任何命令。
/// `isAvailable == false` 时所有文件层检查都记为“未验证”，而不是猜一个结论。
struct UpdateArtifactProbe {
    /// 探针可用性。false 表示这次运行没有注入文件系统能力。
    var isAvailable: Bool
    var isExecutableFile: (String) -> Bool
    var isReadableFile: (String) -> Bool
    var resolveRealPath: (String) -> String?
    var fileSize: (String) -> Int?
    var modificationDate: (String) -> Date?
    /// `st_ino`：同一个路径下文件被替换时 inode 通常会变化。取不到时返回 nil。
    var fileInode: (String) -> UInt64? = { _ in nil }
    /// 流式读取可执行文件内容并计算哈希；超过大小上限或读不到时返回对应的
    /// “未做内容哈希”结果，不返回伪造值。
    var contentHash: (String) -> UpdateArtifactContentHashResult = { _ in .unsupported }
    /// npm 记录的完整性（`integrity`）值：只从本机 npm 元数据/锁文件读取，
    /// 不联网、不执行 npm；取不到或值不符合哈希形状时返回 nil。
    /// 参数依次为：（可执行文件路径，包名，指纹记录的版本）。
    var npmIntegrity: (String, String?, String?) -> String? = { _, _, _ in nil }
    /// 读取指定 `package.json` 的 `name` 字段；读不到或不是合法包名时返回 nil。
    var packageNameAtPackageJSON: (String) -> String?
    /// 从可执行文件路径向上最多 6 层找最近的 `package.json` 并读 `name`。
    var packageNameNear: (String) -> String?

    /// 内容哈希的读取上限（16 MiB）。超过上限不读取内容，只退回元数据证据。
    static let contentHashSizeLimitBytes = 16 * 1024 * 1024
    static let packageJSONSizeLimitBytes = 512 * 1024
    static let lockfileSizeLimitBytes = 4 * 1024 * 1024

    /// 未注入探针：所有文件层检查记为“未验证”。
    static let disabled = UpdateArtifactProbe(
        isAvailable: false,
        isExecutableFile: { _ in false },
        isReadableFile: { _ in false },
        resolveRealPath: { _ in nil },
        fileSize: { _ in nil },
        modificationDate: { _ in nil },
        fileInode: { _ in nil },
        contentHash: { _ in .unsupported },
        npmIntegrity: { _, _, _ in nil },
        packageNameAtPackageJSON: { _ in nil },
        packageNameNear: { _ in nil }
    )

    /// 生产探针：只使用 `FileManager`，不联网、不执行子进程、不发送信号。
    static let live = UpdateArtifactProbe(
        isAvailable: true,
        isExecutableFile: { FileManager.default.isExecutableFile(atPath: $0) },
        isReadableFile: { FileManager.default.isReadableFile(atPath: $0) },
        resolveRealPath: { path in
            guard FileManager.default.fileExists(atPath: path) else { return nil }
            return URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        },
        fileSize: { path in
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
                  let size = attributes[.size] as? NSNumber else { return nil }
            return size.intValue
        },
        modificationDate: { path in
            (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
        },
        fileInode: { path in
            guard let number = (try? FileManager.default.attributesOfItem(atPath: path))?[.systemFileNumber]
                    as? NSNumber else { return nil }
            return number.uint64Value
        },
        contentHash: { path in
            UpdateArtifactProbe.readContentHash(atPath: path)
        },
        npmIntegrity: { path, packageName, fingerprintVersion in
            UpdateArtifactProbe.readNpmIntegrity(
                executablePath: path,
                packageName: packageName,
                fingerprintVersion: fingerprintVersion
            )
        },
        packageNameAtPackageJSON: { path in
            UpdateArtifactProbe.readPackageName(atPackageJSONPath: path)
        },
        packageNameNear: { path in
            UpdateArtifactProbe.readPackageName(near: path)
        }
    )

    /// 流式计算 SHA-256（分块 64 KiB，上限 `contentHashSizeLimitBytes`）。
    /// 只读文件内容；不做任何写入、不执行命令、不联网。
    static func readContentHash(atPath path: String) -> UpdateArtifactContentHashResult {
        guard let size = fileSize(atPath: path) else { return .unreadable }
        if size > contentHashSizeLimitBytes { return .aboveSizeLimit }
        // F4（GitHub #121）：与 readBoundedData 同一道口子，常规文件才打开。
        guard let handle = openRegularFile(atPath: path) else { return .unreadable }
        defer { try? handle.close() }
        var hasher = SHA256()
        var total = 0
        while true {
            let chunk: Data
            do {
                guard let read = try handle.read(upToCount: 64 * 1024), !read.isEmpty else { break }
                chunk = read
            } catch {
                return .unreadable
            }
            total += chunk.count
            if total > contentHashSizeLimitBytes { return .aboveSizeLimit }
            hasher.update(data: chunk)
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return .hashed("sha256:" + digest)
    }

    /// 文件大小（字节）。只读属性，不跟随写入。
    static func fileSize(atPath path: String) -> Int? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attributes[.size] as? NSNumber else { return nil }
        return size.intValue
    }

    /// 取文件类型（不跟随末级符号链接，与 `lstat` 同语义）。
    static func fileType(atPath path: String) -> FileAttributeType? {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.type] as? FileAttributeType
    }

    /// 只打开常规文件（F4，GitHub #121）：FIFO / 设备 / socket 的 `open` 可能无超时阻塞，
    /// 而 `attributesOfItem` 对 FIFO 报出的大小是 `0`，能通过大小上限检查。
    /// 末级符号链接先解析到目标，再要求目标是常规文件（不跟随链接就无法判断真实类型）。
    /// L-3（GitHub #127）：上面的解析/类型判断与 `open` 之间存在窗口，路径可能在两步之间
    /// 被换掉；因此类型闸门对**已打开的句柄**再确认一次（`fstat`），只有句柄本身是常规
    /// 文件才交出去。判定不再依赖两次路径查询之间的一致性，也不改变可读文件的范围。
    static func openRegularFile(atPath path: String) -> FileHandle? {
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        guard fileType(atPath: resolved) == .typeRegular else { return nil }
        guard let handle = FileHandle(forReadingAtPath: resolved) else { return nil }
        var fileStatus = stat()
        guard fstat(handle.fileDescriptor, &fileStatus) == 0,
              (UInt32(fileStatus.st_mode) & UInt32(S_IFMT)) == UInt32(S_IFREG) else {
            try? handle.close()
            return nil
        }
        return handle
    }

    /// 先检查文件属性，再通过句柄做有界读取；超限文件不会打开，读取期间增长也不会越界。
    /// 默认打开路径只接受常规文件（F4，GitHub #121）：FIFO 之类不能无超时地读。
    static func readBoundedData(
        atPath path: String,
        maximumSize: Int,
        fileSize: (String) -> Int? = { UpdateArtifactProbe.fileSize(atPath: $0) },
        openFile: (String) -> FileHandle? = { UpdateArtifactProbe.openRegularFile(atPath: $0) }
    ) -> Data? {
        guard maximumSize >= 0,
              let size = fileSize(path),
              size >= 0,
              size <= maximumSize else { return nil }
        guard let handle = openFile(path) else { return nil }
        defer { try? handle.close() }

        var data = Data()
        while data.count <= maximumSize {
            let remaining = min(64 * 1024, maximumSize + 1 - data.count)
            guard remaining > 0 else { return nil }
            let chunk: Data
            do {
                guard let read = try handle.read(upToCount: remaining), !read.isEmpty else { break }
                chunk = read
            } catch {
                return nil
            }
            data.append(chunk)
        }
        guard !data.isEmpty, data.count <= maximumSize else { return nil }
        return data
    }

    private struct PackageIdentity {
        var name: String
        var version: String?
    }

    /// 读取 `package.json` 的包身份。有界读取（上限 512 KiB），解析失败返回 nil。
    private static func readPackageIdentity(atPackageJSONPath path: String) -> PackageIdentity? {
        guard path.hasSuffix("package.json"),
              let data = readBoundedData(atPath: path, maximumSize: packageJSONSizeLimitBytes),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let name = object["name"] as? String,
              ComponentInstallationDetector.isPackageName(name) else { return nil }
        let version = (object["version"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return PackageIdentity(name: name, version: version?.isEmpty == false ? version : nil)
    }

    /// 读取 `package.json` 的 `name`。有界读取（上限 512 KiB），解析失败返回 nil。
    static func readPackageName(atPackageJSONPath path: String) -> String? {
        return readPackageIdentity(atPackageJSONPath: path)?.name
    }

    /// npm 记录的完整性值形状校验：`<算法>-<base64 形状>`，长度有上限。
    /// 不符合形状的值一律当作“未获取”，不写进指纹。
    static func isIntegrityValue(_ value: String) -> Bool {
        guard value.count <= 200 else { return false }
        let parts = value.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return false }
        let algorithms = ["sha1", "sha256", "sha384", "sha512", "md5"]
        guard algorithms.contains(String(parts[0])) else { return false }
        let payload = parts[1]
        guard !payload.isEmpty else { return false }
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=")
        return payload.allSatisfy { allowed.contains($0) }
    }

    /// 读取 npm 记录的完整性（`integrity`）值，作为降级的附加证据。
    ///
    /// 只读本机文件：从可执行文件目录向上最多 6 层查找 `package-lock.json`、
    /// `.package-lock.json` 与 `node_modules/.package-lock.json`（npm 7+ 的隐藏
    /// 锁文件），在 `packages` / `dependencies` 里找与包名匹配的条目并读 `integrity`。
    /// 取值有界（单个锁文件上限 4 MiB）、值经过形状校验；不联网、不执行 npm、
    /// 不读取 npm 凭据。取不到时返回 nil，调用方必须标注“未获取”。
    ///
    /// 版本基准（GitHub #124）：优先用指纹记录的版本 `fingerprintVersion`，
    /// 使“版本不符”成为相对已记录证据的判断；指纹没有版本时才退回
    /// 可执行文件近旁 `package.json` 的身份版本（同为本机磁盘事实，取不到就不比对）。
    static func readNpmIntegrity(
        executablePath: String,
        packageName: String?,
        fingerprintVersion: String? = nil
    ) -> String? {
        guard executablePath.hasPrefix("/") else { return nil }
        let installedIdentity = readPackageIdentity(near: executablePath)
        let expectedName = packageName ?? installedIdentity?.name
        guard let expectedName, !expectedName.isEmpty else { return nil }
        let expectedVersion = fingerprintVersion
            ?? (installedIdentity?.name == expectedName ? installedIdentity?.version : nil)
        var directory = (executablePath as NSString).deletingLastPathComponent
        var depth = 0
        while !directory.isEmpty, directory != "/", depth < 6 {
            for candidate in [
                (directory as NSString).appendingPathComponent("package-lock.json"),
                (directory as NSString).appendingPathComponent(".package-lock.json"),
                (directory as NSString).appendingPathComponent("node_modules/.package-lock.json")
            ] {
                if let integrity = readIntegrityValue(
                    atLockfilePath: candidate,
                    packageName: expectedName,
                    packageVersion: expectedVersion
                ) {
                    return integrity
                }
            }
            directory = (directory as NSString).deletingLastPathComponent
            depth += 1
        }
        return nil
    }

    /// 从单个锁文件里取指定包名的 `integrity`。精确路径优先；版本不符或候选歧义返回 nil。
    static func readIntegrityValue(
        atLockfilePath path: String,
        packageName: String,
        packageVersion: String? = nil
    ) -> String? {
        guard let data = readBoundedData(atPath: path, maximumSize: lockfileSizeLimitBytes),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }

        func integrity(from value: Any) -> String? {
            guard let entry = value as? [String: Any] else { return nil }
            if let entryVersionValue = entry["version"] {
                guard let entryVersion = entryVersionValue as? String,
                      let packageVersion,
                      entryVersion == packageVersion else { return nil }
            }
            guard let integrity = entry["integrity"] as? String,
                  isIntegrityValue(integrity) else { return nil }
            return integrity
        }

        if let packages = object["packages"] as? [String: Any] {
            let exactKey = "node_modules/\(packageName)"
            if let exactEntry = packages[exactKey] {
                return integrity(from: exactEntry)
            }

            let matchingKeys = packages.keys.sorted().filter { key in
                let suffix = key.components(separatedBy: "node_modules/").last ?? key
                return suffix == packageName
            }
            guard matchingKeys.count <= 1 else { return nil }
            if let key = matchingKeys.first {
                return integrity(from: packages[key] as Any)
            }
        }
        if let dependencies = object["dependencies"] as? [String: Any],
           let entry = dependencies[packageName] {
            return integrity(from: entry)
        }
        return nil
    }

    /// 从 `path` 向上最多 6 层找最近的 `package.json` 并读包身份。
    /// 只做有界目录向上遍历，不递归、不列目录内容。
    private static func readPackageIdentity(near path: String) -> PackageIdentity? {
        guard path.hasPrefix("/") else { return nil }
        var directory = (path as NSString).deletingLastPathComponent
        var depth = 0
        while !directory.isEmpty, directory != "/", depth < 6 {
            let candidate = (directory as NSString).appendingPathComponent("package.json")
            if let identity = readPackageIdentity(atPackageJSONPath: candidate) {
                return identity
            }
            directory = (directory as NSString).deletingLastPathComponent
            depth += 1
        }
        return nil
    }

    /// 从 `path` 向上最多 6 层找最近的 `package.json` 并读 `name`。
    static func readPackageName(near path: String) -> String? {
        return readPackageIdentity(near: path)?.name
    }
}
