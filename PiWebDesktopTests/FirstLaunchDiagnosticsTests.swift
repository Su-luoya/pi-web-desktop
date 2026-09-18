import Foundation
import XCTest

/// 首次启动诊断的 unhosted 测试：路由决策、pi-web 路径选择、默认端口、
/// Pi 配置目录存在性/可读性与服务控件可用性映射。
///
/// 所有命令都走假 runner，所有磁盘访问都走假探针，端口状态由假探针固定：
/// 测试不执行真实 `npm`/`pi`/`pi-web`，不访问网络、真实端口或 `~/.pi`，
/// 也不读取任何认证内容。假 Home 是 `/tmp` 下的固定值，用来验证脱敏。
private final class FirstLaunchFakeRunner: CommandRunning {
    var handler: ([String]) -> String? = { _ in nil }
    private(set) var invocations: [[String]] = []

    func run(_ arguments: [String]) -> String? {
        invocations.append(arguments)
        return handler(arguments)
    }

    /// 已执行命令的扁平文本，供“只读且不安装”的断言使用。
    var invocationLines: [String] {
        invocations.map { $0.joined(separator: " ") }
    }
}

/// 显式登记的假文件系统：只认识测试加进去的可执行文件、文本文件与目录。
private final class FirstLaunchFakeFileSystem: DependencyFileSystemProbing {
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
    /// `readText` 真正读过的路径；用于断言配置目录内容从未被读取。
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

/// 固定结果的假端口探针：不绑定任何真实端口。
private struct FirstLaunchFakePortProbe: DependencyPortProbing {
    var result: Bool?

    func isPortAvailable(host: String, port: Int) -> Bool? {
        result
    }
}

private struct FirstLaunchHarness {
    let runner = FirstLaunchFakeRunner()
    let fileSystem = FirstLaunchFakeFileSystem()
    var portResult: Bool? = true

