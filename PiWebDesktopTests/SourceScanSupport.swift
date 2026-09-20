import XCTest

/// 源码级断言的共享入口。
///
/// 这组测试直接读生产代码文本做结构断言：重构把生产代码从平铺的
/// `Sources/*.swift` 挪进了按领域划分的子目录（`Sources/App`、`Sources/Updates`…），
/// 所以这里按**文件名**在运行时枚举 `Sources/` 定位，而不是写死相对路径：
/// 断言内容不变，文件在目录树里的位置可以继续调整。
///
/// 独立运行器（没有完整 Xcode 时用的本地测试台）把仓库镜像到一个临时目录，
/// 顶层条目都是符号链接，因此定位时统一解析符号链接后再比较前缀。
enum SourceScan {

    /// 仓库根目录（测试文件位于 `<root>/PiWebDesktopTests/`）。先用编译期记录的
    /// 本文件路径（`#filePath`）向上两级，它与进程工作目录无关；再用当前工作
    /// 目录逐级向上回退，两种运行方式（xcodebuild / 独立运行器）都能定位。
    static let repositoryRoot: URL = {
        let derived = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .resolvingSymlinksInPath()
        if isRepositoryRoot(derived) {
            return derived
        }
        var candidate = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .resolvingSymlinksInPath()
        while candidate.path != "/" {
            if isRepositoryRoot(candidate) {
                return candidate
            }
            candidate = candidate.deletingLastPathComponent()
        }
        XCTFail("无法从 \(derived.path) 或当前工作目录定位带 Sources/ 的仓库根目录")
        return derived
    }()

    /// `Sources/` 目录本身（解析符号链接，独立运行器里它指向真实工作树）。
    static let sourcesRoot: URL = repositoryRoot
        .appendingPathComponent("Sources")
        .resolvingSymlinksInPath()

    /// `Sources/` 下所有 Swift 文件的相对路径（相对 `Sources/`），按路径排序。
    static let sourceFiles: [String] = {
        let root = sourcesRoot
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: nil
        ) else {
            return []
        }
        let prefix = root.standardizedFileURL.path
        var found: [String] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let path = url.resolvingSymlinksInPath().standardizedFileURL.path
            guard path.hasPrefix(prefix + "/") else { continue }
            found.append(String(path.dropFirst(prefix.count + 1)))
        }
        return found.sorted()
    }()

    private static func isRepositoryRoot(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.appendingPathComponent("Sources").path)
    }

    /// 按文件名定位唯一的源文件；找不到或存在同名文件时立即失败，避免断言被悄悄跳过。
    static func url(named fileName: String) throws -> URL {
        let matches = sourceFiles.filter { $0.split(separator: "/").last.map(String.init) == fileName }
        guard matches.count == 1, let match = matches.first else {
            XCTFail("Sources/ 下应当有唯一的 \(fileName)，实际匹配 \(matches.count) 个：\(matches)")
            throw SourceScanError.notFound(fileName: fileName, matches: matches)
        }
        return sourcesRoot.appendingPathComponent(match)
    }

    /// 读取一个源文件的文本。
    static func text(named fileName: String) throws -> String {
        try String(contentsOf: url(named: fileName), encoding: .utf8)
    }

    /// 读一族被拆分出来的文件（`AppDelegate.swift` + `AppDelegate+*.swift`）并拼接：
    /// 断言只关心内容，不关心某段代码落在这一族的哪个文件里。
    static func text(ofFamily namePrefix: String) throws -> String {
        try joined(matches: sourceFiles.filter { relativePath in
            guard let last = relativePath.split(separator: "/").last.map(String.init) else { return false }
            return last == "\(namePrefix).swift" || last.hasPrefix("\(namePrefix)+")
        }, described: "\(namePrefix).swift 或 \(namePrefix)+*.swift")
    }

    /// 按文件名前缀取源文件文本：`["PiProcess", "PiCLIUpdate"]` 覆盖这两个领域在
    /// 重构中被拆分出来的所有文件。前缀一个都没命中时立即失败，避免断言静默失去覆盖。
    static func text(matching prefixes: [String]) throws -> String {
        try joined(matches: sourceFiles.filter { relativePath in
            guard let last = relativePath.split(separator: "/").last.map(String.init) else { return false }
            let stem = last.hasSuffix(".swift") ? String(last.dropLast(".swift".count)) : last
            return prefixes.contains { stem.hasPrefix($0) }
        }, described: "文件名以 \(prefixes.joined(separator: " / ")) 开头的源文件")
    }

    private static func joined(matches: [String], described description: String) throws -> String {
        guard !matches.isEmpty else {
            XCTFail("Sources/ 下应当有\(description)，实际一个都没有")
            throw SourceScanError.notFound(fileName: description, matches: [])
        }
        return try matches
            .map { try String(contentsOf: sourcesRoot.appendingPathComponent($0), encoding: .utf8) }
            .joined(separator: "\n")
    }

    /// 去掉 `//` 行注释与行尾注释后的代码文本：注释里提到被禁止的 API 名字是允许的，
    /// 真正要断言的是代码里没有这些调用。
    static func codeText(of source: String) -> String {
        source
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> String in
                let trimmed = line.drop { $0 == " " || $0 == "\t" }
                guard !trimmed.hasPrefix("//") else { return "" }
                guard let range = line.range(of: "//") else { return String(line) }
                return String(line[line.startIndex..<range.lowerBound])
            }
            .joined(separator: "\n")
    }
}

enum SourceScanError: Error {
    case notFound(fileName: String, matches: [String])
}
