/// Read-only probes for the file system, ports, system facts and timed commands.

import Darwin
import Foundation

// MARK: - 文件系统与系统探针

/// 依赖诊断的文件系统探针。
///
/// 诊断只通过这个协议读盘；测试注入假实现，因此不会触碰真实用户目录、npm
/// 缓存或网络。
protocol DependencyFileSystemProbing {
    func isExecutableFile(atPath path: String) -> Bool
    /// 一层的符号链接目标；不是符号链接或读取失败时返回 nil。
    func symlinkDestination(atPath path: String) -> String?
    /// 完整解析符号链接后的真实路径；路径不存在时返回 nil。
    func resolvedPath(atPath path: String) -> String?
    /// 读取 UTF-8 文本；不存在或不可读时返回 nil。
    func readText(atPath path: String) -> String?
    func homeDirectoryPath() -> String
    /// 路径是否存在且是目录；探针无法判定时返回 nil。只回答存在性。
    func directoryExists(atPath path: String) -> Bool?
    /// 目录（或文件）是否可读；探针无法判定时返回 nil。
    /// 只读权限位，不列目录、不读取任何文件内容。
    func isReadableDirectory(atPath path: String) -> Bool?
}

/// 生产实现：只使用 `FileManager` 和标准 URL 解析，Apple 系统框架以内。
struct SystemDependencyFileSystemProbe: DependencyFileSystemProbing {
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func isExecutableFile(atPath path: String) -> Bool {
        fileManager.isExecutableFile(atPath: path)
    }

    func symlinkDestination(atPath path: String) -> String? {
        try? fileManager.destinationOfSymbolicLink(atPath: path)
    }

    func resolvedPath(atPath path: String) -> String? {
        guard fileManager.fileExists(atPath: path) else { return nil }
        return URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }

    func readText(atPath path: String) -> String? {
        guard let data = fileManager.contents(atPath: path) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func homeDirectoryPath() -> String {
        fileManager.homeDirectoryForCurrentUser.path
    }

    func directoryExists(atPath path: String) -> Bool? {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory) else { return false }
        return isDirectory.boolValue
    }

    /// `isReadableFile` 只查询访问权限，不会列出目录内容；Pi 配置目录因此只被
    /// 判断“存在/可读”，认证文件内容永远不会进入诊断。
    func isReadableDirectory(atPath path: String) -> Bool? {
        guard fileManager.fileExists(atPath: path) else { return nil }
        return fileManager.isReadableFile(atPath: path)
    }
}

/// 默认服务端口的本地可用性探针。
///
/// 只在本机创建、绑定并关闭一个 TCP socket：不连接任何远端、不发送数据、
/// 不调用外部命令、不解析域名。返回值语义：
/// - `true`：绑定成功，端口可用；
/// - `false`：`EADDRINUSE`，端口已被其他进程占用；
/// - `nil`：无法判定（主机不是字面量地址、端口非法或其他绑定错误）。
protocol DependencyPortProbing {
    func isPortAvailable(host: String, port: Int) -> Bool?
}

/// 生产实现：`bind(2)` 一个 loopback/字面量地址上的 TCP socket。
struct SystemDependencyPortProbe: DependencyPortProbing {
    func isPortAvailable(host: String, port: Int) -> Bool? {
        guard (1...65535).contains(port) else { return nil }
        let address = Self.normalizedHost(host)

        var ipv4 = in_addr()
        if inet_pton(AF_INET, address, &ipv4) == 1 {
            var socketAddress = sockaddr_in()
            socketAddress.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            socketAddress.sin_family = sa_family_t(AF_INET)
            socketAddress.sin_port = in_port_t(UInt16(port).bigEndian)
            socketAddress.sin_addr = ipv4
            return Self.canBind(family: AF_INET, address: &socketAddress, length: socklen_t(MemoryLayout<sockaddr_in>.size))
        }

        var ipv6 = in6_addr()
        if inet_pton(AF_INET6, address, &ipv6) == 1 {
            var socketAddress = sockaddr_in6()
            socketAddress.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            socketAddress.sin6_family = sa_family_t(AF_INET6)
            socketAddress.sin6_port = in_port_t(UInt16(port).bigEndian)
            socketAddress.sin6_addr = ipv6
            return Self.canBind(family: AF_INET6, address: &socketAddress, length: socklen_t(MemoryLayout<sockaddr_in6>.size))
        }

        // 主机名（例如 `localhost`）不做 DNS 解析：无法判定时不猜测端口状态。
        return nil
    }

    private static func normalizedHost(_ host: String) -> String {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == "localhost" { return "127.0.0.1" }
        return trimmed
    }

    private static func canBind<Address>(family: Int32, address: inout Address, length: socklen_t) -> Bool? {
        let descriptor = socket(family, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, length) }
        }
        if result == 0 { return true }
        return errno == EADDRINUSE ? false : nil
    }
}

/// 系统探针：处理器架构与 macOS 版本。测试注入固定值。
struct DependencySystemProbe {
    var architecture: () -> String
    var operatingSystemVersion: () -> OperatingSystemVersion

    static let live = DependencySystemProbe(
        architecture: { machineArchitecture() },
        operatingSystemVersion: { ProcessInfo.processInfo.operatingSystemVersion }
    )

    /// `uname(2)` 的 machine 字段；Apple Silicon 上为 `arm64`。
    static func machineArchitecture() -> String {
        var name = utsname()
        guard uname(&name) == 0 else { return "unknown" }
        // 在闭包内复制出有效字节，闭包外只使用这份副本。
        let bytes = withUnsafeBytes(of: &name.machine) { raw -> [UInt8] in
            Array(raw.prefix { $0 != 0 })
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}

// MARK: - 路径脱敏

/// Home 路径脱敏：只把注入的 Home 前缀替换为 `~`，其他路径原样保留。
struct DependencyPathRedactor {
    let homeDirectory: String

    init(homeDirectory: String) {
        var normalized = homeDirectory
        while normalized.count > 1 && normalized.hasSuffix("/") {
            normalized.removeLast()
        }
        self.homeDirectory = normalized
    }

    func redact(_ path: String) -> String {
        guard !homeDirectory.isEmpty, homeDirectory != "/" else { return path }
        if path == homeDirectory { return "~" }
        if path.hasPrefix(homeDirectory + "/") {
            return "~/" + String(path.dropFirst(homeDirectory.count + 1))
        }
        return path
    }
}
