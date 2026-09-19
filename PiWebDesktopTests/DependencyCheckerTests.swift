import Foundation
import XCTest

/// 依赖诊断的 unhosted 测试。
///
/// 所有命令都走假 runner，所有磁盘访问都走假探针，架构与系统版本固定注入：
/// 测试不执行真实 `npm`/`pi`/`pi-web`，不访问网络、`~/.pi`、真实用户 Home 或
/// 真实 npm 前缀。假 Home 是 `/tmp` 下的固定值，用来验证脱敏。
private final class DependencyFakeRunner: CommandRunning {
    var handler: ([String]) -> String? = { _ in nil }
    private(set) var invocations: [[String]] = []

    func run(_ arguments: [String]) -> String? {
        invocations.append(arguments)
        return handler(arguments)
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
        "/opt/homebrew/bin/pi-web"
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

        XCTAssertEqual(
            Set(harness.runner.invocationLines),
            Set([
                "/usr/bin/env npm prefix -g",
                "/opt/homebrew/bin/node --version",
                "/opt/homebrew/bin/pi --version",
                "/opt/homebrew/bin/pi-web --version"
            ])
        )
        for line in harness.runner.invocationLines {
            XCTAssertFalse(line.contains("sudo"))
            XCTAssertFalse(line.contains("install"))
            XCTAssertFalse(line.lowercased().contains("http"))
            XCTAssertFalse(line.contains("curl"))
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
}
