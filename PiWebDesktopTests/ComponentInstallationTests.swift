import Foundation
import XCTest

// MARK: - 夹具

/// 组件安装识别的 unhosted 测试夹具。
///
/// 所有文件、目录、符号链接都建在 `FileManager.default.temporaryDirectory` 下的
/// 临时目录里，测试结束（包括断言失败）时删除。命令执行全部由假 runner 回答，
/// 因此测试既不执行真实的 npm/pi/pi-web，也不访问网络、真实 `~/.pi`、真实
/// Keychain 或用户全局目录；真实磁盘只通过 `SystemDependencyFileSystemProbe`
/// 读取夹具内部。
private final class ComponentFixture {
    let root: URL
    let home: URL
    private let fileManager = FileManager.default

    init() {
        root = fileManager.temporaryDirectory
            .appendingPathComponent("pi-web-desktop-component-tests-\(UUID().uuidString)", isDirectory: true)
        home = root.appendingPathComponent("home", isDirectory: true)
        try? fileManager.createDirectory(at: home, withIntermediateDirectories: true)
    }

    func cleanUp() {
        try? fileManager.removeItem(at: root)
    }

    /// 相对 `root` 的路径。
    func path(_ relativePath: String) -> String {
        root.appendingPathComponent(relativePath).path
    }

    /// 建一个可执行文件。内容故意为空：命令输出由假 runner 回答，夹具脚本永远
    /// 不会被真的执行。
    @discardableResult
    func makeExecutable(_ relativePath: String) -> String {
        makeFile(relativePath, contents: "")
        let url = root.appendingPathComponent(relativePath)
        try? fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url.path
    }

    @discardableResult
    func makeFile(_ relativePath: String, contents: String) -> String {
        let url = root.appendingPathComponent(relativePath)
        try? fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? contents.write(to: url, atomically: true, encoding: .utf8)
        return url.path
    }

    @discardableResult
    func makeDirectory(_ relativePath: String) -> String {
        let url = root.appendingPathComponent(relativePath, isDirectory: true)
        try? fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        return url.path
    }

    /// 建符号链接；`destination` 可以是相对链接所在目录的目标。
    @discardableResult
    func makeSymlink(_ relativePath: String, to destination: String) -> String {
        let url = root.appendingPathComponent(relativePath)
        try? fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fileManager.createSymbolicLink(atPath: url.path, withDestinationPath: destination)
        return url.path
    }
}

/// 记录全部调用的假命令 runner；默认回答“命令不存在”。
private final class ComponentFakeRunner: CommandRunning {
    var handler: ([String]) -> String? = { _ in nil }
    private(set) var invocations: [[String]] = []

    func run(_ arguments: [String]) -> String? {
        invocations.append(arguments)
        return handler(arguments)
    }

    var invocationLines: [String] {
        invocations.map { $0.joined(separator: " ") }
    }
}

/// 真实文件系统探针 + 记录：用来断言识别器只读了夹具内部，没有触碰用户目录。
private final class RecordingFileSystemProbe: DependencyFileSystemProbing {
    let homeDirectory: String
    private let base = SystemDependencyFileSystemProbe()
    private(set) var touchedPaths: [String] = []

    init(homeDirectory: String) {
        self.homeDirectory = homeDirectory
    }

    func isExecutableFile(atPath path: String) -> Bool {
        touchedPaths.append(path)
        return base.isExecutableFile(atPath: path)
    }

    func symlinkDestination(atPath path: String) -> String? {
        touchedPaths.append(path)
        return base.symlinkDestination(atPath: path)
    }

    func resolvedPath(atPath path: String) -> String? {
        touchedPaths.append(path)
        return base.resolvedPath(atPath: path)
    }

    func readText(atPath path: String) -> String? {
        touchedPaths.append(path)
        return base.readText(atPath: path)
    }

    func homeDirectoryPath() -> String {
        homeDirectory
    }

    func directoryExists(atPath path: String) -> Bool? {
        touchedPaths.append(path)
        return base.directoryExists(atPath: path)
    }

    func isReadableDirectory(atPath path: String) -> Bool? {
        touchedPaths.append(path)
        return base.isReadableDirectory(atPath: path)
    }
}

/// 夹具目录快照：路径、类型、mtime 与大小；“没有写操作”的断言比较运行前后。
private func fixtureSnapshot(of root: URL) -> [String] {
    let fileManager = FileManager.default
    guard let enumerator = fileManager.enumerator(
        at: root,
        includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey],
        options: []
    ) else { return [] }
    var entries: [String] = []
    for case let url as URL in enumerator {
        let values = try? url.resourceValues(forKeys: [
            .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey
        ])
        let relative = url.path.replacingOccurrences(of: root.path, with: "")
        let kind = (values?.isSymbolicLink ?? false) ? "link" : ((values?.isDirectory ?? false) ? "dir" : "file")
        let size = values?.fileSize ?? -1
        let modified = values?.contentModificationDate?.timeIntervalSince1970 ?? -1
        entries.append("\(relative)|\(kind)|\(size)|\(modified)")
    }
    return entries.sorted()
}

// MARK: - 测试

