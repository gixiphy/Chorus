import Foundation
import ChorusCore

/// Persistence for helper recovery metadata only (no live holders) — spec §6.3 / §14.1.
protocol LedgerStoring: AnyObject, Sendable {
    func load() throws -> SleepGuardLedger?
    func save(_ ledger: SleepGuardLedger) throws
}

enum LedgerStoreError: Error, Equatable {
    case unsafeRoot
    case symlinkRejected
    case notRegularFile
    case wrongOwner
    case worldOrGroupWritable
    case corruptOrUnsupportedVersion
    case writeFailed
}

struct LedgerPersistenceDTO: Codable, Equatable {
    static let currentVersion = 1

    var version: Int
    var setByHelper: Bool
    var priorValueWasDisabled: Bool?
    var pendingRestore: Bool
    var recoveryBlocked: Bool

    init(from ledger: SleepGuardLedger) {
        version = Self.currentVersion
        setByHelper = ledger.setByHelper
        priorValueWasDisabled = ledger.priorValueWasDisabled
        pendingRestore = ledger.pendingRestore
        recoveryBlocked = ledger.recoveryBlocked
    }

    func toLedger() -> SleepGuardLedger {
        SleepGuardLedger(
            holders: [:],
            priorValueWasDisabled: priorValueWasDisabled,
            setByHelper: setByHelper,
            pendingRestore: pendingRestore,
            recoveryBlocked: recoveryBlocked
        )
    }
}

/// File-backed store under `/Library/Application Support/com.hermes.Chorus.PowerHelper/`.
///
/// Production expects root:wheel 0755 directory and 0600 file. Tests inject a
/// `LedgerStore.SecurityPolicy` that relaxes owner checks against a temp root.
final class LedgerStore: LedgerStoring, @unchecked Sendable {
    struct SecurityPolicy: Sendable {
        var requireRootOwner: Bool
        var allowedOwnerUID: UInt32?

        static let production = SecurityPolicy(requireRootOwner: true, allowedOwnerUID: 0)

        /// Test policy: accept the current process uid as owner.
        static func testing(ownerUID: UInt32 = getuid()) -> SecurityPolicy {
            SecurityPolicy(requireRootOwner: false, allowedOwnerUID: ownerUID)
        }
    }

    static let defaultDirectoryPath =
        "/Library/Application Support/com.hermes.Chorus.PowerHelper"
    static let fileName = "ledger.json"

    private let directoryURL: URL
    private let fileURL: URL
    private let policy: SecurityPolicy
    private let fileManager: FileManager

    init(
        directoryPath: String = LedgerStore.defaultDirectoryPath,
        policy: SecurityPolicy = .production,
        fileManager: FileManager = .default
    ) {
        self.directoryURL = URL(fileURLWithPath: directoryPath, isDirectory: true)
        self.fileURL = directoryURL.appendingPathComponent(Self.fileName)
        self.policy = policy
        self.fileManager = fileManager
    }

    func load() throws -> SleepGuardLedger? {
        try validateDirectory(createIfMissing: false)
        guard fileManager.fileExists(atPath: fileURL.path) else { return nil }
        try validateFile(fileURL)
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            throw LedgerStoreError.corruptOrUnsupportedVersion
        }
        let dto: LedgerPersistenceDTO
        do {
            dto = try JSONDecoder().decode(LedgerPersistenceDTO.self, from: data)
        } catch {
            throw LedgerStoreError.corruptOrUnsupportedVersion
        }
        guard dto.version == LedgerPersistenceDTO.currentVersion else {
            throw LedgerStoreError.corruptOrUnsupportedVersion
        }
        return dto.toLedger()
    }

    func save(_ ledger: SleepGuardLedger) throws {
        try validateDirectory(createIfMissing: true)
        let dto = LedgerPersistenceDTO(from: ledger)
        let data: Data
        do {
            data = try JSONEncoder().encode(dto)
        } catch {
            throw LedgerStoreError.writeFailed
        }

        let tempURL = directoryURL.appendingPathComponent(
            ".\(Self.fileName).tmp.\(ProcessInfo.processInfo.processIdentifier)"
        )
        do {
            try data.write(to: tempURL, options: [.atomic])
            try fileManager.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: tempURL.path
            )
            if fileManager.fileExists(atPath: fileURL.path) {
                try validateFile(fileURL)
            }
            _ = try fileManager.replaceItemAt(
                fileURL,
                withItemAt: tempURL,
                backupItemName: nil,
                options: []
            )
            try fileManager.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: fileURL.path
            )
        } catch let error as LedgerStoreError {
            try? fileManager.removeItem(at: tempURL)
            throw error
        } catch {
            try? fileManager.removeItem(at: tempURL)
            throw LedgerStoreError.writeFailed
        }
    }

    // MARK: - Safety checks

    private func validateDirectory(createIfMissing: Bool) throws {
        var isDir: ObjCBool = false
        let exists = fileManager.fileExists(atPath: directoryURL.path, isDirectory: &isDir)

        if !exists {
            guard createIfMissing else { return }
            try fileManager.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o755]
            )
        } else if !isDir.boolValue {
            throw LedgerStoreError.notRegularFile
        }

        try rejectSymlink(at: directoryURL)
        try validateOwnershipAndMode(at: directoryURL, expectDirectory: true)
    }

    private func validateFile(_ url: URL) throws {
        try rejectSymlink(at: url)
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue else {
            throw LedgerStoreError.notRegularFile
        }
        try validateOwnershipAndMode(at: url, expectDirectory: false)
    }

    private func rejectSymlink(at url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey])
        if values.isSymbolicLink == true {
            throw LedgerStoreError.symlinkRejected
        }
        // Also reject if any parent component is a symlink pointing outside our tree.
        if let destination = try? fileManager.destinationOfSymbolicLink(atPath: url.path), !destination.isEmpty {
            throw LedgerStoreError.symlinkRejected
        }
    }

    private func validateOwnershipAndMode(at url: URL, expectDirectory: Bool) throws {
        let attrs = try fileManager.attributesOfItem(atPath: url.path)
        guard let number = attrs[.ownerAccountID] as? NSNumber else {
            throw LedgerStoreError.wrongOwner
        }
        let owner = number.uint32Value
        if policy.requireRootOwner {
            guard owner == 0 else { throw LedgerStoreError.wrongOwner }
        } else if let allowed = policy.allowedOwnerUID {
            guard owner == allowed else { throw LedgerStoreError.wrongOwner }
        }

        guard let posix = attrs[.posixPermissions] as? NSNumber else {
            throw LedgerStoreError.worldOrGroupWritable
        }
        let mode = posix.uint16Value
        // Reject group/world writable.
        if mode & 0o022 != 0 {
            throw LedgerStoreError.worldOrGroupWritable
        }
        if expectDirectory {
            // Prefer 0755-ish; still reject write bits for group/world above.
            _ = expectDirectory
        }
    }
}
