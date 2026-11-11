import AppKit
import Foundation

// MARK: - 结果

/// 一次图标同步的结果。三种情况互斥，用于日志与测试断言。
enum WebAppIconSyncOutcome: Equatable {
    /// 没有可做的事：找不到 pi-web 包、取不到图标、或三个文件已是目标内容。
    case skipped(String)
    /// 实际写入的相对路径（相对 pi-web 包根）。
    case updated([String])
    /// 磁盘拒绝写入或渲染失败。
    case failed(String)
}

// MARK: - 接缝

/// 图标文件读写的接缝：生产环境用 `FileManager`，测试用内存替身。
protocol WebAppIconFileIO {
    func read(from url: URL) -> Data?
    @discardableResult
    func write(_ data: Data, to url: URL) -> Bool
}

/// 生产实现：原子写入，父目录按需创建。
struct SystemWebAppIconFileIO: WebAppIconFileIO {
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func read(from url: URL) -> Data? {
        fileManager.contents(atPath: url.path)
    }

    @discardableResult
    func write(_ data: Data, to url: URL) -> Bool {
        do {
            try fileManager.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }
}

/// 图标同步的调用面：`ServiceManager` 只依赖这一个方法，测试可整体替换。
protocol WebAppIconSyncing {
    func sync(executablePath: String?) -> WebAppIconSyncOutcome
}

// MARK: - 生产实现

/// 把桌面应用的图标同步成 pi-web 的 PWA 图标。
///
/// iOS「添加到主屏幕」取的只是 pi-web 自己那份 `/icons/apple-touch-icon.png`
/// （`PI_WEB_APP_NAME` 明确只改名字、不改图标），所以想和 Mac 图标一致，只能替换
/// 包里的文件。pi-web 是 `next start` 且 `cwd` 为包根，`public/` 在运行时按需
/// 读盘，替换后刷新页面即可生效，不必重启服务。
///
/// 代价是改动了全局安装的 npm 包：`npm install -g` 重新解包会把图标还原，因此
/// 每次启动服务前都幂等重放一遍，直接覆盖图标，不保留备份。
struct SystemWebAppIconSync: WebAppIconSyncing {
    /// 与依赖诊断共用同一个包名常量，避免两处判断漂移。
    static let packageName = InstallCommandManifest.piWebPackageName
    /// 向上找 `package.json` 的最大层数：符号链接解析后通常 1～2 层就能到包根。
    static let searchDepth = 8

    /// HTML 里 `apple-touch-icon`、`icon-192`、`icon-512` 引用的就是这三个文件
    /// （`public/` 根下没有同名副本，manifest 也没有引用别的尺寸）。
    static let targets: [(path: String, side: Int)] = [
        ("public/icons/apple-touch-icon.png", 180),
        ("public/icons/icon-192.png", 192),
        ("public/icons/icon-512.png", 512),
    ]

    private let files: WebAppIconFileIO
    private let probes: DependencyFileSystemProbing
    /// 图标来源：默认读 bundle 里的 `ApplicationIcon.icns`，测试注入固定图像。
    private let iconProvider: () -> NSImage?

    init(
        files: WebAppIconFileIO = SystemWebAppIconFileIO(),
        probes: DependencyFileSystemProbing = SystemDependencyFileSystemProbe(),
        iconProvider: @escaping () -> NSImage? = { NSImage(named: "ApplicationIcon") }
    ) {
        self.files = files
        self.probes = probes
        self.iconProvider = iconProvider
    }

    func sync(executablePath: String?) -> WebAppIconSyncOutcome {
        guard let executablePath, !executablePath.isEmpty else {
            return .skipped("找不到 pi-web 可执行文件")
        }
        guard let root = Self.packageRoot(executablePath: executablePath, probes: probes) else {
            return .skipped("无法从 \(executablePath) 定位 \(Self.packageName) 包目录")
        }
        guard let icon = iconProvider() else {
            return .skipped("读不到应用图标")
        }
        let rootURL = URL(fileURLWithPath: root)
        var written: [String] = []
        for target in Self.targets {
            guard let data = WebAppIconRendering.squarePNG(from: icon, side: target.side) else {
                return .failed("渲染 \(target.side)px 图标失败")
            }
            let url = rootURL.appendingPathComponent(target.path)
            // 幂等：内容逐字节相同就不写，避免每次启动都碰一遍磁盘。
            if files.read(from: url) == data { continue }
            guard files.write(data, to: url) else {
                return .failed("写入 \(target.path) 失败")
            }
            written.append(target.path)
        }
        return written.isEmpty ? .skipped("图标已是最新") : .updated(written)
    }

    /// 从可执行文件解析出的真实路径向上找包根，要求 `package.json` 的 `name` 完全匹配。
    static func packageRoot(
        executablePath: String,
        probes: DependencyFileSystemProbing
    ) -> String? {
        guard let resolved = probes.resolvedPath(atPath: executablePath) else { return nil }
        var directory = (resolved as NSString).deletingLastPathComponent
        var depth = 0
        while !directory.isEmpty, directory != "/", depth < searchDepth {
            let candidate = (directory as NSString).appendingPathComponent("package.json")
            if let text = probes.readText(atPath: candidate),
               let data = text.data(using: .utf8),
               let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
               (object["name"] as? String) == packageName {
                return directory
            }
            directory = (directory as NSString).deletingLastPathComponent
            depth += 1
        }
        return nil
    }
}

// MARK: - 渲染

/// 把带透明边距的 `icns` 图标摊平成 iOS 主屏图标。
///
/// 源图标是「深色圆角方块 + 大片透明边距」，iOS 又会在主屏上再套一层圆角遮罩：
/// 直接交过去会得到「白边包着一个深色小方块」。这里裁掉透明边距、用图标自身的
/// 底色铺满正方形，边角交给 iOS 处理，视觉重量才和旁边那些原生图标一致。
enum WebAppIconRendering {
    /// 判定「不透明」的 alpha 阈值：低于它按透明处理，避免抗锯齿边缘把边界撑大。
    static let alphaThreshold: UInt8 = 8
    /// 取图标中心这一块来铺满画布。源图标边缘有一圈高光描边，不论怎么裁，只要
    /// 把裁剩下的图重新铺满，描边就还在画布边缘绕一圈（裁得越多放大倍数越大，
    /// 位置几乎不变）。取中心 80% 放大后描边整圈跑到画布外，白字也顺势饱满一点。
    /// 前提是图标自带留白：mac 图标内容只占中部，切 10% 碰不到笔画。
    static let centreCropInset: CGFloat = 0.1
    /// 找不到合适的底色时的兜底（深灰），与深色图标并列时不刺眼。
    static let fallbackBackground: (red: CGFloat, green: CGFloat, blue: CGFloat) = (0.07, 0.07, 0.08)

