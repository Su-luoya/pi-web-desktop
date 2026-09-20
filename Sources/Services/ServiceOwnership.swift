import CryptoKit
import Foundation

/// Where a recorded executable path came from.
///
/// `procPidPath` is the real binary image path from libproc; `psComm` is the
/// `ps -o comm=` fallback, which is weaker evidence because it reports the
/// command name rather than the resolved image.

/// Service ownership records, storage and item-by-item verification.

enum ServiceExecutableSource: String, Codable, Equatable {
    case procPidPath = "proc_pidpath"
    case psComm = "ps-comm"
}

/// Ownership record written when this app instance launches the managed
/// `pi-web` service.
///
/// A PID written to a file is not ownership: PIDs are recycled, ports are
/// reused by unrelated processes, and a command line that merely contains
/// "pi-web" is not proof. The record therefore stores process facts that are
/// re-checked against the live process before any signal is sent, so an
/// external service is never stopped.
struct ServiceOwnershipRecord: Codable, Equatable {
    /// Process identifier of the managed service. With `POSIX_SPAWN_SETPGROUP`
    /// the child is also the leader of its own process group.
    var pid: pid_t
    /// Process group created for the managed service. Stop signals target this
    /// group, never a single PID.
    var processGroupID: pid_t
    /// `ps -o lstart=` value observed immediately after the launch.
    var launchedAt: String
    /// Executable identity observed immediately after the launch: the real
    /// image path from `proc_pidpath`, or the `ps -o comm=` fallback.
    var resolvedExecutable: String
    /// Provenance of `resolvedExecutable` (`proc_pidpath` or `ps-comm`).
    var resolvedExecutableSource: ServiceExecutableSource
    /// SHA-256 digest of the normalized command text at launch time.
    var argumentsDigest: String
    /// TCP port the managed service was launched with.
    var port: Int
    /// Identifier of the app instance that launched the service.
    var instanceID: String
    /// ISO-8601 timestamp of the record write.
    var recordedAt: String

    /// Canonical command text for a launch: executable path plus arguments
    /// joined with single spaces, with whitespace runs collapsed.
    ///
    /// For a native executable this is exactly what `ps -o args=` reports. For
    /// npm/shebang installs the kernel replaces `argv[0]` with the interpreter
    /// (`node /opt/homebrew/bin/pi-web …`), so the launch path records the
    /// observed live text instead; this function is the fallback used when the
    /// live text cannot be read.
    static func commandText(executablePath: String, arguments: [String]) -> String {
        normalizedCommandText(([executablePath] + arguments).joined(separator: " "))
    }

