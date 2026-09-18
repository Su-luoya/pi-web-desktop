import Foundation
import XCTest

/// Unhosted tests for the workspace directory rules (GitHub #9):
/// `Sources/WorkspaceDirectory.swift`, `Sources/ServiceConfiguration.swift` and
/// `Sources/AppPaths.swift` are compiled directly into this target. The probe is
/// a fake, so no real directory, permission or user path is touched.
final class WorkspaceDirectoryTests: XCTestCase {
    private let defaultPath = "/tmp/PiWebDesktopTests/support/Workspace"
    private let customPath = "/tmp/PiWebDesktopTests/custom-workspace"

    /// In-memory file system: paths can exist, be directories, be writable, and
    /// directory creation can be forced to fail.
    private final class FakeFileSystem {
        var existingPaths: Set<String> = []
        var directories: Set<String> = []
        var writableDirectories: Set<String> = []
        private(set) var createdDirectories: [String] = []
        var createFails = false

        var probe: WorkspaceDirectoryProbe {
            WorkspaceDirectoryProbe(
                pathExists: { self.existingPaths.contains($0) || self.directories.contains($0) },
                isDirectory: { self.directories.contains($0) },
                isWritable: { self.writableDirectories.contains($0) },
                createDirectory: { path in
                    if self.createFails { throw CocoaError(.fileWriteNoPermission) }
                    self.createdDirectories.append(path)
                    self.existingPaths.insert(path)
                    self.directories.insert(path)
                    self.writableDirectories.insert(path)
                }
            )
        }

        func makeWritableDirectory(_ path: String) {
            existingPaths.insert(path)
            directories.insert(path)
            writableDirectories.insert(path)
        }

        func makeUnwritableDirectory(_ path: String) {
            existingPaths.insert(path)
            directories.insert(path)
        }

        func makeFile(_ path: String) {
            existingPaths.insert(path)
        }
    }

    private func configuration(workspacePath: String = "") -> ServiceConfiguration {
        var configuration = ServiceConfiguration.default
        configuration.workspacePath = workspacePath
        return configuration
    }

    // MARK: - 解析与校验

    func testResolvedPathPrefersTheConfiguredDirectoryAndFallsBackToDefault() {
        XCTAssertEqual(WorkspaceDirectory.resolvedPath(configured: "", defaultPath: defaultPath), defaultPath)
        XCTAssertEqual(WorkspaceDirectory.resolvedPath(configured: "   ", defaultPath: defaultPath), defaultPath)
        XCTAssertEqual(WorkspaceDirectory.resolvedPath(configured: customPath, defaultPath: defaultPath), customPath)

        XCTAssertTrue(WorkspaceDirectory.usesDefaultLocation(configured: ""))
        XCTAssertTrue(WorkspaceDirectory.usesDefaultLocation(configured: "  \n"))
        XCTAssertFalse(WorkspaceDirectory.usesDefaultLocation(configured: customPath))
    }

    func testValidationDistinguishesMissingNotDirectoryAndNotWritable() {
        let fileSystem = FakeFileSystem()

        XCTAssertEqual(
            WorkspaceDirectory.validate(path: defaultPath, probe: fileSystem.probe),
            .unusable(problem: .missing, path: defaultPath)
        )

        fileSystem.makeFile(defaultPath)
        XCTAssertEqual(
            WorkspaceDirectory.validate(path: defaultPath, probe: fileSystem.probe),
            .unusable(problem: .notDirectory, path: defaultPath)
        )

        let unwritable = "/tmp/PiWebDesktopTests/read-only-workspace"
        fileSystem.makeUnwritableDirectory(unwritable)
        XCTAssertEqual(
            WorkspaceDirectory.validate(path: unwritable, probe: fileSystem.probe),
            .unusable(problem: .notWritable, path: unwritable)
        )

        fileSystem.makeWritableDirectory(customPath)
        XCTAssertEqual(WorkspaceDirectory.validate(path: customPath, probe: fileSystem.probe), .usable(path: customPath))
        XCTAssertNil(WorkspaceDirectory.validate(path: customPath, probe: fileSystem.probe).problem)
        XCTAssertTrue(WorkspaceDirectory.validate(path: customPath, probe: fileSystem.probe).isUsable)
    }

    /// 默认工作目录首次使用时创建。
    func testDefaultWorkspaceIsCreatedOnFirstUseAndThenUsable() {
        let fileSystem = FakeFileSystem()

        let prepared = WorkspaceDirectory.prepare(configuredPath: "", defaultPath: defaultPath, probe: fileSystem.probe)

        XCTAssertEqual(prepared, .usable(path: defaultPath))
        XCTAssertEqual(fileSystem.createdDirectories, [defaultPath])
    }

    /// 默认目录创建失败（父目录不可写等）时仍然阻止启动。
    func testDefaultWorkspaceCreationFailureBlocksStartup() {
        let fileSystem = FakeFileSystem()
        fileSystem.createFails = true

        let prepared = WorkspaceDirectory.prepare(configuredPath: "", defaultPath: defaultPath, probe: fileSystem.probe)

        XCTAssertEqual(prepared, .unusable(problem: .missing, path: defaultPath))
        XCTAssertNotNil(prepared.problem)
    }

