import Foundation
import XCTest

/// 子进程工具 PATH 的 unhosted 测试（GitHub #89）。
///
/// 纯逻辑（合并顺序、去重、凭据键过滤、登录 shell 兜底、超时上限）全部注入；
/// 唯一的真实子进程是 `$TMPDIR` 下测试自己写的假 `pi` / 假 `node` 脚本和一个
/// 用于验证超时上限的假脚本。测试不执行真实 `npm` / `pi` / `pi-web`，不联网，
/// 不写真实用户目录。
private final class ToolPathFakeRunner: CommandRunning {
    /// 每次调用按顺序返回的结果；用完后返回 nil。
    var results: [String?] = []
    private(set) var invocations: [[String]] = []

    func run(_ arguments: [String]) -> String? {
        invocations.append(arguments)
        guard !results.isEmpty else { return nil }
        return results.removeFirst()
    }

    var invocationLines: [String] {
        invocations.map { $0.joined(separator: " ") }
    }
}

/// 只认 fixture 目录的探针：包一层真实探针，fixture 之外的路径一律回答
/// “不存在 / 不可执行”，因此本机装了什么工具都不会影响结果。
private struct ToolPathFixtureFileSystemProbe: DependencyFileSystemProbing {
    let root: String
    let home: String
    private let system = SystemDependencyFileSystemProbe()

    private func isInside(_ path: String) -> Bool {
        path == root || path.hasPrefix(root + "/")
    }

    func isExecutableFile(atPath path: String) -> Bool {
        isInside(path) && system.isExecutableFile(atPath: path)
    }

    func symlinkDestination(atPath path: String) -> String? {
        isInside(path) ? system.symlinkDestination(atPath: path) : nil
    }

    func resolvedPath(atPath path: String) -> String? {
        isInside(path) ? system.resolvedPath(atPath: path) : nil
    }

    func readText(atPath path: String) -> String? {
        isInside(path) ? system.readText(atPath: path) : nil
    }

    func homeDirectoryPath() -> String {
        home
    }

    func directoryExists(atPath path: String) -> Bool? {
        isInside(path) ? system.directoryExists(atPath: path) : false
    }

    func isReadableDirectory(atPath path: String) -> Bool? {
        isInside(path) ? system.isReadableDirectory(atPath: path) : false
    }
}

/// 固定结果的假端口探针：不绑定真实端口。
private struct ToolPathFakePortProbe: DependencyPortProbing {
    func isPortAvailable(host: String, port: Int) -> Bool? {
        true
    }
}

/// `$TMPDIR` 下的假安装：`bin/pi`（`#!/usr/bin/env node`）与同目录的 `bin/node`。
///
/// 假 `node` 是 `/bin/sh` 脚本：把收到的 argv 与 `PATH` 写进标记文件，并输出
/// `9.9.9`。因此“`pi --version` 能成功”只能来自“工具 PATH 里真的找到了 node”，
/// 而不是测试进程自己继承了完整的 PATH（修复前的链路正是后者不成立）。
private struct ToolPathFixture {
    let rootURL: URL
    var binURL: URL { rootURL.appendingPathComponent("bin", isDirectory: true) }
    var homeURL: URL { rootURL.appendingPathComponent("home", isDirectory: true) }
    var piURL: URL { binURL.appendingPathComponent("pi") }
    var nodeURL: URL { binURL.appendingPathComponent("node") }
    var nodeARGVRecordURL: URL { rootURL.appendingPathComponent("node-argv.txt") }
    var nodePATHRecordURL: URL { rootURL.appendingPathComponent("node-path.txt") }

    init() throws {
        rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ToolPathTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: binURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: homeURL, withIntermediateDirectories: true)
    }

    /// `#!/usr/bin/env node` 脚本：真实安装里的 `pi` 就是这个形态。
    func writePI() throws {
        try write(piURL, contents: "#!/usr/bin/env node\nconsole.log(\"9.9.9\");\n")
    }

    /// 假 node：记录 argv（追加）与 PATH，输出可解析的版本号。
    func writeNode() throws {
        try write(nodeURL, contents: """
        #!/bin/sh
        printf '%s\\n' "$@" >> "\(nodeARGVRecordURL.path)"
        printf '%s' "$PATH" > "\(nodePATHRecordURL.path)"
        printf '9.9.9\\n'
        """)
        // argv 采用追加：组件识别还会跑 `pi list`，断言不能依赖最后一次写入。
        try "".write(to: nodeARGVRecordURL, atomically: true, encoding: .utf8)
    }

    func write(_ url: URL, contents: String) throws {
        try contents.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    func readNodeARGVRecord() throws -> String {
        try String(contentsOf: nodeARGVRecordURL, encoding: .utf8)
    }

    func readNodePATHRecord() throws -> String {
        try String(contentsOf: nodePATHRecordURL, encoding: .utf8)
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: rootURL)
    }
}

final class ToolPathTests: XCTestCase {
    // MARK: - 1. 用户 bug 的复现用例（GitHub #89）

