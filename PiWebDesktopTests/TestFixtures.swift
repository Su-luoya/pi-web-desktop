import Foundation
import XCTest

// 共享测试夹具：多条更新路径、多个假文件系统都要用的替身与等待原语。
// 某条路径专属的替身（RecordingRunner、World 等）留在各自的用例文件里。

/// 线程安全的单槽盒子：真执行器在内部队列回调，测试从这个盒子里取结果。
final class Locked<T> {
    private let lock = NSLock()
    private var storage: T?

    var value: T? {
        get { lock.lock(); defer { lock.unlock() }; return storage }
        set { lock.lock(); storage = newValue; lock.unlock() }
    }
}

/// 轮询等待：被测代码自己决定回调跑在哪个队列，所以不用 `XCTestExpectation`，
/// 而是让主线程继续跑 RunLoop 直到值出现或超时。
func waitForValue<T>(_ box: Locked<T>, timeout: TimeInterval) -> T? {
    pollUntil(timeout: timeout) { box.value != nil }
    return box.value
}

/// 轮询等待某个路径出现（子进程留下的标记文件、被改写的文件）。
func waitForFile(_ path: String, timeout: TimeInterval) -> Bool {
    pollUntil(timeout: timeout) { FileManager.default.fileExists(atPath: path) }
}

/// 轮询等待条件成立；返回最后一次判断的结果。
@discardableResult
func pollUntil(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition(), Date() < deadline {
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
    }
    return condition()
}

/// 可执行的假命令脚本：只写内容，不执行真实命令。
func makeExecutableScript(in directory: URL, named name: String = "pi", body: String) throws -> String {
    let url = directory.appendingPathComponent(name)
    try ("#!/bin/sh\n" + body + "\n").write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    return url.path
}

/// 日志接收器：三条更新路径的协调器都只要求 `append(String)`。
final class LogSink {
    private(set) var messages: [String] = []

    func append(_ message: String) { messages.append(message) }

    var text: String { messages.joined(separator: "\n") }
}

/// 显式登记的假文件系统：只认识测试加进去的可执行文件、文本文件与目录。
/// 依赖诊断与首次启动诊断共用同一份，避免协议加一个方法就要改两处。
final class FakeDependencyFileSystem: DependencyFileSystemProbing {
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

/// 只关心 `kind`/`status` 的诊断项构造器（其余字段保持“未知”）。
func dependencyFinding(
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