    /// 用户自选目录不会被静默重建：删除后直接进入诊断状态。
    func testConfiguredWorkspaceIsNeverCreatedAndReportsMissing() {
        let fileSystem = FakeFileSystem()

        let prepared = WorkspaceDirectory.prepare(
            configuredPath: customPath,
            defaultPath: defaultPath,
            probe: fileSystem.probe
        )

        XCTAssertEqual(prepared, .unusable(problem: .missing, path: customPath))
        XCTAssertTrue(fileSystem.createdDirectories.isEmpty)
    }

    // MARK: - 可读修复提示

    func testProblemMessagesAreReadableAndNameThePathAndFix() {
        for (problem, keyword) in [
            (WorkspaceDirectoryProblem.missing, "不存在"),
            (.notDirectory, "不是目录"),
            (.notWritable, "不可写")
        ] {
            let message = problem.message(path: customPath, isDefaultLocation: false)
            XCTAssertTrue(message.contains(customPath), "\(problem) 提示缺少路径：\(message)")
            XCTAssertTrue(message.contains(keyword), "\(problem) 提示缺少关键词：\(message)")
            XCTAssertTrue(message.contains("设置"), "\(problem) 提示缺少修复入口：\(message)")
            XCTAssertTrue(message.contains("重新检测"), "\(problem) 提示缺少重新检测入口：\(message)")
        }

        XCTAssertTrue(
            WorkspaceDirectoryProblem.missing
                .message(path: defaultPath, isDefaultLocation: true)
                .contains("默认工作目录")
        )
    }

    func testStatusPageTextPointsAtTheWorkspaceAndItsDefault() {
        let validation = WorkspaceDirectoryValidation.unusable(problem: .notWritable, path: customPath)
        let text = WorkspaceDirectory.statusPageText(validation, defaultPath: defaultPath)

        XCTAssertTrue(text.contains("已暂停启动 Pi Web 服务"))
        XCTAssertTrue(text.contains(customPath))
        XCTAssertTrue(text.contains(defaultPath))
        XCTAssertTrue(text.contains("不可写"))
        XCTAssertFalse(WorkspaceDirectory.statusPageText(.usable(path: customPath), defaultPath: defaultPath).contains("已暂停"))
    }

    // MARK: - 设置窗口选择

    func testSelectionAcceptsAWritableDirectory() {
        let fileSystem = FakeFileSystem()
        fileSystem.makeWritableDirectory(customPath)

        let result = WorkspaceDirectory.Selection.apply(
            selectedPath: "  \(customPath)  ",
            configuration: configuration(),
            defaultPath: defaultPath,
            probe: fileSystem.probe
        )

        XCTAssertNil(result.error)
        XCTAssertEqual(result.configuration.workspacePath, customPath)
    }

    func testSelectionRejectsRelativeMissingAndUnwritablePathsWithoutChangingConfiguration() {
        let fileSystem = FakeFileSystem()
        let unwritable = "/tmp/PiWebDesktopTests/read-only-workspace"
        fileSystem.makeUnwritableDirectory(unwritable)
        let original = configuration(workspacePath: customPath)

        for rejected in ["relative/workspace", "/tmp/PiWebDesktopTests/does-not-exist", unwritable] {
            let result = WorkspaceDirectory.Selection.apply(
                selectedPath: rejected,
                configuration: original,
                defaultPath: defaultPath,
                probe: fileSystem.probe
            )
            XCTAssertNotNil(result.error, "\(rejected) 应被拒绝")
            XCTAssertEqual(result.configuration, original, "拒绝路径不应改写配置：\(rejected)")
        }

        XCTAssertTrue(
            WorkspaceDirectory.Selection.apply(
                selectedPath: unwritable,
                configuration: original,
                defaultPath: defaultPath,
                probe: fileSystem.probe
            ).error?.contains("不可写") == true
        )
        XCTAssertTrue(
            WorkspaceDirectory.Selection.apply(
                selectedPath: "relative/workspace",
                configuration: original,
                defaultPath: defaultPath,
                probe: fileSystem.probe
            ).error?.contains("绝对路径") == true
        )
    }

    func testSelectionWithEmptyPathFallsBackToTheDefaultDirectory() {
        let fileSystem = FakeFileSystem()

        let result = WorkspaceDirectory.Selection.apply(
            selectedPath: "   ",
            configuration: configuration(workspacePath: customPath),
            defaultPath: defaultPath,
            probe: fileSystem.probe
        )

        XCTAssertNil(result.error)
        XCTAssertEqual(result.configuration.workspacePath, "")
        XCTAssertEqual(
            WorkspaceDirectory.resolvedPath(configured: result.configuration.workspacePath, defaultPath: defaultPath),
            defaultPath
        )
    }
}