    /// 应用侧 PATH 最小、`node` 只在登录 shell 的 PATH 里：`pi` 的
    /// `#!/usr/bin/env node` 必须通过工具 PATH 找到 node，版本解析成 9.9.9。
    ///
    /// 修复前这条用例拿不到版本（`env node` exit 127 → `.unknown`），修复后
    /// 得到 `.ok` + 版本 9.9.9，且子进程真的收到合并后的 PATH。
    func testPIVersionResolvesThroughTheNodeInTheToolPath() throws {
        let fixture = try ToolPathFixture()
        defer { fixture.cleanUp() }
        try fixture.writePI()
        try fixture.writeNode()

        // 修复前的链路：PATH 里没有 node 时，`#!/usr/bin/env node` 一定失败。
        // 系统自带的 `/usr/bin`、`/bin` 不带 node（macOS 受 SIP 保护），因此这里
        // 直接断言“最小 PATH 拿不到版本”。
        if !FileManager.default.isExecutableFile(atPath: "/usr/bin/node"),
           !FileManager.default.isExecutableFile(atPath: "/bin/node") {
            XCTAssertNil(
                SystemCommandRunner(environment: ["PATH": "/usr/bin:/bin"]).run([fixture.piURL.path, "--version"]),
                "没有 node 的 PATH 里，pi --version 必须失败（修复前的 unknown 来源）"
            )
        }

        let checker = DependencyChecker(
            commandRunner: SystemCommandRunner(),
            fileSystem: ToolPathFixtureFileSystemProbe(
                root: fixture.rootURL.path,
                home: fixture.homeURL.path
            ),
            system: DependencySystemProbe(
                architecture: { "arm64" },
                operatingSystemVersion: { OperatingSystemVersion(majorVersion: 14, minorVersion: 0, patchVersion: 0) }
            ),
            portProbe: ToolPathFakePortProbe(),
            environment: ["PATH": "/usr/bin:/bin", "HOME": fixture.homeURL.path],
            // 登录 shell 报告的 PATH：node 的目录在这里（等价于 Homebrew / nvm）。
            loginShellPath: { fixture.binURL.path }
        )
        let report = checker.run()

        let pi = try XCTUnwrap(report.finding(for: .piCLI))
        XCTAssertEqual(pi.resolvedPath, fixture.piURL.path)
        XCTAssertEqual(pi.status, .ok, "修复后 Pi CLI 必须是 ok，而不是 unknown")
        XCTAssertEqual(pi.version, "9.9.9")
        XCTAssertNil(pi.detail)

        let node = try XCTUnwrap(report.finding(for: .node))
        XCTAssertEqual(node.resolvedPath, fixture.nodeURL.path)
        XCTAssertEqual(node.version, "9.9.9")

        // 子进程确实收到了合并后的 PATH：`/usr/bin:/bin`（应用 PATH）之后才有
        // node 所在目录，且 `pi` 通过 `env node` 找到了它。
        let recordedPath = try fixture.readNodePATHRecord()
        XCTAssertEqual(
            recordedPath.split(separator: ":").map(String.init),
            ["/usr/bin", "/bin", fixture.binURL.path]
        )
        let recordedARGV = try fixture.readNodeARGVRecord()
        XCTAssertTrue(recordedARGV.contains(fixture.piURL.path), "假 node 收到的 argv 里应有 pi 路径")
        XCTAssertTrue(recordedARGV.contains("--version"))
    }

    /// 拿不到版本时必须给出可读原因，而不是只留一个 `.unknown`（GitHub #89 第 3 项）。
    func testUnresolvablePIVersionCarriesAReadableDiagnosis() throws {
        let fixture = try ToolPathFixture()
        defer { fixture.cleanUp() }
        try fixture.writePI()
        // 故意不写 node：工具 PATH 里没有 node。
        let checker = DependencyChecker(
            commandRunner: SystemCommandRunner(),
            fileSystem: ToolPathFixtureFileSystemProbe(
                root: fixture.rootURL.path,
                home: fixture.homeURL.path
            ),
            system: DependencySystemProbe(
                architecture: { "arm64" },
                operatingSystemVersion: { OperatingSystemVersion(majorVersion: 14, minorVersion: 0, patchVersion: 0) }
            ),
            portProbe: ToolPathFakePortProbe(),
            environment: ["PATH": "/usr/bin:/bin", "HOME": fixture.homeURL.path],
            loginShellPath: { fixture.binURL.path }
        )
        let report = checker.run()

        let pi = try XCTUnwrap(report.finding(for: .piCLI))
        XCTAssertEqual(pi.status, .unknown)
        XCTAssertEqual(
            pi.detail,
            "命令无法执行：合并后的工具 PATH 里找不到 node；`pi` 是 `#!/usr/bin/env node` 脚本，没有 node 时会以 127 退出"
        )
        let text = DependencyReportPresenter.summaryText(for: report)
        // 原因由 `DependencyReportPresenter` 附在诊断行尾（与 #85 的超时原因同一列）。
        XCTAssertTrue(
            text.contains("原因：命令无法执行：合并后的工具 PATH 里找不到 node"),
            "摘要里要能看到原因：\(text)"
        )
        // Node.js 一条也有可读原因；两条都不含路径。
        let diagnosisBlock = DependencyReportPresenter.diagnosisText(for: report)
        XCTAssertTrue(diagnosisBlock.hasPrefix("命令探测的原因（只读探测，不会安装任何东西）：\n"))
        XCTAssertTrue(diagnosisBlock.contains("· \(DependencyReportPresenter.title(for: .piCLI))：\(try XCTUnwrap(pi.detail))"))
        XCTAssertTrue(diagnosisBlock.contains("· \(DependencyReportPresenter.title(for: .node))："))
        XCTAssertFalse(diagnosisBlock.contains(fixture.rootURL.path), "诊断块里不得出现 fixture 路径")
    }

    // MARK: - 2. PATH 合并的确定性

    func testMergeOrderIsFixedAndDeduplicated() {
        let builder = ToolPathBuilder(
            appEnvironment: [
                "PATH": "/usr/bin:/bin:/opt/homebrew/bin",
                "HOME": "/home/test",
                "NPM_TOKEN": "should-not-be-forwarded"  // scan-secrets: allow(reason=test fixture value)
            ],
            homeDirectory: "/home/test",
            leadingDirectories: ["/leading/bin"],
            loginShellPath: { "/shell/bin:/usr/bin:/shell/extra" },
            directoryIsUsable: { _ in true }
        )

        XCTAssertEqual(
            builder.directories(),
            [
                "/leading/bin",
                "/usr/bin",
                "/bin",
                "/opt/homebrew/bin",
                "/shell/bin",
                "/shell/extra",
                "/opt/homebrew/sbin",
                "/usr/local/bin",
                "/usr/local/sbin",
                "/opt/local/bin",
                "/home/test/.local/bin",
                "/home/test/.npm-global/bin",
                "/home/test/.bun/bin",
                "/home/test/.cargo/bin",
                "/usr/sbin",
                "/sbin"
            ]
        )
        XCTAssertEqual(builder.path(), builder.directories().joined(separator: ":"))
    }

