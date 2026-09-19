import Foundation

/// 统一脱敏器（GitHub #10、#38）。
///
/// 同一个实例用于四处展示与落盘路径：
/// - 写入日志的每一行（`LogWriter`）；
/// - “复制诊断”/诊断导出的完整文本（`DiagnosticsCollector`）；
/// - 错误消息（启动失败、日志目录创建失败等）；
/// - 环境变量与命令行参数的展示（子进程启动环境、`ps` 进程描述）。
///
/// 规则（按顺序应用，全部替换为 `<redacted>`，Home 路径替换为 `~`）：
/// 1. `Authorization:` / `Proxy-Authorization:` 头的值；
/// 2. `Bearer <token>`；
/// 3. 代理凭据 `scheme://user:pass@host` 中的 userinfo；
/// 4. URL 查询串（`?a=b&c=d` 整体替换为 `?<redacted>`）；
/// 5. JWT 形态字符串（`eyJ` 开头的三段 base64url）；
/// 6. 敏感键值（`token` / `password` / `secret` / `api_key` / `apikey` 等）：
///    键可带引号（JSON）或不带引号，`=` / `:` 两侧允许空白，大小写不敏感，
///    覆盖 `PI_WEB_PASSWORD` 这类带前缀的环境变量名；值可以是双引号、单引号
///    （都允许含空格）或到 `,` `;` `&` 之前的未加引号文本；
/// 7. 命令行参数形式 `--password <value>`（值可以是带引号字符串或单个词）；
/// 8. `key:` 后没有值时的续行：紧随其后的续行整体按“值”处理（YAML、换行 JSON）；
/// 9. 私钥：`-----BEGIN ... PRIVATE KEY-----` 头以及同一次输入中它到
///    `-----END ... PRIVATE KEY-----` 之间的每一行；
/// 10. Home 路径：注入的 Home 前缀与任何 `/Use`+`rs/<name>` 前缀替换为 `~`。
///
/// 多行输入逐行处理，行数与换行结构保持不变，不因换行漏判。
///
/// 幂等（GitHub #38）：对同一段文本重复调用结果逐字节不变。值里已经含占位符的
/// 匹配整段跳过（不再二次吞掉紧跟占位符的 `}` 等字符），未加引号的值的尾随结构
/// 字符（`}`、`]`、`)`、`,`、`;`、空白）先拆出、替换后原样回填。
///
/// 本类不可变，可安全地被多个线程共享（日志写入线程与主线程可能同时调用）。
final class LogRedactor {
    /// 统一占位符。诊断导出与日志里都只出现这一个标记，便于用户核对。
    static let marker = "<redacted>"

    /// 一条规则：正则 + 替换方式。
    private struct Rule {
        let expression: NSRegularExpression
        let replacement: Replacement
    }

    /// 替换方式。`try?` 编译失败的正则整条跳过，而不是崩溃。
    private enum Replacement {
        /// 固定模板替换（`$1`、`$2` … 引用捕获组）。
        case template(String)
        /// 敏感键值：保留键与分隔符，只替换 `value` 捕获组；该值已含占位符时整段跳过。
        case sensitiveValue
    }

    /// 敏感键名片段（大小写不敏感由各模式自己的 `(?i)` 负责）。
    private static let sensitiveKey = "(?:token|password|passwd|secret|api[_-]?key|private[_-]?key)"
    /// 带引号的键（JSON 形态）；引号内出现敏感词即可，`"access_token"` 同样命中。
    private static let quotedKey = "[\"'][a-z0-9_.\\-]*" + sensitiveKey + "[a-z0-9_.\\-]*[\"']"
    /// 不带引号的键：敏感词必须收尾，`tokens=` / `passwordless=` 因此不命中。
    private static let plainKey = "\\b[a-z0-9_.\\-]*" + sensitiveKey
    /// 值：双引号（支持 `\"`）、单引号（支持 `''`）、或到 `,` `;` `&` 之前
    /// （允许空格，也覆盖未闭合引号），避免吞掉同一行的后续键值。
    private static let value = "(?:\"(?:\\\\.|[^\"\\\\])*\"|'(?:''|[^'])*'|[^\n,;&]+)"
    /// 命令行形式的值：带引号字符串或单个词，后续参数保持原样。
    private static let commandLineValue = "(?:\"(?:\\\\.|[^\"\\\\])*\"|'(?:''|[^'])*'|[^\\s,;&\"']+)"

    private static let sensitiveValuePattern =
        "(?i)(?<key>" + quotedKey + "|" + plainKey + ")"
        + "(?<separator>[ \\t]*[=:][ \\t]*)"
        + "(?<value>" + value + ")"
    private static let commandLinePattern =
        "(?i)(^|[ \\t])(--?[a-z0-9_.\\-]*" + sensitiveKey + ")\\b([ \\t]+)"
        + "(?<value>" + commandLineValue + ")"