    static func squarePNG(from source: NSImage, side: Int) -> Data? {
        guard side > 0, let flattened = flattened(source, side: side) else { return nil }
        guard let cgImage = flattened.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let rep = NSBitmapImageRep(cgImage: cgImage)
        return rep.representation(using: .png, properties: [:])
    }

    /// 裁掉透明边距、用底色铺满的方形图像。宽高都等于 `side`。
    static func flattened(_ source: NSImage, side: Int) -> NSImage? {
        guard side > 0,
              let cgSource = source.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let pixels = rgbaPixels(of: cgSource) else { return nil }
        let detected = opaqueBounds(in: pixels) ?? CGRect(
            x: 0, y: 0, width: pixels.width, height: pixels.height
        )
        let bounds = detected.insetBy(
            dx: detected.width * centreCropInset,
            dy: detected.height * centreCropInset
        )
        guard bounds.width >= 1, bounds.height >= 1,
              let cropped = cgSource.cropping(to: bounds),
              let context = CGContext(
                  data: nil,
                  width: side,
                  height: side,
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return nil }
        let background = backgroundColor(in: pixels, bounds: bounds)
        context.setFillColor(
            red: background.red,
            green: background.green,
            blue: background.blue,
            alpha: 1
        )
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        context.interpolationQuality = .high
        context.draw(cropped, in: CGRect(x: 0, y: 0, width: side, height: side))
        guard let output = context.makeImage() else { return nil }
        return NSImage(cgImage: output, size: NSSize(width: side, height: side))
    }

    // MARK: 像素采样

    struct Pixels {
        let data: [UInt8]
        let width: Int
        let height: Int
    }

    /// 把图像画进 RGBA 缓冲，统一成「每像素 4 字节、alpha 在最后」的布局。
    /// 坐标约定是左上角原点，与 `CGImage.cropping(to:)` 一致。
    static func rgbaPixels(of image: CGImage) -> Pixels? {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return nil }
        let count = width * height * 4
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: count)
        buffer.initialize(repeating: 0, count: count)
        defer {
            buffer.deallocate()
        }
        guard let context = CGContext(
            data: buffer,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        // 翻转成「左上角原点」再画：`CGImage.cropping(to:)` 用的是这套坐标，不翻转
        // 的话包围盒在 Y 方向是镜像的，内容偏上的图标会被裁到偏下。
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return Pixels(data: Array(UnsafeBufferPointer(start: buffer, count: count)), width: width, height: height)
    }

    /// 不透明像素的包围盒。全透明返回 nil，调用方回落到整张图。
    static func opaqueBounds(in pixels: Pixels) -> CGRect? {
        var minX = pixels.width
        var minY = pixels.height
        var maxX = -1
        var maxY = -1
        for y in 0..<pixels.height {
            let row = y * pixels.width * 4
            for x in 0..<pixels.width where pixels.data[row + x * 4 + 3] > alphaThreshold {
                if x < minX { minX = x }
                if x > maxX { maxX = x }
                if y < minY { minY = y }
                if y > maxY { maxY = y }
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }

    /// 图标自身的底色：在不透明区域内取「最暗的那几个采样点」，白色笔画亮度高，
    /// 因此不会被选中；全都不合格（例如纯白图标）时用兜底深灰。
    static func backgroundColor(in pixels: Pixels, bounds: CGRect) -> (red: CGFloat, green: CGFloat, blue: CGFloat) {
        let inset = 0.06
        let points: [(CGFloat, CGFloat)] = [
            (0.5, inset), (inset, inset), (1 - inset, inset),
            (inset, 0.5), (1 - inset, 0.5), (0.5, 1 - inset),
        ]
        var best: (luminance: CGFloat, red: CGFloat, green: CGFloat, blue: CGFloat)?
        for point in points {
            let x = Int(bounds.minX + bounds.width * point.0)
            let y = Int(bounds.minY + bounds.height * point.1)
            guard x >= 0, y >= 0, x < pixels.width, y < pixels.height else { continue }
            let offset = (y * pixels.width + x) * 4
            guard pixels.data[offset + 3] > 200 else { continue }
            let red = CGFloat(pixels.data[offset]) / 255
            let green = CGFloat(pixels.data[offset + 1]) / 255
            let blue = CGFloat(pixels.data[offset + 2]) / 255
            let luminance = 0.2126 * red + 0.7152 * green + 0.0722 * blue
            guard luminance < 0.5 else { continue }
            if best == nil || luminance < best!.luminance {
                best = (luminance, red, green, blue)
            }
        }
        guard let best else { return fallbackBackground }
        return (best.red, best.green, best.blue)
    }
}