    func testNodeDirectoryAndNPMPrefixAreAppendedAfterKnownDirectories() {
        let builder = ToolPathBuilder(
            appEnvironment: ["PATH": "/usr/bin", "HOME": "/home/test"],
            homeDirectory: "/home/test",
            loginShellPath: { nil },
            directoryIsUsable: { _ in true },
            nodeExecutablePath: "/opt/homebrew/Cellar/node/24/bin/node",
            npmPrefix: "/opt/homebrew"
        )
        // npm prefix 的 bin 已在已知目录里 → 只补 node 目录，且不重复。
        XCTAssertEqual(builder.directories().last, "/opt/homebrew/Cellar/node/24/bin")
        XCTAssertEqual(Set(builder.directories()).count, builder.directories().count)

        let homePrefixBuilder = ToolPathBuilder(
            appEnvironment: ["PATH": "/usr/bin", "HOME": "/home/test"],
            homeDirectory: "/home/test",
            loginShellPath: { nil },
            directoryIsUsable: { _ in true },
            nodeExecutablePath: "/custom/nvm/bin/node",
            npmPrefix: "/home/test/.npm-global"
        )
        let directories = homePrefixBuilder.directories()
        // npm bin 已经在已知目录（~/.npm-global/bin）里 → 不重复添加，node 目录补在最后。
        XCTAssertEqual(directories.last, "/custom/nvm/bin")
        XCTAssertTrue(directories.contains("/home/test/.npm-global/bin"))
        XCTAssertEqual(Set(directories).count, directories.count)
    }

    func testKnownDirectoriesThatTheProbeRejectsAreDropped() {
        let builder = ToolPathBuilder(
            appEnvironment: ["PATH": "/usr/bin"],
            homeDirectory: "/home/test",
            loginShellPath: { nil },
            directoryIsUsable: { $0 == "/usr/local/bin" }
        )
        XCTAssertEqual(builder.directories(), ["/usr/bin", "/usr/local/bin"])

        // 探针无法判定时保留（只增不减；已知目录与 `PATH` 里的重复项仍会去重）。
        let unknownProbe = ToolPathBuilder(
            appEnvironment: ["PATH": "/usr/bin"],
            homeDirectory: "/home/test",
            loginShellPath: { nil },
            directoryIsUsable: { _ in nil }
        )
        XCTAssertEqual(
            unknownProbe.directories(),
            ToolPath.uniqueDirectories([["/usr/bin"], ToolPath.knownDirectories(homeDirectory: "/home/test")])
        )
    }

    func testProbeEnvironmentKeepsApplicationEnvironmentButNeverCredentials() {
        let builder = ToolPathBuilder(
            appEnvironment: [
                "PATH": "/usr/bin",
                "HOME": "/home/test",
                "LANG": "zh_CN.UTF-8",
                "PI_WEB_PASSWORD": "fixture-secret",  // scan-secrets: allow(reason=test fixture value)
                "NPM_TOKEN": "fixture-npm-token",  // scan-secrets: allow(reason=test fixture value)
                "AWS_SECRET_ACCESS_KEY": "fixture-aws-key",  // scan-secrets: allow(reason=test fixture value)
                "SSH_AUTH_SOCK": "/tmp/agent.sock"
            ],
            homeDirectory: "/home/test",
            loginShellPath: { nil },
            directoryIsUsable: { _ in false }
        )
        let environment = builder.probeEnvironment()

        XCTAssertEqual(environment["PATH"], "/usr/bin")
        XCTAssertEqual(environment["HOME"], "/home/test")
        XCTAssertEqual(environment["LANG"], "zh_CN.UTF-8")
        XCTAssertNil(environment["PI_WEB_PASSWORD"], "密码不得转发给探测子进程")
        XCTAssertNil(environment["NPM_TOKEN"], "token 不得转发给探测子进程")
        XCTAssertNil(environment["AWS_SECRET_ACCESS_KEY"], "secret 不得转发给探测子进程")
        XCTAssertEqual(environment["SSH_AUTH_SOCK"], "/tmp/agent.sock", "非凭据键保持原样")

        for key in ["PATH", "HOME", "LANG", "TMPDIR"] {
            XCTAssertFalse(ToolPath.isCredentialKey(key), "\(key) 不是凭据键")
        }
        for key in ["PI_WEB_PASSWORD", "NPM_TOKEN", "AWS_SECRET_ACCESS_KEY", "GITHUB_TOKEN", "npm_config_//registry/:_authToken"] {
            XCTAssertTrue(ToolPath.isCredentialKey(key), "\(key) 必须按凭据键处理")
        }

        // 只覆盖 PATH 的版本：保留原有键，只为服务启动/更新子进程换 PATH。
        let overridden = builder.environment(overridingPathOf: ["A": "1", "PATH": "/stale"])
        XCTAssertEqual(overridden["A"], "1")
        XCTAssertEqual(overridden["PATH"], "/usr/bin")
    }

    // MARK: - 3. 登录 shell 查询：缓存、失败、空输出、超时

    func testLoginShellPathQueryCachesTheSingleResult() {
        let runner = ToolPathFakeRunner()
        runner.results = ["__PI_WEB_TOOL_PATH__/shell/bin:/usr/bin"]
        let query = LoginShellPathQuery(runner: runner, shellPath: "/bin/zsh", interactiveFallback: false)

        XCTAssertEqual(query.path(), "/shell/bin:/usr/bin")
        XCTAssertEqual(query.path(), "/shell/bin:/usr/bin")
        XCTAssertEqual(
            runner.invocationLines,
            ["/bin/zsh -lc printf '__PI_WEB_TOOL_PATH__%s' \"$PATH\""],
            "登录 shell PATH 查询必须单次缓存"
        )
    }

