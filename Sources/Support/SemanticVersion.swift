import Darwin
import Foundation

// MARK: - 语义化版本

/// 依赖诊断使用的语义化版本解析与比较。
///
/// 不引第三方库，只实现 Issue #6 需要的子集：可选 `v` 前缀、1–4 段数字、
/// `-prerelease` 与 `+build` 后缀。数字段逐段比较；数字段相同时带 prerelease
/// 的版本低于正式版（SemVer 2.0.0 §11）。prerelease 之间按 §11 的标识符规则
/// 比较：数字标识符按数值、字母数字标识符按 ASCII 顺序、数字标识符低于字母
/// 数字标识符、前缀相同时标识符更少者更低。GitHub #17 的更新检查依赖这条
/// 规则区分 `alpha.1` / `alpha.2` / `beta.1` / 正式版，结果因此是可预测的。

/// Semantic version parsing and comparison used by dependency and update checks.

struct SemanticVersion: Equatable, Comparable, CustomStringConvertible {
    let major: Int
    let minor: Int
    let patch: Int
    /// 第 4 段（例如 `1.2.3.4`）；只有 3 段时为 0。
    let revision: Int
    let prerelease: String?

    init(
        major: Int,
        minor: Int = 0,
        patch: Int = 0,
        revision: Int = 0,
        prerelease: String? = nil
    ) {
        self.major = major
        self.minor = minor
        self.patch = patch
        self.revision = revision
        self.prerelease = prerelease
    }

    /// 解析 `22.19.0`、`v22.19.0`、`1.2`、`1.2.3.4`、`1.2.3-rc.1+build.7`。
    /// 无法解析（空串、非数字段、超过 4 段）时返回 nil。
    init?(_ raw: String) {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if text.hasPrefix("v") || text.hasPrefix("V") {
            text.removeFirst()
        }
        if let plus = text.firstIndex(of: "+") {
            text = String(text[text.startIndex..<plus])
        }
        var prerelease: String?
        if let dash = text.firstIndex(of: "-") {
            prerelease = String(text[text.index(after: dash)...])
            text = String(text[text.startIndex..<dash])
        }
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...4).contains(parts.count) else { return nil }
        var numbers: [Int] = []
        for part in parts {
            guard !part.isEmpty,
                  part.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let value = Int(part) else { return nil }
            numbers.append(value)
        }
        self.init(
            major: numbers[0],
            minor: numbers.count > 1 ? numbers[1] : 0,
            patch: numbers.count > 2 ? numbers[2] : 0,
            revision: numbers.count > 3 ? numbers[3] : 0,
            prerelease: (prerelease?.isEmpty == false) ? prerelease : nil
        )
    }

    var description: String {
        var text = "\(major).\(minor).\(patch)"
        if revision != 0 { text += ".\(revision)" }
        if let prerelease { text += "-\(prerelease)" }
        return text
    }

    static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        if lhs.patch != rhs.patch { return lhs.patch < rhs.patch }
        if lhs.revision != rhs.revision { return lhs.revision < rhs.revision }
        switch (lhs.prerelease, rhs.prerelease) {
        case (nil, nil): return false
        case (nil, _): return false
        case (_, nil): return true
        case let (left?, right?): return Self.prereleasePrecedes(left, right)
        }
    }

    /// SemVer 2.0.0 §11 的 prerelease 先后关系。
    ///
    /// `alpha.2` < `alpha.10`（数字标识符按数值比较），`alpha.2` < `beta.1`
    /// （字母数字标识符按 ASCII 顺序），`alpha.1` < `alpha.1.1`（前缀相同、
    /// 标识符更少者更低），`1.0.0-1` < `1.0.0-alpha`（数字标识符低于字母数字）。
    /// 大小写按 ASCII 顺序处理，不做不区分大小写的回退（与 SemVer 一致）。
    static func prereleasePrecedes(_ lhs: String, _ rhs: String) -> Bool {
        let left = lhs.split(separator: ".", omittingEmptySubsequences: false)
        let right = rhs.split(separator: ".", omittingEmptySubsequences: false)
        for index in 0..<min(left.count, right.count) {
            let leftPart = String(left[index])
            let rightPart = String(right[index])
            if leftPart == rightPart { continue }
            let leftNumber = Int(leftPart)
            let rightNumber = Int(rightPart)
            switch (leftNumber, rightNumber) {
            case let (leftValue?, rightValue?):
                if leftValue != rightValue { return leftValue < rightValue }
                continue
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            case (nil, nil):
                return leftPart < rightPart
            }
        }
        return left.count < right.count
    }

    /// 从命令输出里取第一个可解析的版本，例如 `v22.19.0`、`pi-web 1.2.3`、
    /// `1.2.3 (node 22.19.0)`。取不到时返回 nil（对应诊断的 unknown）。
    static func firstVersion(in output: String) -> SemanticVersion? {
        for token in output.split(whereSeparator: { $0.isWhitespace }) {
            let cleaned = token.trimmingCharacters(in: CharacterSet(charactersIn: "vV()[]{},;:=<>"))
            if let version = SemanticVersion(cleaned) { return version }
        }
        return nil
    }
}
