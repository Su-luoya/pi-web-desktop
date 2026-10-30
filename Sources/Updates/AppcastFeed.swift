/// 自建 appcast：`appcast` 分支上的一个静态 JSON。
///
/// 为什么存在：GitHub 未认证 API 每小时只给 60 次，而且按出口 IP 共享，配额耗尽
/// 时桌面更新会直接失败（GitHub #225）。appcast 走 `raw.githubusercontent.com`
/// 的 CDN，不消耗 API 配额，一个请求就带齐「最新 tag + zip 直链 + SHA-256」，
/// 因此检查与安装都不必再问 `api.github.com`。
///
/// 信任边界：本类型只做结构解析。zip 地址与校验值的形态由
/// `DesktopAppReleaseAssetSelector.select` 校验（必须钉死在
/// `github.com/<repo>/releases/download/<tag>/<name>`，SHA-256 必须是 64 位十六
/// 进制），因此 feed 的内容无法把下载引到别的域名。

import Foundation

enum AppcastFeed {
    /// feed 的主机。响应最终落点不是它就一律作废（不跟随到别的主机）。
    static let host = "raw.githubusercontent.com"
    /// feed 在仓库里的位置：`appcast` 分支根目录的 `appcast.json`。
    ///
    /// 单独分支而不是 `main`：`main` 有分支保护（必须过 PR + CI），而这份文件是
    /// 发布流程自动生成的派生数据，不该为它走一遍评审；分支由
    /// `.github/workflows/appcast.yml` 在 Release 正式发布后维护。
    static let branch = "appcast"
    static let path = "appcast.json"
    /// feed 结构版本。不认识的版本按「解析失败」处理，调用方回落到 GitHub API。
    static let schema = 1

    static var url: URL? {
        URL(string: "https://\(host)/\(UpdateCheckUpstream.desktopRepository)/\(branch)/\(path)")
    }

    struct Zip: Equatable {
        var name: String
        var url: URL
        var sha256: String
    }

    struct Release: Equatable {
        var tag: String
        var version: String
        var zip: Zip
    }

    /// 响应最终落点是否可信：必须仍是 feed 主机。
    static func allows(finalURL: URL) -> Bool {
        finalURL.scheme?.lowercased() == "https" && finalURL.host?.lowercased() == host
    }

    /// 解析 feed。结构不合法（不是 JSON、schema 不认识、缺字段）时返回 nil，
    /// 让调用方回落到 GitHub API，而不是把「feed 坏了」当成更新失败。
    static func releases(from data: Data) -> [Release]? {
        entries(from: data)?.compactMap(release(from:))
    }

    /// 只取 tag 列表：检查路径只需要版本号，不该因为某条 zip 字段不完整
    /// 就把整个版本的可见性一起丢掉。
    static func tags(from data: Data) -> [String]? {
        guard let entries = entries(from: data) else { return nil }
        return entries.compactMap { entry in
            guard let tag = entry["tag"] as? String, !tag.isEmpty else { return nil }
            return tag
        }
    }

    private static func entries(from data: Data) -> [[String: Any]]? {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let json = object as? [String: Any],
              json["schema"] as? Int == schema else { return nil }
        return json["releases"] as? [[String: Any]]
    }

    /// 按 tag 取条目：安装路径只认用户确认过的那个版本，不做「最新即最佳」的推断。
    static func release(tag: String, in data: Data) -> Release? {
        releases(from: data)?.first { $0.tag == tag }
    }

    private static func release(from entry: [String: Any]) -> Release? {
        guard let tag = entry["tag"] as? String, !tag.isEmpty,
              let version = entry["version"] as? String, !version.isEmpty,
              let zip = entry["zip"] as? [String: Any],
              let name = zip["name"] as? String, !name.isEmpty,
              let urlText = zip["url"] as? String,
              let url = URL(string: urlText),
              let sha256 = zip["sha256"] as? String else { return nil }
        return Release(tag: tag, version: version, zip: Zip(name: name, url: url, sha256: sha256))
    }
}
