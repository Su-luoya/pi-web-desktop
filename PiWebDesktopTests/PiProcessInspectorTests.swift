import Foundation
import XCTest

// GitHub #21 的 unhosted 测试（运行进程保护部分）。
//
// 全部进程事实都是注入的假进程表（`PiProcessProbing.fixture`）：测试**绝不枚举
// 真实进程、绝不向任何进程发送信号**。接口 `PiProcessProbing` 也没有任何发送
// 信号、终止或修改进程的方法。磁盘探针同样是内存替身，因此测试不读真实 Home、
// 不写任何文件、不启动任何子进程。
//
// 唯一触碰真实磁盘的是最后一组“源码负向断言”：它只读取本仓库的两个源文件文本，
// 断言里面没有信号/终止 API 与 shell/sudo 路径。

final class PiProcessInspectorTests: XCTestCase {

    private let fixtureHome = "/tmp/pi-process-inspector-tests-home"
    private let referenceDate = Date(timeIntervalSince1970: 1_700_000_000)
    private let nodePath = "/opt/homebrew/Cellar/node@24/24.21.0/bin/node"

    // MARK: - 替身

    /// 内存磁盘探针：只有明确登记的路径才是“可执行文件”或“符号链接”。
    private final class MemoryFileSystemProbe: DependencyFileSystemProbing {
        var executables: Set<String> = []
        var symlinks: Set<String> = []
        private(set) var probedPaths: [String] = []
        let homeDirectory: String

        init(homeDirectory: String) {
            self.homeDirectory = homeDirectory
        }

        func isExecutableFile(atPath path: String) -> Bool {
            probedPaths.append(path)
            return executables.contains(path)
        }

        func symlinkDestination(atPath path: String) -> String? {
            probedPaths.append(path)
            return symlinks.contains(path) ? "/opt/homebrew/lib/node_modules/@agegr/pi-cli/cli.js" : nil
        }

        func resolvedPath(atPath path: String) -> String? {
            probedPaths.append(path)
            return executables.contains(path) ? path : nil
        }

        func readText(atPath path: String) -> String? { nil }
        func homeDirectoryPath() -> String { homeDirectory }
        func directoryExists(atPath path: String) -> Bool? { false }
        func isReadableDirectory(atPath path: String) -> Bool? { false }
    }

    private func makeInspector(
        snapshots: [PiProcessSnapshot],
        executables: Set<String> = [],
        symlinks: Set<String> = []
    ) -> (inspector: PiProcessInspector, fileSystem: MemoryFileSystemProbe) {
        let fileSystem = MemoryFileSystemProbe(homeDirectory: fixtureHome)
        fileSystem.executables = executables
        fileSystem.symlinks = symlinks
        let inspector = PiProcessInspector(
            probe: .fixture(snapshots),
            fileSystem: fileSystem,
            redactor: LogRedactor(homeDirectory: fixtureHome),
            formatStartTime: { _ in "夹具时间" }
        )
        return (inspector, fileSystem)
    }

    private func snapshot(
        pid: pid_t,
        parentPID: pid_t? = 1,
        startedAt: Date? = Date(timeIntervalSince1970: 1_700_000_000),
        imagePath: String? = nil,
        executableName: String? = nil,
        arguments: [String] = [],
        readFailure: PiProcessReadFailure? = nil
    ) -> PiProcessSnapshot {
        PiProcessSnapshot(
            pid: pid,
            parentPID: parentPID,
            startedAt: startedAt,
            imagePath: imagePath,
            executableName: executableName,
            arguments: arguments,
            readFailure: readFailure
        )
    }

    /// 与生产判定相同的假 Pi 进程（镜像路径就是 `pi`）。
    private func piSnapshot(pid: pid_t, parentPID: pid_t? = 1, path: String = "/opt/homebrew/bin/pi") -> PiProcessSnapshot {
        snapshot(pid: pid, parentPID: parentPID, imagePath: path, executableName: "pi", arguments: [path])
    }

    /// 与生产判定相同的假 JS 运行时进程（Pi CLI 的实际承载方式）。
    private func nodeSnapshot(
        pid: pid_t,
        arguments: [String],
        executableName: String = "node",
        imagePath: String? = nil
    ) -> PiProcessSnapshot {
        snapshot(
            pid: pid,
            imagePath: imagePath ?? nodePath,
            executableName: executableName,
            arguments: arguments
        )
    }

