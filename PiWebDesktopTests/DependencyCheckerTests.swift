import Foundation
import XCTest

/// 依赖诊断的 unhosted 测试。
///
/// 所有命令都走假 runner，所有磁盘访问都走假探针，架构与系统版本固定注入：
/// 测试不执行真实 `npm`/`pi`/`pi-web`，不访问网络、`~/.pi`、真实用户 Home 或
/// 真实 npm 前缀。假 Home 是 `/tmp` 下的固定值，用来验证脱敏。
private final class DependencyFakeRunner: CommandRunning {
    var handler: ([String]) -> String? = { _ in nil }
    /// 超时替身：非 nil 时接管“带超时”的探测，用来模拟某条探针挂住（不返回）。
    /// 未设置时走默认实现（退回 `handler`，永不超时），既有的用例因此不受影响。
    var timeoutHandler: (([String]) -> CommandRunResult)?
    private(set) var invocations: [[String]] = []

    func run(_ arguments: [String]) -> String? {
        invocations.append(arguments)
        if let timeoutHandler { return timeoutHandler(arguments).output }
        return handler(arguments)
    }

    func run(_ arguments: [String], timeout: TimeInterval) -> CommandRunResult {
        invocations.append(arguments)
        if let timeoutHandler { return timeoutHandler(arguments) }
        return CommandRunResult(output: handler(arguments))
    }

    /// 已执行命令的扁平文本，供“没有安装/提权/网络动作”的断言使用。
    var invocationLines: [String] {
        invocations.map { $0.joined(separator: " ") }
    }
}

/// 显式登记的假文件系统：只认识测试加进去的可执行文件、符号链接和文本文件。
private final class DependencyFakeFileSystem: DependencyFileSystemProbing {
    /// 固定假 Home；诊断文本里不能出现它，只能出现 `~`。
    let home = "/tmp/pi-web-desktop-tests-home"
    var executables: Set<String> = []
    var symlinks: [String: String] = [:]
    var resolvedPaths: [String: String] = [:]
    var files: [String: String] = [:]
    /// 存在的目录（例如假 Pi 配置目录）。
    var directories: Set<String> = []
    /// 存在但不可读的目录。
    var unreadableDirectories: Set<String> = []
    /// `readText` 实际读过的路径，供“从未读取认证内容”的断言使用。
    private(set) var readPaths: [String] = []

    func isExecutableFile(atPath path: String) -> Bool {
        executables.contains(path)
    }

    func symlinkDestination(atPath path: String) -> String? {
        symlinks[path]
    }

    func resolvedPath(atPath path: String) -> String? {
        if let resolved = resolvedPaths[path] { return resolved }
        guard executables.contains(path) || files[path] != nil || symlinks[path] != nil else { return nil }
        return path
    }

    func readText(atPath path: String) -> String? {
        readPaths.append(path)
        return files[path]
    }

    func homeDirectoryPath() -> String {
        home
    }

    func directoryExists(atPath path: String) -> Bool? {
        directories.contains(path) || unreadableDirectories.contains(path)
    }

    func isReadableDirectory(atPath path: String) -> Bool? {
        guard directoryExists(atPath: path) == true else { return nil }
        return !unreadableDirectories.contains(path)
    }
}

private struct DependencyHarness {
    let runner = DependencyFakeRunner()
    let fileSystem = DependencyFakeFileSystem()
    var architecture = "arm64"
    var osVersion = OperatingSystemVersion(majorVersion: 14, minorVersion: 5, patchVersion: 0)
    var configuredPiWebPath = ""
    /// 默认端口探针结果；nil 表示无法判定。
    var portAvailability: Bool? = true

    func checker() -> DependencyChecker {
        DependencyChecker(
            commandRunner: runner,
            fileSystem: fileSystem,
            system: DependencySystemProbe(
                architecture: { architecture },
                operatingSystemVersion: { osVersion }
            ),
            configuredPiWebPath: configuredPiWebPath,
            portProbe: DependencyFakePortProbe(availability: { portAvailability })
        )
    }
}

/// 固定结果的假端口探针：不绑定真实端口。
private struct DependencyFakePortProbe: DependencyPortProbing {
    var availability: () -> Bool?

    func isPortAvailable(host: String, port: Int) -> Bool? {
        availability()
    }
}

/// 标准“前置齐全”场景：Homebrew 前缀下的 node/pi/pi-web 符号链接、
/// npm 前缀 `/opt/homebrew`、pi-web 的 package.json。
private let nodeResolvedPath = "/opt/homebrew/Cellar/node/22.19.0/bin/node"
/// 真实 macOS Home 前缀，分开拼接：仓库里不允许出现绝对 Home 路径字面值。
private let absoluteHomePrefix = "/Users" + "/"
private let piResolvedPath = "/opt/homebrew/lib/node_modules/@earendil-works/pi-coding-agent/dist/cli.js"
private let piWebResolvedPath = "/opt/homebrew/lib/node_modules/@agegr/pi-web/dist/cli.js"
private let piWebPackageJSONPath = "/opt/homebrew/lib/node_modules/@agegr/pi-web/package.json"

private func makeHarness(
    nodeVersionOutput: String? = "v22.19.0",
    piVersionOutput: String? = "9.9.9",
    piWebVersionOutput: String? = "1.2.3",
    npmPrefix: String? = "/opt/homebrew",
    includePackageJSON: Bool = true
) -> DependencyHarness {
    let harness = DependencyHarness()
    harness.fileSystem.executables = [
        "/opt/homebrew/bin/node",
        "/opt/homebrew/bin/pi",
        "/opt/homebrew/bin/pi-web",
        // 真实安装里链接目标也是存在的可执行文件；不登记的话链接链会被当成悬空。
        nodeResolvedPath,
        piResolvedPath,
        piWebResolvedPath
    ]
    harness.fileSystem.symlinks = [
        "/opt/homebrew/bin/node": "../Cellar/node/22.19.0/bin/node",
        "/opt/homebrew/bin/pi": "../lib/node_modules/@earendil-works/pi-coding-agent/dist/cli.js",
        "/opt/homebrew/bin/pi-web": "../lib/node_modules/@agegr/pi-web/dist/cli.js"
    ]
    harness.fileSystem.resolvedPaths = [
        "/opt/homebrew/bin/node": nodeResolvedPath,
        "/opt/homebrew/bin/pi": piResolvedPath,
        "/opt/homebrew/bin/pi-web": piWebResolvedPath
    ]
    if includePackageJSON {
        harness.fileSystem.files = [
            piWebPackageJSONPath: #"{"name":"@agegr/pi-web","version":"1.2.3"}"#
        ]
    }
    harness.runner.handler = { arguments in
        switch arguments.joined(separator: " ") {
        case "/opt/homebrew/bin/node --version": return nodeVersionOutput.map { $0 + "\n" }
        case "/opt/homebrew/bin/pi --version": return piVersionOutput.map { $0 + "\n" }
        case "/opt/homebrew/bin/pi-web --version": return piWebVersionOutput.map { $0 + "\n" }
        case "/usr/bin/env npm prefix -g": return npmPrefix.map { $0 + "\n" }
        default: return nil
        }
    }
    return harness
}

private func finding(_ kind: DependencyFinding.Kind, _ status: DependencyFinding.Status) -> DependencyFinding {
    DependencyFinding(
        kind: kind,
        status: status,
        path: nil,
        resolvedPath: nil,
        symlinkTarget: nil,
        version: nil,
        installSource: .unknown,
        confidence: .unknown,
        remediationID: nil,
        packageName: nil,
        packageVersion: nil
    )
}

/// 启动门控缓存的假文件接缝（GitHub #169）：只存字节，不碰真实文件系统。
private final class DependencyGateFakeCacheFileIO: DependencyGateCacheFileIO {
    var data: Data?
    var writeSucceeds = true
    private(set) var readURLs: [URL] = []
    private(set) var writtenURLs: [URL] = []

    func read(from url: URL) -> Data? {
        readURLs.append(url)
        return data
    }

    @discardableResult
    func write(_ data: Data, to url: URL) -> Bool {
        writtenURLs.append(url)
        guard writeSucceeds else { return false }
        self.data = data
        return true
    }
}

