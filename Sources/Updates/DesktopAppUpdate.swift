import AppKit
import CryptoKit
import Foundation

private final class DesktopAppArchiveRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(DesktopAppReleaseAssetSelector.allowsAssetRedirect(request.url) ? request : nil)
    }
}

/// 允许下载的桌面应用发布资产。
struct DesktopAppReleaseAsset: Equatable {
    var version: String
    var downloadURL: URL
    var sha256: String?
    var releaseTag: String? = nil
    var assetName: String? = nil
}

enum DesktopAppUpdateResult: Equatable {
    case updated(version: String)
    case failed(DesktopAppUpdateFailure)

    var message: String {
        switch self {
        case .updated(let version): return "桌面应用已更新到 \(version)，应用即将重新启动。"
        case .failed(let failure): return failure.text
        }
    }
}

enum DesktopAppUpdateFailure: String, Error, Equatable {
    case unsupportedInstallation, missingAsset, invalidAssetURL, downloadFailed
    case invalidArchive, checksumUnavailable, checksumMismatch, invalidBundle
    case notWritable, replacementFailed, relaunchFailed

    var text: String {
        switch self {
        case .unsupportedInstallation: return "当前应用不是从 /Applications 安装，无法自动更新。"
        case .missingAsset: return "该版本没有可用的桌面应用 ZIP 发布包。"
        case .invalidAssetURL: return "更新包地址不在允许的 GitHub 主机上。"
        case .downloadFailed: return "更新包下载失败。"
        case .invalidArchive: return "更新包不是有效的桌面应用归档。"
        case .checksumUnavailable: return "更新包缺少 SHA-256 校验值，已停止安装。"
        case .checksumMismatch: return "更新包校验失败，已停止安装。"
        case .invalidBundle: return "更新包中的应用无法验证，已停止安装。"
        case .notWritable: return "当前应用目录不可写，无法自动更新。"
        case .replacementFailed: return "替换桌面应用失败，原应用未被删除。"
        case .relaunchFailed: return "应用已更新，但重新启动失败，请从 /Applications 手动打开。"
        }
    }
}

enum DesktopAppReleaseAssetSelector {
    static let allowedHost = UpdateCheckUpstream.githubHost
    static let allowedAssetHost = "github.com"
    static let allowedRedirectHosts: Set<String> = [
        "github.com", "objects.githubusercontent.com", "release-assets.githubusercontent.com"
    ]
    static let archivePrefix = "Pi-Web-Desktop-"

    static func select(
        version: String,
        assets: [(name: String, url: URL)],
        checksum: String? = nil,
        releaseTag: String? = nil
    ) -> DesktopAppReleaseAsset? {
        let tag = releaseTag ?? version
        guard let archive = assets.first(where: { isArchiveName($0.name, version: version) }),
              allowsDownloadURL(archive.url, assetName: archive.name, releaseTag: tag),
              let checksum = normalizedChecksum(checksum) else { return nil }
        return DesktopAppReleaseAsset(
            version: version, downloadURL: archive.url, sha256: checksum,
            releaseTag: tag, assetName: archive.name
        )
    }

    static func isArchiveName(_ name: String, version: String) -> Bool {
        let prefix = "\(archivePrefix)\(version)"
        guard name.hasPrefix(prefix), name.hasSuffix(".zip") else { return false }
        if name == "\(prefix).zip" { return true }
        let buildPrefix = "\(prefix)+build."
        guard name.hasPrefix(buildPrefix) else { return false }
        let build = name.dropFirst(buildPrefix.count).dropLast(4)
        return !build.isEmpty && build.allSatisfy { $0.isASCII && $0.isNumber }
    }

    static func allowsAssetRedirect(_ url: URL?) -> Bool {
        guard let url else { return false }
        return url.scheme?.lowercased() == "https"
            && allowedRedirectHosts.contains(url.host?.lowercased() ?? "")
            && url.user == nil && url.password == nil
            && url.pathExtension.lowercased() == "zip"
    }

    static func allowsChecksumRedirect(_ url: URL?) -> Bool {
        guard let url else { return false }
        return url.scheme?.lowercased() == "https"
            && allowedRedirectHosts.contains(url.host?.lowercased() ?? "")
            && url.user == nil && url.password == nil
            && url.pathExtension.lowercased() == "sha256"
    }

