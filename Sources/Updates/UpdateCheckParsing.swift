/// Parses upstream release metadata into a comparable version.

import Foundation

// MARK: - 请求身份

/// 固定 User-Agent。只由应用标识与版本组成，不含用户名、主机名或设备名。
struct UpdateCheckIdentity: Equatable {
    var appName: String
    var version: String?
    var bundleIdentifier: String?

    init(appName: String = "Pi Web Desktop", version: String? = nil, bundleIdentifier: String? = nil) {
        self.appName = appName
        self.version = version
        self.bundleIdentifier = bundleIdentifier
    }

    /// 运行中的应用自己：版本与 bundle identifier 只从 Info.plist 读取，不在
    /// 源码里写版本字面值。
    static var current: UpdateCheckIdentity {
        let probe = ApplicationInstallationProbe.current
        return UpdateCheckIdentity(
            appName: "Pi Web Desktop",
            version: probe.version,
            bundleIdentifier: probe.bundleIdentifier
        )
    }

    /// `Pi-Web-Desktop/<版本> (<bundle id>)` 形态（不在源码里写版本字面值）；
    /// 缺字段时省略对应片段，至少保留应用名。
    var userAgent: String {
        var token = appName.replacingOccurrences(of: " ", with: "-")
        if let version, !version.isEmpty { token += "/\(version)" }
        if let bundleIdentifier, !bundleIdentifier.isEmpty {
            token += " (\(bundleIdentifier))"
        }
        return token
    }
}

// MARK: - 响应解析

/// 解析失败的原因（只用于“标记 unknown”和用户可见文案，不含原始文本）。
enum UpdateParseFailure: String, Error, Equatable {
    case malformedJSON
    case unexpectedStructure
    case emptyReleaseList
    case missingVersion
    case unparsableVersion
}

/// 上游最新版本（已解析）。
struct UpdateUpstreamVersion: Equatable {
    var version: String
    var semanticVersion: SemanticVersion
    /// GitHub Release 的 prerelease 标记；npm 端点按版本形态推断。
    var isPrerelease: Bool
    /// GitHub Releases 的原始 tag；npm 结果没有 tag。
    var tag: String?

    init(
        version: String,
        semanticVersion: SemanticVersion,
        isPrerelease: Bool,
        tag: String? = nil
    ) {
        self.version = version
        self.semanticVersion = semanticVersion
        self.isPrerelease = isPrerelease
        self.tag = tag
    }
}

/// 只做 JSON 解析的纯函数集合：不联网、不读文件，可直接用字符串断言。
enum UpdateResponseParser {
    /// 解析 GitHub Releases 列表：忽略 draft，按语义化版本取最大者（含预发布）。
    static func latestGitHubRelease(from data: Data) -> Result<UpdateUpstreamVersion, UpdateParseFailure> {
        guard let object = try? JSONSerialization.jsonObject(with: data) else {
            return .failure(.malformedJSON)
        }
        guard let releases = object as? [[String: Any]] else {
            return .failure(.unexpectedStructure)
        }
        var best: (tag: String, version: SemanticVersion, prerelease: Bool)?
        for release in releases {
            if (release["draft"] as? Bool) == true { continue }
            guard let tag = release["tag_name"] as? String else { continue }
            guard let version = SemanticVersion(tag) else { continue }
            let prerelease = (release["prerelease"] as? Bool) ?? (version.prerelease != nil)
            if let current = best {
                if current.version < version {
                    best = (tag, version, prerelease)
                }
            } else {
                best = (tag, version, prerelease)
            }
        }
        guard let best else {
            return .failure(releases.isEmpty ? .emptyReleaseList : .missingVersion)
        }
        return .success(UpdateUpstreamVersion(
            version: best.version.description,
            semanticVersion: best.version,
            isPrerelease: best.prerelease,
            tag: best.tag
        ))
    }

    /// 解析 npm registry `/latest` 文档：只读顶层 `version` 字段。
    static func latestNpmVersion(from data: Data) -> Result<UpdateUpstreamVersion, UpdateParseFailure> {
        guard let object = try? JSONSerialization.jsonObject(with: data) else {
            return .failure(.malformedJSON)
        }
        guard let document = object as? [String: Any] else {
            return .failure(.unexpectedStructure)
        }
        guard let text = document["version"] as? String else {
            return .failure(.missingVersion)
        }
        guard let version = SemanticVersion(text) else {
            return .failure(.unparsableVersion)
        }
        return .success(UpdateUpstreamVersion(
            version: version.description,
            semanticVersion: version,
            isPrerelease: version.prerelease != nil,
            tag: nil
        ))
    }
}
