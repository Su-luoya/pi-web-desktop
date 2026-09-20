import Foundation
import XCTest

// GitHub #21 的 unhosted 测试（运行进程保护部分）；GitHub #61 在此补充候选筛选
// （argv 读取面）与遮罩边界的断言。
//
// 全部进程事实都是注入的假进程表（`PiProcessProbing.fixture`）：测试**绝不枚举
// 真实进程、绝不向任何进程发送信号**。接口 `PiProcessProbing` 也没有任何发送
// 信号、终止或修改进程的方法。磁盘探针同样是内存替身，因此测试不读真实 Home、
// 不写任何文件、不启动任何子进程。
//
// “哪个 PID 被读过 argv”同样靠注入：`PiProcessProbing.arguments` 是独立闭包，
// `makeRecordingInspector` 用它记录每次读取，所以“非候选进程不触发 argv 读取”
// 是一个可断言的事实，不需要任何真实进程。
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
        /// 符号链接能解析到的真实路径；不在表里的符号链接视为断裂（无法解析）。
        var resolvedPaths: [String: String] = [:]
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
            if let resolved = resolvedPaths[path] { return resolved }
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
        symlinks: Set<String> = [],
        resolvedPaths: [String: String] = [:]
    ) -> (inspector: PiProcessInspector, fileSystem: MemoryFileSystemProbe) {
        let fileSystem = MemoryFileSystemProbe(homeDirectory: fixtureHome)
        fileSystem.executables = executables
        fileSystem.symlinks = symlinks
        fileSystem.resolvedPaths = resolvedPaths
        let inspector = PiProcessInspector(
            probe: .fixture(snapshots),
            fileSystem: fileSystem,
            redactor: LogRedactor(homeDirectory: fixtureHome),
            formatStartTime: { _ in "夹具时间" }
        )
        return (inspector, fileSystem)
    }

    /// 记录 argv 读取的假探针：`arguments` 每被调用一次就记下一个 PID。
    private final class ArgumentReadRecorder {
        private(set) var pids: [pid_t] = []

        func record(_ pid: pid_t) {
            pids.append(pid)
        }
    }

    /// 与 `makeInspector` 相同，但 `arguments` 经由记录器委托给固定进程表，因此
    /// 测试可以断言“哪些 PID 被读过 argv”。判定逻辑与生产实现一致（同一份
    /// `PiProcessInspector.inspect`），只是探针换成了可观测的替身。
    private func makeRecordingInspector(
        snapshots: [PiProcessSnapshot],
        executables: Set<String> = [],
        symlinks: Set<String> = []
    ) -> (inspector: PiProcessInspector, fileSystem: MemoryFileSystemProbe, argvReads: () -> [pid_t]) {
        let fileSystem = MemoryFileSystemProbe(homeDirectory: fixtureHome)
        fileSystem.executables = executables
        fileSystem.symlinks = symlinks
        let fixture = PiProcessProbing.fixture(snapshots)
        let recorder = ArgumentReadRecorder()
        let probe = PiProcessProbing(
            listProcessIdentifiers: fixture.listProcessIdentifiers,
            snapshot: fixture.snapshot,
            arguments: { pid in
                recorder.record(pid)
                return fixture.arguments(pid)
            }
        )
        let inspector = PiProcessInspector(
            probe: probe,
            fileSystem: fileSystem,
            redactor: LogRedactor(homeDirectory: fixtureHome),
            formatStartTime: { _ in "夹具时间" }
        )
        return (inspector, fileSystem, { recorder.pids })
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

    // MARK: - 2. 候选筛选（GitHub #61：只对候选进程读 argv）

    /// 非候选进程（系统守护进程、编译器、编辑器、ssh 与 `pi-web` / `pip` /
    /// `pi-helper`）不触发 argv 读取：读取次数为 0，结论仍是“没有 Pi 进程”。
    func testNonCandidateProcessesDoNotReadArguments() {
        let (inspector, _, argvReads) = makeRecordingInspector(snapshots: [
            snapshot(pid: 100, imagePath: "/sbin/launchd", executableName: "launchd", arguments: ["/sbin/launchd"]),
            snapshot(pid: 200, imagePath: "/usr/bin/cc", executableName: "cc", arguments: ["cc", "-c", "main.c"]),
            snapshot(pid: 300, imagePath: "/usr/bin/vim", executableName: "vim", arguments: ["vim", "/tmp/notes/pi"]),
            snapshot(pid: 400, imagePath: "/usr/bin/ssh", executableName: "ssh", arguments: ["ssh", "host"]),
            snapshot(pid: 500, imagePath: "/opt/homebrew/bin/pi-web", executableName: "pi-web", arguments: ["pi-web"]),
            snapshot(pid: 600, imagePath: "/opt/homebrew/bin/pip", executableName: "pip", arguments: ["pip", "list"]),
            snapshot(pid: 700, imagePath: "/opt/homebrew/bin/pi-helper", executableName: "pi-helper", arguments: ["pi-helper"])
        ])
        XCTAssertEqual(inspector.inspect(), .noProcesses)
        XCTAssertEqual(argvReads(), [], "非候选进程不得触发 argv 读取")
    }

    /// 候选进程（`pi`、JS 运行时、内核进程名是 `pi`）正常读取 argv，每个候选 PID
    /// 恰好读一次；记录仍带命令摘要，判定依据与既有语义一致。
    func testCandidateProcessesReadArgumentsOnceAndKeepRecords() {
        let scriptPath = "/opt/homebrew/lib/node_modules/@agegr/pi-cli/bin/pi"
        let (inspector, _, argvReads) = makeRecordingInspector(
            snapshots: [
                piSnapshot(pid: 100, parentPID: 1),
                nodeSnapshot(pid: 200, arguments: [nodePath, scriptPath, "--verbose"]),
                snapshot(pid: 300, imagePath: nil, executableName: "pi", arguments: ["pi", "update", "--self"])
            ],
            executables: [scriptPath]
        )
        guard case .runningProcesses(let records) = inspector.inspect() else {
            return XCTFail("候选进程应当产出记录")
        }
        XCTAssertEqual(records.map(\.pid), [100, 200, 300])
        XCTAssertEqual(argvReads().sorted(), [100, 200, 300], "每个候选进程恰好读一次 argv")
        // 既有信息不回退：父进程、启动时间、解析后的镜像路径与命令摘要都在。
        XCTAssertEqual(records[0].parentPID, 1)
        XCTAssertEqual(records[0].startedAtText, "夹具时间")
        XCTAssertEqual(records[0].executablePath, "/opt/homebrew/bin/pi")
        XCTAssertEqual(records[0].commandSummary, "/opt/homebrew/bin/pi")
        XCTAssertEqual(records[1].commandSummary, "\(nodePath) \(scriptPath) --verbose")
        XCTAssertEqual(records[2].commandSummary, "pi update --self")
        XCTAssertEqual(records.map(\.matchSource), [.imagePath, .interpreterScript, .executableName])
    }

    /// 真实 Pi 布局都必须被候选判定覆盖：`pi` 二进制、内核进程名、npm/pnpm 全局
    /// 前缀下由 `node` 承载的入口脚本、`#!/usr/bin/env node` 形态。同时确认误报
    /// 防护对象（`pi-web` / `pip` / `pi-helper`）与普通系统进程不是候选。
    func testCandidateCoversRealPiLayouts() {
        let candidates: [(imagePath: String?, executableName: String?)] = [
            ("/opt/homebrew/bin/pi", "pi"),
            (nil, "pi"),
            ("/opt/homebrew/Cellar/node@24/24.21.0/bin/node", "node"),
            (nil, "node"),
            ("/opt/homebrew/bin/npm", "npm"),
            ("/opt/homebrew/bin/node24", "node24"),
            ("/usr/local/bin/bun", "bun")
        ]
        for layout in candidates {
            XCTAssertTrue(
                PiProcessInspector.isCandidate(imagePath: layout.imagePath, executableName: layout.executableName),
                "\(layout.imagePath ?? "nil") / \(layout.executableName ?? "nil") 必须是候选进程"
            )
        }

        let nonCandidates: [(imagePath: String?, executableName: String?)] = [
            ("/opt/homebrew/bin/pi-web", "pi-web"),
            ("/opt/homebrew/bin/pip", "pip"),
            ("/opt/homebrew/bin/pi-helper", "pi-helper"),
            ("/usr/bin/cc", "cc"),
            ("/usr/bin/vim", "vim"),
            ("/System/Library/CoreServices/launchd", "launchd"),
            ("/usr/bin/ssh", nil),
            (nil, nil)
        ]
        for layout in nonCandidates {
            XCTAssertFalse(
                PiProcessInspector.isCandidate(imagePath: layout.imagePath, executableName: layout.executableName),
                "\(layout.imagePath ?? "nil") / \(layout.executableName ?? "nil") 不应是候选进程"
            )
        }
    }

    /// 筛选只是读取优化：非候选进程的结论不依赖 argv（配上任意 argv 也不变），
    /// 而且两个可执行身份都读不到时仍然是 `unknown`（“不确定按不安全处理”
    /// 不因为不读 argv 而降级）。
    func testNonCandidateClassificationDoesNotDependOnArguments() {
        let (inspector, _) = makeInspector(snapshots: [])
        let argv = ["pi", "/opt/homebrew/bin/pi", "--token=<x>"]
        let cases: [(identity: PiProcessSnapshot, expected: PiProcessClassification)] = [
            (snapshot(pid: 100, imagePath: "/sbin/launchd", executableName: "launchd"), .notPi),
            (snapshot(pid: 200, imagePath: "/usr/bin/cc", executableName: "cc"), .notPi),
            (snapshot(pid: 300, imagePath: "/usr/bin/vim", executableName: "vim"), .notPi),
            (snapshot(pid: 400, imagePath: "/usr/bin/python3", executableName: "python3"), .notPi),
            (snapshot(pid: 500, imagePath: "/opt/homebrew/bin/pi-web", executableName: "pi-web"), .notPi),
            (
                snapshot(pid: 600, readFailure: .permissionDenied),
                .unknown(.identityUnavailable(pid: 600, failure: .permissionDenied))
            )
        ]
        for (identity, expected) in cases {
            XCTAssertFalse(PiProcessInspector.isCandidate(identity), "PID \(identity.pid) 不应是候选进程")
            XCTAssertEqual(inspector.classify(identity), expected)
            var withArguments = identity
            withArguments.arguments = argv
            XCTAssertEqual(
                inspector.classify(withArguments),
                expected,
                "PID \(identity.pid) 是非候选，结论不得因为 argv 改变"
            )
        }
    }

    // MARK: - 3. 命中路径与证据

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

    /// 符号链接（npm 全局安装的 `bin/pi` → 包内 `cli.js`）能解析到目标时同样算
    /// 命中；断裂的符号链接见下面的 `unknown` 用例。
    func testInterpreterScriptSymlinkMatchesPi() {
        let scriptPath = "/opt/homebrew/bin/pi"
        let resolvedPath = "/opt/homebrew/lib/node_modules/@agegr/pi-cli/cli.js"
        let (inspector, _) = makeInspector(
            snapshots: [nodeSnapshot(pid: 700, arguments: [nodePath, scriptPath])],
            symlinks: [scriptPath],
            resolvedPaths: [scriptPath: resolvedPath]
        )
        guard case .runningProcesses(let records) = inspector.inspect() else {
            return XCTFail("可解析的符号链接路径为 pi 时应命中")
        }
        XCTAssertEqual(records[0].matchSource, .interpreterScript)
    }

    /// 相对路径的解释器脚本（`./pi`、`../bin/pi`、解释器脚本位置的裸 `pi`）一律按
    /// 不确定处理（L2）：无法确认它相对哪个工作目录解析，判 `notPi` 是漏判方向。
    /// 相对路径也不读磁盘探针。
    func testRelativeInterpreterScriptPathsAreUnknown() {
        for relativePath in ["./pi", "../bin/pi", "pi"] {
            let (inspector, fileSystem) = makeInspector(snapshots: [
                nodeSnapshot(pid: 1300, arguments: [nodePath, relativePath])
            ])
            XCTAssertEqual(
                inspector.inspect(),
                .unknown(.scriptPathUnconfirmed(pid: 1300, path: relativePath)),
                "\(relativePath) 应判 unknown（不确定即不安全），而不是 notPi"
            )
            XCTAssertTrue(fileSystem.probedPaths.isEmpty, "相对路径不应触发磁盘探针")
        }
    }

    /// 符号链接断裂（目标是文件但无法解析、目标不存在）同样是 `unknown`；
    /// 它既不能证明脚本存在，也不能证明脚本不存在。
    func testBrokenInterpreterScriptSymlinkIsUnknown() {
        let path = "/opt/homebrew/bin/pi"
        let (inspector, fileSystem) = makeInspector(
            snapshots: [nodeSnapshot(pid: 1400, arguments: [nodePath, path])],
            symlinks: [path]
        )
        XCTAssertEqual(inspector.inspect(), .unknown(.scriptPathUnconfirmed(pid: 1400, path: path)))
        XCTAssertEqual(Set(fileSystem.probedPaths), [path])
        XCTAssertFalse(inspector.inspect().allowsAutomaticUpdate)
    }

    /// 数据参数位置的裸 `pi`（`node app.js pi`、`node --title pi`）仍不算脚本路径，
    /// 也不读磁盘；只有解释器的脚本位置（index 1）的裸名才算候选。
    func testBarePiInDataArgumentPositionStaysNotPi() {
        let (inspector, fileSystem) = makeInspector(snapshots: [
            nodeSnapshot(pid: 1500, arguments: ["node", "app.js", "pi"]),
            nodeSnapshot(pid: 1501, arguments: ["node", "--title", "pi"])
        ])
        XCTAssertEqual(inspector.inspect(), .noProcesses)
        XCTAssertTrue(fileSystem.probedPaths.isEmpty)
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

    // MARK: - 4. 不确定（全部按不安全处理）

    func testEnumerationFailureIsUnknown() {
        let inspector = PiProcessInspector(
            probe: PiProcessProbing(
                listProcessIdentifiers: { .failed },
                snapshot: { _ in .processGone },
                arguments: { _ in [] }
            ),
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
            )) },
            arguments: { _ in [] }
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
            )) },
            arguments: { _ in ["/opt/homebrew/bin/pi"] }
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

    // MARK: - 5. 脱敏（记录可以安全地写进日志与确认框）

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

    /// 非键值形状的遮罩（GitHub #61）：`-p<值>`（短开关紧跟值）、`--token=<值>`、
    /// 位置参数形式的已知凭据前缀、长 base64/十六进制位置参数、URL 查询串里的
    /// `?token=`。逐条断言，避免“整段字符串里没找到秘密就算过”。
    func testCommandSummaryMasksNonKeyValueSecretShapes() {
        let redactor = LogRedactor(homeDirectory: fixtureHome)
        let secret = "s3cr3t-" + "value"

        func summary(_ arguments: [String]) -> String {
            PiProcessInspector.commandSummary(arguments: arguments, redactor: redactor)
        }

        // 1. `--token=<值>`：键值形态，保留键。
        XCTAssertEqual(summary(["pi", "--token=\(secret)"]), "pi --token=<redacted>")

        // 2. `-p<值>`：短开关紧跟值，保留开关本身。
        XCTAssertEqual(summary(["pi", "-p\(secret)"]), "pi -p<redacted>")
        XCTAssertEqual(summary(["pi", "-t\(secret)"]), "pi -t<redacted>")
        XCTAssertEqual(summary(["pi", "-s\(secret)"]), "pi -s<redacted>")

        // 3. 位置参数形式的已知凭据前缀：整段换成占位符（前缀也不保留）。
        for prefix in ["sk-", "ghp_", "xoxb-"] {
            let token = prefix + secret
            let maskedSummary = summary(["pi", token])
            XCTAssertEqual(maskedSummary, "pi <redacted>", "\(prefix) 开头的 token 必须整段遮罩")
            XCTAssertFalse(maskedSummary.contains(secret))
            XCTAssertFalse(maskedSummary.contains(prefix), "前缀本身也不保留（整段替换）")
        }

        // 4. 长 base64/十六进制位置参数（长度达到阈值）。
        let hexToken = String(repeating: "a1b2c3d4", count: 8)
        let base64Token = String(repeating: "Ab3_-", count: 9)
        XCTAssertEqual(summary(["pi", hexToken]), "pi <redacted>")
        XCTAssertEqual(summary(["pi", base64Token]), "pi <redacted>")

        // 5. URL 查询串里的 `?token=`：交给 `LogRedactor` 整体替换。
        let url = "https://api.example.test/callback?token=\(secret)"
        let urlSummary = summary(["pi", url])
        XCTAssertFalse(urlSummary.contains(secret))
        XCTAssertTrue(urlSummary.contains("callback?<redacted>"), "查询串应整体替换，实际是 \(urlSummary)")

        // 6. 组合：遮罩后整段摘要里不再出现秘密原文，且五处凭据各留一个占位符。
        let combined = summary([
            "pi",
            "--token=\(secret)",
            "-p\(secret)",
            "sk-\(secret)",
            hexToken,
            url
        ])
        XCTAssertFalse(combined.contains(secret))
        XCTAssertEqual(combined.components(separatedBy: LogRedactor.marker).count - 1, 5)
    }

    /// M6：短开关的大小写与三种取值形态逐条断言（`-p 值`、`-p=值`、`-p值`），
    /// 含多字母开关 `-pw` 与长开关的 `=` 形态；每一行都是精确相等断言，
    /// 避免“整段字符串里没找到秘密就算过”。
    func testCommandSummaryMasksCaseInsensitiveShortAndLongSwitchForms() {
        let redactor = LogRedactor(homeDirectory: fixtureHome)
        let secret = "S3CRET-VALUE-123"

        func summary(_ arguments: [String]) -> String {
            PiProcessInspector.commandSummary(arguments: arguments, redactor: redactor)
        }

        // 1. 短开关 + 等号（原两层脱敏都漏掉的形态）：大小写都要遮值、保留开关名。
        XCTAssertEqual(summary(["pi", "-p=\(secret)"]), "pi -p=<redacted>")
        XCTAssertEqual(summary(["pi", "-t=\(secret)"]), "pi -t=<redacted>")
        XCTAssertEqual(summary(["pi", "-s=\(secret)"]), "pi -s=<redacted>")
        XCTAssertEqual(summary(["pi", "-P=\(secret)"]), "pi -P=<redacted>")
        XCTAssertEqual(summary(["pi", "-T=\(secret)"]), "pi -T=<redacted>")
        XCTAssertEqual(summary(["pi", "-S=\(secret)"]), "pi -S=<redacted>")

        // 2. 短开关 + 下一个 token：只遮值，后续参数仍可读。
        XCTAssertEqual(summary(["pi", "-P", secret, "--verbose"]), "pi -P <redacted> --verbose")
        XCTAssertEqual(summary(["pi", "-t", secret]), "pi -t <redacted>")

        // 3. 大小写不敏感的紧跟形态。
        XCTAssertEqual(summary(["pi", "-P\(secret)"]), "pi -P<redacted>")
        XCTAssertEqual(summary(["pi", "-T\(secret)"]), "pi -T<redacted>")
        XCTAssertEqual(summary(["pi", "-S\(secret)"]), "pi -S<redacted>")

        // 4. 多字母短开关 `-pw`：三种形态都要遮，且必须识别为 `pw` 而不是 `p`+值。
        XCTAssertEqual(summary(["pi", "-pw", secret]), "pi -pw <redacted>")
        XCTAssertEqual(summary(["pi", "-pw=\(secret)"]), "pi -pw=<redacted>")
        XCTAssertEqual(summary(["pi", "-pw\(secret)"]), "pi -pw<redacted>")
        XCTAssertEqual(summary(["pi", "-PW=\(secret)"]), "pi -PW=<redacted>")

        // 5. 长开关：裸开关、等号形态与大小写都要遮。
        XCTAssertEqual(summary(["pi", "--password", secret, "--verbose"]), "pi --password <redacted> --verbose")
        XCTAssertEqual(summary(["pi", "--password=\(secret)"]), "pi --password=<redacted>")
        XCTAssertEqual(summary(["pi", "--PASSWORD=\(secret)"]), "pi --PASSWORD=<redacted>")
        XCTAssertEqual(summary(["pi", "--token=\(secret)"]), "pi --token=<redacted>")
        XCTAssertEqual(summary(["pi", "--api-key", secret]), "pi --api-key <redacted>")

        // 6. 值里含空格/引号：argv 已按 token 边界切分，整段值一起遮。
        XCTAssertEqual(summary(["pi", "--token=a b c"]), "pi --token=<redacted>")
        XCTAssertEqual(summary(["pi", "-p", "a b c"]), "pi -p <redacted>")
        XCTAssertEqual(summary(["pi", "-p=\"a b\""]), "pi -p=<redacted>")

        // 7. 开关后面紧跟另一个开关：无法区分值与下一个开关，连尾巴一起隐藏。
        let ambiguous = summary(["pi", "-p", "--verbose", secret])
        XCTAssertFalse(ambiguous.contains(secret))
        XCTAssertEqual(ambiguous, "pi -p <redacted>")
    }

    /// M6 的近似样例取舍（已知边界，`docs/privacy.md` 同步写明）：遮罩不能区分
    /// `-p` 是密码还是端口，因此 `-p 8080` 这类非秘密数值也会被遮；纯短开关字母
    /// 组成的开关组（`-pt`）同样按裸开关处理；不敏感的短开关不受影响。
    func testCommandSummaryDocumentsNearMissShortSwitchTradeoffs() {
        let redactor = LogRedactor(homeDirectory: fixtureHome)
        let secret = "s3cr3t-value"

        func summary(_ arguments: [String]) -> String {
            PiProcessInspector.commandSummary(arguments: arguments, redactor: redactor)
        }

        // 端口这类非秘密数值：宁可少展示，不少脱敏（已写进隐私文档）。
        XCTAssertEqual(summary(["pi", "-p", "8080", "--verbose"]), "pi -p <redacted> --verbose")
        // 纯短开关字母组成的开关组：取值在下一个 token，同样遮掉。
        XCTAssertEqual(summary(["pi", "-pt", secret, "--verbose"]), "pi -pt <redacted> --verbose")
        XCTAssertFalse(summary(["pi", "-pt", secret]).contains(secret))
        // 不敏感的短开关与普通参数不误伤。
        XCTAssertEqual(summary(["pi", "-v", "--verbose", "8080"]), "pi -v --verbose 8080")
        XCTAssertEqual(summary(["pi", "-q"]), "pi -q")
    }

    /// 已知边界（明确断言的保留行为）：遮罩是模式化的，不是“凡秘密必被遮”。
    /// 短于阈值、又没有已知前缀或敏感键名的自由文本会**原样保留**；这里把保留
    /// 行为写成断言（而不是含糊的“可能保留”），`docs/privacy.md` 同步如实说明。
    func testCommandSummaryRetainsUnrecognizedFreeText() {
        let redactor = LogRedactor(homeDirectory: fixtureHome)
        let freeText = "open sesame please"
        let shortOpaque = "shortvalue"
        let summary = PiProcessInspector.commandSummary(
            arguments: ["pi", freeText, shortOpaque, "--verbose", "/opt/homebrew/bin/pi"],
            redactor: redactor
        )
        XCTAssertEqual(
            summary,
            "pi \(freeText) \(shortOpaque) --verbose /opt/homebrew/bin/pi",
            "不符合已知形状的自由文本按已知边界原样保留"
        )
    }

    func testCommandSummaryIsBounded() {
        // 长参数用普通路径形状（不是秘密形状）：这里断言的是截断，不是遮罩。
        let longArgument = String(repeating: "some/path/segment/", count: 20) + "notes.txt"
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

    // MARK: - 6. 状态文案（诊断页/设置页）

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

    // MARK: - 7. 源码负向断言（没有信号、没有 shell、没有 sudo）

    /// 这两个文件的代码里不得出现任何“向进程发送信号/终止进程”的调用，也不得
    /// 出现 shell、`sudo` 调用或硬编码的用户目录。
    func testPiUpdateSourcesContainNoSignalOrKillAPIs() throws {
        let forbidden = [
            "kill(", "killpg(", "raise(", "signal(", "SIGTERM", "SIGKILL", "SIGINT",
            ".terminate(", ".interrupt(", "posix_spawn", "/bin/sh", "/bin/bash",
            "Process.arguments", // 只用 plan.arguments，禁止拼接 shell 字符串
            "sudo ", "sudo\"", "sudo'", "sudo(", "[\"sudo\", \"-S\"]"
        ]
        // 这族文件在重构里被按声明边界拆成了 ``PiProcess*`` / ``PiCLIUpdate*``，
        // 断言按文件名前缀覆盖整族：代码挪到哪一个文件里都跑不掉。
        let code = SourceScan.codeText(of: try SourceScan.text(matching: ["PiProcess", "PiCLIUpdate"]))
        for token in forbidden {
            XCTAssertFalse(
                code.contains(token),
                "源码里不得出现 \(token)（信号/终止/shell/sudo 都在禁止之列）"
            )
        }
    }

    /// 命令执行器只以参数数组执行计划里的 argv：参数固定为 `update --self`，
    /// 没有 shell 字符串，也没有额外参数。
    func testExecutableIsStartedWithArgumentArrayOnly() throws {
        let text = try SourceScan.text(matching: ["PiCLIUpdate"])
        XCTAssertTrue(text.contains("process.arguments = plan.arguments"))
        XCTAssertTrue(text.contains("static let requiredArguments = [\"update\", \"--self\"]"))
        XCTAssertFalse(text.contains("shellPath"))
    }
}
