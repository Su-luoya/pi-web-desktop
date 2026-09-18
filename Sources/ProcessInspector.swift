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
///
/// This type only reports facts. The decision whether a process belongs to the
/// app lives in `ServiceOwnershipVerifier`, and no signal path may treat a
/// command line as ownership proof.
struct ProcessInspector {
    static let processCommand = "/bin/ps"
    static let listenerCommand = "/usr/sbin/lsof"

    private let runner: CommandRunning
    private let processIsAlive: (pid_t) -> Bool
    private let processExecutablePath: (pid_t) -> String?

    init(
        runner: CommandRunning = SystemCommandRunner(),
        processIsAlive: @escaping (pid_t) -> Bool = ProcessInspector.defaultProcessIsAlive,
        processExecutablePath: @escaping (pid_t) -> String? = ProcessInspector.defaultProcessExecutablePath
    ) {
        self.runner = runner
        self.processIsAlive = processIsAlive
        self.processExecutablePath = processExecutablePath
    }

    // MARK: - Pure parsing

    /// `kill(pid, 0)` liveness probe. PIDs 0 and 1 are never treated as app-owned.
    static func defaultProcessIsAlive(_ pid: pid_t) -> Bool {
        pid > 1 && kill(pid, 0) == 0
    }

    /// Real executable image path through libproc (`proc_pidpath`).
    ///
    /// This is stronger evidence than `ps -o comm=` and resolves the actual
    /// binary behind symlinks and shebang scripts. It only works for the
    /// current user's processes; other users' processes make it fail, which
    /// callers treat as "fall back to `ps -o comm=`".
    static func defaultProcessExecutablePath(_ pid: pid_t) -> String? {
        guard pid > 1 else { return nil }
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        let path = String(cString: buffer)
        return path.isEmpty ? nil : path
    }

    /// Parses a PID record file (`app.pid`, or the legacy `service.pid` while
    /// it is being removed). Invalid values and PIDs below 2 are rejected,
    /// matching the previous inline checks.
    static func parsePIDRecord(_ text: String?) -> pid_t? {
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard let pid = pid_t(trimmed), pid > 1 else { return nil }
        return pid
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

    /// Parses `ps -o pgid=` output. Values below 2 are rejected, matching the
    /// "never signal PID 0, 1 or a negative value" rule.
    static func parseProcessGroupID(_ output: String?) -> pid_t? {
        let trimmed = output?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard let processGroupID = pid_t(trimmed), processGroupID > 1 else { return nil }
        return processGroupID
    }

    /// Parses `ps -o lstart=` output. Whitespace runs are collapsed so the
    /// value is stable regardless of the column spacing `ps` chooses.
    static func parseProcessStartTime(_ output: String?) -> String? {
        let trimmed = output?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return nil }
        return trimmed.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// Parses `ps -o comm=` output: the executable path of a PID.
    static func parseResolvedExecutable(_ output: String?) -> String? {
        let trimmed = output?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Parses `ps -o args=` output: the command line the process reports.
    ///
    /// Whitespace runs are collapsed to single spaces, which is the same
    /// normalization used for the recorded digest. `ps` does not preserve
    /// quoting, so argument boundaries inside the text are not recoverable
    /// (see docs/security-ownership.md).
    static func parseCommandLine(_ output: String?) -> String? {
        let trimmed = output?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return nil }
        return trimmed.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    // MARK: - Commands

    func isProcessAlive(_ pid: pid_t) -> Bool {
        processIsAlive(pid)
    }

    /// Human readable command line for a PID, or "未知" when `ps` has nothing.
    func processDescription(of pid: pid_t) -> String {
        Self.parseProcessDescription(runner.run([Self.processCommand, "-o", "command=", "-p", "\(pid)"])) ?? "未知"
    }

    /// `ps -o pgid=` for a PID, or nil when `ps` cannot read the process (for
    /// example another user's process without `sudo`).
    func processGroupID(of pid: pid_t) -> pid_t? {
        Self.parseProcessGroupID(runner.run([Self.processCommand, "-o", "pgid=", "-p", "\(pid)"]))
    }

    /// `ps -o lstart=` for a PID, or nil when `ps` cannot read the process.
    /// The value has a one-second granularity, which limits PID-reuse
    /// detection (see docs/security-ownership.md).
    func processLaunchTime(of pid: pid_t) -> String? {
        Self.parseProcessStartTime(runner.run([Self.processCommand, "-o", "lstart=", "-p", "\(pid)"]))
    }

    /// `ps -o comm=` for a PID, or nil when `ps` cannot read the process.
    func resolvedExecutable(of pid: pid_t) -> String? {
        Self.parseResolvedExecutable(runner.run([Self.processCommand, "-o", "comm=", "-p", "\(pid)"]))
    }

    /// `ps -o args=` for a PID (normalized), or nil when `ps` cannot read the
    /// process or reports nothing. This is the live argv the ownership record
    /// is verified against.
    func commandLine(of pid: pid_t) -> String? {
        Self.parseCommandLine(runner.run([Self.processCommand, "-o", "args=", "-p", "\(pid)"]))
    }

    /// Executable identity for a PID: `proc_pidpath` first, `ps -o comm=` as a
    /// fallback. The provenance is returned with the path so records can mark
    /// weak evidence.
    func resolvedExecutableInfo(of pid: pid_t) -> (path: String, source: ServiceExecutableSource)? {
        if let path = processExecutablePath(pid), !path.isEmpty {
            return (path, .procPidPath)
        }
        guard let fallback = resolvedExecutable(of: pid) else { return nil }
        return (fallback, .psComm)
    }

    /// Facts needed to verify an ownership record.
    ///
    /// `pgid`, `lstart` and an executable identity are required; `commandLine`
    /// may be empty when `ps -o args=` yields nothing, and the verifier then
    /// treats the record as a mismatch (an empty argv is not ownership proof).
    func processFacts(of pid: pid_t) -> ServiceProcessFacts? {
        guard pid > 1,
              let processGroupID = processGroupID(of: pid),
              let launchedAt = processLaunchTime(of: pid),
              let executable = resolvedExecutableInfo(of: pid) else { return nil }
        return ServiceProcessFacts(
            pid: pid,
            processGroupID: processGroupID,
            launchedAt: launchedAt,
            resolvedExecutable: executable.path,
            resolvedExecutableSource: executable.source,
            commandLine: commandLine(of: pid) ?? ""
        )
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
}
