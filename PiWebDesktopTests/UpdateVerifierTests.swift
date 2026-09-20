import Darwin
import XCTest

/// 更新验证器的独立边界测试（GitHub #120 / T-3，GitHub #121 / F4）。
///
/// 只测验证器与探针的直接调用面：文件上界、锁文件条目的唯一性与版本基准、
/// 隐藏锁文件与上层目录的查找顺序，以及非常规文件（FIFO）不能打开。
/// 集成路径（协调器、历史、降级）仍在 `UpdateTransactionTests.swift`；
/// 已有用例不搬运，避免无谓的 90 KB 文件手术。
final class UpdateVerifierTests: XCTestCase {

    private let packageName = "pi-extension-boundary-fixture"

    // MARK: - 夹具

    private func tempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("update-verifier-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func integrityValue(_ filler: Character = "A") -> String {
        "sha512-" + String(repeating: String(filler), count: 86)
    }

    private func lockfileData(
        packages: [String: Any]? = nil,
        dependencies: [String: Any]? = nil
    ) throws -> Data {
        var object: [String: Any] = [:]
        if let packages { object["packages"] = packages }
        if let dependencies { object["dependencies"] = dependencies }
        return try JSONSerialization.data(withJSONObject: object)
    }

    @discardableResult
    private func writeLockfile(
        packages: [String: Any]? = nil,
        dependencies: [String: Any]? = nil,
        in directory: URL,
        name: String = "package-lock.json"
    ) throws -> String {
        let url = directory.appendingPathComponent(name)
        try lockfileData(packages: packages, dependencies: dependencies).write(to: url)
        return url.path
    }

    // MARK: - 锁文件条目

    /// 精确路径 `node_modules/<包名>` 优先于任何嵌套的同名条目。
    func testIntegrityPrefersTheExactNodeModulesPath() throws {
        let directory = try tempDirectory()
        let exact = integrityValue("A")
        let nested = integrityValue("B")
        let path = try writeLockfile(
            packages: [
                "node_modules/\(packageName)": ["version": "1.0.0", "integrity": exact],
                "node_modules/host/node_modules/\(packageName)": ["version": "1.0.0", "integrity": nested]
            ],
            in: directory
        )
        XCTAssertEqual(
            UpdateArtifactProbe.readIntegrityValue(
                atLockfilePath: path,
                packageName: packageName,
                packageVersion: "1.0.0"
            ),
            exact
        )
    }

    /// 同名条目出现多次且没有精确路径时判为歧义：不猜，按“未获取”处理。
    func testAmbiguousNestedEntriesAreRejected() throws {
        let directory = try tempDirectory()
        let path = try writeLockfile(
            packages: [
                "node_modules/host-a/node_modules/\(packageName)": [
                    "version": "1.0.0",
                    "integrity": integrityValue("A")
                ],
                "node_modules/host-b/node_modules/\(packageName)": [
                    "version": "1.0.0",
                    "integrity": integrityValue("B")
                ]
            ],
            in: directory
        )
        XCTAssertNil(UpdateArtifactProbe.readIntegrityValue(
            atLockfilePath: path,
            packageName: packageName,
            packageVersion: "1.0.0"
        ))
    }

    /// 条目登记的版本必须与比较基准一致；基准未知（nil）时不采用带版本的条目。
    func testIntegrityEntryVersionMustMatchTheComparisonBaseline() throws {
        let directory = try tempDirectory()
        let integrity = integrityValue("C")
        let path = try writeLockfile(
            packages: ["node_modules/\(packageName)": ["version": "1.0.0", "integrity": integrity]],
            in: directory
        )
        XCTAssertEqual(
            UpdateArtifactProbe.readIntegrityValue(
                atLockfilePath: path,
                packageName: packageName,
                packageVersion: "1.0.0"
            ),
            integrity
        )
        XCTAssertNil(UpdateArtifactProbe.readIntegrityValue(
            atLockfilePath: path,
            packageName: packageName,
            packageVersion: "2.0.0"
        ))
        XCTAssertNil(UpdateArtifactProbe.readIntegrityValue(
            atLockfilePath: path,
            packageName: packageName
        ))
    }

    /// 没有 `packages` 段时退回 `dependencies`（npm 6 形状），版本规则相同。
    func testDependenciesFallbackIsUsedWhenPackagesIsAbsent() throws {
        let directory = try tempDirectory()
        let integrity = integrityValue("D")
        let path = try writeLockfile(
            dependencies: [packageName: ["version": "1.0.0", "integrity": integrity]],
            in: directory
        )
        XCTAssertEqual(
            UpdateArtifactProbe.readIntegrityValue(
                atLockfilePath: path,
                packageName: packageName,
                packageVersion: "1.0.0"
            ),
            integrity
        )
        XCTAssertNil(UpdateArtifactProbe.readIntegrityValue(
            atLockfilePath: path,
            packageName: packageName,
            packageVersion: "2.0.0"
        ))
    }