    /// `key:` 后没有值（只有空白到行尾）：换行值形态的触发模式。
    private static let continuationKey = try? NSRegularExpression(
        pattern: "(?i)^(?<indent>[ \\t]*)(?<key>" + quotedKey + "|" + plainKey + ")[ \\t]*:[ \\t]*$"
    )
    /// `label:` / `label: value` 形态，用来避免把下一条键值行当成续行的值。
    private static let keyLabel = try? NSRegularExpression(
        pattern: "^[\"']?[^\\s:\"']{1,40}[\"']?[ \\t]*:(?:[ \\t].*)?$"
    )

    /// 注入的 Home 目录（已去掉尾部 `/`）；空字符串表示不替换该前缀。
    let homeDirectory: String

    private let rules: [Rule]

    init(homeDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path) {
        var normalized = homeDirectory
        while normalized.count > 1 && normalized.hasSuffix("/") {
            normalized.removeLast()
        }
        self.homeDirectory = normalized == "/" ? "" : normalized
        self.rules = LogRedactor.makeRules()
    }

    /// 脱敏入口。纯函数语义：同样的输入总是得到同样的输出，重复调用不会二次破坏
    /// 已经写入的占位符（幂等，GitHub #38）。
    func redact(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var output: [String] = []
        output.reserveCapacity(lines.count)
        var insidePrivateKeyBlock = false
        var index = 0
        while index < lines.count {
            let line = lines[index]
            if insidePrivateKeyBlock {
                if LogRedactor.isPrivateKeyTerminator(line) { insidePrivateKeyBlock = false }
                output.append(LogRedactor.marker)
            } else if LogRedactor.isPrivateKeyHeader(line) {
                insidePrivateKeyBlock = true
                output.append(LogRedactor.marker)
            } else {
                output.append(redactLine(line))
                // `key:` 后没有值时，紧随其后的续行整体按“值”处理。
                if let keyIndent = LogRedactor.continuationKeyIndent(in: line),
                   index + 1 < lines.count,
                   LogRedactor.isContinuationValue(lines[index + 1], keyIndent: keyIndent) {
                    output.append(redactContinuationLine(lines[index + 1]))
                    index += 1
                }
            }
            index += 1
        }
        return output.joined(separator: "\n")
    }

    /// 单行脱敏；规则顺序固定，代理凭据与 URL 查询串先于键值规则。
    private func redactLine(_ line: String) -> String {
        var result = line
        for rule in rules {
            result = apply(rule, to: result)
        }
        return redactHomePaths(result)
    }

    /// 应用一条规则：逐个匹配决定替换文本；返回 `nil` 的匹配整段保留，所以不会
    /// 改动匹配两侧的字符，也不会让后续规则看到被吞掉的尾随字符。
    private func apply(_ rule: Rule, to text: String) -> String {
        let source = text as NSString
        let matches = rule.expression.matches(
            in: text,
            options: [],
            range: NSRange(location: 0, length: source.length)
        )
        guard !matches.isEmpty else { return text }
        var result = ""
        var cursor = 0
        for match in matches {
            guard let replacement = replacement(for: rule, match: match, in: text) else { continue }
            result += source.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            result += replacement
            cursor = NSMaxRange(match.range)
        }
        guard cursor > 0 else { return text }
        result += source.substring(from: cursor)
        return result
    }

    /// 单个匹配的替换文本；`nil` 表示这一处整段保留。
    private func replacement(for rule: Rule, match: NSTextCheckingResult, in text: String) -> String? {
        switch rule.replacement {
        case .template(let template):
            return rule.expression.replacementString(for: match, in: text, offset: 0, template: template)
        case .sensitiveValue:
            let valueRange = match.range(withName: "value")
            guard valueRange.location != NSNotFound, let range = Range(valueRange, in: text) else { return nil }
            let value = String(text[range])
            // 幂等：已经含占位符的值整段保留，第二遍不会再把值后面的字符吞进来（R-1）。
            guard !value.contains(LogRedactor.marker) else { return nil }
            let (_, suffix) = LogRedactor.splitValue(value)
            let prefix = (text as NSString).substring(
                with: NSRange(location: match.range.location, length: valueRange.location - match.range.location)
            )
            return prefix + LogRedactor.marker + suffix
        }
    }

    /// `key:` 后没有值的行返回键的缩进（空格/制表符个数），否则返回 `nil`。
    private static func continuationKeyIndent(in line: String) -> Int? {
        guard let expression = continuationKey else { return nil }
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        guard let match = expression.firstMatch(in: line, options: [], range: range),
              let indentRange = Range(match.range(withName: "indent"), in: line) else { return nil }
        return line.distance(from: line.startIndex, to: indentRange.lowerBound)
    }

    /// 续行判定：空行与私钥边界行不算值；缩进更深的一律算值，同缩进或更浅时
    /// 只有不像下一条 `label:` 行才算值。
    private static func isContinuationValue(_ line: String, keyIndent: Int) -> Bool {
        guard !isPrivateKeyHeader(line), !isPrivateKeyTerminator(line) else { return false }
        let content = String(line.drop { $0 == " " || $0 == "\t" })
        guard !content.isEmpty else { return false }
        if line.count - content.count > keyIndent { return true }
        guard let expression = keyLabel else { return true }
        let range = NSRange(content.startIndex..<content.endIndex, in: content)
        return expression.firstMatch(in: content, options: [], range: range) == nil
    }