final class ComponentInstallationTests: XCTestCase {
    private func makeDetector(
        fixture: ComponentFixture,
        runner: ComponentFakeRunner,
        environment: [String: String] = [:],
        fileSystem: DependencyFileSystemProbing? = nil,
        homeDirectory: String? = nil
    ) -> ComponentInstallationDetector {
        ComponentInstallationDetector(
            commandRunner: runner,
            fileSystem: fileSystem ?? SystemDependencyFileSystemProbe(),
            environment: environment,
            homeDirectory: homeDirectory ?? fixture.home.path,
            knownNPMPrefix: nil
        )
    }

    private func request(
        kind: ComponentKind = .piWeb,
        packageName: String? = nil,
        names: [String] = ["tool"],
        candidates: [String]
    ) -> ComponentInstallationDetector.ComponentDetectionRequest {
        ComponentInstallationDetector.ComponentDetectionRequest(
            kind: kind,
            packageName: packageName,
            executableNames: names,
            candidates: candidates
        )
    }

    // MARK: 符号链接链

    func testMultiHopSymlinkChainIsRecordedAndResolved() {
        let fixture = ComponentFixture()
        defer { fixture.cleanUp() }

        let target = fixture.makeExecutable("home/dev/tool/real/cli.js")
        fixture.makeSymlink("home/dev/tool/hop2", to: "real/cli.js")
        fixture.makeSymlink("home/dev/tool/hop1", to: "hop2")
        let linkPath = fixture.makeSymlink("home/dev/tool/bin/tool", to: "../hop1")

        let runner = ComponentFakeRunner()
        runner.handler = { arguments in
            arguments == [linkPath, "--version"] ? "1.2.3\n" : nil
        }

        let installation = makeDetector(fixture: fixture, runner: runner)
            .detect(request(candidates: [linkPath]))

        XCTAssertEqual(installation.executablePath, linkPath)
        XCTAssertEqual(installation.resolvedPath, target)
        XCTAssertEqual(installation.symlinkChain, [
            linkPath,
            fixture.path("home/dev/tool/hop1"),
            fixture.path("home/dev/tool/hop2"),
            target
        ])
        XCTAssertEqual(installation.version, "1.2.3")
        XCTAssertEqual(installation.source, .localPath)
        XCTAssertEqual(installation.confidence, .inferred)
        XCTAssertTrue(installation.evidence.contains { $0.contains("符号链接链") })
    }

    func testDanglingSymlinkChainIsRecordedAndDegradesToUnknown() {
        let fixture = ComponentFixture()
        defer { fixture.cleanUp() }

        let linkPath = fixture.makeSymlink("home/bin/tool", to: "../missing/tool")
        let danglingTarget = fixture.path("home/missing/tool")
        let runner = ComponentFakeRunner()

        let installation = makeDetector(fixture: fixture, runner: runner)
            .detect(request(candidates: [linkPath]))

        XCTAssertEqual(installation.executablePath, linkPath)
        XCTAssertNil(installation.resolvedPath)
        XCTAssertEqual(installation.symlinkChain, [linkPath, danglingTarget])
        XCTAssertNil(installation.version)
        // 悬空链不是安装证据：不能崩溃，也不能猜成某个来源。
        XCTAssertEqual(installation.source, .unknown)
        XCTAssertEqual(installation.confidence, .unknown)
        XCTAssertTrue(installation.evidence.contains { $0.contains("悬空") }, installation.evidence.joined(separator: "\n"))
        XCTAssertFalse(installation.evidence.contains { $0.contains("可执行位已确认") })
    }

    // MARK: 多套 Node 环境互不污染

    func testNWMAndNPMGlobalPrefixDoNotContaminateEachOther() {
        let fixture = ComponentFixture()
        defer { fixture.cleanUp() }

        // 同一台机器上两个 Node 环境：~/.nvm 与一个独立的 npm 全局 prefix。
        let nuMuPiTarget = fixture.makeExecutable("home/.nvm/versions/node/v22.19.0/lib/node_modules/@earendil-works/pi-coding-agent/dist/cli.js")
        let nuMuPi = fixture.makeSymlink("home/.nvm/versions/node/v22.19.0/bin/pi", to: "../lib/node_modules/@earendil-works/pi-coding-agent/dist/cli.js")
        let npmRoot = fixture.makeDirectory("home/npm-global/lib/node_modules")
        let piWebTarget = fixture.makeExecutable("home/npm-global/lib/node_modules/@agegr/pi-web/dist/cli.js")
        let piWebLink = fixture.makeSymlink("home/npm-global/bin/pi-web", to: "../lib/node_modules/@agegr/pi-web/dist/cli.js")

        let runner = ComponentFakeRunner()
        runner.handler = { arguments in
            switch arguments {
            case ["/usr/bin/env", "npm", "root", "-g"]: return npmRoot + "\n"
            case ["/usr/bin/env", "pnpm", "root", "-g"]: return nil
            case [nuMuPi, "--version"]: return "0.5.0\n"
            case [piWebLink, "--version"]: return "1.2.3\n"
            default: return nil
            }
        }

        let detector = makeDetector(
            fixture: fixture,
            runner: runner,
            environment: ["NVM_DIR": fixture.path("home/.nvm")]
        )
        let pi = detector.detect(request(kind: .piCLI, names: ["pi"], candidates: [nuMuPi]))
        let piWeb = detector.detect(request(kind: .piWeb, names: ["pi-web"], candidates: [piWebLink]))

        // nvm 目录里的包：路径段 + 环境标记 → nvm；npm 全局 root 指向别处，不能污染。
        XCTAssertEqual(pi.resolvedPath, nuMuPiTarget)
        XCTAssertEqual(pi.source, .nvm)
        XCTAssertEqual(pi.confidence, .verified)
        XCTAssertTrue(pi.evidence.contains { $0.contains("nvm 证据") })
        XCTAssertFalse(pi.evidence.contains { $0.contains("npm 全局 root") })

        // npm 全局 root 下的包：命令输出的 root 命中 → npm 全局；也不能被 nvm 抢走。
        XCTAssertEqual(piWeb.resolvedPath, piWebTarget)
        XCTAssertEqual(piWeb.source, .npmGlobal)
        XCTAssertEqual(piWeb.confidence, .verified)
        XCTAssertTrue(piWeb.evidence.contains { $0.contains("npm 全局 root") })
        XCTAssertFalse(piWeb.evidence.contains { $0.contains("nvm 证据") })
    }