    static func allowsDownloadURL(_ url: URL, assetName: String? = nil, releaseTag: String? = nil) -> Bool {
        guard url.scheme?.lowercased() == "https", url.host?.lowercased() == allowedAssetHost,
              url.user == nil, url.password == nil, url.pathExtension.lowercased() == "zip",
              url.query == nil, url.fragment == nil else { return false }
        return allowsPinnedAssetPath(url, assetName: assetName, releaseTag: releaseTag)
    }

    static func allowsChecksumDownloadURL(_ url: URL, assetName: String? = nil, releaseTag: String? = nil) -> Bool {
        guard url.scheme?.lowercased() == "https", url.host?.lowercased() == allowedAssetHost,
              url.user == nil, url.password == nil, url.pathExtension.lowercased() == "sha256",
              url.query == nil, url.fragment == nil else { return false }
        return allowsPinnedAssetPath(url, assetName: assetName, releaseTag: releaseTag)
    }

    private static func allowsPinnedAssetPath(_ url: URL, assetName: String?, releaseTag: String?) -> Bool {
        guard let assetName, let releaseTag, isReleaseTag(releaseTag),
              url.lastPathComponent.removingPercentEncoding == assetName,
              url.path == "/Su-luoya/pi-web-desktop/releases/download/\(releaseTag)/\(assetName)" else {
            return false
        }
        return true
    }

    static func isReleaseTag(_ tag: String) -> Bool {
        !tag.isEmpty && tag.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "._-".contains($0)) }
    }

    static func normalizedChecksum(_ value: String?) -> String? {
        guard let value else { return nil }
        let first = value.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r" }).first
        guard let first, first.count == 64, first.allSatisfy({ $0.isHexDigit }) else { return nil }
        return String(first).lowercased()
    }
}

protocol DesktopAppUpdateInstalling: AnyObject {
    func install(asset: DesktopAppReleaseAsset, completion: @escaping (DesktopAppUpdateResult) -> Void)
}