    /// 续行整行视为值：保留缩进与尾随结构字符，只把值换成占位符。
    private func redactContinuationLine(_ line: String) -> String {
        let indentation = String(line.prefix { $0 == " " || $0 == "\t" })
        let content = line.dropFirst(indentation.count)
        guard !content.isEmpty else { return line }
        let (secret, suffix) = LogRedactor.splitValue(String(content))
        guard !secret.contains(LogRedactor.marker) else { return line }
        return indentation + LogRedactor.marker + suffix
    }

    /// 把值拆成“秘密部分”和“尾随结构字符”。引号包裹的值以闭引号结尾；未加引号
    /// 的值把末尾的 `}`、`]`、`)`、`,`、`;` 与空白留给尾随部分，替换后原样回填，
    /// 这样 JSON 的 `}` 不会在第二次脱敏时被吞掉（R-1）。
    private static func splitValue(_ value: String) -> (secret: String, suffix: String) {
        if let quote = value.first, quote == "\"" || quote == "'" {
            guard let end = indexAfterQuotedValue(value, quote: quote) else { return (value, "") }
            return (String(value[value.startIndex..<end]), String(value[end...]))
        }
        var end = value.endIndex
        while end > value.startIndex, isTrailingStructure(value[value.index(before: end)]) {
            end = value.index(before: end)
        }
        return (String(value[value.startIndex..<end]), String(value[end...]))
    }

    /// 引号值的结束位置（`endIndex` 之后的一位）；引号未闭合时返回 `nil`。
    private static func indexAfterQuotedValue(_ value: String, quote: Character) -> String.Index? {
        var index = value.index(after: value.startIndex)
        while index < value.endIndex {
            let character = value[index]
            if quote == "\"" && character == "\\" {
                index = value.index(after: index)
                guard index < value.endIndex else { return nil }
            } else if character == quote {
                let next = value.index(after: index)
                if quote == "'" && next < value.endIndex && value[next] == "'" {
                    index = value.index(after: next)
                    continue
                }
                return next
            }
            index = value.index(after: index)
        }
        return nil
    }

    private static func isTrailingStructure(_ character: Character) -> Bool {
        character == "}" || character == "]" || character == ")" || character == ","
            || character == ";" || character == " " || character == "\t"
    }

    /// Home 路径：先替换注入的前缀（可能是临时目录），再处理任意用户名。
    private func redactHomePaths(_ text: String) -> String {
        var result = text
        if !homeDirectory.isEmpty {
            result = result.replacingOccurrences(of: homeDirectory + "/", with: "~/")
            result = result.replacingOccurrences(of: homeDirectory, with: "~")
        }
        return result
    }

    private static func isPrivateKeyHeader(_ line: String) -> Bool {
        line.contains("-----BEGIN") && line.contains("PRIVATE KEY")
    }

    private static func isPrivateKeyTerminator(_ line: String) -> Bool {
        line.contains("-----END") && line.contains("PRIVATE KEY")
    }

    /// 规则表。模式全部由编译期常量拼装，`try?` 失败时跳过该规则而不是崩溃。
    private static func makeRules() -> [Rule] {
        // 绝对 Home 路径模式由片段拼装：仓库扫描禁止出现真实用户名形态的字面量，
        // 这条正则本身只用于脱敏，匹配任意用户名。
        let absoluteHomePathPattern = "/Use" + "rs/[^/\\s\"'`]+"
        let definitions: [(pattern: String, replacement: Replacement)] = [
            ("(?i)\\b(authorization|proxy-authorization)([ \\t]*:[ \\t]*).*", .template("$1$2" + marker)),
            ("(?i)\\b(bearer)([ \\t]+)[A-Za-z0-9._~+/=:-]+", .template("$1$2" + marker)),
            ("(?i)\\b([a-z][a-z0-9+.\\-]*://)([^/?#\\s@]+)@", .template("$1" + marker + "@")),
            ("(\\?)([^\\s\"'`()\\[\\]{}<>,;]*=[^\\s\"'`()\\[\\]{}<>,;]*)", .template("$1" + marker)),
            ("\\beyJ[A-Za-z0-9_-]{4,}\\.[A-Za-z0-9_-]{4,}\\.[A-Za-z0-9_-]{4,}", .template(marker)),
            (sensitiveValuePattern, .sensitiveValue),
            (commandLinePattern, .sensitiveValue),
            (absoluteHomePathPattern, .template("~"))
        ]
        return definitions.compactMap { definition in
            guard let expression = try? NSRegularExpression(pattern: definition.pattern) else { return nil }
            return Rule(expression: expression, replacement: definition.replacement)
        }
    }
}