final class DependencyCheckerTests: XCTestCase {
    // MARK: - 语义化版本

    func testVersionParsing() {
        XCTAssertEqual(SemanticVersion("v22.19.0")?.description, "22.19.0")
        XCTAssertEqual(SemanticVersion("22.19")?.description, "22.19.0")
        XCTAssertEqual(SemanticVersion("1.2.3.4")?.description, "1.2.3.4")
        XCTAssertEqual(SemanticVersion("1.2.3-rc.1+build.7")?.description, "1.2.3-rc.1")
        XCTAssertNil(SemanticVersion(""))
        XCTAssertNil(SemanticVersion("v"))
        XCTAssertNil(SemanticVersion("1..2"))
        XCTAssertNil(SemanticVersion("1.2.3.4.5"))
        XCTAssertNil(SemanticVersion("not-a-version"))
    }

    func testVersionComparisonIsNumericAndTreatsPrereleaseAsLower() {
        XCTAssertLessThan(SemanticVersion("9.0.0")!, SemanticVersion("10.0.0")!)
        XCTAssertLessThan(SemanticVersion("22.18.9")!, SemanticVersion("22.19.0")!)
        XCTAssertLessThan(SemanticVersion("22.19.0")!, SemanticVersion("22.19.1")!)
        XCTAssertLessThan(SemanticVersion("22.19.0-rc.1")!, SemanticVersion("22.19.0")!)
        XCTAssertEqual(SemanticVersion("22.19.0"), SemanticVersion("v22.19.0"))
        XCTAssertFalse(SemanticVersion("22.19.0")! < SemanticVersion("22.19.0")!)
    }

    func testFirstVersionPicksTheVersionToken() {
        XCTAssertEqual(SemanticVersion.firstVersion(in: "pi-web 1.2.3 (node 22.19.0)")?.description, "1.2.3")
        XCTAssertEqual(SemanticVersion.firstVersion(in: "v22.19.0\n")?.description, "22.19.0")
        XCTAssertEqual(SemanticVersion.firstVersion(in: "(9.9.9)")?.description, "9.9.9")
        XCTAssertNil(SemanticVersion.firstVersion(in: "unknown\n"))
        XCTAssertNil(SemanticVersion.firstVersion(in: ""))
    }

    // MARK: - canStartService 门控

    func testAllPrerequisitesAllowServiceStart() {
        let harness = makeHarness()
        let report = harness.checker().run()

        XCTAssertEqual(
            report.findings.map(\.kind),
            [.system, .node, .piCLI, .piWeb, .port, .piConfigDirectory]
        )
        XCTAssertTrue(report.blockingFindings.isEmpty)
        XCTAssertTrue(report.canStartService)
    }

    // MARK: - 探针超时（W4 M1：超时按不可用处理，不能永久关闭门控）

    private static let timeoutDetail = "依赖探测超时：命令在 10 秒上限内没有返回"

    /// 登录 shell 的 `command -v` 超时：pi 报为缺失，但带着可读原因；诊断文本
    /// 里能看到“依赖探测超时”，门控关闭不再是无提示的永久状态；超时也不粘住，
    /// 下一次正常探测立即恢复就绪。
    func testShellLookupTimeoutBlocksTheGateWithAReadableReasonAndRecovers() {
        let harness = makeHarness()
        // `pi` 的候选路径暂时不可用，只能靠登录 shell 解析；这条 shell 探针不返回。
        let originalExecutables = harness.fileSystem.executables
        let originalSymlinks = harness.fileSystem.symlinks
        let originalResolvedPaths = harness.fileSystem.resolvedPaths
        harness.fileSystem.executables.remove("/opt/homebrew/bin/pi")
        harness.fileSystem.symlinks.removeValue(forKey: "/opt/homebrew/bin/pi")
        harness.fileSystem.resolvedPaths.removeValue(forKey: "/opt/homebrew/bin/pi")
        harness.runner.timeoutHandler = { arguments in
            arguments.joined(separator: " ") == "/bin/zsh -lc command -v pi 2>/dev/null"
                ? CommandRunResult(output: nil, timedOut: true)
                : CommandRunResult(output: harness.runner.handler(arguments))
        }

        let report = harness.checker().run()
        XCTAssertFalse(report.canStartService)
        XCTAssertEqual(report.finding(for: .piCLI)?.status, .missing)
        XCTAssertEqual(report.finding(for: .piCLI)?.detail, Self.timeoutDetail)
        XCTAssertNil(report.finding(for: .piWeb)?.detail, "未超时的探针不得背锅")
        let text = DependencyReportPresenter.statusPageText(for: report, setupIncomplete: false)
        XCTAssertTrue(text.contains("依赖探测超时"), "诊断文本里要能看到超时原因")
        XCTAssertTrue(text.contains("重新检测"), "超时后的下一步应是重新检测，而不是安装")
        XCTAssertTrue(text.contains("~/.zprofile"), "提示要点出登录 shell 阻塞这个可能原因")

        // 超时不是粘性状态：路径恢复、探测正常返回时门控恢复。
        harness.runner.timeoutHandler = nil
        harness.fileSystem.executables = originalExecutables
        harness.fileSystem.symlinks = originalSymlinks
        harness.fileSystem.resolvedPaths = originalResolvedPaths
        XCTAssertTrue(harness.checker().run().canStartService)
    }

    /// `--version` 探针超时：只影响对应的诊断项，原因写在那一项上。
    func testVersionProbeTimeoutIsReportedOnTheAffectedItemOnly() {
        // 不提供 package.json，版本只能来自 `--version`。
        let harness = makeHarness(includePackageJSON: false)
        harness.runner.timeoutHandler = { arguments in
            arguments.joined(separator: " ") == "/opt/homebrew/bin/pi-web --version"
                ? CommandRunResult(output: nil, timedOut: true)
                : CommandRunResult(output: harness.runner.handler(arguments))
        }

        let report = harness.checker().run()
        XCTAssertFalse(report.canStartService)
        XCTAssertEqual(report.finding(for: .piWeb)?.status, .unknown)
        XCTAssertEqual(report.finding(for: .piWeb)?.detail, Self.timeoutDetail)
        XCTAssertNil(report.finding(for: .piCLI)?.detail)
        XCTAssertNil(report.finding(for: .node)?.detail)
        XCTAssertNil(report.finding(for: .system)?.detail)
    }

    func testGateMatrix() {
        XCTAssertFalse(DependencyReport(findings: []).canStartService)
        XCTAssertFalse(
            DependencyReport(findings: [finding(.node, .ok), finding(.piCLI, .ok)]).canStartService,
            "缺少 pi-web 条目时门控必须关闭"
        )
        XCTAssertTrue(
            DependencyReport(findings: [
                finding(.system, .missing),
                finding(.node, .ok),
                finding(.piCLI, .ok),
                finding(.piWeb, .ok)
            ]).canStartService,
            "系统项只做提示，不阻塞启动"
        )
        XCTAssertFalse(
            DependencyReport(findings: [
                finding(.node, .ok),
                finding(.piCLI, .unknown),
                finding(.piWeb, .unknown)
            ]).canStartService,
            "pi/pi-web 版本无法解析（unknown）不得放行启动"
        )
        XCTAssertFalse(
            DependencyReport(findings: [
                finding(.node, .ok),
                finding(.piCLI, .ok),
                finding(.piWeb, .unknown)
            ]).canStartService,
            "pi-web 版本无法解析时无法确认身份，必须关闭门控"
        )
        XCTAssertFalse(
            DependencyReport(findings: [
                finding(.node, .outdated),
                finding(.piCLI, .ok),
                finding(.piWeb, .ok)
            ]).canStartService
        )
        XCTAssertFalse(
            DependencyReport(findings: [
                finding(.node, .unknown),
                finding(.piCLI, .ok),
                finding(.piWeb, .ok)
            ]).canStartService
        )
        XCTAssertFalse(
            DependencyReport(findings: [
                finding(.node, .ok),
                finding(.piCLI, .missing),
                finding(.piWeb, .ok)
            ]).canStartService
        )
        XCTAssertFalse(
            DependencyReport(findings: [
                finding(.node, .ok),
                finding(.piCLI, .ok),
                finding(.piWeb, .missing)
            ]).canStartService
        )
    }