    /// Whitespace-normalized form of a command line: leading/trailing whitespace
    /// removed and internal whitespace runs collapsed to single spaces. `ps`
    /// does not preserve quoting, so this is the strongest canonical form the
    /// live process text can be compared in.
    static func normalizedCommandText(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// SHA-256 of a command line, normalized the same way as the record.
    static func commandDigest(ofCommandText commandText: String) -> String {
        let digest = SHA256.hash(data: Data(normalizedCommandText(commandText).utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// SHA-256 of the canonical command text for an executable and arguments.
    static func commandDigest(executablePath: String, arguments: [String]) -> String {
        commandDigest(ofCommandText: commandText(executablePath: executablePath, arguments: arguments))
    }
}

/// Facts read from `ps`/libproc for one live process.
struct ServiceProcessFacts: Equatable {
    var pid: pid_t
    var processGroupID: pid_t
    var launchedAt: String
    var resolvedExecutable: String
    var resolvedExecutableSource: ServiceExecutableSource
    /// Normalized `ps -o args=` text; empty when the command line could not be
    /// read, which the verifier treats as a mismatch.
    var commandLine: String
}

/// What the current app instance expects a valid record to contain.
struct ServiceOwnershipExpectation: Equatable {
    /// Port the current configuration would launch on.
    var port: Int
    /// Random identifier of the running app instance.
    var instanceID: String
}

/// The first check that proved an ownership record wrong. Kept as a value so
/// the decision is testable and diagnosable without touching a real process.
enum ServiceOwnershipMismatch: String, Equatable {
    case invalidRecord
    case instanceMismatch
    case portMismatch
    case argumentsMismatch
    case processNotAlive
    case processFactsUnavailable
    case processGroupMismatch
    case launchTimeMismatch
    case executableMismatch
}

enum ServiceOwnershipVerdict: Equatable {
    /// The record matches this app instance and the live process.
    case managed
    /// The record is stale, foreign or cannot be verified: treat as external.
    case external(ServiceOwnershipMismatch)

    /// Mismatched records are removed from disk, unverifiable ones are kept.
    ///
    /// A transient `ps` failure must not destroy the only ownership proof, so
    /// `.processFactsUnavailable` keeps the record and simply refuses to claim
    /// ownership for that check.
    var shouldRemoveRecord: Bool {
        switch self {
        case .managed: return false
        case .external(.processFactsUnavailable): return false
        case .external: return true
        }
    }
}

/// 重启后的认领决策（GitHub #9）。
///
/// 应用重启时磁盘上可能留着上一次运行写的 `service-owner.json`。只有通过
/// `ServiceOwnershipVerifier` 逐项校验的进程组才可以继续被管理；记录缺失或校验
/// 失败一律按外部服务处理，不认领、不发信号、不改状态。
enum ServiceAdoption: Equatable {
    /// 校验通过：可以继续管理这个进程组。
    case adopt(ServiceOwnershipRecord)
    /// 校验失败或没有记录：只读的外部服务。
    case external(ServiceOwnershipMismatch)

    /// 认领到的记录；外部服务为 nil。
    var adoptedRecord: ServiceOwnershipRecord? {
        guard case .adopt(let record) = self else { return nil }
        return record
    }

    var isAdopted: Bool { adoptedRecord != nil }
}

/// Decides whether an ownership record still describes a process this app
/// instance started.
///
/// Pure logic over injected probes, so the whole decision table can be
/// exercised with fake `ps` output and an injected liveness function.
enum ServiceOwnershipVerifier {
    /// 记录 + 校验结果 → 认领决策（GitHub #9）。
    ///
    /// 没有记录，或校验结果是 `.managed` 却没有记录，都按“不能认领”处理：
    /// 认领必须有可复核的证据。
    static func adoption(
        record: ServiceOwnershipRecord?,
        verdict: ServiceOwnershipVerdict
    ) -> ServiceAdoption {
        guard let record, case .managed = verdict else {
            if case .external(let mismatch) = verdict { return .external(mismatch) }
            return .external(.invalidRecord)
        }
        return .adopt(record)
    }

    static func verify(
        record: ServiceOwnershipRecord,
        expectation: ServiceOwnershipExpectation,
        processIsAlive: (pid_t) -> Bool,
        facts: (pid_t) -> ServiceProcessFacts?
    ) -> ServiceOwnershipVerdict {
        guard record.pid > 1,
              record.processGroupID > 1,
              // The app only ever launches group leaders; any other record was
              // not written by this launch path.
              record.processGroupID == record.pid,
              !record.launchedAt.isEmpty,
              !record.resolvedExecutable.isEmpty,
              !record.argumentsDigest.isEmpty,
              !record.instanceID.isEmpty,
              (1...65535).contains(record.port),
              !expectation.instanceID.isEmpty,
              (1...65535).contains(expectation.port) else {
            return .external(.invalidRecord)
        }
        // A record from another app instance can never be adopted again, even
        // when the process is still the one this app launched.
        guard record.instanceID == expectation.instanceID else { return .external(.instanceMismatch) }
        guard record.port == expectation.port else { return .external(.portMismatch) }
        guard processIsAlive(record.pid) else { return .external(.processNotAlive) }
        // `ps` hides other users' processes; without facts nothing can be
        // proven, so no signal is allowed.
        guard let facts = facts(record.pid) else { return .external(.processFactsUnavailable) }
        guard facts.processGroupID == record.processGroupID else { return .external(.processGroupMismatch) }
        guard facts.launchedAt == record.launchedAt else { return .external(.launchTimeMismatch) }
        // Live command line: the recorded digest must match what the process
        // currently reports through `ps -o args=`. Empty or unparsable output
        // is a mismatch, not a pass.
        guard !facts.commandLine.isEmpty,
              ServiceOwnershipRecord.commandDigest(ofCommandText: facts.commandLine) == record.argumentsDigest else {
            return .external(.argumentsMismatch)
        }
        // When the executable path came from the `ps -o comm=` fallback it is
        // weak evidence on its own; the command-line digest above is what keeps
        // the verdict sound, so the path is still compared but never trusted
        // alone.
        guard facts.resolvedExecutable == record.resolvedExecutable else { return .external(.executableMismatch) }
        return .managed
    }
}

/// Persists the ownership record. Injected so tests can simulate a failed
/// write, which downgrades a launched process to "unhosted".
protocol ServiceOwnershipStoring: AnyObject {
    func loadRecord(from url: URL) -> ServiceOwnershipRecord?
    func save(_ record: ServiceOwnershipRecord, to url: URL) throws
    func removeRecord(at url: URL)
}

/// JSON file store used by the app. Decoding failures are treated as "no
/// record": an unreadable record is never an ownership proof.
final class FileServiceOwnershipStore: ServiceOwnershipStoring {
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder = encoder
        self.decoder = JSONDecoder()
    }

    func loadRecord(from url: URL) -> ServiceOwnershipRecord? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        do {
            return try decoder.decode(ServiceOwnershipRecord.self, from: data)
        } catch {
            // An undecodable record (for example one written by an older
            // format) is never an ownership proof; drop it instead of leaving
            // it behind forever. No signal is sent for the file's process.
            removeRecord(at: url)
            return nil
        }
    }

    func save(_ record: ServiceOwnershipRecord, to url: URL) throws {
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(record).write(to: url, options: .atomic)
    }

    func removeRecord(at url: URL) {
        try? fileManager.removeItem(at: url)
    }
}

/// How the app terminates a managed service.
///
/// There is deliberately no single-PID API: the app only signals the process
/// group of a verified record, so a recycled PID is never hit by accident and
/// helper processes of the service are covered as well.
protocol ServiceSignaling: AnyObject {
    /// Sends `signal` to the whole process group. Implementations must refuse
    /// non-positive group identifiers.
    func sendGroupSignal(_ signal: Int32, toProcessGroup processGroupID: pid_t)
    /// `kill(-pgid, 0)`: true while the group still has at least one member.
    func isProcessGroupAlive(_ processGroupID: pid_t) -> Bool
}

final class POSIXServiceSignaler: ServiceSignaling {
    func sendGroupSignal(_ signal: Int32, toProcessGroup processGroupID: pid_t) {
        guard processGroupID > 1 else { return }
        _ = kill(-processGroupID, signal)
    }

    func isProcessGroupAlive(_ processGroupID: pid_t) -> Bool {
        guard processGroupID > 1 else { return false }
        return kill(-processGroupID, 0) == 0
    }
}