    func testMiseInstallDirectoryIsRecognizedWithTheEnvironmentMarker() {
        let fixture = ComponentFixture()
        defer { fixture.cleanUp() }

        let tool = fixture.makeExecutable("home/.local/share/mise/installs/node/22.19.0/bin/node")
        let runner = ComponentFakeRunner()
        runner.handler = { arguments in
            arguments == [tool, "--version"] ? "v22.19.0\n" : nil
        }
        let detector = makeDetector(
            fixture: fixture,
            runner: runner,
            environment: ["MISE_DATA_DIR": fixture.path("home/.local/share/mise")]
        )

        let installation = detector.detect(request(kind: .piCLI, packageName: nil, names: ["node"], candidates: [tool]))

        XCTAssertEqual(installation.source, .mise)
        XCTAssertEqual(installation.confidence, .verified)
        XCTAssertTrue(installation.evidence.contains { $0.contains("mise 证据") })
    }

    // MARK: 非 npm 来源

    func testGitCheckoutAndLocalPathAreDetectedWithoutPackageManagerEvidence() {
        let fixture = ComponentFixture()
        defer { fixture.cleanUp() }

        fixture.makeDirectory("home/dev/pi-web/.git")
        let packageJSON = fixture.makeFile(
            "home/dev/pi-web/package.json",
            contents: #"{"name":"@agegr/pi-web","version":"1.2.3"}"#
        )
        let checkoutExecutable = fixture.makeExecutable("home/dev/pi-web/dist/cli.js")
        let localExecutable = fixture.makeExecutable("home/bin/local-tool")

        let runner = ComponentFakeRunner()
        runner.handler = { arguments in
            switch arguments {
            case [checkoutExecutable, "--version"]: return "1.2.3\n"
            case [localExecutable, "--version"]: return "0.1.0\n"
            default: return nil
            }
        }
        let detector = makeDetector(fixture: fixture, runner: runner)

        let checkout = detector.detect(request(packageName: "@agegr/pi-web", candidates: [checkoutExecutable]))
        XCTAssertEqual(checkout.source, .gitCheckout)
        XCTAssertEqual(checkout.confidence, .verified)
        XCTAssertEqual(checkout.packageName, "@agegr/pi-web")
        XCTAssertEqual(checkout.packageJSONPath, packageJSON)
        XCTAssertTrue(checkout.evidence.contains { $0.contains(".git") })
        // git checkout 不给包管理器命令。
        XCTAssertNil(checkout.suggestedCommand)
        XCTAssertTrue(checkout.evidence.contains { $0.contains("未给出更新命令") })

        let local = detector.detect(request(candidates: [localExecutable]))
        XCTAssertEqual(local.source, .localPath)
        XCTAssertEqual(local.confidence, .inferred)
        XCTAssertNil(local.suggestedCommand)
        XCTAssertTrue(local.evidence.contains { $0.contains("未验证原因") })
    }

    /// worktree / submodule 的 `.git` 是一个文件（`gitdir: …`）而不是目录，也算 git 证据。
    func testGitFileFormIsAlsoCheckoutEvidence() {
        let fixture = ComponentFixture()
        defer { fixture.cleanUp() }

        let gitFile = fixture.makeFile("home/dev/pi-web/.git", contents: "gitdir: /somewhere/else/.git/worktrees/pi-web\n")
        let executable = fixture.makeExecutable("home/dev/pi-web/dist/cli.js")
        let runner = ComponentFakeRunner()
        runner.handler = { arguments in
            arguments == [executable, "--version"] ? "1.2.3\n" : nil
        }

        let installation = makeDetector(fixture: fixture, runner: runner)
            .detect(request(candidates: [executable]))

        XCTAssertEqual(installation.source, .gitCheckout)
        XCTAssertEqual(installation.confidence, .verified)
        XCTAssertTrue(installation.evidence.contains { $0.contains(gitFile) })
    }

    // MARK: Homebrew

    func testHomebrewCellarAndOptStructuresAreVerified() {
        let fixture = ComponentFixture()
        defer { fixture.cleanUp() }

        let cellar = fixture.makeExecutable("homebrew/Cellar/pi-web/1.2.3/bin/pi-web")
        let opt = fixture.makeExecutable("homebrew/opt/pi-cli/bin/pi")
        let runner = ComponentFakeRunner()
        runner.handler = { arguments in
            switch arguments {
            case [cellar, "--version"]: return "1.2.3\n"
            case [opt, "--version"]: return "0.5.0\n"
            default: return nil
            }
        }
        let detector = makeDetector(fixture: fixture, runner: runner)

        let cellarInstallation = detector.detect(request(candidates: [cellar]))
        XCTAssertEqual(cellarInstallation.source, .homebrew)
        XCTAssertEqual(cellarInstallation.confidence, .verified)
        XCTAssertTrue(cellarInstallation.evidence.contains { $0.contains("Cellar/opt 结构") })
        XCTAssertNil(cellarInstallation.suggestedCommand, "Homebrew 不给包管理器命令")

        let optInstallation = detector.detect(request(kind: .piCLI, names: ["pi"], candidates: [opt]))
        XCTAssertEqual(optInstallation.source, .homebrew)
        XCTAssertEqual(optInstallation.confidence, .verified)
    }