    func testBlockingFindingsListOnlyTheBlockers() {
        let report = DependencyReport(findings: [
            finding(.system, .outdated),
            finding(.node, .outdated),
            finding(.piCLI, .missing),
            finding(.piWeb, .ok)
        ])
        XCTAssertEqual(report.blockingFindings.map(\.kind), [.node, .piCLI])
    }

    // MARK: - 缺少命令

    func testMissingCommandsAreReportedAsMissingAndBlockStart() {
        let harness = DependencyHarness()
        harness.runner.handler = { _ in nil }
        let report = harness.checker().run()

        XCTAssertFalse(report.canStartService)
        XCTAssertEqual(report.blockingFindings.map(\.kind), [.node, .piCLI, .piWeb])

        let node = report.finding(for: .node)
        XCTAssertEqual(node?.status, .missing)
        XCTAssertNil(node?.path)
        XCTAssertNil(node?.version)
        XCTAssertEqual(node?.confidence, .unknown)
        XCTAssertEqual(node?.remediationID, "install.node")

        let pi = report.finding(for: .piCLI)
        XCTAssertEqual(pi?.status, .missing)
        XCTAssertEqual(pi?.remediationID, "install.pi")

        let piWeb = report.finding(for: .piWeb)
        XCTAssertEqual(piWeb?.status, .missing)
        XCTAssertEqual(piWeb?.remediationID, "install.pi-web")
        XCTAssertNil(piWeb?.packageName)
    }

    // MARK: - Node 版本

    func testNodeAtMinimumVersionIsAccepted() {
        let report = makeHarness(nodeVersionOutput: "v22.19.0").checker().run()
        XCTAssertEqual(report.finding(for: .node)?.status, .ok)
        XCTAssertEqual(report.finding(for: .node)?.version, "22.19.0")
        XCTAssertNil(report.finding(for: .node)?.remediationID)
        XCTAssertTrue(report.canStartService)
    }

    func testOutdatedNodeBlocksServiceStart() {
        let report = makeHarness(nodeVersionOutput: "v22.18.9").checker().run()
        let node = report.finding(for: .node)
        XCTAssertEqual(node?.status, .outdated)
        XCTAssertEqual(node?.version, "22.18.9")
        XCTAssertEqual(node?.confidence, .verified)
        XCTAssertEqual(node?.remediationID, "install.node")
        XCTAssertFalse(report.canStartService)
        XCTAssertEqual(report.blockingFindings.map(\.kind), [.node])
    }

    func testPrereleaseOfTheMinimumNodeVersionIsOutdated() {
        let report = makeHarness(nodeVersionOutput: "v22.19.0-rc.1").checker().run()
        XCTAssertEqual(report.finding(for: .node)?.status, .outdated)
        XCTAssertFalse(report.canStartService)
    }

    func testUnparseableNodeVersionIsUnknownAndBlocks() {
        let report = makeHarness(nodeVersionOutput: "version unknown").checker().run()
        let node = report.finding(for: .node)
        XCTAssertEqual(node?.status, .unknown)
        XCTAssertNil(node?.version)
        XCTAssertEqual(node?.confidence, .inferred)
        XCTAssertEqual(node?.remediationID, "install.node")
        XCTAssertFalse(report.canStartService)
        XCTAssertEqual(report.blockingFindings.map(\.kind), [.node])
    }

    func testNodeFoundByShellWithoutReadableVersionIsUnknown() {
        let harness = DependencyHarness()
        harness.fileSystem.executables = ["/tmp/vendor/bin/node"]
        harness.runner.handler = { arguments in
            arguments.joined(separator: " ") == "/bin/zsh -lc command -v node 2>/dev/null" ? "/tmp/vendor/bin/node\n" : nil
        }
        let report = harness.checker().run()
        XCTAssertEqual(report.finding(for: .node)?.status, .unknown)
        XCTAssertEqual(report.finding(for: .node)?.path, "/tmp/vendor/bin/node")
        XCTAssertFalse(report.canStartService)
    }

    /// 候选路径存在但 `--version` 失败时，不得用另一个 node 的版本把它放行：
    /// 版本必须与报告的路径同源，否则记为 unknown 并阻塞启动。
    func testUnusableNodePathIsNotRescuedByAnotherNodesVersion() {
        let harness = DependencyHarness()
        harness.fileSystem.executables = ["/opt/homebrew/bin/node", "/usr/local/bin/node"]
        harness.runner.handler = { arguments in
            switch arguments.joined(separator: " ") {
            case "/opt/homebrew/bin/node --version": return nil
            // 旧实现会回退到这个命令并把结果贴到候选路径上（路径/版本不同源）。
            case "/usr/bin/env node --version": return "v24.21.0\n"
            case "/usr/bin/env node -p process.execPath": return "/usr/local/bin/node\n"
            case "/usr/local/bin/node --version": return "v24.21.0\n"
            default: return nil
            }
        }

        let report = harness.checker().run()
        let node = report.finding(for: .node)
        XCTAssertEqual(node?.status, .unknown)
        XCTAssertNil(node?.version)
        XCTAssertEqual(node?.path, "/opt/homebrew/bin/node")
        XCTAssertEqual(node?.remediationID, "install.node")
        XCTAssertFalse(report.canStartService)
        XCTAssertFalse(
            harness.runner.invocationLines.contains("/usr/bin/env node --version"),
            "不得用另一个 node 的版本放行不可运行的候选路径"
        )
        XCTAssertFalse(
            harness.runner.invocationLines.contains("/usr/local/bin/node --version"),
            "不得用另一个 node 的版本放行不可运行的候选路径"
        )
    }

    /// 候选路径完全不存在时才走进程 PATH 回退，并记录真正产出该版本的可执行路径。
    func testNodeFallbackRecordsTheResolvedPathAndItsOwnVersion() {
        let harness = DependencyHarness()
        harness.fileSystem.executables = ["/tmp/env-node/bin/node"]
        harness.runner.handler = { arguments in
            switch arguments.joined(separator: " ") {
            case "/usr/bin/env node -p process.execPath": return "/tmp/env-node/bin/node\n"
            case "/tmp/env-node/bin/node --version": return "v22.19.0\n"
            default: return nil
            }
        }

        let report = harness.checker().run()
        let node = report.finding(for: .node)
        XCTAssertEqual(node?.path, "/tmp/env-node/bin/node")
        XCTAssertEqual(node?.version, "22.19.0")
        XCTAssertEqual(node?.status, .ok)
        XCTAssertNil(node?.remediationID)
    }

    /// 回退解析不出可执行路径时不采信任何版本（不阻塞也不放行）。
    func testNodeFallbackWithoutAResolvablePathIsMissing() {
        let harness = DependencyHarness()
        harness.runner.handler = { arguments in
            arguments.joined(separator: " ") == "/usr/bin/env node -p process.execPath" ? "/tmp/ghost/bin/node\n" : nil
        }

        let report = harness.checker().run()
        XCTAssertEqual(report.finding(for: .node)?.status, .missing)
        XCTAssertNil(report.finding(for: .node)?.version)
        XCTAssertFalse(report.canStartService)
    }

    // MARK: - 符号链接与安装来源

    func testSymlinkedPiWebReportsPathResolvedPathAndTarget() {
        let report = makeHarness().checker().run()
        let piWeb = report.finding(for: .piWeb)

        XCTAssertEqual(piWeb?.path, "/opt/homebrew/bin/pi-web")
        XCTAssertEqual(piWeb?.resolvedPath, piWebResolvedPath)
        XCTAssertEqual(piWeb?.symlinkTarget, "../lib/node_modules/@agegr/pi-web/dist/cli.js")
        XCTAssertEqual(piWeb?.version, "1.2.3")
        XCTAssertEqual(piWeb?.packageName, "@agegr/pi-web")
        XCTAssertEqual(piWeb?.packageVersion, "1.2.3")
        XCTAssertEqual(piWeb?.status, .ok)
        XCTAssertEqual(piWeb?.installSource, .npmGlobal)
        XCTAssertEqual(piWeb?.confidence, .verified)
        XCTAssertNil(piWeb?.remediationID)
    }

