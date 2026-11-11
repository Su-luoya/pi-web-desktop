import AppKit
import XCTest

final class WebAppIconSyncTests: XCTestCase {
    // MARK: - 渲染

    /// 透明边距必须被填掉：iOS 会把透明区域显示成白色，直接交原图就是「白边包着
    /// 一个深色小方块」。
    func testFlattenedImageHasOpaqueCornersInIconColour() {
        guard let flattened = WebAppIconRendering.flattened(makeIcon(), side: 180) else {
            return XCTFail("渲染失败")
        }
        XCTAssertEqual(flattened.size, NSSize(width: 180, height: 180))
        guard let rep = bitmap(of: flattened) else { return XCTFail("取不到位图") }
        for point in [(2, 2), (177, 2), (2, 177), (177, 177)] {
            guard let colour = rep.colorAt(x: point.0, y: point.1) else {
                return XCTFail("取不到像素 \(point)")
            }
            XCTAssertEqual(colour.alphaComponent, 1, accuracy: 0.01, "角 \(point) 仍有透明")
            // 深色底，不是白底。
            XCTAssertLessThan(colour.brightnessComponent, 0.3, "角 \(point) 不是图标底色")
        }
    }

    /// 白色的 Pi 笔画必须还在中间：铺底色不能把内容盖掉。
    func testFlattenedImageKeepsWhiteForeground() {
        guard let flattened = WebAppIconRendering.flattened(makeIcon(), side: 180),
              let rep = bitmap(of: flattened),
              let centre = rep.colorAt(x: 90, y: 90) else {
            return XCTFail("渲染失败")
        }
        XCTAssertGreaterThan(centre.brightnessComponent, 0.9, "白色笔画丢了")
    }

    /// 每一档独立渲染，输出尺寸必须就是 HTML 里声明的那个尺寸。
    func testSquarePNGMatchesRequestedSide() {
        for side in [180, 192, 512] {
            guard let data = WebAppIconRendering.squarePNG(from: makeIcon(), side: side),
                  let rep = NSBitmapImageRep(data: data) else {
                return XCTFail("\(side)px 渲染失败")
            }
            XCTAssertEqual(rep.pixelsWide, side)
            XCTAssertEqual(rep.pixelsHigh, side)
        }
    }

    func testSquarePNGRejectsNonPositiveSide() {
        XCTAssertNil(WebAppIconRendering.squarePNG(from: makeIcon(), side: 0))
    }

    // MARK: - 包根定位