final class DesktopAppUpdateInstaller: NSObject, DesktopAppUpdateInstalling {
    private let applicationURL: URL
    private let fileManager: FileManager
    private let session: URLSession?
    private let completionQueue: DispatchQueue
    private lazy var ownedDownloadSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = UpdateChecker.requestTimeout
        configuration.timeoutIntervalForResource = UpdateChecker.requestTimeout
        return URLSession(configuration: configuration, delegate: DesktopAppArchiveRedirectDelegate(), delegateQueue: nil)
    }()
    private var installInProgress = false
    private var completionDelivered = false
    private var activeCompletion: ((DesktopAppUpdateResult) -> Void)?
    private var replacementProcessDidStart = false
    private let stateLock = NSLock()

    init(applicationURL: URL = Bundle.main.bundleURL, fileManager: FileManager = .default,
         session: URLSession = .shared, completionQueue: DispatchQueue = .main) {
        self.applicationURL = applicationURL.standardizedFileURL
        self.fileManager = fileManager
        self.session = session == URLSession.shared ? nil : session
        self.completionQueue = completionQueue
    }

    func install(asset: DesktopAppReleaseAsset, completion: @escaping (DesktopAppUpdateResult) -> Void) {
        stateLock.lock()
        let busy = installInProgress || replacementProcessDidStart
        if !busy { installInProgress = true; completionDelivered = false; activeCompletion = completion }
        stateLock.unlock()
        guard !busy else { completionQueue.async { completion(.failed(.replacementFailed)) }; return }
        guard let tag = asset.releaseTag, let name = asset.assetName,
              DesktopAppReleaseAssetSelector.allowsDownloadURL(asset.downloadURL, assetName: name, releaseTag: tag) else {
            finish(.failed(.invalidAssetURL)); return
        }
        let id = Bundle(url: applicationURL)?.bundleIdentifier
        let root = URL(fileURLWithPath: "/Applications", isDirectory: true)
            .resolvingSymlinksInPath().path
        let installed = applicationURL.resolvingSymlinksInPath()
        guard Self.canReplaceInstalledApp(applicationURL, fileManager: fileManager),
              installed.path == root + "/Pi-Web-Desktop.app" else {
            finish(.failed(.unsupportedInstallation)); return
        }
        guard id == "io.github.su-luoya.pi-web-desktop" else { finish(.failed(.invalidBundle)); return }
        guard Self.canWriteApplicationDirectory(applicationURL: applicationURL, fileManager: fileManager) else {
            finish(.failed(.notWritable)); return
        }
        guard let expectedHash = DesktopAppReleaseAssetSelector.normalizedChecksum(asset.sha256) else {
            finish(.failed(.checksumUnavailable)); return
        }

        let downloader = session ?? ownedDownloadSession
        let task = downloader.downloadTask(with: URLRequest(url: asset.downloadURL)) { [weak self] file, response, error in
            guard let self, let file, error == nil,
                  let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode,
                  let finalURL = http.url,
                  DesktopAppReleaseAssetSelector.allowsAssetRedirect(finalURL) else {
                self?.finish(.failed(.downloadFailed)); return
            }
            do {
                guard try Self.sha256(of: file) == expectedHash else { self.finish(.failed(.checksumMismatch)); return }
                let staging = self.fileManager.temporaryDirectory.appendingPathComponent("PiWebDesktop-update-\(UUID().uuidString)", isDirectory: true)
                try self.fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
                try self.unzip(file, into: staging)
                let staged = try Self.findBundle(in: staging, fileManager: self.fileManager)
                guard Self.isValidBundle(staged, fileManager: self.fileManager, expectedBundleIdentifier: id, expectedVersion: asset.version) else {
                    try? self.fileManager.removeItem(at: staging); self.finish(.failed(.invalidBundle)); return
                }
                try self.launchReplacement(stagedApp: staged, staging: staging)
                self.finish(.updated(version: asset.version))
            } catch let failure as DesktopAppUpdateFailure { self.finish(.failed(failure)) }
            catch { self.finish(.failed(.invalidArchive)) }
        }
        task.resume()
    }

    private func finish(_ result: DesktopAppUpdateResult) {
        stateLock.lock(); let callback = completionDelivered ? nil : activeCompletion
        completionDelivered = true; activeCompletion = nil; installInProgress = false; stateLock.unlock()
        if let callback { completionQueue.async { callback(result) } }
    }

    private func launchReplacement(stagedApp: URL, staging: URL) throws {
        let script = fileManager.temporaryDirectory.appendingPathComponent("PiWebDesktop-replace-\(UUID().uuidString).sh")
        let old = Self.shellQuote(applicationURL.path), new = Self.shellQuote(stagedApp.path)
        let parent = Self.shellQuote(applicationURL.deletingLastPathComponent().path)
        let stagingArg = Self.shellQuote(staging.path), scriptArg = Self.shellQuote(script.path)
        let pid = Self.shellQuote(String(ProcessInfo.processInfo.processIdentifier))
        let body = """
        #!/bin/sh
        set -eu
        old=\(old); new=\(new); parent=\(parent); staging=\(stagingArg); script=\(scriptArg); pid=\(pid)
        deadline=$(( $(date +%s) + 60 ))
        while kill -0 "$pid" 2>/dev/null; do
            if [ "$(date +%s)" -ge "$deadline" ]; then rm -rf "$staging"; rm -f "$script"; exit 1; fi
            sleep 0.1
        done
        backup="$parent/.PiWebDesktop.previous.$$"
        while [ -e "$backup" ]; do backup="$backup.x"; done
        if ! mv "$old" "$backup"; then rm -rf "$staging"; rm -f "$script"; exit 1; fi
        if ! mv "$new" "$old"; then mv "$backup" "$old" || true; rm -rf "$staging"; rm -f "$script"; exit 1; fi
        rm -rf "$backup" "$staging"; rm -f "$script"
        open -n "$old"
        """
        try body.write(to: script, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/bin/sh"); process.arguments = [script.path]
        stateLock.lock(); let alreadyStarted = replacementProcessDidStart
        if !alreadyStarted { replacementProcessDidStart = true }; stateLock.unlock()
        guard !alreadyStarted else { try? fileManager.removeItem(at: script); throw DesktopAppUpdateFailure.replacementFailed }
        do { try process.run() } catch {
            stateLock.lock(); replacementProcessDidStart = false; stateLock.unlock()
            try? fileManager.removeItem(at: script); throw DesktopAppUpdateFailure.replacementFailed
        }
        NSApp.terminate(nil)
    }

    private static func shellQuote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    private func unzip(_ archive: URL, into directory: URL) throws {
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", archive.path, directory.path]
        try process.run(); process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw DesktopAppUpdateFailure.invalidArchive }
        try? fileManager.removeItem(at: archive)
    }
    private static func findBundle(in directory: URL, fileManager: FileManager) throws -> URL {
        let root = directory.resolvingSymlinksInPath().path + "/"
        guard let app = try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first(where: {
            $0.pathExtension == "app" && $0.lastPathComponent == "Pi-Web-Desktop.app"
                && $0.resolvingSymlinksInPath().path.hasPrefix(root)
        }) else { throw DesktopAppUpdateFailure.invalidArchive }
        return app
    }
    static func canReplaceInstalledApp(_ app: URL, fileManager: FileManager = .default) -> Bool {
        let root = URL(fileURLWithPath: "/Applications", isDirectory: true)
            .resolvingSymlinksInPath().path
        let originalPath = app.path.hasSuffix("/") ? String(app.path.dropLast()) : app.path
        let appURL = URL(fileURLWithPath: originalPath, isDirectory: true).standardizedFileURL
        let resolvedApp = appURL.resolvingSymlinksInPath()
        let resolvedParent = appURL.deletingLastPathComponent().resolvingSymlinksInPath()
        guard appURL.path == originalPath, appURL.pathExtension == "app",
              appURL.lastPathComponent == "Pi-Web-Desktop.app", appURL.path == root + "/Pi-Web-Desktop.app",
              resolvedApp.path == appURL.path, resolvedParent.path == root,
              fileManager.fileExists(atPath: appURL.appendingPathComponent("Contents/Info.plist").path) else { return false }
        return true
    }

    static func isRunningFromApplications(_ url: URL) -> Bool {
        canReplaceInstalledApp(url)
    }
    static func canWriteApplicationDirectory(applicationURL: URL, fileManager: FileManager = .default) -> Bool {
        guard canReplaceInstalledApp(applicationURL, fileManager: fileManager) else { return false }
        let probe = applicationURL.deletingLastPathComponent().appendingPathComponent(".PiWebDesktop-write-test-\(UUID().uuidString)")
        do { try Data().write(to: probe); try fileManager.removeItem(at: probe); return true }
        catch { try? fileManager.removeItem(at: probe); return false }
    }
    private static func isValidBundle(_ bundle: URL, fileManager: FileManager,
                                      expectedBundleIdentifier: String?, expectedVersion: String) -> Bool {
        guard let object = Bundle(url: bundle), object.bundleIdentifier == expectedBundleIdentifier,
              object.bundleIdentifier == "io.github.su-luoya.pi-web-desktop",
              let version = object.infoDictionary?["CFBundleShortVersionString"] as? String,
              SemanticVersion(version)?.description == expectedVersion,
              let executable = object.executableURL, fileManager.isExecutableFile(atPath: executable.path),
              fileManager.fileExists(atPath: bundle.appendingPathComponent("Contents/Info.plist").path) else { return false }
        return true
    }
    private static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        var hasher = SHA256()
        while true { let chunk = try handle.read(upToCount: 1024 * 1024) ?? Data(); if chunk.isEmpty { break }; hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

#if DEBUG
private enum DesktopAppUpdateSelfCheck {
    static func verify() {
        assert(DesktopAppReleaseAssetSelector.isReleaseTag("v2.5.0"))
        assert(!DesktopAppReleaseAssetSelector.isReleaseTag("v2/5.0"))
        assert(DesktopAppReleaseAssetSelector.normalizedChecksum(String(repeating: "A", count: 64)) != nil)
        assert(DesktopAppReleaseAssetSelector.normalizedChecksum("not-a-checksum") == nil)
    }
}
#endif