    func testHomebrewCellarResolutionIsVerified() {
        let report = makeHarness().checker().run()
        let node = report.finding(for: .node)
        XCTAssertEqual(node?.path, "/opt/homebrew/bin/node")
        XCTAssertEqual(node?.symlinkTarget, "../Cellar/node/22.19.0/bin/node")
        XCTAssertEqual(node?.resolvedPath, nodeResolvedPath)
        XCTAssertEqual(node?.installSource, .homebrew)
        XCTAssertEqual(node?.confidence, .verified)
    }

    func testNPMPrefixModulePathIsVerifiedEvenWithoutCellar() {
        let report = makeHarness().checker().run()
        XCTAssertEqual(report.finding(for: .piCLI)?.installSource, .npmGlobal)
        XCTAssertEqual(report.finding(for: .piCLI)?.confidence, .verified)
    }

    func testUnknownInstallSourceDoesNotBlockStart() {
        let harness = DependencyHarness()
        harness.fileSystem.executables = ["/tmp/vendor/bin/node", "/tmp/vendor/bin/pi", "/tmp/vendor/bin/pi-web"]
        harness.runner.handler = { arguments in
            switch arguments.joined(separator: " ") {
            case "/bin/zsh -lc command -v node 2>/dev/null": return "/tmp/vendor/bin/node\n"
            case "/bin/zsh -lc command -v pi 2>/dev/null": return "/tmp/vendor/bin/pi\n"
            case "/bin/zsh -lc command -v pi-web 2>/dev/null": return "/tmp/vendor/bin/pi-web\n"
            case "/tmp/vendor/bin/node --version": return "v22.19.0\n"
            case "/tmp/vendor/bin/pi --version": return "9.9.9\n"
            case "/tmp/vendor/bin/pi-web --version": return "1.2.3\n"
            default: return nil
            }
        }
        let report = harness.checker().run()
        XCTAssertEqual(report.finding(for: .piWeb)?.installSource, .unknown)
        XCTAssertEqual(report.finding(for: .piWeb)?.status, .ok)
        XCTAssertEqual(report.finding(for: .piWeb)?.confidence, .unknown)
        XCTAssertTrue(report.canStartService, "来源未知只降低可信度，不阻塞启动")
    }

    func testLocalPathUnderHomeIsInferredAndRedacted() {
        let harness = DependencyHarness()
        let home = harness.fileSystem.home
        harness.fileSystem.executables = [
            "\(home)/opt/node/bin/node",
            "\(home)/tools/bin/pi",
            "\(home)/tools/bin/pi-web"
        ]
        harness.runner.handler = { arguments in
            switch arguments.joined(separator: " ") {
            case "/bin/zsh -lc command -v node 2>/dev/null": return "\(home)/opt/node/bin/node\n"
            case "/bin/zsh -lc command -v pi 2>/dev/null": return "\(home)/tools/bin/pi\n"
            case "/bin/zsh -lc command -v pi-web 2>/dev/null": return "\(home)/tools/bin/pi-web\n"
            case "\(home)/opt/node/bin/node --version": return "v22.19.0\n"
            case "\(home)/tools/bin/pi --version": return "9.9.9\n"
            case "\(home)/tools/bin/pi-web --version": return "1.2.3\n"
            default: return nil
            }
        }
        let report = harness.checker().run()
        let piWeb = report.finding(for: .piWeb)

        XCTAssertEqual(piWeb?.path, "~/tools/bin/pi-web")
        XCTAssertEqual(piWeb?.installSource, .localPath)
        XCTAssertEqual(piWeb?.confidence, .inferred)
        XCTAssertTrue(report.canStartService)

        let text = DependencyReportPresenter.summaryText(for: report)
        XCTAssertTrue(text.contains("~/tools/bin/pi-web"))
        XCTAssertFalse(text.contains(home), "诊断文本不能包含真实 Home 绝对路径")
    }

    // MARK: - pi-web 的版本来源与配置路径

    func testPackageJSONVersionIsTheFallbackWhenTheCommandOutputIsUnparseable() {
        let report = makeHarness(piWebVersionOutput: "unknown").checker().run()
        let piWeb = report.finding(for: .piWeb)
        XCTAssertEqual(piWeb?.status, .ok)
        XCTAssertEqual(piWeb?.version, "1.2.3")
        XCTAssertEqual(piWeb?.packageVersion, "1.2.3")
        XCTAssertTrue(report.canStartService)
    }

    func testUnparseablePiWebVersionWithoutPackageJSONIsUnknownAndBlocks() {
        let report = makeHarness(piWebVersionOutput: "unknown", includePackageJSON: false).checker().run()
        let piWeb = report.finding(for: .piWeb)
        XCTAssertEqual(piWeb?.status, .unknown)
        XCTAssertNil(piWeb?.version)
        XCTAssertNil(piWeb?.packageName)
        XCTAssertEqual(piWeb?.confidence, .inferred)
        XCTAssertEqual(piWeb?.remediationID, "install.pi-web")
        XCTAssertFalse(report.canStartService, "无法解析版本且没有 package.json 名称时不能放行")
        XCTAssertEqual(report.blockingFindings.map(\.kind), [.piWeb])
    }

    /// pi 版本无法解析时同样不能放行：门控要求三条硬性前置都能核对身份。
    func testUnparseablePiVersionIsUnknownAndBlocks() {
        let report = makeHarness(piVersionOutput: "unknown").checker().run()
        XCTAssertEqual(report.finding(for: .piCLI)?.status, .unknown)
        XCTAssertFalse(report.canStartService)
        XCTAssertEqual(report.blockingFindings.map(\.kind), [.piCLI])
    }

    func testForeignPackageNameLowersConfidenceToInferred() {
        let harness = makeHarness()
        harness.fileSystem.files = [
            piWebPackageJSONPath: #"{"name":"not-pi-web","version":"1.2.3"}"#
        ]
        let report = harness.checker().run()
        XCTAssertEqual(report.finding(for: .piWeb)?.packageName, "not-pi-web")
        XCTAssertEqual(report.finding(for: .piWeb)?.confidence, .inferred)
    }

    func testConfiguredPiWebPathWinsOverCandidates() {
        var harness = makeHarness()
        harness.configuredPiWebPath = "/tmp/custom/pi-web"
        harness.fileSystem.executables.insert("/tmp/custom/pi-web")
        harness.runner.handler = { arguments in
            switch arguments.joined(separator: " ") {
            case "/opt/homebrew/bin/node --version": return "v22.19.0\n"
            case "/opt/homebrew/bin/pi --version": return "9.9.9\n"
            case "/tmp/custom/pi-web --version": return "7.7.7\n"
            case "/usr/bin/env npm prefix -g": return "/opt/homebrew\n"
            default: return nil
            }
        }
        let report = harness.checker().run()
        XCTAssertEqual(report.finding(for: .piWeb)?.path, "/tmp/custom/pi-web")
        XCTAssertEqual(report.finding(for: .piWeb)?.version, "7.7.7")
        XCTAssertTrue(report.canStartService)
    }

    func testConfiguredPiWebPathThatIsNotExecutableBlocksStart() {
        var harness = makeHarness()
        harness.configuredPiWebPath = "/tmp/custom/missing-pi-web"
        let report = harness.checker().run()
        XCTAssertEqual(report.finding(for: .piWeb)?.status, .missing)
        XCTAssertEqual(report.blockingFindings.map(\.kind), [.piWeb])
        XCTAssertFalse(report.canStartService)
    }

    // MARK: - 路径选择的身份证据