    func testPackageRootRequiresMatchingPackageName() {
        let probes = makeProbes(executable: "/opt/homebrew/bin/pi-web",
                                resolved: "/opt/homebrew/lib/node_modules/@agegr/pi-web/bin/pi-web.js",
                                packageJSON: #"{"name":"@agegr/pi-web","version":"0.15.0"}"#)
        XCTAssertEqual(
            SystemWebAppIconSync.packageRoot(executablePath: "/opt/homebrew/bin/pi-web", probes: probes),
            "/opt/homebrew/lib/node_modules/@agegr/pi-web"
        )
    }

    /// 同名但不是 pi-web（例如一个随手叫 pi-web 的项目）不能被当成包根。
    func testPackageRootIgnoresForeignPackages() {
        let probes = makeProbes(executable: "/opt/example/src/pi-web",
                                resolved: "/opt/example/src/pi-web/bin/pi-web.js",
                                packageJSON: #"{"name":"pi-web"}"#, root: "/opt/example/src/pi-web")
        XCTAssertNil(SystemWebAppIconSync.packageRoot(executablePath: "/opt/example/src/pi-web", probes: probes))
    }

    func testPackageRootReturnsNilForMissingExecutable() {
        let probes = FakeDependencyFileSystem()
        XCTAssertNil(SystemWebAppIconSync.packageRoot(executablePath: "/nope", probes: probes))
    }

    // MARK: - 同步

    func testSyncWritesOnlyTargetIcons() {
        let (sync, files, root) = makeSync()
        let originalPaths = Set(files.storage.keys)
        let outcome = sync.sync(executablePath: "/opt/homebrew/bin/pi-web")

        guard case let .updated(paths) = outcome else { return XCTFail("期望 updated，得到 \(outcome)") }
        XCTAssertEqual(paths, SystemWebAppIconSync.targets.map(\.path))
        for target in SystemWebAppIconSync.targets {
            let written = files.storage[root + "/" + target.path]
            XCTAssertNotNil(written)
            XCTAssertNotEqual(written, Data("original".utf8), "\(target.path) 没被替换")
        }
        XCTAssertEqual(Set(files.storage.keys), originalPaths, "只应覆盖目标图标，不应生成额外文件")
        XCTAssertEqual(files.writeCount, SystemWebAppIconSync.targets.count)
    }

    /// 每次启动都会跑一遍：内容没变就必须是空操作，不能反复碰磁盘。
    func testSyncIsIdempotent() {
        let (sync, files, _) = makeSync()
        _ = sync.sync(executablePath: "/opt/homebrew/bin/pi-web")
        let firstPass = files.storage
        let second = sync.sync(executablePath: "/opt/homebrew/bin/pi-web")
        XCTAssertEqual(second, .skipped("图标已是最新"))
        XCTAssertEqual(files.storage, firstPass, "第二次运行改动了文件")
        XCTAssertEqual(files.writeCount, SystemWebAppIconSync.targets.count,
                       "第二次运行仍在写盘（每个目标只写一次图标）")
    }

    func testSyncSkipsWhenExecutableIsUnknown() {
        let (sync, files, _) = makeSync()
        XCTAssertEqual(sync.sync(executablePath: nil), .skipped("找不到 pi-web 可执行文件"))
        XCTAssertEqual(sync.sync(executablePath: "/nowhere/pi-web"), .skipped("无法从 /nowhere/pi-web 定位 \(SystemWebAppIconSync.packageName) 包目录"))
        XCTAssertEqual(files.writeCount, 0, "跳过时不应写盘")
    }

    func testSyncReappliesIconsAfterPackageReinstallation() {
        let (sync, files, root) = makeSync()
        _ = sync.sync(executablePath: "/opt/homebrew/bin/pi-web")
        let syncedIcons = files.storage
        for target in SystemWebAppIconSync.targets {
            files.storage[root + "/" + target.path] = Data("reinstalled".utf8)
        }

        guard case .updated = sync.sync(executablePath: "/opt/homebrew/bin/pi-web") else {
            return XCTFail("期望重新同步图标")
        }
        XCTAssertEqual(files.storage, syncedIcons)
        XCTAssertEqual(files.writeCount, SystemWebAppIconSync.targets.count * 2)
    }

    func testSyncReportsWriteFailure() {
        let (sync, files, root) = makeSync()
        files.rejectedPaths = Set(SystemWebAppIconSync.targets.map { root + "/" + $0.path })
        guard case let .failed(reason) = sync.sync(executablePath: "/opt/homebrew/bin/pi-web") else {
            return XCTFail("期望 failed")
        }
        XCTAssertEqual(reason, "写入 public/icons/apple-touch-icon.png 失败")
    }

    // MARK: - 夹具

    private func makeSync() -> (SystemWebAppIconSync, MemoryIconFileIO, String) {
        let root = "/opt/homebrew/lib/node_modules/@agegr/pi-web"
        let probes = makeProbes(executable: "/opt/homebrew/bin/pi-web",
                                resolved: root + "/bin/pi-web.js",
                                packageJSON: #"{"name":"@agegr/pi-web"}"#)
        let files = MemoryIconFileIO()
        // 三个原文件都存在，覆盖替换与幂等两条路径。
        for target in SystemWebAppIconSync.targets {
            files.storage[root + "/" + target.path] = Data("original".utf8)
        }
        let sync = SystemWebAppIconSync(
            files: files,
            probes: probes,
            iconProvider: { self.makeIcon() }
        )
        return (sync, files, root)
    }

    private func makeProbes(
        executable: String,
        resolved: String,
        packageJSON: String,
        root: String = "/opt/homebrew/lib/node_modules/@agegr/pi-web"
    ) -> FakeDependencyFileSystem {
        let probes = FakeDependencyFileSystem()
        probes.executables.insert(executable)
        probes.resolvedPaths[executable] = resolved
        probes.files[root + "/package.json"] = packageJSON
        return probes
    }

    /// 深色圆角方块 + 中央白色小方块 + 大片透明边距，形状与真实的 `icns` 一致。
    private func makeIcon(size: CGFloat = 512) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            let body = rect.insetBy(dx: size * 0.18, dy: size * 0.18)
            NSColor(srgbRed: 0.08, green: 0.08, blue: 0.09, alpha: 1).setFill()
            NSBezierPath(roundedRect: body, xRadius: size * 0.08, yRadius: size * 0.08).fill()
            NSColor.white.setFill()
            NSRect(x: size * 0.42, y: size * 0.42, width: size * 0.16, height: size * 0.16).fill()
            return true
        }
    }

    private func bitmap(of image: NSImage) -> NSBitmapImageRep? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        return NSBitmapImageRep(cgImage: cgImage)
    }
}

// MARK: - 内存替身

private final class MemoryIconFileIO: WebAppIconFileIO {
    var storage: [String: Data] = [:]
    var rejectedPaths: Set<String> = []
    private(set) var writeCount = 0

    func read(from url: URL) -> Data? {
        storage[url.path]
    }

    func write(_ data: Data, to url: URL) -> Bool {
        guard !rejectedPaths.contains(url.path) else { return false }
        writeCount += 1
        storage[url.path] = data
        return true
    }
}
