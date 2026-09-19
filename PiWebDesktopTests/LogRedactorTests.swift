import Foundation
import XCTest

/// Unhosted tests for `Sources/LogRedactor.swift`: the same instance is used for
/// log lines, diagnostics export, error messages and environment/command-line
/// display, so every rule is asserted here with fake values only. Nothing in this
/// file touches a real home directory or a real secret.
final class LogRedactorTests: XCTestCase {
    /// 假 Home：脱敏依赖注入值，测试不读取真实用户目录。
    private let fakeHome = "/tmp/PiWebDesktopTests/home"
    private var redactor: LogRedactor { LogRedactor(homeDirectory: fakeHome) }

    // MARK: URL 查询串

    func testURLQueryStringIsReplacedAsAWhole() {
        let text = redactor.redact("GET https://pi.example.invalid/api/status?a=b&c=d&token=hunter2 done")
        XCTAssertTrue(text.contains("https://pi.example.invalid/api/status?\(LogRedactor.marker) done"), text)
        XCTAssertFalse(text.contains("a=b"))
        XCTAssertFalse(text.contains("c=d"))
        XCTAssertFalse(text.contains("hunter2"))
    }

    func testURLWithoutQueryIsUntouched() {
        let line = "服务地址: http://127.0.0.1:30141/"
        XCTAssertEqual(redactor.redact(line), line)
    }

    // MARK: Authorization / Bearer

    func testAuthorizationHeadersAndBearerTokensAreRedacted() {
        let text = redactor.redact("""
        Authorization: Bearer abc.def.ghi
        proxy-authorization: Basic dXNlcjpwYXNz
        request with Bearer standalone-token-value
        """)
        XCTAssertFalse(text.contains("abc.def.ghi"))
        XCTAssertFalse(text.contains("dXNlcjpwYXNz"))
        XCTAssertFalse(text.contains("standalone-token-value"))
        XCTAssertTrue(text.contains("Authorization: \(LogRedactor.marker)"))
        XCTAssertTrue(text.contains("proxy-authorization: \(LogRedactor.marker)"))
        XCTAssertTrue(text.contains("Bearer \(LogRedactor.marker)"))
    }

    // MARK: 键值 / JWT / 私钥

    func testSensitiveKeyValuesAreRedactedInEveryForm() {
        let values = [
            "token=token-value-1",  // scan-secrets: allow
            "password=hunter2-password",  // scan-secrets: allow
            "secret: secret-value-3",
            "api_key=api-key-value-4",  // scan-secrets: allow
            "apikey=apikey-value-5",  // scan-secrets: allow
            "\"token\": \"json-secret-6\"",
            "PI_WEB_PASSWORD=env-secret-7",
            "--password cli-secret-8",
            "access_token=access-secret-9"  // scan-secrets: allow
        ]
        for line in values {
            let redacted = redactor.redact(line)
            XCTAssertTrue(redacted.contains(LogRedactor.marker), "not redacted: \(line) -> \(redacted)")
        }
        let combined = redactor.redact(values.joined(separator: "\n"))
        for secret in ["token-value-1", "hunter2-password", "secret-value-3", "api-key-value-4",
                       "apikey-value-5", "json-secret-6", "env-secret-7", "cli-secret-8", "access-secret-9"] {
            XCTAssertFalse(combined.contains(secret), "leaked \(secret)")
        }
    }

    /// 精度：不相关的词不会被误伤，避免诊断文本被无意义地涂掉。
    func testUnrelatedWordsAreNotRedacted() {
        let line = "tokenizer=fast passwordless=true tokens=10 secretive thing"
        XCTAssertEqual(redactor.redact(line), line)
    }

    func testJWTShapedStringIsRedacted() {
        let jwt = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dozjgNryP4J3jVmNHl0w5N"  // scan-secrets: allow
        let text = redactor.redact("credential \(jwt) end")
        XCTAssertEqual(text, "credential \(LogRedactor.marker) end")
    }

    func testPrivateKeyHeaderAndBodyAreRedacted() {
        let key = """
        -----BEGIN OPENSSH PRIVATE KEY-----  // scan-secrets: allow
        b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtzc2gtZW
        QyNTUxOQAAACD1234567890abcdefghijklmnopqrstuvwxyz
        -----END OPENSSH PRIVATE KEY-----
        """
        let text = redactor.redact("before\n\(key)\nafter")
        XCTAssertFalse(text.contains("BEGIN OPENSSH PRIVATE KEY"))
        XCTAssertFalse(text.contains("b3BlbnNzaC1rZXktdjE"))
        XCTAssertTrue(text.contains("before"))
        XCTAssertTrue(text.contains("after"))
        XCTAssertEqual(text.components(separatedBy: "\n").count, 6)
    }