    /// 路径选择用的只读证据：可执行位、`--version` 版本、package.json 名称。
    /// 可执行位不是身份，所以不满足版本/包名时 `confirmsPiWebIdentity` 为 false。
    func testPiWebIdentityEvidenceReportsExecutabilityVersionAndPackageName() {
        let checker = makeHarness().checker()

        let piWeb = checker.piWebIdentityEvidence(atPath: "/opt/homebrew/bin/pi-web")
        XCTAssertTrue(piWeb.isExecutable)
        XCTAssertEqual(piWeb.version, "1.2.3")
        XCTAssertEqual(piWeb.packageName, "@agegr/pi-web")
        XCTAssertTrue(piWeb.confirmsPiWebIdentity)

        // 可执行但版本无法解析、包名也不符（`/bin/echo` 这类文件）：身份不成立。
        let echoHarness = DependencyHarness()
        echoHarness.fileSystem.executables = ["/bin/echo"]
        echoHarness.runner.handler = { arguments in
            arguments.joined(separator: " ") == "/bin/echo --version" ? "--version\n" : nil
        }
        let echo = echoHarness.checker().piWebIdentityEvidence(atPath: "/bin/echo")
        XCTAssertTrue(echo.isExecutable)
        XCTAssertNil(echo.version)
        XCTAssertNil(echo.packageName)
        XCTAssertFalse(echo.confirmsPiWebIdentity)

        // 不可执行：不运行任何命令，直接报告不可用。
        let missing = echoHarness.checker().piWebIdentityEvidence(atPath: "/bin/definitely-not-here")
        XCTAssertFalse(missing.isExecutable)
        XCTAssertFalse(missing.confirmsPiWebIdentity)
        XCTAssertFalse(echoHarness.runner.invocationLines.contains("/bin/definitely-not-here --version"))
    }

    // MARK: - 系统检查

    func testAppleSiliconAndMacOS14AreRequiredForOK() {
        let supported = DependencyHarness()
        supported.runner.handler = { _ in nil }
        XCTAssertEqual(supported.checker().run().finding(for: .system)?.status, .ok)
        XCTAssertTrue(supported.checker().run().finding(for: .system)?.version?.contains("arm64") == true)
        XCTAssertEqual(supported.checker().run().finding(for: .system)?.confidence, .verified)

        var intel = DependencyHarness()
        intel.architecture = "x86_64"
        intel.runner.handler = { _ in nil }
        XCTAssertEqual(intel.checker().run().finding(for: .system)?.status, .missing)

        var oldSystem = DependencyHarness()
        oldSystem.osVersion = OperatingSystemVersion(majorVersion: 13, minorVersion: 6, patchVersion: 0)
        oldSystem.runner.handler = { _ in nil }
        XCTAssertEqual(oldSystem.checker().run().finding(for: .system)?.status, .outdated)
    }

    /// `uname` 失败时 machineArchitecture 为 "unknown"：系统项不能声称已验证。
    func testUnknownArchitectureIsReportedWithUnknownConfidence() {
        var harness = DependencyHarness()
        harness.architecture = "unknown"
        harness.runner.handler = { _ in nil }

        let report = harness.checker().run()
        let system = report.finding(for: .system)
        XCTAssertEqual(system?.status, .missing)
        XCTAssertEqual(system?.confidence, .unknown)
        XCTAssertTrue(system?.version?.contains("unknown") == true)
        // 系统项本来就不阻塞，置信度不影响启动结论。
        XCTAssertFalse(report.blockingFindings.contains { $0.kind == .system })

        harness.architecture = ""
        XCTAssertEqual(harness.checker().run().finding(for: .system)?.confidence, .unknown)
    }

    func testUnsupportedSystemDoesNotBlockServiceStart() {
        let report = DependencyReport(findings: [
            finding(.system, .outdated),
            finding(.node, .ok),
            finding(.piCLI, .ok),
            finding(.piWeb, .ok)
        ])
        XCTAssertTrue(report.blockingFindings.isEmpty)
        XCTAssertTrue(report.canStartService)
    }

    // MARK: - 脱敏与呈现

    func testSummaryTextIsRedactedAndContainsTheRequiredFields() {
        let report = makeHarness().checker().run()
        let text = DependencyReportPresenter.summaryText(for: report)

        for label in ["系统：", "Node.js：", "Pi CLI：", "Pi Web："] {
            XCTAssertTrue(text.contains(label), "缺少诊断项 \(label)")
        }
        XCTAssertTrue(text.contains("路径：/opt/homebrew/bin/pi-web"))
        XCTAssertTrue(text.contains("真实路径：\(piWebResolvedPath)"))
        XCTAssertTrue(text.contains("符号链接目标：../lib/node_modules/@agegr/pi-web/dist/cli.js"))
        XCTAssertTrue(text.contains("版本：1.2.3"))
        XCTAssertTrue(text.contains("安装来源：npm 全局"))
        XCTAssertTrue(text.contains("可信度：已验证"))
        XCTAssertTrue(text.contains("package.json：@agegr/pi-web@1.2.3"))
        XCTAssertTrue(text.contains("结论：可以启动 Pi Web 服务。"))
        XCTAssertFalse(text.contains(absoluteHomePrefix))
        XCTAssertFalse(text.contains("?"))
    }

    func testStatusPageListsMissingItemsAndTheirNextSteps() {
        let harness = makeHarness()
        harness.fileSystem.executables.remove("/opt/homebrew/bin/pi")
        let report = harness.checker().run()
        XCTAssertEqual(report.blockingFindings.map(\.kind), [.piCLI])

        let statusPage = DependencyReportPresenter.statusPageText(for: report, setupIncomplete: false)
        XCTAssertTrue(statusPage.contains("Pi CLI：缺失"))
        XCTAssertTrue(statusPage.contains("下一步："))
        XCTAssertTrue(statusPage.contains("重新检测"))
        XCTAssertTrue(statusPage.contains("缺少硬性前置"))
        XCTAssertFalse(statusPage.contains(harness.fileSystem.home))
        XCTAssertTrue(statusPage.contains("不会退出"), "缺少硬性前置时必须说明应用不会退出")
    }

    func testInstallCommandsTextComesFromTheStaticManifest() {
        let outdatedNode = makeHarness(nodeVersionOutput: "v22.18.0").checker().run()
        XCTAssertEqual(DependencyReportPresenter.remediationEntries(for: outdatedNode).map(\.id), ["install.node"])
        let nodeText = DependencyReportPresenter.installCommandsText(for: outdatedNode)
        XCTAssertTrue(nodeText.contains("Node.js"))
        XCTAssertTrue(nodeText.contains("22.19.0"))
        XCTAssertTrue(nodeText.contains("https://nodejs.org/en/download"))
        XCTAssertFalse(nodeText.contains("npm install"))
        XCTAssertFalse(nodeText.contains("sudo"))

        let missingPiWeb = makeHarness()
        missingPiWeb.fileSystem.executables.remove("/opt/homebrew/bin/pi-web")
        let piWebText = DependencyReportPresenter.installCommandsText(for: missingPiWeb.checker().run())
        XCTAssertTrue(piWebText.contains("npm install -g @agegr/pi-web"))
        XCTAssertTrue(piWebText.contains("https://github.com/agegr/pi-web"))
        XCTAssertFalse(piWebText.contains("?"))

        let satisfied = makeHarness().checker().run()
        XCTAssertTrue(DependencyReportPresenter.remediationEntries(for: satisfied).isEmpty)
        XCTAssertTrue(DependencyReportPresenter.installCommandsText(for: satisfied).isEmpty)
    }

    func testInstallCommandsOnlyCoverBlockingDependencies() {
        let harness = makeHarness()
        harness.fileSystem.executables.remove("/opt/homebrew/bin/pi")
        let entries = DependencyReportPresenter.remediationEntries(for: harness.checker().run())
        XCTAssertEqual(entries.map(\.id), ["install.pi"])
    }

    func testSanitizeRemovesCredentialsQueryAndFragment() {
        XCTAssertEqual(
            DependencyReportPresenter.sanitize(url: "https://user:secret@example.invalid/docs?token=abc#frag"),
            "https://example.invalid/docs"
        )
        XCTAssertEqual(
            DependencyReportPresenter.sanitize(url: "https://nodejs.org/en/download"),
            "https://nodejs.org/en/download"
        )
    }