    // MARK: - 1. 没有 Pi 进程

    func testNoPiProcessesWhenOnlyUnrelatedProcessesRun() {
        let (inspector, _) = makeInspector(snapshots: [
            snapshot(pid: 100, imagePath: "/sbin/launchd", executableName: "launchd"),
            snapshot(pid: 200, imagePath: "/usr/bin/ssh", executableName: "ssh", arguments: ["/usr/bin/ssh", "host"]),
            nodeSnapshot(pid: 300, arguments: ["node", "/opt/homebrew/bin/pi-web", "--port", "30141"]),
            snapshot(pid: 400, imagePath: "/opt/homebrew/bin/pi-web", executableName: "pi-web"),
            snapshot(pid: 500, imagePath: "/usr/bin/vim", executableName: "vim", arguments: ["/usr/bin/vim", "/tmp/notes/pi"])
        ])
        XCTAssertEqual(inspector.inspect(), .noProcesses)
        XCTAssertTrue(inspector.inspect().allowsAutomaticUpdate)
    }

    /// `pi-web` / `pip` / `pi-helper` / 大小写不同的 `Pi` 都不是 Pi CLI：
    /// 判定只做精确的可执行名比较。
    func testSimilarNamesAreNotPiProcesses() {
        let names = ["pi-web", "pip", "pip3", "pi-helper", "pi-web-desktop", "Pi", "PI", "pi++"]
        let snapshots = names.enumerated().map { index, name in
            snapshot(pid: pid_t(1000 + index), imagePath: "/opt/homebrew/bin/\(name)", executableName: name)
        }
        let (inspector, _) = makeInspector(snapshots: snapshots)
        XCTAssertEqual(inspector.inspect(), .noProcesses)
        for name in names {
            let classified = inspector.classify(snapshot(pid: 1, imagePath: "/opt/homebrew/bin/\(name)", executableName: name))
            XCTAssertEqual(classified, .notPi, "\(name) 不应被判定为 Pi")
        }
    }

    /// 数据参数里的 `pi`（编辑器打开名为 pi 的文件、脚本参数）不是进程标题，
    /// 也不是绝对路径，因此不命中。
    func testArgumentsThatAreNotCommandTitlesOrPathsDoNotMatch() {
        let (inspector, fileSystem) = makeInspector(snapshots: [
            nodeSnapshot(pid: 100, arguments: ["node", "app.js", "pi"]),
            nodeSnapshot(pid: 200, arguments: ["node", "--title", "pi"]),
            snapshot(pid: 300, imagePath: "/usr/bin/vim", executableName: "vim", arguments: ["vim", "pi"])
        ])
        XCTAssertEqual(inspector.inspect(), .noProcesses)
        // 只有绝对路径参数才会触发可执行位探针：数据参数不读磁盘。
        XCTAssertTrue(fileSystem.probedPaths.isEmpty, "数据参数不应触发磁盘探针")
    }

    // MARK: - 2. 命中路径与证据

    func testImagePathExactNameMatchesPi() {
        let (inspector, _) = makeInspector(snapshots: [piSnapshot(pid: 4242, parentPID: 4000)])
        guard case .runningProcesses(let records) = inspector.inspect() else {
            return XCTFail("应当命中 1 个 Pi 进程")
        }
        XCTAssertEqual(records.count, 1)
        let record = records[0]
        XCTAssertEqual(record.pid, 4242)
        XCTAssertEqual(record.parentPID, 4000)
        XCTAssertEqual(record.matchSource, .imagePath)
        XCTAssertEqual(record.executablePath, "/opt/homebrew/bin/pi")
        XCTAssertEqual(record.startedAtText, "夹具时间")
        XCTAssertEqual(record.commandSummary, "/opt/homebrew/bin/pi")
        XCTAssertNil(record.scriptPath)
        XCTAssertFalse(inspector.inspect().allowsAutomaticUpdate)
    }