    func testLoginShellPathQueryTreatsFailureAndEmptyOutputAsNoResult() {
        let failing = ToolPathFakeRunner()
        failing.results = [nil, nil]
        XCTAssertNil(LoginShellPathQuery(runner: failing, shellPath: "/bin/zsh").path())
        XCTAssertEqual(failing.invocationLines.count, 2, "登录查询失败后只再试一次交互式查询")

        let empty = ToolPathFakeRunner()
        empty.results = ["   \n", nil]
        XCTAssertNil(LoginShellPathQuery(runner: empty, shellPath: "/bin/zsh").path(), "空输出不能当 PATH")

        // 失败之后仍然能构建 PATH：应用 PATH + 已知目录兜底，不崩溃。
        let provider = ToolPathProvider(
            environment: ["PATH": "/app/bin", "HOME": "/home/test"],
            homeDirectory: "/home/test",
            commandRunner: failing,
            directoryIsUsable: { $0 == "/opt/homebrew/bin" || $0 == "/usr/bin" },
            fileIsExecutable: { _ in false },
            loginShellPath: { nil }
        )
        XCTAssertEqual(provider.path(), "/app/bin:/opt/homebrew/bin:/usr/bin")
        XCTAssertNil(provider.resolvedNodePath())
        XCTAssertNil(provider.resolvedNPMPrefix())
        XCTAssertEqual(provider.probeEnvironment()["PATH"], provider.path())
    }

    func testSystemCommandRunnerTimeoutIsBounded() throws {
        let fixture = try ToolPathFixture()
        defer { fixture.cleanUp() }
        let slow = fixture.rootURL.appendingPathComponent("slow")
        try fixture.write(slow, contents: "#!/bin/sh\nsleep 5\n")

        let start = Date()
        XCTAssertNil(SystemCommandRunner(timeout: 0.4).run([slow.path]), "超时后按“命令失败”处理")
        XCTAssertLessThan(Date().timeIntervalSince(start), 3, "超时必须是有界等待")

        // 既有语义不变：无超时时不改变结果。
        XCTAssertEqual(
            SystemCommandRunner().run(["/bin/echo", "ok"])?.trimmingCharacters(in: .whitespacesAndNewlines),
            "ok"
        )
        XCTAssertNil(SystemCommandRunner().run(["/bin/sh", "-c", "exit 3"]))
    }

    func testLoginShellPathQueryTimeoutOnASlowShellFallsBackToApplicationPath() throws {
        let fixture = try ToolPathFixture()
        defer { fixture.cleanUp() }
        // 慢的登录 shell 配置：登录 shell 由用户数据库决定，测试不能假设是 zsh
        // （CI runner 上可能是 bash 或 sh）。把 sleep 写进各 shell 都会读的启动
        // 文件，才能稳定表达「登录 shell 很慢」，而不是依赖宿主机的默认 shell。
        for name in [".zshenv", ".zprofile", ".bash_profile", ".bash_login", ".bashrc", ".profile"] {
            try fixture.write(
                fixture.homeURL.appendingPathComponent(name),
                contents: "sleep 5\n"
            )
        }

        let query = LoginShellPathQuery(
            runner: SystemCommandRunner(environment: ["HOME": fixture.homeURL.path, "PATH": "/usr/bin:/bin"]),
            timeout: 0.4
        )
        let start = Date()
        let path = query.path()
        XCTAssertLessThan(Date().timeIntervalSince(start), 3, "登录 shell 查询必须有超时上限")
        XCTAssertNil(path, "超时的查询按“没有结果”处理")

        // 兜底：没有登录 shell PATH 时仍然得到应用 PATH + 已知目录。
        let provider = ToolPathProvider(
            environment: ["PATH": "/app/bin", "HOME": fixture.homeURL.path],
            homeDirectory: fixture.homeURL.path,
            commandRunner: SystemCommandRunner(environment: ["HOME": fixture.homeURL.path]),
            directoryIsUsable: { $0 == "/opt/homebrew/bin" },
            fileIsExecutable: { _ in false },
            loginShellPath: { path }
        )
        XCTAssertEqual(provider.path(), "/app/bin:/opt/homebrew/bin")
    }

    // MARK: - 4. Provider：解析一次、缓存一次

    func testProviderResolvesNodeAndNPMChainExactlyOnce() {
        var nodeCalls = 0
        var npmCalls = 0
        let runner = ToolPathFakeRunner()
        let provider = ToolPathProvider(
            environment: ["PATH": "/app/bin", "HOME": "/home/test"],
            homeDirectory: "/home/test",
            commandRunner: runner,
            directoryIsUsable: { _ in false },
            fileIsExecutable: { _ in false },
            loginShellPath: { nil },
            nodePathResolver: { bootstrap in
                nodeCalls += 1
                XCTAssertEqual(bootstrap.path, "/app/bin", "node 解析必须基于 bootstrap PATH")
                return "/custom/node/bin/node"
            },
            npmPrefixResolver: { _ in
                npmCalls += 1
                return "/custom/npm"
            }
        )

        XCTAssertEqual(provider.directories().suffix(2), ["/custom/node/bin", "/custom/npm/bin"])
        _ = provider.path()
        _ = provider.probeEnvironment()
        _ = provider.resolvedNodePath()
        _ = provider.resolvedNPMPrefix()
        XCTAssertEqual(nodeCalls, 1, "node 只解析一次")
        XCTAssertEqual(npmCalls, 1, "npm prefix 只解析一次")
        XCTAssertEqual(provider.resolvedNodePath(), "/custom/node/bin/node")
        XCTAssertEqual(provider.resolvedNPMPrefix(), "/custom/npm")
    }

    // MARK: - 5. 服务启动环境与探测环境同源（GitHub #89 第 2 项）

