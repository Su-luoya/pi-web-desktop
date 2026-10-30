import Foundation

/// 预下载好的桌面更新包。
///
/// 检查发现新版本后，后台先把 zip 下好并校验，用户点“更新”时只剩解压与替换，
/// 不再等一次下载（GitHub #219 的进度窗口里，下载那一步通常是最长的一段）。
struct DesktopUpdatePackage: Equatable {
    let version: String
    let releaseTag: String
    let archiveName: String
    let sha256: String
    let archiveURL: URL
    let downloadedAt: Date
}

/// 预下载缓存：`~/Library/Caches/<bundle id>/desktop-update/`，只保留一个版本。
///
/// 只缓存“已经校验过”的包：写进来的字节必须先与发布资产里的 `.sha256` 对上，
/// 否则下次安装会用一个坏包。缓存命中后安装器还会再算一次 SHA-256——缓存目录
/// 是用户可写的，不能只信写缓存那一刻的结果。
final class DesktopUpdatePackageCache {
    struct Metadata: Codable, Equatable {
        let version: String
        let releaseTag: String
        let archiveName: String
        let sha256: String
        let downloadedAt: Date
    }

    static let shared = DesktopUpdatePackageCache()

    private let directory: URL
    private let fileManager: FileManager
    private let metadataName = "package.json"

    init(
        directory: URL = DesktopUpdatePackageCache.defaultDirectory(),
        fileManager: FileManager = .default
    ) {
        self.directory = directory
        self.fileManager = fileManager
    }

    static func defaultDirectory(fileManager: FileManager = .default) -> URL {
        let base = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        let bundle = Bundle.main.bundleIdentifier ?? "io.github.su-luoya.pi-web-desktop"
        return base
            .appendingPathComponent(bundle, isDirectory: true)
            .appendingPathComponent("desktop-update", isDirectory: true)
    }

    /// 命中的缓存包。版本或 tag 对不上都算未命中：宁可重新下载，也不装错包。
    func package(matching version: String, releaseTag: String) -> DesktopUpdatePackage? {
        guard let metadata = storedMetadata(),
              metadata.version == version,
              metadata.releaseTag == releaseTag else { return nil }
        let archiveURL = directory.appendingPathComponent(metadata.archiveName)
        guard fileManager.fileExists(atPath: archiveURL.path) else { return nil }
        return DesktopUpdatePackage(
            version: metadata.version,
            releaseTag: metadata.releaseTag,
            archiveName: metadata.archiveName,
            sha256: metadata.sha256,
            archiveURL: archiveURL,
            downloadedAt: metadata.downloadedAt
        )
    }

    /// 把一个已经校验过的下载结果收进缓存，替换掉上一个版本。
    @discardableResult
    func store(archiveAt url: URL, asset: DesktopAppReleaseAsset) throws -> DesktopUpdatePackage {
        guard let releaseTag = asset.releaseTag,
              let archiveName = asset.assetName,
              let sha256 = DesktopAppReleaseAssetSelector.normalizedChecksum(asset.sha256) else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        let version = asset.version
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent(archiveName)
        // 先清掉上一个版本：缓存只留一个，避免每次发版都在用户盘上留 1.6MB。
        if fileManager.fileExists(atPath: directory.appendingPathComponent(metadataName).path) {
            try? fileManager.removeItem(at: directory.appendingPathComponent(metadataName))
        }
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        do {
            try fileManager.moveItem(at: url, to: destination)
        } catch {
            // 跨卷（下载临时目录在别的分区）时 move 会失败，退化成拷贝。
            try fileManager.copyItem(at: url, to: destination)
            try? fileManager.removeItem(at: url)
        }
        try removeOtherArchives(keeping: archiveName)
        let metadata = Metadata(
            version: version,
            releaseTag: releaseTag,
            archiveName: archiveName,
            sha256: sha256,
            downloadedAt: Date()
        )
        let data = try JSONEncoder().encode(metadata)
        try data.write(to: directory.appendingPathComponent(metadataName), options: .atomic)
        return DesktopUpdatePackage(
            version: metadata.version,
            releaseTag: metadata.releaseTag,
            archiveName: metadata.archiveName,
            sha256: metadata.sha256,
            archiveURL: destination,
            downloadedAt: metadata.downloadedAt
        )
    }

    func removeAll() {
        try? fileManager.removeItem(at: directory)
    }

    private func storedMetadata() -> Metadata? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(metadataName)) else {
            return nil
        }
        return try? JSONDecoder().decode(Metadata.self, from: data)
    }

    private func removeOtherArchives(keeping name: String) throws {
        let entries = (try? fileManager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        )) ?? []
        for entry in entries where entry.lastPathComponent != name && entry.lastPathComponent != metadataName {
            try? fileManager.removeItem(at: entry)
        }
    }
}