    func testDiagnosticsTextContainsNoRealHomePathOrSecret() {
        let harness = makeHarness()
        let report = harness.checker().run()
        let combined = [
            DependencyReportPresenter.summaryText(for: report),
            DependencyReportPresenter.statusPageText(for: report, setupIncomplete: false),
            DependencyReportPresenter.installCommandsText(for: report)
        ].joined(separator: "\n")

        XCTAssertFalse(combined.contains(harness.fileSystem.home))
        XCTAssertFalse(combined.contains(absoluteHomePrefix))
        XCTAssertFalse(combined.contains("token="))
        XCTAssertFalse(combined.contains("?"))
        XCTAssertFalse(combined.contains("sudo"))
    }

    // MARK: - 只读约束

    func testCheckerOnlyRunsReadOnlyVersionAndPrefixCommands() {
        let harness = makeHarness()
        _ = harness.checker().run()

        // #16 的组件识别只多了这些只读查询：npm/pnpm 全局 root 与 `pi list`。
        // #89 的输出 PATH 构建额外做只读的登录 shell PATH 查询：优先用户自己的
        // 登录 shell（`-lc`），拿不到值时再试一次交互式查询（`-ilc`）。
        let shell = LoginShellResolver.shellPath(environment: ProcessInfo.processInfo.environment)
        XCTAssertEqual(
            Set(harness.runner.invocationLines),
            Set([
                "/usr/bin/env npm prefix -g",
                "/usr/bin/env npm root -g",
                "/usr/bin/env pnpm root -g",
                "/opt/homebrew/bin/node --version",
                "/opt/homebrew/bin/pi --version",
                "/opt/homebrew/bin/pi list",
                "/opt/homebrew/bin/pi-web --version",
                "\(shell) -lc \(LoginShellPathQuery.command)",
                "\(shell) -ilc \(LoginShellPathQuery.command)"
            ])
        )
        for line in harness.runner.invocationLines {
            XCTAssertFalse(line.contains("sudo"))
            XCTAssertFalse(line.contains("install"))
            XCTAssertFalse(line.lowercased().contains("http"))
            XCTAssertFalse(line.contains("curl"))
        }
    }

    /// #16：报告里带上组件安装模型；npm 全局 + 证据齐全时给静态清单里的更新命令，
    /// `pi list` 无输出时降级为 unknown 而不是崩溃。
    func testReportCarriesComponentInstallationsFromTheSameProbes() {
        let harness = makeHarness()
        let report = harness.checker().run()

        XCTAssertEqual(report.components.map(\.kind), [.piCLI, .piWeb, .piPackage])

        let piWeb = report.component(for: .piWeb)
        XCTAssertEqual(piWeb?.packageName, InstallCommandManifest.piWebPackageName)
        XCTAssertEqual(piWeb?.version, "1.2.3")
        XCTAssertEqual(piWeb?.executablePath, "/opt/homebrew/bin/pi-web")
        XCTAssertEqual(piWeb?.resolvedPath, piWebResolvedPath)
        XCTAssertEqual(piWeb?.source, .npmGlobal)
        XCTAssertEqual(piWeb?.confidence, .verified)
        XCTAssertEqual(piWeb?.suggestedCommand, InstallCommandManifest.updateNPMPiWeb.command)

        let piCLI = report.component(for: .piCLI)
        XCTAssertEqual(piCLI?.packageName, InstallCommandManifest.piCLIPackageName)
        XCTAssertEqual(piCLI?.version, "9.9.9")
        XCTAssertEqual(piCLI?.source, .npmGlobal)
        XCTAssertEqual(piCLI?.suggestedCommand, InstallCommandManifest.updateNPMPiCLI.command)

        let piPackage = report.component(for: .piPackage)
        XCTAssertEqual(piPackage?.source, .unknown)
        XCTAssertEqual(piPackage?.confidence, .unknown)
        XCTAssertNil(piPackage?.suggestedCommand)
        XCTAssertTrue(
            piPackage?.evidence.contains { $0.contains("pi list") } == true,
            "降级原因必须写进证据"
        )

        for component in report.components {
            XCTAssertFalse(component.summaryLine.contains(harness.fileSystem.home))
            XCTAssertFalse(component.evidence.contains { $0.contains(harness.fileSystem.home) })
        }
    }

    // MARK: - 版本解析边界

    func testVersionParsingTrimsWhitespaceAndDropsBuildMetadata() {
        XCTAssertEqual(SemanticVersion("  v1.2.3  ")?.description, "1.2.3")
        XCTAssertEqual(SemanticVersion("V2.0")?.description, "2.0.0")
        XCTAssertEqual(SemanticVersion("1.2.3+build.7")?.description, "1.2.3")
        XCTAssertEqual(SemanticVersion("1.2.3-")?.description, "1.2.3", "空 prerelease 要当正式版")
        XCTAssertEqual(SemanticVersion("1.2.03")?.description, "1.2.3", "前导零不是新版本")
        XCTAssertNil(SemanticVersion("."))
        XCTAssertNil(SemanticVersion("١٢.٣"), "非 ASCII 数字不是版本段")
        XCTAssertNil(SemanticVersion("99999999999999999999.1"), "溢出段必须拒绝而不是崩溃")
    }

    func testFirstVersionSkipsUnparseableTokensInOrder() {
        XCTAssertEqual(SemanticVersion.firstVersion(in: "pi-web unknown 1.2.3")?.description, "1.2.3")
        XCTAssertEqual(SemanticVersion.firstVersion(in: "1.2.3 2.0.0")?.description, "1.2.3")
        XCTAssertEqual(SemanticVersion.firstVersion(in: "v22.19.0,")?.description, "22.19.0")
        XCTAssertNil(SemanticVersion.firstVersion(in: "1.2.3.4.5"))
    }

    // MARK: - 安装来源推断与脱敏

    /// Homebrew 前缀但不在 Cellar 下：来源可推断，置信度只能是 inferred。
    func testHomebrewPrefixWithoutCellarIsInferredNotVerified() {
        let harness = DependencyHarness()
        harness.fileSystem.executables = [
            "/usr/local/bin/node",
            "/usr/local/bin/pi",
            "/usr/local/bin/pi-web"
        ]
        harness.runner.handler = { arguments in
            switch arguments.joined(separator: " ") {
            case "/usr/local/bin/node --version": return "v22.19.0\n"
            case "/usr/local/bin/pi --version": return "9.9.9\n"
            case "/usr/local/bin/pi-web --version": return "1.2.3\n"
            default: return nil
            }
        }

        let report = harness.checker().run()
        let piWeb = report.finding(for: .piWeb)
        XCTAssertEqual(piWeb?.status, .ok)
        XCTAssertEqual(piWeb?.installSource, .homebrew)
        XCTAssertEqual(piWeb?.confidence, .inferred)
    }

    /// `~/.npm-global/bin` 命中 npm 全局，但没有 package.json 佐证时置信度只能是
    /// inferred，不能标成 verified。
    func testNPMGlobalHomeBinDirectoryIsInferredNotVerified() {
        let harness = DependencyHarness()
        let home = harness.fileSystem.home
        harness.fileSystem.executables = [
            "\(home)/.npm-global/bin/node",
            "\(home)/.npm-global/bin/pi",
            "\(home)/.npm-global/bin/pi-web"
        ]
        harness.runner.handler = { arguments in
            switch arguments.joined(separator: " ") {
            case "\(home)/.npm-global/bin/node --version": return "v22.19.0\n"
            case "\(home)/.npm-global/bin/pi --version": return "9.9.9\n"
            case "\(home)/.npm-global/bin/pi-web --version": return "1.2.3\n"
            default: return nil
            }
        }

        let report = harness.checker().run()
        let piWeb = report.finding(for: .piWeb)
        XCTAssertEqual(piWeb?.status, .ok)
        XCTAssertEqual(piWeb?.installSource, .npmGlobal)
        XCTAssertEqual(piWeb?.confidence, .inferred)
        XCTAssertTrue(report.canStartService)
    }