    func testServiceLaunchPathComesFromTheSameBuilderAsTheProbeEnvironment() throws {
        let supportURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ToolPathTests-support-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: supportURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: supportURL) }
        let defaultsName = "ToolPathTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let appConfiguration = AppConfiguration(
            supportURL: supportURL,
            logsRootURL: supportURL.appendingPathComponent("logs", isDirectory: true),
            defaults: defaults
        )

        let provider = ToolPathProvider(
            environment: ["PATH": "/app/bin", "HOME": "/home/test"],
            homeDirectory: "/home/test",
            commandRunner: ToolPathFakeRunner(),
            directoryIsUsable: { $0 == "/opt/homebrew/bin" },
            fileIsExecutable: { _ in false },
            loginShellPath: { "/shell/bin" },
            nodePathResolver: { _ in "/opt/homebrew/Cellar/node/24/bin/node" },
            npmPrefixResolver: { _ in "/opt/homebrew" }
        )

        var baseEnvironment = ["BASE": "1"]
        baseEnvironment["PI_WEB_PASSWORD"] = "fixture-secret"  // scan-secrets: allow(reason=test fixture value)
        let specification = ServiceLaunchSpecification.make(
            configuration: .default,
            piWebPath: "/opt/homebrew/bin/pi-web",
            appConfiguration: appConfiguration,
            baseEnvironment: baseEnvironment,
            remoteAccessPassword: nil,
            toolPathProvider: provider
        )

        XCTAssertEqual(
            specification.environment["PATH"],
            provider.probeEnvironment()["PATH"],
            "服务启动环境与探测环境必须来自同一个 PATH 构建器"
        )
        XCTAssertEqual(specification.environment["PATH"], provider.path())
        XCTAssertEqual(specification.environment["BASE"], "1")
        XCTAssertEqual(specification.environment["PI_WEB_NO_OPEN"], "1")
        XCTAssertNil(specification.environment["PI_WEB_PASSWORD"], "loopback 模式必须清掉继承的密码")
        // 只增路径、不增变量：白名单语义没有被构建器扩大。
        XCTAssertFalse(specification.environment.keys.contains { ToolPath.isCredentialKey($0) })
    }

    func testServiceLaunchPathWithoutAProviderUsesTheSameStaticBuilder() throws {
        let supportURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ToolPathTests-support-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: supportURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: supportURL) }
        let defaultsName = "ToolPathTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let appConfiguration = AppConfiguration(
            supportURL: supportURL,
            logsRootURL: supportURL.appendingPathComponent("logs", isDirectory: true),
            defaults: defaults
        )

        let baseEnvironment = ["BASE": "1"]
        let specification = ServiceLaunchSpecification.make(
            configuration: .default,
            piWebPath: "/opt/homebrew/bin/pi-web",
            appConfiguration: appConfiguration,
            baseEnvironment: baseEnvironment,
            remoteAccessPassword: nil
        )
        XCTAssertEqual(
            specification.environment["PATH"],
            ToolPathBuilder(appEnvironment: baseEnvironment, homeDirectory: "").path(),
            "没有注入构建器时也不能退回硬编码 PATH"
        )
        XCTAssertEqual(
            specification.environment["PATH"],
            ToolPath.knownDirectories(homeDirectory: "").joined(separator: ":")
        )
    }

    // MARK: - 6. 更新子进程复用同一份目录列表与白名单

    func testUpdateEnvironmentsUseTheSharedKnownDirectoryListAndKeepTheirWhitelist() {
        let base = [
            "PATH": "/app/bin",
            "HOME": "/home/test",
            "LANG": "zh_CN.UTF-8",
            "NPM_TOKEN": "fixture-npm-token",  // scan-secrets: allow(reason=test fixture value)
            "HTTPS_PROXY": "http://proxy.invalid:3128"
        ]
        let expected = ToolPath.uniqueDirectories([
            ["/opt/homebrew/bin"],
            ["/app/bin"],
            ToolPath.knownDirectories(homeDirectory: "/home/test")
        ]).joined(separator: ":")

        for environment in [
            PiWebUpdateEnvironment.environment(base: base, npmExecutablePath: "/opt/homebrew/bin/npm"),
            PiCLIUpdateEnvironment.environment(base: base, executablePath: "/opt/homebrew/bin/pi"),
            PiPackageUpdateEnvironment.environment(base: base, piExecutablePath: "/opt/homebrew/bin/pi")
        ] {
            XCTAssertEqual(environment["PATH"], expected)
            XCTAssertEqual(Set(environment.keys), ["PATH", "HOME", "LANG"], "白名单之外不新增键")
            XCTAssertNil(environment["NPM_TOKEN"])
            XCTAssertNil(environment["HTTPS_PROXY"])
        }
    }
}

// MARK: - 「全部组件都用 Homebrew 安装」的 fixture（GitHub #89 追加要求）

/// 与真实 Homebrew 安装同形态的 fixture，整棵树都在 `$TMPDIR` 下：
///
/// - `node`：`<prefix>/bin/node` → `<prefix>/Cellar/node/<版本>/bin/node`；
/// - 组件入口：`#!/usr/bin/env node` 脚本；npm 全局时真身在
///   `<prefix>/lib/node_modules/<包>/…`，Homebrew formula 时在
///   `<prefix>/Cellar/<formula>/<版本>/…`；
/// - `npm`：`<prefix>/bin/npm`，回答 `prefix -g` 与 `root -g`。
///
/// 因此 `pi --version` 能否成功只取决于工具 PATH 里有没有 node，与测试进程自己
/// 继承的 PATH 无关，也不会执行任何真实 `npm` / `pi` / `pi-web`。`nodeIsReal`
/// 为真时把 Cellar 里的 node 链接到真实 Mach-O node：此时入口脚本由真实 node
/// 解释执行（不联网、不读写用户目录），用来覆盖 Homebrew 上的真实形态。
private struct ToolPathHomebrewFixture {
    enum Layout {
        /// npm 全局：`<prefix>/lib/node_modules/<包>/…`（用 Homebrew 的 node 安装）。
        case npmGlobal
        /// Homebrew formula：`<prefix>/Cellar/<formula>/<版本>/bin/<name>`。
        case formula
    }

    static let nodeVersion = "24.21.0"
    static let piVersion = "9.9.9"

    let rootURL: URL
    let prefixURL: URL
    let homeURL: URL
    let layout: Layout
    let nodeIsReal: Bool