    // MARK: Home 路径与代理凭据

    func testHomePathsAreReplacedWithoutLeavingTheUserName() {
        let name = "alice"
        let absoluteOtherHome = "/Use" + "rs/\(name)/projects/demo"
        let text = redactor.redact("""
        cwd: \(fakeHome)/Library/Logs/Pi Web Desktop.log
        other: \(absoluteOtherHome)/main.swift
        config: ~/.pi/agent
        """)
        XCTAssertTrue(text.contains("cwd: ~/Library/Logs/Pi Web Desktop.log"), text)
        XCTAssertTrue(text.contains("other: ~/projects/demo/main.swift"), text)
        XCTAssertTrue(text.contains("config: ~/.pi/agent"))
        XCTAssertFalse(text.contains(fakeHome))
        XCTAssertFalse(text.contains("\(name)/projects"))
        XCTAssertFalse(text.contains("/Use" + "rs/\(name)"))
    }

    func testProxyCredentialsAreRedactedButTheEndpointRemains() {
        let text = redactor.redact("HTTPS_PROXY=http://proxy-user:proxy-pass@proxy.example.invalid:8080")
        XCTAssertEqual(text, "HTTPS_PROXY=http://\(LogRedactor.marker)@proxy.example.invalid:8080")
        XCTAssertFalse(text.contains("proxy-user"))
        XCTAssertFalse(text.contains("proxy-pass"))
    }

    // MARK: 多行与幂等

    func testEveryLineOfMultiLineInputIsProcessed() {
        let input = """
        line 1 ok
        token=first-secret  // scan-secrets: allow
        line 3 ok
        Authorization: Bearer second-secret
        line 5 ok
        """
        let output = redactor.redact(input)
        XCTAssertEqual(
            output.components(separatedBy: "\n").count,
            input.components(separatedBy: "\n").count,
            "换行结构必须保持不变"
        )
        XCTAssertFalse(output.contains("first-secret"))
        XCTAssertFalse(output.contains("second-secret"))
        for expected in ["line 1 ok", "line 3 ok", "line 5 ok"] {
            XCTAssertTrue(output.contains(expected))
        }
    }

    func testRedactionIsIdempotent() {
        let input = """
        Authorization: Bearer abc.def.ghi
        token=value
        https://pi.example.invalid/api?x=1&y=2
        cwd \(fakeHome)/work
        """
        let once = redactor.redact(input)
        XCTAssertEqual(redactor.redact(once), once)
    }

    // MARK: 引号值、带空白的键值分隔符与续行（GitHub #38 R-2）

    /// 引号值（单/双引号）与含空格的值必须整段替换，而不是只替换到第一个空格或
    /// 完全不替换；`=` / `:` 两侧的空白不影响匹配。
    func testQuotedAndSpacedValuesAreRedactedCompletely() {
        let cases: [(String, String)] = [
            ("password=\"a b c\"", "password=\(LogRedactor.marker)"),
            ("token='d e f'", "token=\(LogRedactor.marker)"),
            ("secret = \"spaced-value\"", "secret = \(LogRedactor.marker)"),
            ("api_key : 'spaced value'", "api_key : \(LogRedactor.marker)"),
            ("password=AA BB CC DD", "password=\(LogRedactor.marker)"),
            ("secret: value with spaces", "secret: \(LogRedactor.marker)"),
            ("PI_WEB_PASSWORD=\"env value\"", "PI_WEB_PASSWORD=\(LogRedactor.marker)")
        ]
        for (input, expected) in cases {
            XCTAssertEqual(redactor.redact(input), expected, input)
        }
    }

    /// 等号/冒号两侧带空白的各种组合都要命中（R-2 的 `secret = "…"` 形态）。
    func testSeparatorWhitespaceIsAcceptedOnBothSides() {
        for input in ["secret=\"v\"", "secret =\"v\"", "secret= \"v\"",
                      "secret = \"v\"", "secret : \"v\"", "secret:\"v\""] {
            let expected = input.replacingOccurrences(of: "\"v\"", with: LogRedactor.marker)
            XCTAssertEqual(redactor.redact(input), expected, input)
        }
    }