    /// 脱敏只替换 Home 边界：Home 本身与 Home 下的路径换成 `~`，同前缀目录
    /// （例如 Home 后面还多一个 `-other` 段）不能被误伤。
    func testPathRedactorOnlyReplacesTheHomeBoundary() {
        let home = "/tmp/pi-web-desktop-tests-home"
        let redactor = DependencyPathRedactor(homeDirectory: home + "/")
        XCTAssertEqual(redactor.redact(home), "~")
        XCTAssertEqual(redactor.redact(home + "/tools/bin/pi"), "~/tools/bin/pi")
        XCTAssertEqual(redactor.redact(home + "-other/bin/pi"), home + "-other/bin/pi")
        XCTAssertEqual(redactor.redact("/opt/homebrew/bin/pi"), "/opt/homebrew/bin/pi")

        XCTAssertEqual(DependencyPathRedactor(homeDirectory: "/").redact("/opt/homebrew/bin/pi"), "/opt/homebrew/bin/pi")
        XCTAssertEqual(DependencyPathRedactor(homeDirectory: "").redact("/opt/homebrew/bin/pi"), "/opt/homebrew/bin/pi")
    }

    // MARK: - 启动门控快路径缓存（GitHub #169）

    /// 缓存里的样例报告：三条硬性前置都 `ok`，带一个 pi-web 组件与一条不阻塞的
    /// 端口提示（端口占用只提示、不影响 `canStartService`）。
    private func makeCacheReport() -> DependencyReport {
        var piWeb = finding(.piWeb, .ok)
        piWeb.path = "~/tools/bin/pi-web"
        piWeb.version = "1.2.3"
        piWeb.installSource = .npmGlobal
        piWeb.confidence = .verified
        piWeb.packageName = "@agegr/pi-web"
        piWeb.packageVersion = "1.2.3"
        var port = finding(.port, .occupied)
        port.detail = "端口已被占用，将复用已有服务"
        return DependencyReport(
            findings: [finding(.node, .ok), finding(.piCLI, .ok), piWeb, port],
            components: [
                ComponentInstallation(
                    kind: .piWeb,
                    packageName: "@agegr/pi-web",
                    version: "1.2.3",
                    executablePath: "~/tools/bin/pi-web",
                    resolvedPath: "~/tools/lib/node_modules/@agegr/pi-web/cli.js",
                    symlinkChain: ["~/tools/bin/pi-web"],
                    packageJSONPath: "~/tools/lib/node_modules/@agegr/pi-web/package.json",
                    source: .npmGlobal,
                    confidence: .verified,
                    evidence: ["npm 全局前缀命中"],
                    suggestedCommand: "npm install -g @agegr/pi-web@latest"
                )
            ]
        )
    }

    private func makeCacheFingerprint() -> DependencyGateFingerprint {
        DependencyGateFingerprint(
            appVersion: "0.1.0",
            piWebPath: "",
            workspacePath: "",
            hostname: "127.0.0.1",
            port: 30141,
            toolPathDigest: "3f2a1b"
        )
    }

    private func makeCacheStore(_ io: DependencyGateFakeCacheFileIO) -> DependencyGateCacheStore {
        DependencyGateCacheStore(
            url: URL(fileURLWithPath: "/tmp/pi-web-desktop-tests-home/support/dependency-gate-cache.json"),
            fileIO: io
        )
    }

    /// 缓存文件位置：支持目录下的独立 JSON（不写用户偏好设置、不进仓库）。
    func testDependencyGateCacheLivesUnderSupportDirectoryAsItsOwnFile() {
        let support = URL(fileURLWithPath: "/tmp/pi-web-desktop-tests-home/support")
        let configuration = AppConfiguration(
            supportURL: support,
            logsRootURL: URL(fileURLWithPath: "/tmp/pi-web-desktop-tests-home/logs"),
            defaults: UserDefaults(suiteName: "pi-web-desktop-cache-tests") ?? .standard
        )
        XCTAssertEqual(configuration.dependencyGateCacheURL.lastPathComponent, "dependency-gate-cache.json")
        XCTAssertEqual(
            configuration.dependencyGateCacheURL.deletingLastPathComponent().path,
            configuration.supportURL.path
        )
        XCTAssertEqual(
            configuration.dependencyGateCacheURL.path,
            configuration.supportURL.appendingPathComponent("dependency-gate-cache.json").path
        )
    }

    /// 写入 → 读取 → 判定全链路：报告与指纹逐字段还原，结论可以放行。
    func testDependencyGateCacheRoundTripsReportAndFingerprint() {
        let io = DependencyGateFakeCacheFileIO()
        let store = makeCacheStore(io)
        let fingerprint = makeCacheFingerprint()
        let writtenAt = Date(timeIntervalSince1970: 1_700_000_000)
        let cache = DependencyGateCache(report: makeCacheReport(), fingerprint: fingerprint, writtenAt: writtenAt)

        XCTAssertTrue(store.save(cache))
        XCTAssertEqual(io.writtenURLs, [store.url])
        let loaded = store.load()
        XCTAssertEqual(loaded, cache)

        let verdict = DependencyGateFastPath.decide(
            cache: loaded,
            fingerprint: fingerprint,
            now: writtenAt.addingTimeInterval(3_600)
        )
        guard case .valid(let report) = verdict else {
            return XCTFail("缓存应当可用，实际：\(verdict)")
        }
        XCTAssertEqual(report.findings, makeCacheReport().findings)
        XCTAssertEqual(report.components, makeCacheReport().components)
        XCTAssertTrue(report.canStartService)
        XCTAssertEqual(report.component(for: .piWeb)?.version, "1.2.3")
        XCTAssertEqual(report.component(for: .piWeb)?.suggestedCommand, "npm install -g @agegr/pi-web@latest")
    }