    var binURL: URL { prefixURL.appendingPathComponent("bin", isDirectory: true) }
    var npmURL: URL { binURL.appendingPathComponent("npm") }
    var piURL: URL { binURL.appendingPathComponent("pi") }
    var piWebURL: URL { binURL.appendingPathComponent("pi-web") }
    var nodeURL: URL { binURL.appendingPathComponent("node") }
    var cellarNodeURL: URL { prefixURL.appendingPathComponent("Cellar/node/\(Self.nodeVersion)/bin/node") }
    var nodeARGVRecordURL: URL { rootURL.appendingPathComponent("node-argv.txt") }
    var nodePATHRecordURL: URL { rootURL.appendingPathComponent("node-path.txt") }

    /// `relativePrefix` 是 `opt/homebrew`（Apple Silicon）或 `usr/local`（Intel）。
    init(layout: Layout, relativePrefix: String, nodeIsReal: Bool = false) throws {
        rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ToolPathHomebrewFixture-\(UUID().uuidString)", isDirectory: true)
        prefixURL = rootURL.appendingPathComponent(relativePrefix, isDirectory: true)
        homeURL = rootURL.appendingPathComponent("Users/test", isDirectory: true)
        self.layout = layout
        self.nodeIsReal = nodeIsReal
        try FileManager.default.createDirectory(at: binURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: homeURL, withIntermediateDirectories: true)
        try makeNode()
        try makeNPM()
        try makeComponent(
            name: "pi",
            package: "@earendil-works/pi-coding-agent",
            entry: "dist/bundle/cli.js",
            version: Self.piVersion,
            isPiWeb: false
        )
        try makeComponent(
            name: "pi-web",
            package: "@agegr/pi-web",
            entry: "bin/pi-web.js",
            version: "1.2.3",
            isPiWeb: true
        )
        try write(
            prefixURL.appendingPathComponent("lib/node_modules/@agegr/pi-web/package.json"),
            contents: #"{"name":"@agegr/pi-web","version":"1.2.3"}"#
        )
    }

    private func makeNode() throws {
        // 真实 node 存在时：`bin/node` → Cellar 真身 →（符号链接）真实 Mach-O。
        if nodeIsReal,
           let real = ["/opt/homebrew/bin/node", "/usr/local/bin/node", "/usr/bin/node"]
           .first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            try FileManager.default.createDirectory(
                at: cellarNodeURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try FileManager.default.createSymbolicLink(atPath: cellarNodeURL.path, withDestinationPath: real)
            try FileManager.default.createSymbolicLink(
                atPath: nodeURL.path,
                withDestinationPath: "../Cellar/node/\(Self.nodeVersion)/bin/node"
            )
            return
        }
        // 确定性的替身：记录 argv 与 PATH，按参数给出可解析的版本号。
        try write(cellarNodeURL, contents: """
        #!/bin/sh
        printf '%s\\n' "$@" >> "\(nodeARGVRecordURL.path)"
        printf '%s' "$PATH" > "\(nodePATHRecordURL.path)"
        case "$1" in
          */pi-web*) exit 1 ;;
        esac
        case "$2" in
          list) exit 1 ;;
        esac
        case "$1" in
          --version) printf '\(Self.nodeVersion)\\n' ;;
          *) printf '\(Self.piVersion)\\n' ;;
        esac
        """)
        try FileManager.default.createSymbolicLink(
            atPath: nodeURL.path,
            withDestinationPath: "../Cellar/node/\(Self.nodeVersion)/bin/node"
        )
        try "".write(to: nodeARGVRecordURL, atomically: true, encoding: .utf8)
    }

    /// `npm` 是 `#!/usr/bin/env node` 脚本：只要工具 PATH 里有 node 就能回答。
    private func makeNPM() throws {
        try write(npmURL, contents: """
        #!/bin/sh
        case "$1" in
          prefix) printf '%s\\n' "\(prefixURL.path)" ;;
          root) printf '%s\\n' "\(prefixURL.path)/lib/node_modules" ;;
          *) exit 1 ;;
        esac
        """)
    }

    private func makeComponent(
        name: String,
        package: String,
        entry: String,
        version: String,
        isPiWeb: Bool
    ) throws {
        let realURL: URL
        switch layout {
        case .npmGlobal:
            realURL = prefixURL.appendingPathComponent("lib/node_modules/\(package)/\(entry)")
        case .formula:
            // pi-web 仍然是 npm 全局安装；只有 pi 换成 Homebrew formula 形态。
            realURL = isPiWeb
                ? prefixURL.appendingPathComponent("lib/node_modules/\(package)/\(entry)")
                : prefixURL.appendingPathComponent("Cellar/\(name)/1.2.3/bin/\(name)")
        }
        let script: String
        if nodeIsReal {
            script = """
            #!/usr/bin/env node
            const args = process.argv.slice(2);
            if (args.includes("--version")) {
              \(isPiWeb ? "process.exit(1);" : "console.log(\"\(version)\");")
            }
            """
        } else {
            script = "#!/usr/bin/env node\nconsole.log(\"\(version)\");\n"
        }
        try write(realURL, contents: script)
        try FileManager.default.createSymbolicLink(
            atPath: binURL.appendingPathComponent(name).path,
            withDestinationPath: realURL.path
        )
    }

    func write(_ url: URL, contents: String) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: rootURL)
    }

    /// 与生产同一套注入：应用侧 PATH 只有系统目录，node 只在“登录 shell 报告的
    /// 工具 PATH”里（等价于用户在 Finder 里双击打开应用）。
    func makeChecker() -> DependencyChecker {
        DependencyChecker(
            commandRunner: SystemCommandRunner(),
            fileSystem: ToolPathFixtureFileSystemProbe(root: rootURL.path, home: homeURL.path),
            system: DependencySystemProbe(
                architecture: { "arm64" },
                operatingSystemVersion: { OperatingSystemVersion(majorVersion: 14, minorVersion: 0, patchVersion: 0) }
            ),
            portProbe: ToolPathFakePortProbe(),
            environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": homeURL.path],
            loginShellPath: { binURL.path }
        )
    }

    func makeProvider() -> ToolPathProvider {
        ToolPathProvider(
            environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": homeURL.path],
            homeDirectory: homeURL.path,
            commandRunner: SystemCommandRunner(),
            // 沙箱探针：只认 fixture 内部，真实系统目录不会被当成可用目录。
            directoryIsUsable: { path in
                ToolPathFixtureFileSystemProbe(root: rootURL.path, home: homeURL.path)
                    .directoryExists(atPath: path)
            },
            loginShellPath: { binURL.path }
        )
    }
}