    /// 同一条路径前缀（`/opt/homebrew/bin`）不足以判定 Homebrew：这是反例用例。
    func testHomebrewPrefixAloneIsNotEnoughEvidence() {
        let verdict = ComponentSourceResolver.resolve(ComponentSourceEvidence(
            kind: .piWeb,
            executablePath: "/opt/homebrew/bin/pi-web",
            resolvedPath: "/opt/homebrew/bin/pi-web",
            symlinkChain: ["/opt/homebrew/bin/pi-web"],
            npmRoot: "/usr/local/lib/node_modules",
            npmRootEvidence: "npm root -g → /usr/local/lib/node_modules",
            homeDirectory: "/tmp/component-tests-home"
        ))

        XCTAssertNotEqual(verdict.source, .homebrew)
        XCTAssertEqual(verdict.source, .unknown)
        XCTAssertEqual(verdict.confidence, .unknown)
        XCTAssertTrue(
            verdict.evidence.contains { $0.contains("仅凭前缀不判定为 Homebrew") },
            verdict.evidence.joined(separator: "\n")
        )
        XCTAssertTrue(
            verdict.evidence.contains { $0.hasPrefix("未验证原因") },
            verdict.evidence.joined(separator: "\n")
        )
    }

    /// 只有在 Cellar/opt 结构或 npm/pnpm 全局 root 命中时才算验证过；同前缀的
    /// `/opt/homebrew/bin` 链接到 `/opt/homebrew/lib/node_modules` 应判为 npm 全局。
    func testHomebrewPrefixWithNPMRootEvidenceIsClassifiedByTheRoot() {
        let verdict = ComponentSourceResolver.resolve(ComponentSourceEvidence(
            kind: .piWeb,
            executablePath: "/opt/homebrew/bin/pi-web",
            resolvedPath: "/opt/homebrew/lib/node_modules/@agegr/pi-web/dist/cli.js",
            symlinkChain: [
                "/opt/homebrew/bin/pi-web",
                "/opt/homebrew/lib/node_modules/@agegr/pi-web/dist/cli.js"
            ],
            npmRoot: "/opt/homebrew/lib/node_modules",
            npmRootEvidence: "npm root -g → /opt/homebrew/lib/node_modules",
            homeDirectory: "/tmp/component-tests-home"
        ))

        XCTAssertEqual(verdict.source, .npmGlobal)
        XCTAssertEqual(verdict.confidence, .verified)
    }

    /// 文件系统层面也验证一次：`<前缀>/homebrew/bin` 里直接放一个可执行文件
    /// （没有 Cellar/opt）不是 Homebrew 证据，也不能被猜成别的来源。
    func testHomebrewLikeRootWithoutCellarOrOptIsNotHomebrew() {
        let fixture = ComponentFixture()
        defer { fixture.cleanUp() }

        let plain = fixture.makeExecutable("homebrew/bin/pi-web")
        let runner = ComponentFakeRunner()
        runner.handler = { arguments in
            arguments == [plain, "--version"] ? "1.2.3\n" : nil
        }

        let installation = makeDetector(fixture: fixture, runner: runner)
            .detect(request(candidates: [plain]))

        XCTAssertNotEqual(installation.source, .homebrew)
        XCTAssertEqual(installation.source, .unknown)
        XCTAssertEqual(installation.confidence, .unknown)
        XCTAssertTrue(installation.evidence.contains { $0.contains("未验证原因") })
    }

    // MARK: package.json 缺失 / 缺版本

    func testMissingPackageJSONWithoutVersionOutputDegradesToUnknown() {
        let fixture = ComponentFixture()
        defer { fixture.cleanUp() }

        let executable = fixture.makeExecutable("home/tools/pi-web")
        let runner = ComponentFakeRunner()
        runner.handler = { arguments in
            // `--version` 不可解析：只有 package.json 能提供版本，而它并不存在。
            arguments == [executable, "--version"] ? "unknown option --version\n" : nil
        }

        let installation = makeDetector(fixture: fixture, runner: runner)
            .detect(request(candidates: [executable]))

        XCTAssertNil(installation.version)
        XCTAssertNil(installation.packageJSONPath)
        XCTAssertEqual(installation.confidence, .unknown)
        XCTAssertTrue(
            installation.evidence.contains { $0.contains("package.json：向上") },
            installation.evidence.joined(separator: "\n")
        )
        XCTAssertTrue(installation.evidence.contains { $0.contains("未验证原因") })
    }