    func checker(configuredPiWebPath: String = "") -> DependencyChecker {
        DependencyChecker(
            commandRunner: runner,
            fileSystem: fileSystem,
            system: DependencySystemProbe(
                architecture: { "arm64" },
                operatingSystemVersion: { OperatingSystemVersion(majorVersion: 14, minorVersion: 0, patchVersion: 0) }
            ),
            configuredPiWebPath: configuredPiWebPath,
            portProbe: FirstLaunchFakePortProbe(result: portResult)
        )
    }
}

private let firstLaunchPiWebResolvedPath = "/opt/homebrew/lib/node_modules/@agegr/pi-web/dist/cli.js"
private let firstLaunchPiWebPackageJSONPath = "/opt/homebrew/lib/node_modules/@agegr/pi-web/package.json"

/// 直接构造诊断项，用来验证“报告缺少必需条目”的边界情况。
private func firstLaunchFinding(
    _ kind: DependencyFinding.Kind,
    _ status: DependencyFinding.Status
) -> DependencyFinding {
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

/// Node.js 与 Pi CLI 总是存在；pi-web 可以只通过配置路径可见。
/// Pi 配置目录默认存在且可读。
private func makeFirstLaunchHarness(
    includePiWebInPath: Bool = true,
    includePiConfigurationDirectory: Bool = true,
    portAvailable: Bool? = true
) -> FirstLaunchHarness {
    var harness = FirstLaunchHarness()
    harness.portResult = portAvailable
    harness.fileSystem.executables = ["/opt/homebrew/bin/node", "/opt/homebrew/bin/pi"]
    if includePiWebInPath {
        harness.fileSystem.executables.insert("/opt/homebrew/bin/pi-web")
    }
    // 配置路径选中的可执行文件（测试只声明它可执行，不依赖真实磁盘）。
    harness.fileSystem.executables.insert("/tmp/pi-web")
    harness.fileSystem.resolvedPaths = ["/opt/homebrew/bin/pi-web": firstLaunchPiWebResolvedPath]
    harness.fileSystem.files = [
        firstLaunchPiWebPackageJSONPath: #"{"name":"@agegr/pi-web","version":"1.2.3"}"#
    ]
    if includePiConfigurationDirectory {
        harness.fileSystem.directories.insert(harness.fileSystem.home + "/.pi/agent")
    }
    harness.runner.handler = { arguments in
        switch arguments.joined(separator: " ") {
        case "/opt/homebrew/bin/node --version": return "v22.19.0\n"
        case "/opt/homebrew/bin/pi --version": return "9.9.9\n"
        case "/opt/homebrew/bin/pi-web --version": return "1.2.3\n"
        case "/tmp/pi-web --version": return "1.2.3\n"
        case "/usr/bin/env npm prefix -g": return "/opt/homebrew\n"
        default: return nil
        }
    }
    return harness
}

final class FirstLaunchDiagnosticsTests: XCTestCase {
    // MARK: - 首次启动路由

    func testCleanEnvironmentRoutesToTheDiagnosticsPageWithMissingItemsAndNextSteps() {
        // 干净环境（全部缺失）：假 runner 不返回任何命令输出，假文件系统为空。
        let harness = FirstLaunchHarness()
        harness.runner.handler = { _ in nil }
        let report = harness.checker().run()

        XCTAssertFalse(report.canStartService)
        XCTAssertEqual(report.blockingFindings.map(\.kind), [.node, .piCLI, .piWeb])
        XCTAssertEqual(
            DiagnosticsRouting.route(.init(report: report, hasCompletedFirstLaunchSetup: false)),
            .diagnostics([.unmetPrerequisites([.node, .piCLI, .piWeb])])
        )
        XCTAssertEqual(
            DiagnosticsRouting.route(.init(report: report, hasCompletedFirstLaunchSetup: true)),
            .diagnostics([.unmetPrerequisites([.node, .piCLI, .piWeb])])
        )

        let text = DependencyReportPresenter.statusPageText(for: report, setupIncomplete: true)
        for item in [
            "Node.js：缺失",
            "Pi CLI：缺失",
            "Pi Web：缺失",
            "默认端口：正常",
            "Pi 配置目录：缺失",
            "下一步：",
            "重新检测"
        ] {
            XCTAssertTrue(text.contains(item), "诊断状态页缺少 \(item)")
        }
        XCTAssertTrue(text.contains("不会退出"))
        // 只出现脱敏后的路径，不出现假 Home 绝对路径。
        XCTAssertFalse(text.contains(harness.fileSystem.home))
        XCTAssertTrue(text.contains("~/.pi/agent"))
    }

    func testMissingPrerequisitesNeverTerminateTheApp() {
        let harness = makeFirstLaunchHarness(includePiWebInPath: false)
        let report = harness.checker().run()

        XCTAssertFalse(report.canStartService)
        let route = DiagnosticsRouting.route(.init(report: report, hasCompletedFirstLaunchSetup: true))
        guard case .diagnostics(let reasons) = route else {
            return XCTFail("缺少 pi-web 时必须停留在诊断状态页")
        }
        XCTAssertEqual(reasons, [.unmetPrerequisites([.piWeb])])
        // 路由只有主窗口与诊断页两种取值：缺少 pi/pi-web 时没有退出应用的分支。
        XCTAssertNotEqual(route, .mainWindow)
        XCTAssertFalse(DiagnosticsRouting.completesFirstLaunchSetup(report: report))
    }

    func testReadyPrerequisitesWithoutFirstLaunchSetupStayOnTheDiagnosticsPage() {
        let harness = makeFirstLaunchHarness()
        let report = harness.checker().run()

        XCTAssertTrue(report.canStartService)
        XCTAssertTrue(report.blockingFindings.isEmpty)
        XCTAssertTrue(DiagnosticsRouting.completesFirstLaunchSetup(report: report))
        XCTAssertEqual(
            DiagnosticsRouting.route(.init(report: report, hasCompletedFirstLaunchSetup: false)),
            .diagnostics([.firstLaunchSetupIncomplete])
        )
        XCTAssertEqual(
            DiagnosticsRouting.route(.init(report: report, hasCompletedFirstLaunchSetup: true)),
            .mainWindow
        )
        let text = DependencyReportPresenter.statusPageText(for: report, setupIncomplete: true)
        XCTAssertTrue(text.contains("开始使用 Pi Web"))
        XCTAssertFalse(text.contains("缺少硬性前置"))
    }

    // MARK: - 选择 pi-web 路径与重新检测

    func testSelectingAnExecutablePiWebWritesTheConfigurationAndReleasesTheGate() {
        let harness = makeFirstLaunchHarness(includePiWebInPath: false)
        let before = harness.checker().run()
        XCTAssertEqual(before.blockingFindings.map(\.kind), [.piWeb])
        XCTAssertFalse(before.canStartService)

        let selection = PiWebPathSelection.apply(
            selectedPath: "/tmp/pi-web",
            configuration: .default,
            evidence: { path in
                PiWebIdentityEvidence(
                    isExecutable: path == "/tmp/pi-web",
                    version: path == "/tmp/pi-web" ? "1.2.3" : nil,
                    packageName: nil
                )
            }
        )
        XCTAssertNil(selection.error)
        XCTAssertEqual(selection.configuration.piWebPath, "/tmp/pi-web")

        // 重新检测：配置路径里的可执行 pi-web 被识别，状态更新且门控解除。
        let after = harness.checker(configuredPiWebPath: selection.configuration.piWebPath).run()
        XCTAssertEqual(after.finding(for: .piWeb)?.status, .ok)
        XCTAssertEqual(after.finding(for: .piWeb)?.path, "/tmp/pi-web")
        XCTAssertEqual(after.finding(for: .piWeb)?.version, "1.2.3")
        XCTAssertTrue(after.blockingFindings.isEmpty)
        XCTAssertTrue(after.canStartService)
        XCTAssertEqual(
            DiagnosticsRouting.route(.init(report: after, hasCompletedFirstLaunchSetup: true)),
            .mainWindow
        )
        XCTAssertTrue(ServiceControlState(gate: .ready).canStart)
        XCTAssertTrue(ServiceControlState(gate: .ready).canStop)
        XCTAssertTrue(ServiceControlState(gate: .ready).canRestart)

        // 重新检测时若身份证据不足（可执行但版本与包名都无法核对），仍不得放行启动。
        harness.fileSystem.executables.insert("/tmp/not-pi-web")
        let unverifiable = harness.checker(configuredPiWebPath: "/tmp/not-pi-web").run()
        XCTAssertEqual(unverifiable.finding(for: .piWeb)?.status, .unknown)
        XCTAssertFalse(unverifiable.canStartService)
        XCTAssertEqual(
            DiagnosticsRouting.route(.init(report: unverifiable, hasCompletedFirstLaunchSetup: true)),
            .diagnostics([.unmetPrerequisites([.piWeb])])
        )

        // 重新检测只使用只读命令，且从不安装、不联网。
        for line in harness.runner.invocationLines {
            XCTAssertFalse(line.contains("install"))
            XCTAssertFalse(line.contains("sudo"))
            XCTAssertFalse(line.lowercased().contains("http"))
        }
    }

    func testSelectingANonExecutableFileKeepsTheConfigurationAndReturnsAReadableError() {
        var configuration = ServiceConfiguration.default
        configuration.piWebPath = "/tmp/previous-choice"

        let result = PiWebPathSelection.apply(
            selectedPath: "/tmp/not-executable",
            configuration: configuration,
            evidence: { _ in PiWebIdentityEvidence(isExecutable: false, version: nil, packageName: nil) }
        )

        XCTAssertEqual(result.configuration, configuration, "选择不可执行文件时配置必须保持不变")
        XCTAssertEqual(result.configuration.piWebPath, "/tmp/previous-choice")
        let error = result.error
        XCTAssertNotNil(error)
        XCTAssertTrue(error?.contains("不可执行") == true)
        XCTAssertTrue(error?.contains("/tmp/not-executable") == true)
    }

    /// 只校验可执行位是不够的：`/bin/echo` 也可执行，但它不是 pi-web。
    func testSelectingAnExecutableThatIsNotPiWebIsRejectedWithoutTouchingTheConfiguration() {
        var configuration = ServiceConfiguration.default
        configuration.piWebPath = "/tmp/previous-choice"

        let result = PiWebPathSelection.apply(
            selectedPath: "/bin/echo",
            configuration: configuration,
            evidence: { _ in PiWebIdentityEvidence(isExecutable: true, version: nil, packageName: nil) }
        )

        XCTAssertEqual(result.configuration, configuration, "无法确认是 pi-web 时配置必须保持不变")
        XCTAssertEqual(result.configuration.piWebPath, "/tmp/previous-choice")
        let error = result.error
        XCTAssertNotNil(error)
        XCTAssertTrue(error?.contains("无法确认该文件是 pi-web") == true)
        XCTAssertTrue(error?.contains("/bin/echo") == true)
        XCTAssertTrue(error?.contains(DependencyChecker.piWebPackageName) == true)
    }

    /// 可执行且能解析出版本，或 package.json 名称就是 pi-web，都算身份成立。
    func testPiWebIdentityIsAcceptedByAVersionOrByThePackageName() {
        let byVersion = PiWebPathSelection.apply(
            selectedPath: "/tmp/pi-web",
            configuration: .default,
            evidence: { _ in PiWebIdentityEvidence(isExecutable: true, version: "7.7.7", packageName: nil) }
        )
        XCTAssertNil(byVersion.error)
        XCTAssertEqual(byVersion.configuration.piWebPath, "/tmp/pi-web")

        let byPackageName = PiWebPathSelection.apply(
            selectedPath: "/tmp/another-pi-web",
            configuration: .default,
            evidence: { _ in
                PiWebIdentityEvidence(
                    isExecutable: true,
                    version: nil,
                    packageName: DependencyChecker.piWebPackageName
                )
            }
        )
        XCTAssertNil(byPackageName.error)
        XCTAssertEqual(byPackageName.configuration.piWebPath, "/tmp/another-pi-web")
    }

    /// 报告缺少必需条目（含空报告）时不能因为 blockingFindings 为空就进主窗口。
    func testReportsMissingRequiredItemsOrWithNoFindingsStayOnTheDiagnosticsPage() {
        let empty = DependencyReport(findings: [])
        XCTAssertTrue(empty.blockingFindings.isEmpty)
        XCTAssertEqual(empty.unsatisfiedPrerequisiteKinds, [.node, .piCLI, .piWeb])
        XCTAssertFalse(empty.canStartService, "缺项报告不得放行启动")
        XCTAssertEqual(
            DiagnosticsRouting.route(.init(report: empty, hasCompletedFirstLaunchSetup: true)),
            .diagnostics([.unmetPrerequisites([.node, .piCLI, .piWeb])])
        )

        let missingPiWeb = DependencyReport(findings: [
            firstLaunchFinding(.node, .ok),
            firstLaunchFinding(.piCLI, .ok)
        ])
        XCTAssertTrue(missingPiWeb.blockingFindings.isEmpty)
        XCTAssertEqual(missingPiWeb.unsatisfiedPrerequisiteKinds, [.piWeb])
        XCTAssertFalse(missingPiWeb.canStartService)
        XCTAssertEqual(
            DiagnosticsRouting.route(.init(report: missingPiWeb, hasCompletedFirstLaunchSetup: true)),
            .diagnostics([.unmetPrerequisites([.piWeb])])
        )
    }

    /// 报告里有条目但版本无法解析（unknown）时也不得放行，路由必须停在诊断页。
    func testUnknownVersionsNeverReleaseTheGateOrReachTheMainWindow() {
        let report = DependencyReport(findings: [
            firstLaunchFinding(.system, .ok),
            firstLaunchFinding(.node, .ok),
            firstLaunchFinding(.piCLI, .ok),
            firstLaunchFinding(.piWeb, .unknown)
        ])
        XCTAssertEqual(report.blockingFindings.map(\.kind), [.piWeb])
        XCTAssertFalse(report.canStartService)
        XCTAssertEqual(
            DiagnosticsRouting.route(.init(report: report, hasCompletedFirstLaunchSetup: true)),
            .diagnostics([.unmetPrerequisites([.piWeb])])
        )
    }

    func testEmptyOrRelativeSelectionIsRejectedWithoutTouchingTheConfiguration() {
        let configuration = ServiceConfiguration.default
        let executable: (String) -> PiWebIdentityEvidence = { _ in
            PiWebIdentityEvidence(isExecutable: true, version: "1.2.3", packageName: nil)
        }

        let empty = PiWebPathSelection.apply(selectedPath: "   ", configuration: configuration, evidence: executable)
        XCTAssertEqual(empty.configuration, configuration)
        XCTAssertNotNil(empty.error)

        let relative = PiWebPathSelection.apply(selectedPath: "bin/pi-web", configuration: configuration, evidence: executable)
        XCTAssertEqual(relative.configuration, configuration)
        XCTAssertNotNil(relative.error)
    }

    // MARK: - 默认端口

    func testOccupiedPortIsReportedButDoesNotBlockStartup() {
        let harness = makeFirstLaunchHarness(portAvailable: false)
        let report = harness.checker().run()

        let port = report.finding(for: .port)
        XCTAssertEqual(port?.status, .occupied)
        XCTAssertEqual(port?.path, "\(ServiceConfiguration.defaultHostname):\(ServiceConfiguration.defaultPort)")
        XCTAssertEqual(port?.confidence, .verified)
        XCTAssertEqual(port?.installSource, .system)
        XCTAssertNil(port?.remediationID)
        XCTAssertEqual(DependencyReportPresenter.statusText(for: .occupied), "被占用")

        XCTAssertTrue(report.canStartService)
        XCTAssertFalse(report.blockingFindings.contains { $0.kind == .port })
        XCTAssertEqual(
            DiagnosticsRouting.route(.init(report: report, hasCompletedFirstLaunchSetup: true)),
            .mainWindow
        )
        let text = DependencyReportPresenter.statusPageText(for: report, setupIncomplete: false)
        XCTAssertTrue(text.contains("默认端口：被占用"))
    }

    func testUnknownPortResultIsReportedWithoutBlockingStartup() {
        let harness = makeFirstLaunchHarness(portAvailable: nil)
        let report = harness.checker().run()

        XCTAssertEqual(report.finding(for: .port)?.status, .unknown)
        XCTAssertEqual(report.finding(for: .port)?.confidence, .unknown)
        XCTAssertTrue(report.canStartService)
        XCTAssertFalse(report.blockingFindings.contains { $0.kind == .port })
    }

    // MARK: - Pi 配置目录

    func testMissingPiConfigurationIsReportedWithoutReadingAnyFile() {
        let harness = makeFirstLaunchHarness(includePiConfigurationDirectory: false)
        let report = harness.checker().run()
        let configurationDirectory = report.finding(for: .piConfigDirectory)

        XCTAssertEqual(configurationDirectory?.status, .missing)
        XCTAssertEqual(configurationDirectory?.path, "~/.pi/agent")
        XCTAssertEqual(configurationDirectory?.confidence, .verified)
        XCTAssertNil(configurationDirectory?.remediationID, "Pi 配置缺失只提示，不产生修复命令")
        XCTAssertFalse(report.blockingFindings.contains { $0.kind == .piConfigDirectory })
        XCTAssertTrue(report.canStartService)

        // 关键断言：目录内容从未被读取，只问过“存在吗/可读吗”。
        let configurationPath = harness.fileSystem.home + "/.pi/agent"
        XCTAssertFalse(harness.fileSystem.readPaths.contains { $0.hasPrefix(configurationPath) })

        let text = DependencyReportPresenter.statusPageText(for: report, setupIncomplete: false)
        XCTAssertTrue(text.contains("Pi 配置目录：缺失"))
        XCTAssertTrue(text.contains("~/.pi/agent"))
        XCTAssertFalse(text.contains(harness.fileSystem.home))
    }

    func testUnreadablePiConfigurationIsReportedWithoutReadingAnyFile() {
        let harness = makeFirstLaunchHarness(includePiConfigurationDirectory: false)
        harness.fileSystem.unreadableDirectories = [harness.fileSystem.home + "/.pi/agent"]
        let report = harness.checker().run()

        let configurationDirectory = report.finding(for: .piConfigDirectory)
        XCTAssertEqual(configurationDirectory?.status, .unreadable)
        XCTAssertEqual(configurationDirectory?.confidence, .verified)
        XCTAssertEqual(DependencyReportPresenter.statusText(for: .unreadable), "不可读")
        XCTAssertFalse(report.blockingFindings.contains { $0.kind == .piConfigDirectory })
        XCTAssertFalse(harness.fileSystem.readPaths.contains { $0.hasPrefix(harness.fileSystem.home + "/.pi") })
    }

    // MARK: - 诊断 smoke 夹具

    func testDiagnosticsSmokeFixtureIsDeterministicAndTouchesNoRealProbe() {
        let first = DiagnosticsSmokeFixture.report()
        let second = DiagnosticsSmokeFixture.report()

        XCTAssertEqual(first, second, "诊断 smoke 报告必须确定性")
        XCTAssertEqual(
            first.findings.map(\.kind),
            [.system, .node, .piCLI, .piWeb, .port, .piConfigDirectory]
        )
        // 前置固定判定为缺失：smoke 不依赖机器上真实安装了什么。
        XCTAssertEqual(first.blockingFindings.map(\.kind), [.node, .piCLI, .piWeb])
        XCTAssertFalse(first.canStartService)
        XCTAssertEqual(
            DiagnosticsRouting.route(.init(report: first, hasCompletedFirstLaunchSetup: false)),
            .diagnostics([.unmetPrerequisites([.node, .piCLI, .piWeb])])
        )
        // 端口探针不绑定真实端口，Pi 配置目录只报告“缺失”。
        XCTAssertEqual(first.finding(for: .port)?.status, .ok)
        XCTAssertEqual(first.finding(for: .piConfigDirectory)?.status, .missing)
        let text = DependencyReportPresenter.statusPageText(for: first, setupIncomplete: true)
        XCTAssertTrue(text.contains("~/.pi/agent"))
        XCTAssertFalse(text.contains("/smoke"))
    }

    // MARK: - 状态页字段完整性

    /// 每项都必须输出路径/版本/来源/可信度五个字段，缺失时用占位符，
    /// 不得因为值为 nil 而省略整行（GitHub #7 复审）。
    func testStatusPagePrintsEveryItemWithPathVersionSourceAndConfidence() {
        let harness = makeFirstLaunchHarness(includePiWebInPath: false, includePiConfigurationDirectory: false)
        let report = harness.checker().run()
        let text = DependencyReportPresenter.statusPageText(for: report, setupIncomplete: true)

        for row in DependencyReportPresenter.rows(for: report) {
            XCTAssertTrue(text.contains("· \(row.title)："), "状态页缺少 \(row.title) 行")
        }
        // 缺失的可执行文件：完整一行，路径写“未找到”、版本写“未知”。
        XCTAssertTrue(
            text.contains("· Pi Web：缺失  路径：未找到  版本：未知  来源：未知  可信度：未知"),
            "缺失项也必须输出全部字段"
        )
        // 端口/配置目录没有版本概念，仍要输出占位符与来源、可信度。
        XCTAssertTrue(text.contains("来源：系统"))
        XCTAssertTrue(text.contains("可信度：已验证"))
        XCTAssertTrue(text.contains("来源：未知"))
        XCTAssertTrue(text.contains("可信度：未知"))
        XCTAssertTrue(text.contains("· 默认端口：正常  路径：\(ServiceConfiguration.defaultHostname):\(ServiceConfiguration.defaultPort)"))
        XCTAssertTrue(text.contains("· Pi 配置目录：缺失  路径：~/.pi/agent  版本：—"))
        XCTAssertFalse(text.contains(harness.fileSystem.home))
    }

    // MARK: - 首次设置完成后的启动语义

    /// 首次设置刚完成时必须显式启动服务；正常启动仍尊重 autoStart（GitHub #7 复审）。
    func testFirstLaunchCompletionForcesAnExplicitStartWhileANormalLaunchRespectsAutoStart() {
        XCTAssertEqual(ServiceLaunchIntent.intent(firstLaunchSetupJustCompleted: false), .respectAutoStart)
        XCTAssertEqual(ServiceLaunchIntent.intent(firstLaunchSetupJustCompleted: true), .startExplicitly)
        XCTAssertFalse(ServiceLaunchIntent.respectAutoStart.forcesStart)
        XCTAssertTrue(ServiceLaunchIntent.startExplicitly.forcesStart)
    }

    // MARK: - 控件可用性映射

    func testServiceControlsAreDisabledUnlessTheGateIsReady() {
        XCTAssertEqual(
            ServiceControlState(gate: .blocked),
            ServiceControlState(canStart: false, canStop: false, canRestart: false)
        )
        XCTAssertEqual(
            ServiceControlState(gate: .checking),
            ServiceControlState(canStart: false, canStop: false, canRestart: false)
        )
        XCTAssertEqual(
            ServiceControlState(gate: .ready),
            ServiceControlState(canStart: true, canStop: true, canRestart: true)
        )
    }

    // MARK: - 诊断行

    func testReportRowsFollowTheFirstLaunchOrder() {
        let report = makeFirstLaunchHarness().checker().run()

        XCTAssertEqual(
            report.findings.map(\.kind),
            [.system, .node, .piCLI, .piWeb, .port, .piConfigDirectory]
        )
        let rows = DependencyReportPresenter.rows(for: report)
        XCTAssertEqual(
            rows.map(\.title),
            ["系统", "Node.js", "Pi CLI", "Pi Web", "默认端口", "Pi 配置目录"]
        )
        XCTAssertEqual(rows[4].path, "\(ServiceConfiguration.defaultHostname):\(ServiceConfiguration.defaultPort)")
        XCTAssertEqual(rows[4].version, "—")
        XCTAssertEqual(rows[4].source, "系统")
        XCTAssertEqual(rows[5].path, "~/.pi/agent")
        XCTAssertEqual(rows[5].version, "—")
        XCTAssertEqual(rows[5].source, "本地路径")
    }
}