    /// `key:` 后没有值时，紧随其后的续行整体按值处理；尾随的 `,` 等结构字符保留。
    func testContinuationLineAfterAKeyIsRedacted() {
        XCTAssertEqual(
            redactor.redact("password:\n  next-line-value"),
            "password:\n  \(LogRedactor.marker)"
        )
        XCTAssertEqual(
            redactor.redact("password:\nnext-line-value"),
            "password:\n\(LogRedactor.marker)"
        )
        XCTAssertEqual(
            redactor.redact("\"password\":\n  \"a b\",\n  \"port\": 30141"),
            "\"password\":\n  \(LogRedactor.marker),\n  \"port\": 30141"
        )
    }

    /// 空行与下一条 `label:` 行不是值：续行规则不能把后续字段一并吞掉。
    func testContinuationStopsAtBlankLinesAndTheNextLabel() {
        XCTAssertEqual(redactor.redact("password:\n\n  value"), "password:\n\n  value")
        XCTAssertEqual(redactor.redact("password:\nport: 30141"), "password:\nport: 30141")
    }

    /// 命令行形式的值可以是带引号的字符串，后续参数保持原样。
    func testCommandLineQuotedValueIsRedactedWithoutEatingLaterArguments() {
        XCTAssertEqual(
            redactor.redact("--password \"cli secret\" --port 30141"),
            "--password \(LogRedactor.marker) --port 30141"
        )
    }

    // MARK: 幂等（GitHub #38 R-1）

    /// R-1 回归：JSON 引号键脱敏后紧跟占位符的 `}` 不能被第二次处理吞掉。
    func testJSONQuotedKeyRedactionIsIdempotent() {
        let inputs = [
            "{\"token\": \"json-secret\"} trailing-context",
            "{\"token\": \"abc\", \"port\": 30141, \"nested\": {\"secret\": \"xyz\"}}",
            "{\"password\": <redacted>}",
            "{\"password\": <redacted>} trailing-context",
            "{\"password\":\"a b\",\"token\":\"c d\"}"
        ]
        for input in inputs {
            let once = redactor.redact(input)
            XCTAssertEqual(redactor.redact(once), once, input)
        }

        let once = redactor.redact(inputs[0])
        XCTAssertTrue(once.contains("}"), once)
        XCTAssertTrue(once.contains("trailing-context"), once)
        XCTAssertFalse(once.contains("json-secret"), once)
    }

    /// 值尾部的结构字符（`}`、`)` 等）与整段已脱敏文本都要逐字节稳定。
    func testTrailingStructureAndAlreadyRedactedTextStayByteIdentical() {
        XCTAssertEqual(redactor.redact("{\"token\": abc}"), "{\"token\": \(LogRedactor.marker)}")
        XCTAssertEqual(redactor.redact("(token=abc)"), "(token=\(LogRedactor.marker))")

        let alreadyRedacted = """
        Authorization: \(LogRedactor.marker)
        token=\(LogRedactor.marker)
        {"password": \(LogRedactor.marker)}
        {"secret": <redacted>} trailing-context
        password:
          <redacted>
        """
        XCTAssertEqual(redactor.redact(alreadyRedacted), alreadyRedacted)
    }

    /// 覆盖范围内所有形态连续两次脱敏都必须一致（含续行与 CLI 引号值）。
    func testIdempotenceAcrossTheCoveredForms() {
        let inputs = [
            "password=\"a b c\"",
            "secret = 'd e f'",
            "password:\n  next-value",
            "{\"token\": \"abc\", \"port\": 30141}",
            "--password \"cli value\" --port 30141",
            "HTTPS_PROXY=http://proxy-user:proxy-pass@proxy.example.invalid:8080",
            "cwd \(fakeHome)/work"
        ]
        for input in inputs {
            let once = redactor.redact(input)
            XCTAssertEqual(redactor.redact(once), once, input)
        }
    }

    /// 诊断导出使用真实 Home；此时临时目录前缀不参与替换，但用户名形态的路径
    /// 仍然必须被脱敏（不能依赖“只有当前用户的 Home 才会出现”这个假设）。
    func testOtherUsersHomeIsRedactedEvenWhenItIsNotTheInjectedHome() {
        let redactor = LogRedactor(homeDirectory: fakeHome)
        let name = "bob"
        let text = redactor.redact("env: HOME=/Use" + "rs/\(name)")
        XCTAssertEqual(text, "env: HOME=~")
        XCTAssertFalse(text.contains(name))
    }
}