    /// 形状不合法的 `integrity` 一律当作“未获取”，不写进指纹。
    func testMalformedIntegrityShapeIsTreatedAsMissing() throws {
        let directory = try tempDirectory()
        let malformed = [
            "sha999-\(String(repeating: "A", count: 20))",   // 未知算法
            "sha512-!!!not-base64!!!",                        // 非 base64 字符
            "sha512-",                                        // 空载荷
            "sha512-\(String(repeating: "A", count: 400))",    // 超出长度上限
            "no-separator"                                    // 缺算法分隔
        ]
        for (index, value) in malformed.enumerated() {
            let path = try writeLockfile(
                packages: ["node_modules/\(packageName)": ["version": "1.0.0", "integrity": value]],
                in: directory,
                name: "package-lock-\(index).json"
            )
            XCTAssertNil(
                UpdateArtifactProbe.readIntegrityValue(
                    atLockfilePath: path,
                    packageName: packageName,
                    packageVersion: "1.0.0"
                ),
                "\(value) 不应被当作可用完整性值"
            )
        }
    }

    // MARK: - 查找范围

    /// 向上查找覆盖 npm 7+ 的隐藏锁文件 `node_modules/.package-lock.json`；
    /// 更近的锁文件优先于更上层无关的锁文件。
    func testNpmIntegrityPrefersTheNearestLockfileAndFindsHiddenOnes() throws {
        let directory = try tempDirectory()
        let packageDirectory = directory
            .appendingPathComponent("lib/node_modules/\(packageName)", isDirectory: true)
        let binaryDirectory = packageDirectory.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: binaryDirectory, withIntermediateDirectories: true)
        let executable = binaryDirectory.appendingPathComponent("pi-extension-boundary-fixture")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        let hidden = integrityValue("E")
        try lockfileData(packages: [
            "node_modules/\(packageName)": ["version": "1.0.0", "integrity": hidden]
        ]).write(to: directory.appendingPathComponent("lib/node_modules/.package-lock.json"))
        // 上层的无关锁文件更近不到，但会被先遇到；只有包名匹配才采用。
        try lockfileData(packages: [
            "node_modules/unrelated-package": ["version": "1.0.0", "integrity": integrityValue("F")]
        ]).write(to: directory.appendingPathComponent("package-lock.json"))

        XCTAssertEqual(
            UpdateArtifactProbe.readNpmIntegrity(
                executablePath: executable.path,
                packageName: packageName,
                fingerprintVersion: "1.0.0"
            ),
            hidden
        )
        XCTAssertNil(UpdateArtifactProbe.readNpmIntegrity(
            executablePath: executable.path,
            packageName: "another-package",
            fingerprintVersion: "1.0.0"
        ))
    }

    /// 只有无关条目时返回“未获取”，不要把别的包的完整性当成本包的。
    func testUnrelatedLockfilesAreNotMatched() throws {
        let directory = try tempDirectory()
        let binaryDirectory = directory.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: binaryDirectory, withIntermediateDirectories: true)
        let executable = binaryDirectory.appendingPathComponent("pi-extension-boundary-fixture")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
        try lockfileData(packages: [
            "node_modules/unrelated-package": ["version": "1.0.0", "integrity": integrityValue("F")]
        ]).write(to: directory.appendingPathComponent("package-lock.json"))

        XCTAssertNil(UpdateArtifactProbe.readNpmIntegrity(
            executablePath: executable.path,
            packageName: packageName,
            fingerprintVersion: "1.0.0"
        ))
    }

    // MARK: - 非常规文件（F4，GitHub #121）

    /// FIFO 不能被无超时地打开：探针按“不可读”处理，不阻塞、不读取。
    func testProbeTreatsFIFOAsUnreadable() throws {
        let directory = try tempDirectory()
        let fifo = directory.appendingPathComponent("package.json")
        XCTAssertEqual(mkfifo(fifo.path, 0o644), 0, "构造 FIFO 夹具失败")
        XCTAssertNotEqual(UpdateArtifactProbe.fileType(atPath: fifo.path), .typeRegular)
        XCTAssertNil(UpdateArtifactProbe.readPackageName(atPackageJSONPath: fifo.path))
        XCTAssertNil(UpdateArtifactProbe.readBoundedData(atPath: fifo.path, maximumSize: 1024))
    }

    /// 符号链接指向常规文件时仍要能读（正常的 npm 链接布局不能被误伤）。
    func testProbeReadsThroughSymlinkToRegularFile() throws {
        let directory = try tempDirectory()
        let target = directory.appendingPathComponent("real-package.json")
        try Data("{\"name\":\"\(packageName)\",\"version\":\"1.0.0\"}".utf8).write(to: target)
        let link = directory.appendingPathComponent("package.json")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: target.path)

        XCTAssertEqual(UpdateArtifactProbe.fileType(atPath: link.path), .typeSymbolicLink)
        XCTAssertEqual(UpdateArtifactProbe.readPackageName(atPackageJSONPath: link.path), packageName)
        XCTAssertEqual(
            UpdateArtifactProbe.readBoundedData(atPath: link.path, maximumSize: 4096),
            Data("{\"name\":\"\(packageName)\",\"version\":\"1.0.0\"}".utf8)
        )
    }
}