    /// 缓存缺失、内容不是 JSON、枚举取值无法识别：都按“没有可用缓存”处理。
    func testDependencyGateCacheTreatsMissingOrUnreadableDataAsNoCache() {
        let io = DependencyGateFakeCacheFileIO()
        let store = makeCacheStore(io)
        XCTAssertNil(store.load())
        XCTAssertEqual(
            DependencyGateFastPath.decide(cache: store.load(), fingerprint: makeCacheFingerprint(), now: Date()),
            .invalid(.missingOrUnreadable)
        )

        io.data = Data("{ not json".utf8)
        XCTAssertNil(store.load())

        io.data = nil
        let cache = DependencyGateCache(
            report: makeCacheReport(),
            fingerprint: makeCacheFingerprint(),
            writtenAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        XCTAssertTrue(store.save(cache))
        let text = String(data: io.data ?? Data(), encoding: .utf8) ?? ""
        XCTAssertTrue(text.contains("\"pi-web\""))
        // 把一个合法 JSON 里的枚举取值改成不认识的字符串：整份缓存不可用。
        io.data = Data(text.replacingOccurrences(of: "\"pi-web\"", with: "\"pi-web-legacy\"").utf8)
        XCTAssertNil(store.load())
    }

    /// schema 版本不符：即字段含义变化后的旧缓存。
    func testDependencyGateCacheRejectsSchemaMismatch() {
        var cache = DependencyGateCache(
            report: makeCacheReport(),
            fingerprint: makeCacheFingerprint(),
            writtenAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        XCTAssertEqual(cache.schemaVersion, DependencyGateCache.schemaVersion)
        cache.schemaVersion = DependencyGateCache.schemaVersion + 1
        XCTAssertEqual(
            DependencyGateFastPath.decide(
                cache: cache,
                fingerprint: makeCacheFingerprint(),
                now: Date(timeIntervalSince1970: 1_700_000_100)
            ),
            .invalid(.schemaMismatch)
        )
    }

    /// 有效期：默认 7 天，边界内可用、边界外失效；时钟回拨得到的“未来缓存”不可信。
    func testDependencyGateCacheHonoursItsAgeLimit() {
        let policy = DependencyGateCachePolicy()
        XCTAssertEqual(policy.maximumAge, 7 * 24 * 60 * 60)
        let writtenAt = Date(timeIntervalSince1970: 1_700_000_000)
        let fingerprint = makeCacheFingerprint()
        let cache = DependencyGateCache(report: makeCacheReport(), fingerprint: fingerprint, writtenAt: writtenAt)

        XCTAssertEqual(
            DependencyGateFastPath.decide(
                cache: cache,
                fingerprint: fingerprint,
                policy: policy,
                now: writtenAt.addingTimeInterval(policy.maximumAge - 1)
            ),
            .valid(makeCacheReport())
        )
        XCTAssertEqual(
            DependencyGateFastPath.decide(
                cache: cache,
                fingerprint: fingerprint,
                policy: policy,
                now: writtenAt.addingTimeInterval(policy.maximumAge + 1)
            ),
            .invalid(.expired)
        )
        XCTAssertEqual(
            DependencyGateFastPath.decide(
                cache: cache,
                fingerprint: fingerprint,
                policy: policy,
                now: writtenAt.addingTimeInterval(-1)
            ),
            .invalid(.expired)
        )
    }

    /// 指纹的每个字段变化都必须让缓存失效。
    func testDependencyGateCacheRejectsEveryFingerprintChange() {
        let fingerprint = makeCacheFingerprint()
        let writtenAt = Date(timeIntervalSince1970: 1_700_000_000)
        let cache = DependencyGateCache(report: makeCacheReport(), fingerprint: fingerprint, writtenAt: writtenAt)

        var variants: [(String, DependencyGateFingerprint)] = []
        var variant = fingerprint
        variant.appVersion = "0.2.0"
        variants.append(("应用版本", variant))
        variant = fingerprint
        variant.piWebPath = "~/other/pi-web"
        variants.append(("pi-web 路径", variant))
        variant = fingerprint
        variant.workspacePath = "~/code"
        variants.append(("工作目录", variant))
        variant = fingerprint
        variant.hostname = "127.0.0.2"
        variants.append(("服务地址", variant))
        variant = fingerprint
        variant.port = 30142
        variants.append(("服务端口", variant))
        variant = fingerprint
        variant.toolPathDigest = "9c8b7a"
        variants.append(("工具 PATH 摘要", variant))

        for (label, changed) in variants {
            XCTAssertEqual(
                DependencyGateFastPath.decide(
                    cache: cache,
                    fingerprint: changed,
                    now: writtenAt.addingTimeInterval(60)
                ),
                .invalid(.fingerprintChanged),
                "\(label)变化必须让缓存失效"
            )
        }
    }

    /// 上次结论为不可启动：即使指纹与时间都一致也必须重跑完整检查。
    func testDependencyGateCacheRejectsReportThatCouldNotStartService() {
        var report = makeCacheReport()
        report.findings = report.findings.map { item in
            item.kind == .piWeb ? finding(.piWeb, .missing) : item
        }
        let cache = DependencyGateCache(
            report: report,
            fingerprint: makeCacheFingerprint(),
            writtenAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        XCTAssertFalse(cache.canStartService)
        XCTAssertFalse(report.canStartService)
        XCTAssertEqual(
            DependencyGateFastPath.decide(
                cache: cache,
                fingerprint: makeCacheFingerprint(),
                now: Date(timeIntervalSince1970: 1_700_000_060)
            ),
            .invalid(.canStartServiceIsFalse)
        )
    }

    /// 缓存里的布尔值不能单独放行：结论以 findings 重新计算的 `canStartService`
    /// 为准（缓存文件被改坏时宁可多跑一次完整检查）。
    func testDependencyGateCacheRecomputesCanStartServiceFromFindings() {
        var cache = DependencyGateCache(
            report: makeCacheReport(),
            fingerprint: makeCacheFingerprint(),
            writtenAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        XCTAssertTrue(cache.canStartService)
        cache.findings = [finding(.node, .ok), finding(.piWeb, .missing)]
        XCTAssertEqual(
            DependencyGateFastPath.decide(
                cache: cache,
                fingerprint: makeCacheFingerprint(),
                now: Date(timeIntervalSince1970: 1_700_000_060)
            ),
            .invalid(.canStartServiceIsFalse)
        )
    }

    /// 写失败不抛错、不改变判定：只是下一次启动拿不到缓存。
    func testDependencyGateCacheWriteFailureIsReportedInsteadOfThrowing() {
        let io = DependencyGateFakeCacheFileIO()
        io.writeSucceeds = false
        let store = makeCacheStore(io)
        let cache = DependencyGateCache(
            report: makeCacheReport(),
            fingerprint: makeCacheFingerprint(),
            writtenAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        XCTAssertFalse(store.save(cache))
        XCTAssertNil(io.data)
        XCTAssertNil(store.load())
    }

    /// 摘要函数：同样输入同样结果，分隔符不同不能撞车。
    func testDependencyGateDigestSeparatesInputs() {
        XCTAssertEqual(DependencyGateCacheDigest.digest(["a", "b"]), DependencyGateCacheDigest.digest(["a", "b"]))
        XCTAssertNotEqual(DependencyGateCacheDigest.digest(["ab"]), DependencyGateCacheDigest.digest(["a", "b"]))
        XCTAssertNotEqual(DependencyGateCacheDigest.digest(["a"]), DependencyGateCacheDigest.digest(["A"]))
        // 原文不进摘要：摘要只比较是否变化，不含主目录路径原文。
        XCTAssertFalse(DependencyGateCacheDigest.digest(["/tmp/pi-web-desktop-tests-home"]).contains("tmp"))
    }

    /// 快路径之后的收敛判据（安全关键路径）：只有“路由仍是主窗口且复查同意可启动”
    /// 才不收敛，其余三种情况都必须收敛到真实状态。
    func testDependencyGateFastPathConvergenceCoversEveryOutcome() {
        XCTAssertFalse(
            DependencyGateFastPath.requiresConvergence(canStartService: true, routeIsMainWindow: true),
            "一致时不得重新路由（重跑路由会把服务页换回加载页并再启动一次服务）"
        )
        XCTAssertTrue(
            DependencyGateFastPath.requiresConvergence(canStartService: false, routeIsMainWindow: true),
            "复查发现不可启动时必须收敛"
        )
        XCTAssertTrue(
            DependencyGateFastPath.requiresConvergence(canStartService: true, routeIsMainWindow: false),
            "复查路由到诊断页时必须收敛"
        )
        XCTAssertTrue(
            DependencyGateFastPath.requiresConvergence(canStartService: false, routeIsMainWindow: false),
            "复查与路由都不成立时必须收敛"
        )
    }

    /// 接线断言（test target 装不了 AppDelegate，沿用仓库既有的源码级断言做法）：
    /// 启动路径走快路径入口、用户“重新检测”不走，复查不一致时复用可测的收敛判据
    /// 并停掉本应用托管的服务。
    func testAppWiringUsesStartupFastPathAndConvergesOnDivergence() throws {
        let diagnostics = SourceScan.codeText(of: try SourceScan.text(named: "AppDelegate+Diagnostics.swift"))
        XCTAssertTrue(diagnostics.contains("func runStartupDependencyCheck()"), "启动路径必须有快路径入口")
        XCTAssertTrue(diagnostics.contains("guard applyDependencyGateCacheFastPath()"), "快路径必须先于完整检查")
        XCTAssertTrue(
            diagnostics.contains("DependencyGateFastPath.requiresConvergence("),
            "复查收敛必须复用可测的纯函数判据"
        )
        XCTAssertTrue(diagnostics.contains("serviceManager.stopService()"), "复查不一致时必须停掉本应用托管的服务")
        XCTAssertTrue(diagnostics.contains("logDependencyGate("), "快路径命中/失效/复查不一致都必须写日志")
        // 快路径调用点只有声明与启动入口两处：用户“重新检测”的入口必须绕开快路径。
        XCTAssertEqual(
            diagnostics.components(separatedBy: "applyDependencyGateCacheFastPath()").count,
            3,
            "快路径只能被启动入口调用一次"
        )

        let packageUpdates = SourceScan.codeText(of: try SourceScan.text(named: "AppDelegate+PackageUpdates.swift"))
        XCTAssertTrue(packageUpdates.contains("runStartupDependencyCheck()"), "启动装配必须改走快路径入口")
        XCTAssertFalse(packageUpdates.contains("runDependencyCheck()"), "启动装配不得直接跑完整检查")
    }
}
