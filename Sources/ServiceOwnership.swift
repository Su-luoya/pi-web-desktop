import CryptoKit
import Foundation

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
    /// `ps -o comm=` value observed immediately after the launch.
    var resolvedExecutable: String
    /// SHA-256 digest of the normalized launch arguments.
    var argumentsDigest: String
    /// TCP port the managed service was launched with.
    var port: Int
    /// Identifier of the app instance that launched the service.
    var instanceID: String
    /// ISO-8601 timestamp of the record write.
    var recordedAt: String

    /// Canonical digest of launch arguments.
    ///
    /// Each argument is length-prefixed and arguments are joined with U+001F, so
    /// the encoding stays unambiguous even when an argument contains the
    /// separator. `argv[0]` is intentionally excluded: the same configuration
    /// must produce the same digest regardless of how the executable path is
    /// spelled.
    static func argumentsDigest(of arguments: [String]) -> String {
        let canonical = arguments
            .map { "\($0.utf8.count):\($0)" }
            .joined(separator: "\u{1F}")
        let digest = SHA256.hash(data: Data(canonical.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

/// Facts read from `ps` for one live process.
struct ServiceProcessFacts: Equatable {
    var pid: pid_t
    var processGroupID: pid_t
    var launchedAt: String
    var resolvedExecutable: String
}

/// What the current app instance expects a valid record to contain.
struct ServiceOwnershipExpectation: Equatable {
    /// Digest of the arguments the current configuration would launch.
    var argumentsDigest: String
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

/// Decides whether an ownership record still describes a process this app
/// instance started.
///
/// Pure logic over injected probes, so the whole decision table can be
/// exercised with fake `ps` output and an injected liveness function.
enum ServiceOwnershipVerifier {
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
              !expectation.argumentsDigest.isEmpty,
              !expectation.instanceID.isEmpty,
              (1...65535).contains(expectation.port) else {
            return .external(.invalidRecord)
        }
        // A record from another app instance can never be adopted again, even
        // when the process is still the one this app launched.
        guard record.instanceID == expectation.instanceID else { return .external(.instanceMismatch) }
        guard record.port == expectation.port else { return .external(.portMismatch) }
        // The configuration changed since the launch: the running process no
        // longer matches what the app would start, so it is external.
        guard record.argumentsDigest == expectation.argumentsDigest else { return .external(.argumentsMismatch) }
        guard processIsAlive(record.pid) else { return .external(.processNotAlive) }
        // `ps` hides other users' processes; without facts nothing can be
        // proven, so no signal is allowed.
        guard let facts = facts(record.pid) else { return .external(.processFactsUnavailable) }
        guard facts.processGroupID == record.processGroupID else { return .external(.processGroupMismatch) }
        guard facts.launchedAt == record.launchedAt else { return .external(.launchTimeMismatch) }
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
        return try? decoder.decode(ServiceOwnershipRecord.self, from: data)
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