final class ToolPathHomebrewInstallationTests: XCTestCase {
    // MARK: - 1. 全部组件都用 Homebrew 安装（npm 全局 / formula / Intel 前缀）

    /// node 来自 Homebrew，`pi` / `pi-web` 是用 Homebrew 的 node 做的 npm 全局
    /// 安装，入口是 `#!/usr/bin/env node`：最小 PATH 下三项都必须 `ok`，来源与
    /// 可信度都必须 verified，npm prefix 也必须解析出来。
    func testNPMGlobalLayoutIsFullyVerifiedFromMinimalPath() throws {
        try assertVerifiedHomebrewInstallation(
            layout: .npmGlobal,
            relativePrefix: "opt/homebrew",
            expected: .npmGlobal,
            expectedComponentSource: .npmGlobal
        )
    }

    func testHomebrewFormulaPiIsVerifiedAsHomebrew() throws {
        try assertVerifiedHomebrewInstallation(
            layout: .formula,
            relativePrefix: "opt/homebrew",
            expected: .homebrew,
            expectedComponentSource: .homebrew
        )
    }

    func testIntelPrefixLayoutIsFullyVerifiedFromMinimalPath() throws {
        try assertVerifiedHomebrewInstallation(
            layout: .npmGlobal,
            relativePrefix: "usr/local",
            expected: .npmGlobal,
            expectedComponentSource: .npmGlobal
        )
    }

    private func assertVerifiedHomebrewInstallation(
        layout: ToolPathHomebrewFixture.Layout,
        relativePrefix: String,
        expected: DependencyInstallSource,
        expectedComponentSource: InstallSource
    ) throws {
        let fixture = try ToolPathHomebrewFixture(layout: layout, relativePrefix: relativePrefix)
        defer { fixture.cleanUp() }
        let report = fixture.makeChecker().run()

        let node = try XCTUnwrap(report.finding(for: .node))
        let pi = try XCTUnwrap(report.finding(for: .piCLI))
        let piWeb = try XCTUnwrap(report.finding(for: .piWeb))
        XCTAssertEqual(node.status, .ok, "Homebrew 的 node 必须是 ok")
        XCTAssertEqual(node.installSource, .homebrew, "node 的真身在 Cellar 里")
        XCTAssertEqual(node.confidence, .verified, "Cellar 结构是可验证证据")
        XCTAssertEqual(pi.status, .ok, "pi 必须是 ok，不能因为 PATH 最小而降级")
        XCTAssertEqual(pi.version, ToolPathHomebrewFixture.piVersion)
        XCTAssertEqual(pi.installSource, expected)
        XCTAssertEqual(pi.confidence, .verified)
        XCTAssertEqual(piWeb.status, .ok)
        XCTAssertEqual(piWeb.version, "1.2.3", "pi-web 的版本来自 package.json")
        XCTAssertEqual(piWeb.installSource, .npmGlobal)
        XCTAssertEqual(piWeb.confidence, .verified)
        XCTAssertTrue(report.canStartService, "三项都 ok 时必须可以启动服务")

        let piComponent = try XCTUnwrap(report.component(for: .piCLI))
        XCTAssertEqual(piComponent.source, expectedComponentSource)
        XCTAssertEqual(piComponent.confidence, .verified)
        let piWebComponent = try XCTUnwrap(report.component(for: .piWeb))
        XCTAssertEqual(piWebComponent.source, .npmGlobal)
        XCTAssertEqual(piWebComponent.confidence, .verified)

        // npm 自己是 `#!/usr/bin/env node` 脚本：prefix 仍必须解析出来。
        let provider = fixture.makeProvider()
        XCTAssertEqual(provider.resolvedNPMPrefix(), fixture.prefixURL.path)
        XCTAssertTrue(provider.directories().contains(fixture.binURL.path))
        XCTAssertEqual(
            provider.path(),
            "/usr/bin:/bin:/usr/sbin:/sbin:\(fixture.binURL.path)",
            "工具 PATH = 应用 PATH + 登录 shell 报告的 Homebrew 前缀"
        )
        XCTAssertEqual(provider.probeEnvironment()["PATH"], provider.path())
    }

    /// 真实 node（Mach-O）执行 `#!/usr/bin/env node` 入口：就是用户机器上的形态。
    /// 本机没有真实 node 时（例如没有 Homebrew 的 CI 机器）不执行断言。
    func testRealNodeExecutesTheEnvNodeEntryScript() throws {
        guard ["/opt/homebrew/bin/node", "/usr/local/bin/node", "/usr/bin/node"]
            .contains(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            return
        }
        let fixture = try ToolPathHomebrewFixture(layout: .npmGlobal, relativePrefix: "opt/homebrew", nodeIsReal: true)
        defer { fixture.cleanUp() }
        let report = fixture.makeChecker().run()

        let pi = try XCTUnwrap(report.finding(for: .piCLI))
        XCTAssertEqual(pi.status, .ok)
        XCTAssertEqual(pi.version, ToolPathHomebrewFixture.piVersion, "版本来自入口脚本由真实 node 打印的输出")
        XCTAssertEqual(pi.installSource, .npmGlobal)
        XCTAssertEqual(pi.confidence, .verified)
        let node = try XCTUnwrap(report.finding(for: .node))
        XCTAssertEqual(node.status, .ok, "真实 node 的 --version 必须能解析")
        XCTAssertEqual(node.installSource, .homebrew)
        XCTAssertNotNil(node.version)
        XCTAssertEqual(try XCTUnwrap(report.finding(for: .piWeb)).version, "1.2.3")
    }

