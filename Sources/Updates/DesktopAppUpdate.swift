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
    /// 菜单入口拿到的结论不满足 `DesktopAppUpdateInstallPolicy` 的准入条件。
    case unconfirmedUpdate

    var text: String {
        switch self {
        case .unsupportedInstallation: return "当前应用不是从 /Applications 安装，无法自动更新。"
        case .unconfirmedUpdate: return "本次检查结果不是本轮从上游确认的可用更新，或目标版本不比当前版本新；请重新检查更新后再试。"
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

/// 人工「更新桌面应用」流程的目标：要装的版本与要按哪个 tag 联网复核。
struct DesktopAppUpdateInstallTarget: Equatable {
    var version: String
    var releaseTag: String
}

/// 人工「更新桌面应用」流程的准入判定（GitHub #176）。
///
/// 自动安装必须要求 `origin == .network`（只有本次从白名单主机取回的结果可用，见
/// `UpdateCheckOrigin` 的来源文档）。人工流程不一样：它由用户在菜单里点出、看到
/// 版本号并确认之后才下载，而且 `AppDelegate+UpdateChecks.swift` 的
/// `downloadAndInstallDesktopApp` 会按 tag 重新联网取 `releases/tags/<tag>`、钉死
/// `releases/download/<tag>/<assetName>`、用 GitHub 公布的 `.sha256` 校验，最后
/// 核对 bundle id 与 `CFBundleShortVersionString`（见本文件 `isValidBundle`）。
/// 版本值在这里只是待确认的线索，不是信任来源。
///
/// 所以条件请求命中 304（`freshness == .fresh`、`origin == .cachedFallback`）也要
/// 允许进入下载流程：304 是成功的网络往返，只把缓存结论当「提示」会让菜单入口在
/// 每一次热缓存检查后都报「该版本没有可用的桌面应用 ZIP 发布包」。
///
/// 代价是版本字符串可能来自本机缓存文件（同一用户可改写），因此这里保留三道硬
/// 条件：本轮网络往返成功（`freshness == .fresh`）、上游结构验证通过
/// (`confidence == .verified`)、目标版本比正在运行的版本新。缓存的版本字符串决定
/// 下载哪个资产名，没有最后这道比较，改写缓存就能让人工流程装回旧版本。
enum DesktopAppUpdateInstallPolicy {
    static func installTarget(
        for result: UpdateCheckResult?,
        runningVersion: String?
    ) -> DesktopAppUpdateInstallTarget? {
        guard let result,
              result.status == .updateAvailable,
              result.freshness == .fresh,
              result.confidence == .verified,
              let version = result.latestVersion,
              let releaseTag = result.upstreamTag,
              let candidate = SemanticVersion(version),
              let running = runningVersion.flatMap({ SemanticVersion($0) }),
              candidate > running else { return nil }
        return DesktopAppUpdateInstallTarget(version: version, releaseTag: releaseTag)
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

    /// 允许跟随的重定向目标：必须还在 GitHub 的下载主机里，且文件名后缀仍是被期望的
    /// 资产类型。GitHub 的签名直链把文件名放在查询串里
    /// （`response-content-disposition=attachment; filename=….zip`，`rscd` 同义），
    /// 路径却是 `github-production-release-asset/<id>/<uuid>` 这样的不透明 id：只看
    /// `url.pathExtension` 会把真实的重定向当成非法，下载与校验值读取全部失败
    /// （GitHub #177，真机 E2E 发现）。
    static func allowsAssetRedirect(_ url: URL?) -> Bool {
        allowsRedirect(url, requiringExtension: "zip")
    }

    static func allowsChecksumRedirect(_ url: URL?) -> Bool {
        allowsRedirect(url, requiringExtension: "sha256")
    }

    private static func allowsRedirect(_ url: URL?, requiringExtension expected: String) -> Bool {
        guard let url, url.scheme?.lowercased() == "https",
              url.user == nil, url.password == nil,
              allowedRedirectHosts.contains(url.host?.lowercased() ?? "") else { return false }
        if url.pathExtension.lowercased() == expected { return true }
        guard let name = signedFileName(in: url)?.lowercased() else { return false }
        return name.hasSuffix(".\(expected)")
    }

    /// 从签名直链的查询串里取回原始资产名：`response-content-disposition` 与
    /// `rscd` 都长成 `attachment; filename=<asset>`；拿不到或没有 filename 时返回 nil。
    static func signedFileName(in url: URL) -> String? {
        for key in ["response-content-disposition", "rscd"] {
            guard let value = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                        .queryItems?.first(where: { $0.name.lowercased() == key })?.value,
                  let filename = value.range(of: "filename=", options: .caseInsensitive) else { continue }
            var name = String(value[filename.upperBound...])
            if let semicolon = name.firstIndex(of: ";") { name = String(name[..<semicolon]) }
            name = name.trimmingCharacters(in: .whitespacesAndNewlines)
            name = name.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            if !name.isEmpty { return name }
        }
        return nil
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
    static func canReplaceInstalledApp(_ app: URL,
                                       applicationsRoot: URL = URL(fileURLWithPath: "/Applications", isDirectory: true),
                                       fileManager: FileManager = .default) -> Bool {
        let root = applicationsRoot.resolvingSymlinksInPath().path
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
