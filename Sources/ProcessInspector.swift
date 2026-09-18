import Foundation

/// Runs a command line tool for the app. The protocol exists so process checks
/// can be exercised with canned `ps`/`lsof` output instead of real processes.
protocol CommandRunning {
    /// Returns standard output when the command exits 0; nil when it cannot be
    /// launched or exits with a non-zero status.
    func run(_ arguments: [String]) -> String?
}

/// Production runner. Same semantics as the previous AppDelegate helper: stdout
/// is captured, stderr is discarded and a non-zero exit status yields nil.
struct SystemCommandRunner: CommandRunning {
    func run(_ arguments: [String]) -> String? {
        guard let executable = arguments.first else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = Array(arguments.dropFirst())
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
    }
}

/// Process, listener and managed-instance inspection.
///
/// Commands are executed through the injected `CommandRunning`; the parsing
/// rules are pure static functions so they can be tested with fake `ps`/`lsof`
/// output. Liveness checks are injectable for the same reason.
struct ProcessInspector {
    static let processCommand = "/bin/ps"
    static let listenerCommand = "/usr/sbin/lsof"
    static let commandMarker = "pi-web"

    private let runner: CommandRunning
    private let fileManager: FileManager
    private let processIsAlive: (pid_t) -> Bool

    init(
        runner: CommandRunning = SystemCommandRunner(),
        fileManager: FileManager = .default,
        processIsAlive: @escaping (pid_t) -> Bool = ProcessInspector.defaultProcessIsAlive
    ) {
        self.runner = runner
        self.fileManager = fileManager
        self.processIsAlive = processIsAlive
    }

    // MARK: - Pure parsing

    /// `kill(pid, 0)` liveness probe. PIDs 0 and 1 are never treated as app-owned.
    static func defaultProcessIsAlive(_ pid: pid_t) -> Bool {
        pid > 1 && kill(pid, 0) == 0
    }

    /// Parses a PID record file (service.pid / app.pid). Invalid values and PIDs
    /// below 2 are rejected, matching the previous inline checks.
    static func parsePIDRecord(_ text: String?) -> pid_t? {
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard let pid = pid_t(trimmed), pid > 1 else { return nil }
        return pid
    }

    /// Parses `ps -o ppid=` output. Unknown or malformed output means "no parent"
    /// (0), which callers already treat as an unusable candidate.
    static func parseParentPID(_ output: String?) -> pid_t {
        let trimmed = output?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return pid_t(trimmed) ?? 0
    }

    /// Parses `lsof -t` output: the first line is the listener, later lines are
    /// ignored exactly like the previous `split(...).first` implementation.
    static func parseListenerPID(_ output: String?) -> pid_t? {
        let firstLine = output?
            .split(whereSeparator: { $0.isNewline })
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard let pid = pid_t(firstLine), pid > 1 else { return nil }
        return pid
    }

    /// `ps -o command=` output without surrounding whitespace; nil when empty.
    static func parseProcessDescription(_ output: String?) -> String? {
        let trimmed = output?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    /// A command is an app-managed pi-web process when its `ps` command line
    /// contains "pi-web" (case-insensitive).
    static func isPiWebCommand(_ output: String?) -> Bool {
        (output ?? "").lowercased().contains(commandMarker)
    }

    // MARK: - Commands

    func isProcessAlive(_ pid: pid_t) -> Bool {
        processIsAlive(pid)
    }

    func isPiWebProcess(_ pid: pid_t) -> Bool {
        Self.isPiWebCommand(runner.run([Self.processCommand, "-o", "command=", "-p", "\(pid)"]))
    }

    /// Human readable command line for a PID, or "未知" when `ps` has nothing.
    func processDescription(of pid: pid_t) -> String {
        Self.parseProcessDescription(runner.run([Self.processCommand, "-o", "command=", "-p", "\(pid)"])) ?? "未知"
    }

    func parentProcess(of pid: pid_t) -> pid_t {
        Self.parseParentPID(runner.run([Self.processCommand, "-o", "ppid=", "-p", "\(pid)"]))
    }

    /// PID listening on the configured TCP port, when there is one.
    func listenerPID(port: Int) -> pid_t? {
        Self.parseListenerPID(runner.run([Self.listenerCommand, "-nP", "-t", "-iTCP:\(port)", "-sTCP:LISTEN"]))
    }

    /// Diagnostics form of `listenerPID(port:)`: "无" when no listener exists.
    func listenerPIDDescription(port: Int) -> String {
        listenerPID(port: port).map(String.init) ?? "无"
    }

    /// `ps` description of the current listener, or "无" when no listener exists.
    func listenerProcessDescription(port: Int) -> String {
        guard let pid = listenerPID(port: port) else { return "无" }
        return processDescription(of: pid)
    }

    /// Owned service PID recorded in a PID file. Stale, unparsable or foreign
    /// records are removed and reported as nil; the running child process is
    /// tracked by AppDelegate and checked before this method is used.
    func managedServicePID(pidFileURL: URL) -> pid_t? {
        let record = try? String(contentsOf: pidFileURL, encoding: .utf8)
        guard let pid = Self.parsePIDRecord(record), processIsAlive(pid), isPiWebProcess(pid) else {
            try? fileManager.removeItem(at: pidFileURL)
            return nil
        }
        return pid
    }
}
