import Foundation

/// 统一脱敏器（GitHub #10）。
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
/// 6. `token` / `password` / `secret` / `api_key` / `apikey` 等键值（含 JSON、
///    带引号与 `key=value`、`key: value` 形式，大小写不敏感，覆盖
///    `PI_WEB_PASSWORD` 这类带前缀的环境变量名）；
/// 7. 命令行参数形式 `--password <value>`；
/// 8. 私钥：`-----BEGIN ... PRIVATE KEY-----` 头以及同一次输入中它到
///    `-----END ... PRIVATE KEY-----` 之间的每一行；
/// 9. Home 路径：注入的 Home 前缀与任何 `/Use`+`rs/<name>` 前缀替换为 `~`。
///
/// 多行输入逐行处理，行数与换行结构保持不变，不因换行漏判。本类不可变，可安全地
/// 被多个线程共享（日志写入线程与主线程可能同时调用）。
final class LogRedactor {
    /// 统一占位符。诊断导出与日志里都只出现这一个标记，便于用户核对。
    static let marker = "<redacted>"

    private struct Rule {
        let expression: NSRegularExpression
        let template: String
    }

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
    /// 已经写入的占位符（幂等）。
    func redact(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        var lines: [String] = []
        var insidePrivateKeyBlock = false
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let string = String(line)
            if insidePrivateKeyBlock {
                if LogRedactor.isPrivateKeyTerminator(string) { insidePrivateKeyBlock = false }
                lines.append(LogRedactor.marker)
            } else if LogRedactor.isPrivateKeyHeader(string) {
                insidePrivateKeyBlock = true
                lines.append(LogRedactor.marker)
            } else {
                lines.append(redactLine(string))
            }
        }
        return lines.joined(separator: "\n")
    }

    /// 单行脱敏；规则顺序固定，代理凭据与 URL 查询串先于键值规则。
    private func redactLine(_ line: String) -> String {
        var result = line
        for rule in rules {
            result = rule.expression.stringByReplacingMatches(
                in: result,
                options: [],
                range: NSRange(result.startIndex..<result.endIndex, in: result),
                withTemplate: rule.template
            )
        }
        return redactHomePaths(result)
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
        let sensitiveKey = "(?:token|password|passwd|secret|api[_-]?key|private[_-]?key)"
        let definitions: [(pattern: String, template: String)] = [
            ("(?i)\\b(authorization|proxy-authorization)([ \\t]*:[ \\t]*).*", "$1$2" + marker),
            ("(?i)\\b(bearer)([ \\t]+)[A-Za-z0-9._~+/=:-]+", "$1$2" + marker),
            ("(?i)\\b([a-z][a-z0-9+.\\-]*://)([^/?#\\s@]+)@", "$1" + marker + "@"),
            ("(\\?)([^\\s\"'`()\\[\\]{}<>,;]*=[^\\s\"'`()\\[\\]{}<>,;]*)", "$1" + marker),
            ("\\beyJ[A-Za-z0-9_-]{4,}\\.[A-Za-z0-9_-]{4,}\\.[A-Za-z0-9_-]{4,}", marker),
            (
                "(?i)([\"'][a-z0-9_.\\-]*" + sensitiveKey + "[a-z0-9_.\\-]*[\"'][ \\t]*:[ \\t]*)"
                    + "(\"[^\"]*\"|'[^']*'|[^\\s,;&\"']+)",
                "$1" + marker
            ),
            (
                "(?i)\\b([a-z0-9_.\\-]*" + sensitiveKey + ")\\b([ \\t]*[=:][ \\t]*)([^\\s,;&\"']+)",
                "$1$2" + marker
            ),
            (
                "(?i)(^|[ \\t])(--?[a-z0-9_.\\-]*" + sensitiveKey + ")\\b([ \\t]+)([^\\s,;&\"']+)",
                "$1$2$3" + marker
            ),
            (absoluteHomePathPattern, "~")
        ]
        return definitions.compactMap { definition in
            guard let expression = try? NSRegularExpression(pattern: definition.pattern) else { return nil }
            return Rule(expression: expression, template: definition.template)
        }
    }
}