    func testPackageJSONWithoutVersionDegradesToUnknown() {
        let fixture = ComponentFixture()
        defer { fixture.cleanUp() }

        let packageJSON = fixture.makeFile(
            "home/tools/package.json",
            contents: #"{"name":"@agegr/pi-web"}"#
        )
        let executable = fixture.makeExecutable("home/tools/pi-web")
        let runner = ComponentFakeRunner()
        runner.handler = { _ in nil }

        let installation = makeDetector(fixture: fixture, runner: runner)
            .detect(request(packageName: "@agegr/pi-web", candidates: [executable]))

        XCTAssertEqual(installation.packageJSONPath, packageJSON)
        XCTAssertEqual(installation.packageName, "@agegr/pi-web")
        XCTAssertNil(installation.version)
        XCTAssertEqual(installation.confidence, .unknown)
        XCTAssertTrue(
            installation.evidence.contains { $0.contains("package.json 缺少可用的 version") },
            installation.evidence.joined(separator: "\n")
        )
    }

    /// `--version` 不可用、package.json 能提供版本时仍然可以 verified（#6 的回落）。
    func testPackageJSONVersionIsUsedWhenTheExecutableCannotReportOne() {
        let fixture = ComponentFixture()
        defer { fixture.cleanUp() }

        fixture.makeFile("home/tools/package.json", contents: #"{"name":"@agegr/pi-web","version":"1.2.3"}"#)
        let executable = fixture.makeExecutable("home/tools/pi-web")
        let runner = ComponentFakeRunner()
        runner.handler = { _ in nil }

        let installation = makeDetector(fixture: fixture, runner: runner)
            .detect(request(packageName: "@agegr/pi-web", candidates: [executable]))

        XCTAssertEqual(installation.version, "1.2.3")
        XCTAssertEqual(installation.confidence, .inferred, "来源只能算 localPath，整体取最弱证据")
    }

    // MARK: `pi list`

    func testPiListFailureAndMalformedOutputDegradeToUnknownWithoutCrashing() {
        let fixture = ComponentFixture()
        defer { fixture.cleanUp() }

        let pi = fixture.makeExecutable("home/bin/pi")

        let failing = ComponentFakeRunner()
        failing.handler = { _ in nil }
        let failureEntries = makeDetector(fixture: fixture, runner: failing).detectPiPackages(piExecutablePath: pi)
        XCTAssertEqual(failureEntries.count, 1)
        XCTAssertEqual(failureEntries.first?.kind, .piPackage)
        XCTAssertEqual(failureEntries.first?.source, .unknown)
        XCTAssertEqual(failureEntries.first?.confidence, .unknown)
        XCTAssertNil(failureEntries.first?.suggestedCommand)
        XCTAssertTrue(failureEntries.first?.evidence.contains { $0.contains("pi list") } == true)

        let malformed = ComponentFakeRunner()
        malformed.handler = { arguments in
            arguments == [pi, "list"] ? "no packages here\n!!!\n:::\n" : nil
        }
        let malformedEntries = makeDetector(fixture: fixture, runner: malformed).detectPiPackages(piExecutablePath: pi)
        XCTAssertEqual(malformedEntries.count, 1)
        XCTAssertEqual(malformedEntries.first?.source, .unknown)
        XCTAssertEqual(malformedEntries.first?.confidence, .unknown)
        XCTAssertTrue(malformedEntries.first?.evidence.contains { $0.contains("没有可解析") } == true)

        // 没有 pi 可执行文件时不生成条目（没有证据就不猜）。
        XCTAssertTrue(makeDetector(fixture: fixture, runner: ComponentFakeRunner())
            .detectPiPackages(piExecutablePath: nil).isEmpty)
    }

    func testPiListEntriesWithoutPackageDirectoryStayUnknown() {
        let fixture = ComponentFixture()
        defer { fixture.cleanUp() }

        let pi = fixture.makeExecutable("home/bin/pi")
        let runner = ComponentFakeRunner()
        runner.handler = { arguments in
            switch arguments {
            case [pi, "list"]: return "@scope/one@1.2.3\nplain 2.0.0\n# comment\n\n"
            default: return nil
            }
        }

        let entries = makeDetector(fixture: fixture, runner: runner).detectPiPackages(piExecutablePath: pi)

        XCTAssertEqual(entries.map(\.packageName), ["@scope/one", "plain"])
        XCTAssertEqual(entries.map(\.version), ["1.2.3", "2.0.0"])
        for entry in entries {
            XCTAssertEqual(entry.source, .unknown)
            XCTAssertEqual(entry.confidence, .unknown)
            XCTAssertNil(entry.executablePath)
            XCTAssertTrue(entry.evidence.contains { $0.contains("没有找到同名包目录") })
        }
    }

    func testPiListEntriesFindTheirPackageDirectoryUnderNPMRoot() {
        let fixture = ComponentFixture()
        defer { fixture.cleanUp() }

        let pi = fixture.makeExecutable("home/bin/pi")
        let npmRoot = fixture.makeDirectory("home/npm-global/lib/node_modules")
        let packageJSON = fixture.makeFile(
            "home/npm-global/lib/node_modules/@scope/one/package.json",
            contents: #"{"name":"@scope/one","version":"1.2.3"}"#
        )
        let runner = ComponentFakeRunner()
        runner.handler = { arguments in
            switch arguments {
            case [pi, "list"]: return "@scope/one@1.2.3\n"
            case ["/usr/bin/env", "npm", "root", "-g"]: return npmRoot + "\n"
            default: return nil
            }
        }

        let entries = makeDetector(fixture: fixture, runner: runner).detectPiPackages(piExecutablePath: pi)

        XCTAssertEqual(entries.count, 1)
        let entry = entries[0]
        XCTAssertEqual(entry.kind, .piPackage)
        XCTAssertEqual(entry.packageName, "@scope/one")
        XCTAssertEqual(entry.version, "1.2.3")
        XCTAssertEqual(entry.packageJSONPath, packageJSON)
        XCTAssertEqual(entry.source, .npmGlobal)
        XCTAssertEqual(entry.confidence, .verified)
        // Pi 扩展包没有固定包名的静态命令：只给指引，不给命令。
        XCTAssertNil(entry.suggestedCommand)
    }

    func testPiListParserAcceptsDocumentedShapesOnly() {
        let parsed = ComponentInstallationDetector.parsePiList("""
        @scope/one@1.2.3
        plain 2.0.0
        # comment
        header without version
        @scope/two@notaversion
        """)

        XCTAssertEqual(parsed.map(\.name), ["@scope/one", "plain"])
        XCTAssertEqual(parsed.map(\.version), ["1.2.3", "2.0.0"])
        XCTAssertTrue(ComponentInstallationDetector.parsePiList("").isEmpty)
        XCTAssertTrue(ComponentInstallationDetector.parsePiList("nothing here\n").isEmpty)
    }

    // MARK: 应用自身

    func testDesktopApplicationInApplicationsDirectoryIsInferredOfficialInstaller() {
        let fixture = ComponentFixture()
        defer { fixture.cleanUp() }

        let bundle = fixture.makeDirectory("Applications/Pi Web Desktop.app")
        let runner = ComponentFakeRunner()

        let installation = makeDetector(fixture: fixture, runner: runner).detect(
            ComponentInstallationDetector.ComponentDetectionRequest(
                kind: .desktopApp,
                packageName: nil,
                executableNames: [],
                candidates: [bundle],
                knownVersion: "1.2.3",
                runsVersionCommand: false,
                isApplicationBundle: true
            )
        )

        XCTAssertEqual(installation.source, .officialInstaller)
        XCTAssertEqual(installation.confidence, .inferred)
        XCTAssertEqual(installation.version, "1.2.3")
        XCTAssertEqual(installation.executablePath, bundle)
        XCTAssertTrue(installation.evidence.contains { $0.contains("Applications 目录") })
        XCTAssertNil(installation.suggestedCommand)
    }

    // MARK: 建议命令策略

    func testSuggestedCommandsOnlyComeFromNPMOrPNPMGlobalGuidance() {
        // npm/pnpm 全局：有静态命令。
        XCTAssertEqual(
            InstallCommandManifest.updateGuidance(for: .piWeb, source: .npmGlobal)?.command,
            "npm install -g @agegr/pi-web"
        )
        XCTAssertEqual(
            InstallCommandManifest.updateGuidance(for: .piCLI, source: .npmGlobal)?.command,
            "npm install -g --ignore-scripts @earendil-works/pi-coding-agent"
        )
        XCTAssertEqual(
            InstallCommandManifest.updateGuidance(for: .piWeb, source: .pnpmGlobal)?.command,
            "pnpm add -g @agegr/pi-web"
        )
        XCTAssertEqual(
            InstallCommandManifest.updateGuidance(for: .piCLI, source: .pnpmGlobal)?.command,
            "pnpm add -g @earendil-works/pi-coding-agent"
        )

        // 其它来源：一律不给命令，且指引里不得出现 `npm install -g`。
        for source in [InstallSource.homebrew, .nvm, .mise, .gitCheckout, .officialInstaller, .localPath, .unknown] {
            for kind in [ComponentKind.piCLI, .piWeb, .piPackage, .desktopApp] {
                let guidance = InstallCommandManifest.updateGuidance(for: kind, source: source)
                XCTAssertNil(guidance?.command, "\(kind) 的来源 \(source) 不应有命令")
                XCTAssertFalse(
                    guidance?.note.contains("npm install -g") == true,
                    "\(kind) 的来源 \(source) 的指引里出现了统一 npm 命令"
                )
            }
        }

        // Pi 扩展包永远没有静态命令（包名不固定，不能动态拼接）。
        XCTAssertNil(InstallCommandManifest.updateGuidance(for: .piPackage, source: .npmGlobal)?.command)

        // updateGuidance 之外没有别的更新命令来源：静态清单的 install 条目只用于
        // 未安装时的“复制安装命令”。
        XCTAssertNotNil(InstallCommandManifest.entry(withID: "update.pi-web.npm-global"))
        XCTAssertNotNil(InstallCommandManifest.entry(withID: "install.pi-web"))
    }

    func testUnverifiedPackageManagerSourceDoesNotGetACommand() {
        let fixture = ComponentFixture()
        defer { fixture.cleanUp() }

        // `~/.npm-global` 是弱证据（没有 npm root -g 输出）：来源是 npm 全局，
        // 但可信度只有 inferred，因此不能给出更新命令。
        let executable = fixture.makeExecutable("home/.npm-global/bin/pi-web")
        let runner = ComponentFakeRunner()
        runner.handler = { arguments in
            arguments == [executable, "--version"] ? "1.2.3\n" : nil
        }

        let installation = makeDetector(fixture: fixture, runner: runner)
            .detect(request(candidates: [executable]))

        XCTAssertEqual(installation.source, .npmGlobal)
        XCTAssertEqual(installation.confidence, .inferred)
        XCTAssertNil(installation.suggestedCommand)
    }

    // MARK: 只读约束

    /// 调用方已解析过可执行文件（`probesShellPath: false`）时不得再执行 `command -v`；
    /// 候选路径都不存在时也不得凭空造出路径。
    func testShellLookupIsSkippedWhenTheCallerAlreadyResolvedTheExecutable() {
        let fixture = ComponentFixture()
        defer { fixture.cleanUp() }

        let runner = ComponentFakeRunner()
        let installation = makeDetector(fixture: fixture, runner: runner).detect(
            ComponentInstallationDetector.ComponentDetectionRequest(
                kind: .piCLI,
                packageName: nil,
                executableNames: ["pi"],
                candidates: [fixture.path("home/bin/pi")],
                probesShellPath: false
            )
        )

        XCTAssertNil(installation.executablePath)
        XCTAssertEqual(installation.source, .unknown)
        XCTAssertEqual(installation.confidence, .unknown)
        // 只允许 npm/pnpm 全局 root 查询；不得有 `command -v` 或 `--version`（路径不存在）。
        XCTAssertEqual(runner.invocationLines, [
            "/usr/bin/env npm root -g",
            "/usr/bin/env pnpm root -g"
        ])
        XCTAssertFalse(runner.invocationLines.contains { $0.contains("command -v") })
    }

    func testDetectionOnlyReadsTheFixtureAndRunsReadOnlyCommands() {
        let fixture = ComponentFixture()
        defer { fixture.cleanUp() }

        // 覆盖各类证据：nvm、npm 全局 root、Cellar、git checkout、本地路径。
        let nvmPi = fixture.makeExecutable("home/.nvm/versions/node/v22.19.0/lib/node_modules/@earendil-works/pi-coding-agent/dist/cli.js")
        let nvmLink = fixture.makeSymlink("home/.nvm/versions/node/v22.19.0/bin/pi", to: "../lib/node_modules/@earendil-works/pi-coding-agent/dist/cli.js")
        let npmRoot = fixture.makeDirectory("home/npm-global/lib/node_modules")
        fixture.makeExecutable("home/npm-global/lib/node_modules/@agegr/pi-web/dist/cli.js")
        let npmLink = fixture.makeSymlink("home/npm-global/bin/pi-web", to: "../lib/node_modules/@agegr/pi-web/dist/cli.js")
        let cellar = fixture.makeExecutable("homebrew/Cellar/node/22.19.0/bin/node")
        fixture.makeDirectory("home/dev/checkout/.git")
        let checkout = fixture.makeExecutable("home/dev/checkout/dist/cli.js")
        let local = fixture.makeExecutable("home/bin/local-tool")

        let before = fixtureSnapshot(of: fixture.root)
        let runner = ComponentFakeRunner()
        runner.handler = { arguments in
            switch arguments {
            case ["/usr/bin/env", "npm", "root", "-g"]: return npmRoot + "\n"
            case ["/usr/bin/env", "pnpm", "root", "-g"]: return nil
            case [nvmLink, "--version"]: return "0.5.0\n"
            case [npmLink, "--version"]: return "1.2.3\n"
            case [cellar, "--version"]: return "v22.19.0\n"
            case [checkout, "--version"]: return "1.0.0\n"
            case [local, "--version"]: return "0.1.0\n"
            case [nvmPi, "list"]: return "@scope/one@1.2.3\n"
            default: return nil
            }
        }
        let probe = RecordingFileSystemProbe(homeDirectory: fixture.home.path)
        let detector = makeDetector(fixture: fixture, runner: runner, fileSystem: probe)

        let installations = detector.detectAll([
            ComponentInstallationDetector.ComponentDetectionRequest(
                kind: .piCLI, packageName: nil, executableNames: ["pi"], candidates: [nvmLink]
            ),
            ComponentInstallationDetector.ComponentDetectionRequest(
                kind: .piWeb, packageName: nil, executableNames: ["pi-web"], candidates: [npmLink]
            ),
            ComponentInstallationDetector.ComponentDetectionRequest(
                kind: .piCLI, packageName: nil, executableNames: ["node"], candidates: [cellar]
            ),
            ComponentInstallationDetector.ComponentDetectionRequest(
                kind: .piPackage, packageName: nil, executableNames: ["cli"], candidates: [checkout]
            ),
            ComponentInstallationDetector.ComponentDetectionRequest(
                kind: .piPackage, packageName: nil, executableNames: ["local-tool"], candidates: [local]
            )
        ])
        let packages = detector.detectPiPackages(piExecutablePath: nvmLink)

        XCTAssertEqual(installations.count, 5)
        XCTAssertFalse(packages.isEmpty)

        // 只读命令允许清单：没有任何 sudo、安装、升级、写操作或网络命令。
        let allowed = [
            "/usr/bin/env npm root -g",
            "/usr/bin/env npm prefix -g",
            "/usr/bin/env pnpm root -g",
            "\(nvmLink) --version",
            "\(npmLink) --version",
            "\(cellar) --version",
            "\(checkout) --version",
            "\(local) --version",
            "\(nvmLink) list"
        ]
        for line in runner.invocationLines {
            XCTAssertFalse(line.contains("sudo"), "不得调用 sudo: \(line)")
            XCTAssertFalse(line.contains("install"), "不得执行安装: \(line)")
            XCTAssertFalse(line.contains("add"), "不得执行安装: \(line)")
            XCTAssertFalse(line.contains("upgrade") || line.contains("update"), "不得执行更新: \(line)")
            XCTAssertFalse(line.lowercased().contains("http"), "不得访问网络: \(line)")
            XCTAssertFalse(line.contains("curl") || line.contains("wget"), "不得访问网络: \(line)")
            XCTAssertFalse(line.contains("rm ") || line.contains("mv ") || line.contains(">"), "不得写文件: \(line)")
            XCTAssertTrue(allowed.contains(line), "只允许只读命令: \(line)")
        }

        // 文件系统探针只读了夹具内部，以及 package.json / .git 的向上候选路径
        // （证据收集本身要求向上查找）；没有用户全局目录、没有真实 Home。
        let homePrefix = FileManager.default.homeDirectoryForCurrentUser.path
        for path in probe.touchedPaths {
            let name = (path as NSString).lastPathComponent
            let isUpwardCandidate = name == "package.json" || name == ".git"
            XCTAssertTrue(
                path.hasPrefix(fixture.root.path) || isUpwardCandidate,
                "探针只应读夹具内部或 package.json/.git 候选路径: \(path)"
            )
            XCTAssertFalse(path.hasPrefix(homePrefix), "探针不得触碰真实 Home: \(path)")
        }
        XCTAssertFalse(probe.touchedPaths.isEmpty)

        // 识别过程没有写入夹具（快照逐项一致）。
        XCTAssertEqual(fixtureSnapshot(of: fixture.root), before, "识别过程不得写文件")
    }

    // MARK: 证据组合规则（纯函数）

    func testResolverPrefersGitCheckoutWhenThePackageDirectoryHasGit() {
        let verdict = ComponentSourceResolver.resolve(ComponentSourceEvidence(
            kind: .piWeb,
            executablePath: "/tmp/home/bin/pi-web",
            resolvedPath: "/tmp/home/dev/pi-web/dist/cli.js",
            symlinkChain: ["/tmp/home/bin/pi-web", "/tmp/home/dev/pi-web/dist/cli.js"],
            packageDirectory: "/tmp/home/dev/pi-web",
            gitEvidencePath: "/tmp/home/dev/pi-web/.git",
            homeDirectory: "/tmp/home"
        ))

        XCTAssertEqual(verdict.source, .gitCheckout)
        XCTAssertEqual(verdict.confidence, .verified)
    }

    /// npm link 形态：链接路径在 npm 全局 root 内、真实路径在别处 → 记录矛盾并按
    /// 真实路径继续判定，不把“链接位置”当安装来源。
    func testResolverRecordsTheNPMLinkContradiction() {
        let verdict = ComponentSourceResolver.resolve(ComponentSourceEvidence(
            kind: .piWeb,
            executablePath: "/opt/homebrew/lib/node_modules/@agegr/pi-web/dist/cli.js",
            resolvedPath: "/tmp/home/dev/pi-web/dist/cli.js",
            symlinkChain: [
                "/opt/homebrew/lib/node_modules/@agegr/pi-web/dist/cli.js",
                "/tmp/home/dev/pi-web/dist/cli.js"
            ],
            packageDirectory: "/tmp/home/dev/pi-web",
            gitEvidencePath: "/tmp/home/dev/pi-web/.git",
            npmRoot: "/opt/homebrew/lib/node_modules",
            npmRootEvidence: "npm root -g → /opt/homebrew/lib/node_modules",
            homeDirectory: "/tmp/home"
        ))

        XCTAssertEqual(verdict.source, .gitCheckout)
        XCTAssertTrue(verdict.evidence.contains { $0.contains("疑似 npm link") }, verdict.evidence.joined(separator: "\n"))
    }

    func testResolverWithoutAnyEvidenceIsUnknown() {
        let verdict = ComponentSourceResolver.resolve(ComponentSourceEvidence(
            kind: .piWeb,
            executablePath: nil,
            resolvedPath: nil,
            homeDirectory: "/tmp/home"
        ))

        XCTAssertEqual(verdict.source, .unknown)
        XCTAssertEqual(verdict.confidence, .unknown)
        XCTAssertTrue(verdict.evidence.contains { $0.hasPrefix("未验证原因") })
    }

    // MARK: 脱敏

    func testComponentInstallationRedactionCoversPathsAndEvidenceLines() {
        let fixture = ComponentFixture()
        defer { fixture.cleanUp() }

        let executable = fixture.makeExecutable("home/.npm-global/bin/pi-web")
        let runner = ComponentFakeRunner()
        runner.handler = { arguments in
            arguments == [executable, "--version"] ? "1.2.3\n" : nil
        }
        let installation = makeDetector(fixture: fixture, runner: runner)
            .detect(request(candidates: [executable]))

        let redactor = DependencyPathRedactor(homeDirectory: fixture.home.path)
        let redacted = installation.redacted(using: redactor)

        XCTAssertEqual(redacted.executablePath, "~/.npm-global/bin/pi-web")
        XCTAssertTrue(redacted.symlinkChain.allSatisfy { !$0.contains(fixture.home.path) })
        XCTAssertTrue(redacted.evidence.allSatisfy { !$0.contains(fixture.home.path) })
        // 判定结果只受路径脱敏影响之外的字段保持不变。
        XCTAssertEqual(redacted.source, installation.source)
        XCTAssertEqual(redacted.confidence, installation.confidence)
        XCTAssertEqual(redacted.version, installation.version)
        XCTAssertFalse(redacted.summaryLine.contains(fixture.home.path))
    }
}