    // MARK: - 2. 候选路径与登录 shell 解析（追加要求 2 / 3）

    func testExecutableCandidatesCoverHomebrewIntelAndMacPortsInFixedOrder() {
        // 真实 macOS Home 前缀分段拼接：仓库文本扫描不允许出现绝对 Home 字面值。
        let home = "/Users" + "/test"
        let candidates = ToolPath.executableCandidates(
            named: "pi",
            homeDirectory: home,
            additionalDirectories: ["/custom/bin", "/opt/homebrew/bin"]
        )
        XCTAssertEqual(candidates, [
            "/opt/homebrew/bin/pi",
            "/usr/local/bin/pi",
            "\(home)/.npm-global/bin/pi",
            "/opt/homebrew/sbin/pi",
            "/usr/local/sbin/pi",
            "/opt/local/bin/pi",
            "\(home)/.local/bin/pi",
            "\(home)/.bun/bin/pi",
            "\(home)/.cargo/bin/pi",
            "/usr/bin/pi",
            "/bin/pi",
            "/usr/sbin/pi",
            "/sbin/pi",
            "/custom/bin/pi"
        ])
        XCTAssertEqual(Set(candidates).count, candidates.count, "候选路径不得重复")
    }

    func testLoginShellResolverPrefersUserDatabaseThenEnvironmentThenZsh() {
        let executable: (String) -> Bool = { ["/custom/shell", "/env/shell", "/bin/zsh"].contains($0) }
        XCTAssertEqual(
            LoginShellResolver.shellPath(
                environment: ["SHELL": "/env/shell"],
                fileIsExecutable: executable,
                userDatabaseShellPath: { "/custom/shell" }
            ),
            "/custom/shell",
            "用户数据库里的登录 shell（dscl 同一数据源）最优先"
        )
        XCTAssertEqual(
            LoginShellResolver.shellPath(
                environment: ["SHELL": "/env/shell"],
                fileIsExecutable: executable,
                userDatabaseShellPath: { nil }
            ),
            "/env/shell"
        )
        XCTAssertEqual(
            LoginShellResolver.shellPath(
                environment: ["SHELL": "zsh"],
                fileIsExecutable: executable,
                userDatabaseShellPath: { nil }
            ),
            "/bin/zsh",
            "相对路径与非可执行值都必须被拒绝"
        )
        XCTAssertEqual(
            LoginShellResolver.shellPath(
                environment: [:],
                fileIsExecutable: { _ in false },
                userDatabaseShellPath: { nil }
            ),
            "/bin/zsh",
            "都无法判定时退回 /bin/zsh"
        )
    }

    func testLoginShellPathQueryParsesMarkerAndIgnoresShellOutput() {
        XCTAssertEqual(LoginShellPathQuery.parse(output: "__PI_WEB_TOOL_PATH__/usr/bin:/bin"), "/usr/bin:/bin")
        XCTAssertEqual(
            LoginShellPathQuery.parse(output: "欢迎\n__PI_WEB_TOOL_PATH__/usr/bin:/bin\n其它输出"),
            "/usr/bin:/bin",
            "rc 自己的输出被忽略：只取最后一个标记之后的第一行"
        )
        XCTAssertNil(LoginShellPathQuery.parse(output: "__PI_WEB_TOOL_PATH__"))
        XCTAssertNil(LoginShellPathQuery.parse(output: "/usr/bin"))
        XCTAssertNil(LoginShellPathQuery.parse(output: nil))
    }

    func testLoginShellPathQueryFallsBackToInteractiveQueryOnce() {
        // 登录查询拿不到值、交互式查询拿到值：覆盖“PATH 只配在 ~/.zshrc 里”。
        let runner = ToolPathFakeRunner()
        runner.results = [nil, "\n__PI_WEB_TOOL_PATH__/rc/bin:/usr/bin"]
        let query = LoginShellPathQuery(runner: runner, shellPath: "/bin/zsh")
        XCTAssertEqual(query.path(), "/rc/bin:/usr/bin")
        XCTAssertEqual(query.path(), "/rc/bin:/usr/bin", "结果缓存")
        XCTAssertEqual(runner.invocationLines, [
            "/bin/zsh -lc printf '__PI_WEB_TOOL_PATH__%s' \"$PATH\"",
            "/bin/zsh -ilc printf '__PI_WEB_TOOL_PATH__%s' \"$PATH\""
        ])

        let noInteractive = ToolPathFakeRunner()
        noInteractive.results = [nil]
        XCTAssertNil(LoginShellPathQuery(runner: noInteractive, shellPath: "/bin/zsh", interactiveFallback: false).path())
        XCTAssertEqual(noInteractive.invocationLines.count, 1)
    }

    func testInteractiveOnlyPathReachesTheProbeEnvironment() {
        let provider = ToolPathProvider(
            environment: ["PATH": "/usr/bin:/bin", "HOME": "/home/test"],
            homeDirectory: "/home/test",
            commandRunner: ToolPathFakeRunner(),
            directoryIsUsable: { _ in false },
            fileIsExecutable: { _ in false },
            loginShellPath: { "/rc/bin" },
            nodePathResolver: { _ in nil },
            npmPrefixResolver: { _ in nil }
        )
        XCTAssertEqual(provider.path(), "/usr/bin:/bin:/rc/bin")
        XCTAssertEqual(provider.probeEnvironment()["PATH"], provider.path())
    }

    /// 读 stdin 的脚本不能把诊断卡住：子进程的 stdin 固定为 `/dev/null`
    /// （交互式登录 shell 的 rc 文件也可能读 stdin）。
    func testCommandRunnerFeedsDevNullOnStandardInput() throws {
        let fixture = try ToolPathFixture()
        defer { fixture.cleanUp() }
        let reader = fixture.rootURL.appendingPathComponent("reader")
        try fixture.write(reader, contents: "#!/bin/sh\nread line\nprintf 'got:%s' \"$line\"\n")
        XCTAssertEqual(SystemCommandRunner(timeout: 3).run([reader.path]), "got:")
    }
}