    /// 镜像路径不可得时，内核进程名（`pbi_comm`）恰好是 `pi` 也算命中。
    func testKernelProcessNameMatchesWhenImagePathIsUnavailable() {
        let (inspector, _) = makeInspector(snapshots: [
            snapshot(pid: 500, executableName: "pi", arguments: ["pi", "update", "--self"])
        ])
        guard case .runningProcesses(let records) = inspector.inspect() else {
            return XCTFail("内核进程名为 pi 时应命中")
        }
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].matchSource, .executableName)
        XCTAssertNil(records[0].executablePath)
    }

    /// Pi CLI 以 `#!/usr/bin/env node` 脚本形式发行：内核只看到 Node，判定证据
    /// 来自 argv 里的绝对脚本路径。
    func testInterpreterScriptPathMatchesPi() {
        let scriptPath = "/opt/homebrew/bin/pi"
        let (inspector, fileSystem) = makeInspector(
            snapshots: [nodeSnapshot(pid: 600, arguments: [nodePath, scriptPath, "--version"])],
            executables: [scriptPath]
        )
        guard case .runningProcesses(let records) = inspector.inspect() else {
            return XCTFail("解释器脚本路径为 pi 时应命中")
        }
        XCTAssertEqual(records[0].matchSource, .interpreterScript)
        XCTAssertEqual(records[0].scriptPath, scriptPath)
        XCTAssertEqual(records[0].executablePath, nodePath)
        XCTAssertEqual(Set(fileSystem.probedPaths), [scriptPath])
    }

    /// 符号链接（npm 全局安装的 `bin/pi` → 包内 `cli.js`）同样算命中。
    func testInterpreterScriptSymlinkMatchesPi() {
        let scriptPath = "/opt/homebrew/bin/pi"
        let (inspector, _) = makeInspector(
            snapshots: [nodeSnapshot(pid: 700, arguments: [nodePath, scriptPath])],
            symlinks: [scriptPath]
        )
        guard case .runningProcesses(let records) = inspector.inspect() else {
            return XCTFail("符号链接路径为 pi 时应命中")
        }
        XCTAssertEqual(records[0].matchSource, .interpreterScript)
    }

    /// Pi CLI 会把进程标题改写成 `pi`（原始参数被清零）：`argv[0] == "pi"`
    /// 也算命中，但普通 JS 应用的 `argv[0]` 是运行时自己的名字，不会命中。
    func testProcessTitleArgumentZeroMatchesBarePi() {
        let (inspector, _) = makeInspector(snapshots: [
            nodeSnapshot(pid: 800, arguments: ["pi"]),
            nodeSnapshot(pid: 900, arguments: ["node", "/opt/homebrew/bin/pi-web"])
        ])
        guard case .runningProcesses(let records) = inspector.inspect() else {
            return XCTFail("进程标题为 pi 时应命中")
        }
        XCTAssertEqual(records.map(\.pid), [800])
        XCTAssertEqual(records[0].matchSource, .processTitle)
        XCTAssertEqual(records[0].commandSummary, "pi")
    }

    // MARK: - 3. 不确定（全部按不安全处理）

    func testEnumerationFailureIsUnknown() {
        let inspector = PiProcessInspector(
            probe: PiProcessProbing(listProcessIdentifiers: { .failed }, snapshot: { _ in .processGone }),
            fileSystem: MemoryFileSystemProbe(homeDirectory: fixtureHome),
            redactor: LogRedactor(homeDirectory: fixtureHome),
            formatStartTime: { _ in "夹具时间" }
        )
        XCTAssertEqual(inspector.inspect(), .unknown(.enumerationFailed))
        XCTAssertFalse(inspector.inspect().allowsAutomaticUpdate)
    }

    /// 镜像路径与内核进程名都读不到（权限不足 / 受保护进程）→ 不确定。
    func testUnreadableIdentityIsUnknown() {
        let (inspector, _) = makeInspector(snapshots: [
            snapshot(pid: 1000, readFailure: .permissionDenied)
        ])
        XCTAssertEqual(inspector.inspect(), .unknown(.identityUnavailable(pid: 1000, failure: .permissionDenied)))
        XCTAssertFalse(inspector.inspect().allowsAutomaticUpdate)
        XCTAssertTrue(inspector.inspect().statusText.contains("无法确认 Pi 进程状态"))
    }

    /// JS 运行时进程的 argv 不可读：无法排除它是 Pi → 不确定。
    func testInterpreterWithoutArgumentsIsUnknown() {
        let (inspector, _) = makeInspector(snapshots: [nodeSnapshot(pid: 1100, arguments: [])])
        XCTAssertEqual(
            inspector.inspect(),
            .unknown(.argumentsUnavailable(pid: 1100, interpreter: "node"))
        )
    }

    /// argv 里出现名为 `pi` 的绝对路径，但它既不可执行也不是符号链接（普通文件）
    /// → 不确定，而不是“不是 Pi”。
    func testScriptPathThatIsNotExecutableIsUnknown() {
        let path = "/tmp/notes/pi"
        let (inspector, fileSystem) = makeInspector(snapshots: [nodeSnapshot(pid: 1200, arguments: [nodePath, path])])
        XCTAssertEqual(
            inspector.inspect(),
            .unknown(.scriptPathUnconfirmed(pid: 1200, path: path))
        )
        XCTAssertEqual(Set(fileSystem.probedPaths), [path])
        XCTAssertFalse(inspector.inspect().allowsAutomaticUpdate)
    }

    /// 已经确认存在 Pi 进程时，结论以“有进程在运行”优先：其它无法判定的进程不会
    /// 把结论降级成 `unknown`（两者都禁止自动更新）。
    func testConfirmedPiProcessTakesPrecedenceOverUnknownProcess() {
        let (inspector, _) = makeInspector(snapshots: [
            piSnapshot(pid: 1300),
            snapshot(pid: 1400, readFailure: .permissionDenied)
        ])
        guard case .runningProcesses(let records) = inspector.inspect() else {
            return XCTFail("确认有 Pi 进程时应返回 runningProcesses")
        }
        XCTAssertEqual(records.map(\.pid), [1300])
        XCTAssertFalse(inspector.inspect().allowsAutomaticUpdate)
    }

    /// 枚举与读取之间的进程退出是正常竞态，不是不确定。
    func testExitedProcessesAreSkipped() {
        let probe = PiProcessProbing(
            listProcessIdentifiers: { .pids([100, 200]) },
            snapshot: { pid in pid == 100 ? .processGone : .snapshot(PiProcessSnapshot(
                pid: 200,
                parentPID: 1,
                startedAt: self.referenceDate,
                imagePath: "/usr/bin/ssh",
                executableName: "ssh",
                arguments: [],
                readFailure: nil
            )) }
        )
        let inspector = PiProcessInspector(
            probe: probe,
            fileSystem: MemoryFileSystemProbe(homeDirectory: fixtureHome),
            redactor: LogRedactor(homeDirectory: fixtureHome),
            formatStartTime: { _ in "夹具时间" }
        )
        XCTAssertEqual(inspector.inspect(), .noProcesses)
    }

    /// `proc_listpids` 可能返回重复的 PID：同一次检查里只算一个。
    func testDuplicatePidsAreCountedOnce() {
        let probe = PiProcessProbing(
            listProcessIdentifiers: { .pids([100, 100, 100]) },
            snapshot: { pid in .snapshot(PiProcessSnapshot(
                pid: pid,
                parentPID: 1,
                startedAt: self.referenceDate,
                imagePath: "/opt/homebrew/bin/pi",
                executableName: "pi",
                arguments: [],
                readFailure: nil
            )) }
        )
        let inspector = PiProcessInspector(
            probe: probe,
            fileSystem: MemoryFileSystemProbe(homeDirectory: fixtureHome),
            redactor: LogRedactor(homeDirectory: fixtureHome),
            formatStartTime: { _ in "夹具时间" }
        )
        guard case .runningProcesses(let records) = inspector.inspect() else {
            return XCTFail("应当命中 1 个 Pi 进程")
        }
        XCTAssertEqual(records.count, 1)
    }

    // MARK: - 4. 脱敏（记录可以安全地写进日志与确认框）

    func testCommandSummaryRedactsHomeCredentialsAndEnvironment() {
        let secret = "sk-live-abcdefghijklmnop"
        let (inspector, _) = makeInspector(snapshots: [piSnapshot(pid: 1500)], executables: [])
        let snapshot = nodeSnapshot(pid: 1500, arguments: [
            "pi",
            "\(fixtureHome)/projects/pi/bin/pi",
            "--token=\(secret)",
            "--password",
            "hunter2hunter2",
            "https://api.example.test/v1/items?api_key=\(secret)",
            "PI_WEB_PASSWORD=\(secret)",
            "PATH=/usr/bin"
        ])
        let classified = inspector.classify(snapshot)
        guard case .pi(let record) = classified else {
            return XCTFail("应当命中（进程标题/脚本路径），实际是 \(classified)")
        }
        let summary = record.commandSummary
        XCTAssertFalse(summary.contains(secret), "命令摘要不得包含凭据原文")
        XCTAssertFalse(summary.contains("hunter2hunter2"), "命令摘要不得包含密码原文")
        XCTAssertFalse(summary.contains("PI_WEB_PASSWORD="), "环境变量片段不得进入命令摘要")
        XCTAssertFalse(summary.contains("PATH=/usr/bin"), "环境变量片段不得进入命令摘要")
        XCTAssertTrue(summary.contains("~/projects/pi/bin/pi"), "Home 前缀应替换为 ~，实际是 \(summary)")
        XCTAssertTrue(summary.contains(LogRedactor.marker), "凭据与查询串应替换为占位符，实际是 \(summary)")
    }

    /// Token 级凭据脱敏的边界：`键=值`、`键 值`、`键值`（无分隔符）三种形态都
    /// 不得让值进入摘要；URL 查询串交给 `LogRedactor` 整体处理。
    func testCommandSummaryMasksAllCredentialForms() {
        let secret = "s3cr3t-value"
        let redactor = LogRedactor(homeDirectory: fixtureHome)

        func summary(_ arguments: [String]) -> String {
            PiProcessInspector.commandSummary(arguments: arguments, redactor: redactor)
        }

        let equalsForm = summary(["pi", "--token=\(secret)", "--verbose"])
        XCTAssertEqual(equalsForm, "pi --token=<redacted> --verbose")

        let separatorForm = summary(["pi", "--password", secret, "--verbose"])
        XCTAssertFalse(separatorForm.contains(secret))
        XCTAssertTrue(separatorForm.contains("--password <redacted>"))

        // 开关后面又是开关：无法区分“值”与“下一个开关”，因此尾巴整段隐藏。
        let ambiguousForm = summary(["pi", "--password", "--verbose", secret])
        XCTAssertFalse(ambiguousForm.contains(secret))
        XCTAssertTrue(ambiguousForm.contains("--password <redacted>"))

        // 没有分隔符的粘连形态：整段换成占位符。
        let gluedForm = summary(["node", "--api-key\(secret)"])
        XCTAssertFalse(gluedForm.contains(secret))
        XCTAssertTrue(gluedForm.contains(LogRedactor.marker))

        // URL 查询串：即使同一行前面已经出现过凭据占位符，也不能被吞掉。
        let queryForm = summary(["pi", "--token=\(secret)", "https://x.test/a?page=2&limit=3"])
        XCTAssertFalse(queryForm.contains(secret))
        XCTAssertFalse(queryForm.contains("page=2"), "查询串应整体替换为占位符，实际是 \(queryForm)")
        XCTAssertTrue(queryForm.contains("https://x.test/a?<redacted>"))
    }

    func testCommandSummaryIsBounded() {
        let longArgument = String(repeating: "a", count: 400)
        let summary = PiProcessInspector.commandSummary(
            arguments: ["/opt/homebrew/bin/pi", longArgument],
            redactor: LogRedactor(homeDirectory: fixtureHome)
        )
        XCTAssertEqual(summary.count, PiProcessRecord.commandSummaryLimit + 1)
        XCTAssertTrue(summary.hasSuffix("…"))
    }

    func testExecutablePathAndDisplayLinesAreRedacted() {
        let path = "\(fixtureHome)/bin/pi"
        let (inspector, _) = makeInspector(snapshots: [piSnapshot(pid: 1600, path: path)])
        guard case .runningProcesses(let records) = inspector.inspect() else {
            return XCTFail("应当命中 1 个 Pi 进程")
        }
        let record = records[0]
        XCTAssertEqual(record.executablePath, "~/bin/pi")
        let text = record.displayLines.joined(separator: "\n")
        XCTAssertFalse(text.contains(fixtureHome), "展示文本不得包含未脱敏的 Home 前缀")
        XCTAssertTrue(text.contains("进程 PID：1600"))
        XCTAssertTrue(text.contains("父进程 PID：1"))
        XCTAssertTrue(text.contains("启动时间：夹具时间"))
        XCTAssertEqual(record.shortText, "PID 1600，父进程 1，启动于 夹具时间")
    }

    func testMissingStartTimeAndParentAreReportedAsUnknown() {
        let (inspector, _) = makeInspector(snapshots: [
            snapshot(pid: 1700, parentPID: nil, startedAt: nil, imagePath: "/opt/homebrew/bin/pi", executableName: "pi")
        ])
        guard case .runningProcesses(let records) = inspector.inspect() else {
            return XCTFail("应当命中 1 个 Pi 进程")
        }
        XCTAssertNil(records[0].startedAtText)
        let text = records[0].displayLines.joined(separator: "\n")
        XCTAssertTrue(text.contains("父进程 PID：未知"))
        XCTAssertTrue(text.contains("启动时间：未知"))
    }

    // MARK: - 5. 状态文案（诊断页/设置页）

    func testStatusTextDescribesEachState() {
        let records = [PiProcessRecord(
            pid: 1,
            parentPID: 1,
            startedAtText: "夹具时间",
            executablePath: "/opt/homebrew/bin/pi",
            scriptPath: nil,
            matchSource: .imagePath,
            commandSummary: "/opt/homebrew/bin/pi"
        )]
        XCTAssertEqual(PiProcessInspection.noProcesses.statusText, "没有检测到运行中的 Pi 进程")
        XCTAssertTrue(
            PiProcessInspection.runningProcesses(records).statusText.contains("检测到 1 个运行中的 Pi 进程")
        )
        XCTAssertTrue(
            PiProcessInspection.unknown(.enumerationFailed).statusText.contains("无法确认 Pi 进程状态")
        )
        XCTAssertTrue(
            PiProcessInspection.unknown(.enumerationFailed).deferralText.contains("按不安全处理")
        )
        XCTAssertTrue(
            PiProcessInspection.runningProcesses(records).deferralText.contains("本次不自动更新")
        )
    }

    // MARK: - 6. 源码负向断言（没有信号、没有 shell、没有 sudo）

    /// 仓库根目录（测试文件位于 `<root>/PiWebDesktopTests/`）。
    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func sourceText(relativePath: String) throws -> String {
        let url = repositoryRoot().appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// 去掉 `//` 行注释与行尾注释后的代码文本：注释里提到被禁止的 API 名字是
    /// 允许的（而且要鼓励），真正要断言的是代码里没有这些调用。
    private func codeText(of source: String) -> String {
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

    /// 这两个文件的代码里不得出现任何“向进程发送信号/终止进程”的调用，也不得
    /// 出现 shell、`sudo` 调用或硬编码的用户目录。
    func testPiUpdateSourcesContainNoSignalOrKillAPIs() throws {
        let forbidden = [
            "kill(", "killpg(", "raise(", "signal(", "SIGTERM", "SIGKILL", "SIGINT",
            ".terminate(", ".interrupt(", "posix_spawn", "/bin/sh", "/bin/bash",
            "Process.arguments", // 只用 plan.arguments，禁止拼接 shell 字符串
            "sudo ", "sudo\"", "sudo'", "sudo(", "[\"sudo\", \"-S\"]"
        ]
        for relativePath in [
            "Sources/PiProcessInspector.swift",
            "Sources/PiCLIUpdateAdapter.swift"
        ] {
            let code = codeText(of: try sourceText(relativePath: relativePath))
            for token in forbidden {
                XCTAssertFalse(
                    code.contains(token),
                    "\(relativePath) 的代码里不得出现 \(token)（信号/终止/shell/sudo 都在禁止之列）"
                )
            }
        }
    }

    /// 命令执行器只以参数数组执行计划里的 argv：参数固定为 `update --self`，
    /// 没有 shell 字符串，也没有额外参数。
    func testExecutableIsStartedWithArgumentArrayOnly() throws {
        let text = try sourceText(relativePath: "Sources/PiCLIUpdateAdapter.swift")
        XCTAssertTrue(text.contains("process.arguments = plan.arguments"))
        XCTAssertTrue(text.contains("static let requiredArguments = [\"update\", \"--self\"]"))
        XCTAssertFalse(text.contains("shellPath"))
    }
}
