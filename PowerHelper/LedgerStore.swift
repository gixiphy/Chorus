import Foundation
import ChorusCore
import Darwin

/// Persistence for helper recovery metadata only (no live holders) — spec §6.3 / §14.1 / W1-12.
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
/// Uses no-follow, descriptor-relative open/rename; validates root-owned non-writable
/// ancestors; rejects symlink/FIFO/non-regular files; O_EXCL temp + atomic rename + 0600.
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

    private let directoryPath: String
    private let policy: SecurityPolicy

    init(
        directoryPath: String = LedgerStore.defaultDirectoryPath,
        policy: SecurityPolicy = .production,
        fileManager: FileManager = .default
    ) {
        self.directoryPath = directoryPath
        self.policy = policy
        _ = fileManager // retained API compatibility; I/O is Darwin fd-based
    }

    func load() throws -> SleepGuardLedger? {
        var dirStat = stat()
        if lstat(directoryPath, &dirStat) != 0 {
            if errno == ENOENT { return nil }
            throw LedgerStoreError.unsafeRoot
        }

        let dirFD = try openValidatedDirectory(createIfMissing: false)
        defer { close(dirFD) }

        // fstatat first so FIFO/device nodes are rejected without blocking open(2).
        var leafStat = stat()
        if fstatat(dirFD, Self.fileName, &leafStat, AT_SYMLINK_NOFOLLOW) != 0 {
            if errno == ENOENT { return nil }
            throw LedgerStoreError.writeFailed
        }
        let leafType = leafStat.st_mode & S_IFMT
        if leafType == S_IFLNK { throw LedgerStoreError.symlinkRejected }
        guard leafType == S_IFREG else { throw LedgerStoreError.notRegularFile }

        let fd = openat(dirFD, Self.fileName, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        if fd < 0 {
            if errno == ENOENT { return nil }
            if errno == ELOOP { throw LedgerStoreError.symlinkRejected }
            throw LedgerStoreError.writeFailed
        }
        defer { close(fd) }
        try validateOpenFile(fd: fd, expectDirectory: false)

        let data = try readAll(fd: fd)
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
        let dirFD = try openValidatedDirectory(createIfMissing: true)
        defer { close(dirFD) }

        let dto = LedgerPersistenceDTO(from: ledger)
        let data: Data
        do {
            data = try JSONEncoder().encode(dto)
        } catch {
            throw LedgerStoreError.writeFailed
        }

        let tmpName = ".\(Self.fileName).tmp.\(getpid()).\(MonotonicTime.seconds())"
        let tmpFD = openat(
            dirFD,
            tmpName,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            0o600
        )
        guard tmpFD >= 0 else {
            if errno == ELOOP || errno == EEXIST { throw LedgerStoreError.symlinkRejected }
            throw LedgerStoreError.writeFailed
        }
        var renamed = false
        defer {
            close(tmpFD)
            if !renamed {
                _ = unlinkat(dirFD, tmpName, 0)
            }
        }

        try writeAll(fd: tmpFD, data: data)
        if fchmod(tmpFD, 0o600) != 0 {
            throw LedgerStoreError.writeFailed
        }
        if fsync(tmpFD) != 0 {
            throw LedgerStoreError.writeFailed
        }

        // If destination exists, validate it is a regular file we own before replace.
        let existing = openat(dirFD, Self.fileName, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        if existing >= 0 {
            defer { close(existing) }
            try validateOpenFile(fd: existing, expectDirectory: false)
        } else if errno != ENOENT {
            if errno == ELOOP { throw LedgerStoreError.symlinkRejected }
            if errno == EISDIR { throw LedgerStoreError.notRegularFile }
            throw LedgerStoreError.writeFailed
        }

        if renameat(dirFD, tmpName, dirFD, Self.fileName) != 0 {
            if errno == ELOOP { throw LedgerStoreError.symlinkRejected }
            throw LedgerStoreError.writeFailed
        }
        renamed = true

        let finalFD = openat(dirFD, Self.fileName, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard finalFD >= 0 else { throw LedgerStoreError.writeFailed }
        defer { close(finalFD) }
        try validateOpenFile(fd: finalFD, expectDirectory: false)
        if fchmod(finalFD, 0o600) != 0 {
            throw LedgerStoreError.writeFailed
        }
    }

    // MARK: - Path / fd validation

    private func openValidatedDirectory(createIfMissing: Bool) throws -> Int32 {
        try validateAncestorChain(directoryPath)

        var st = stat()
        if lstat(directoryPath, &st) == 0 {
            try validateStat(&st, expectDirectory: true)
        } else if errno == ENOENT {
            guard createIfMissing else { throw LedgerStoreError.unsafeRoot }
            try createDirectoryTree(directoryPath)
        } else {
            throw LedgerStoreError.unsafeRoot
        }

        let fd = open(directoryPath, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else {
            if errno == ELOOP { throw LedgerStoreError.symlinkRejected }
            throw LedgerStoreError.unsafeRoot
        }
        do {
            try validateOpenFile(fd: fd, expectDirectory: true)
        } catch {
            close(fd)
            throw error
        }
        return fd
    }

    private func createDirectoryTree(_ path: String) throws {
        let components = (path as NSString).pathComponents
        var built = ""
        let lastIndex = components.count - 1
        for (index, component) in components.enumerated() {
            if index == 0, component == "/" {
                built = "/"
                continue
            }
            built = (built as NSString).appendingPathComponent(component)
            var st = stat()
            if lstat(built, &st) == 0 {
                let isLink = (st.st_mode & S_IFMT) == S_IFLNK
                let isLeaf = index == lastIndex
                if isLink {
                    if isLeaf { throw LedgerStoreError.symlinkRejected }
                    continue
                }
                if isLeaf || policy.requireRootOwner {
                    try validateStat(&st, expectDirectory: true)
                }
                continue
            }
            if errno != ENOENT { throw LedgerStoreError.unsafeRoot }
            if mkdir(built, 0o755) != 0 {
                throw LedgerStoreError.writeFailed
            }
            // Re-lstat to reject TOCTOU symlink plant.
            if lstat(built, &st) != 0 {
                throw LedgerStoreError.writeFailed
            }
            try validateStat(&st, expectDirectory: true)
        }
    }

    private func validateAncestorChain(_ path: String) throws {
        let components = (path as NSString).pathComponents
        var built = ""
        let lastIndex = components.count - 1
        for (index, component) in components.enumerated() {
            if index == 0, component == "/" {
                built = "/"
                continue
            }
            built = (built as NSString).appendingPathComponent(component)
            var st = stat()
            if lstat(built, &st) != 0 {
                if errno == ENOENT {
                    // Remaining components will be created; ancestors that exist were checked.
                    return
                }
                throw LedgerStoreError.unsafeRoot
            }
            let isLink = (st.st_mode & S_IFMT) == S_IFLNK
            let isLeaf = index == lastIndex
            if isLink {
                // Leaf directory must never be a symlink. Intermediate hops like
                // /var → /private/var are normal on macOS temp paths.
                if isLeaf {
                    throw LedgerStoreError.symlinkRejected
                }
                continue
            }
            if isLeaf {
                try validateStat(&st, expectDirectory: true)
            } else if policy.requireRootOwner {
                // Production: every ancestor must be root-owned and not group/world-writable.
                try validateStat(&st, expectDirectory: true)
            }
            // Testing: skip intermediate system ancestors (root-owned /var/folders/…).
        }
    }

    private func validateOpenFile(fd: Int32, expectDirectory: Bool) throws {
        var st = stat()
        guard fstat(fd, &st) == 0 else { throw LedgerStoreError.writeFailed }
        try validateStat(&st, expectDirectory: expectDirectory)
    }

    private func validateStat(_ st: inout stat, expectDirectory: Bool) throws {
        let type = st.st_mode & S_IFMT
        if type == S_IFLNK {
            throw LedgerStoreError.symlinkRejected
        }
        if expectDirectory {
            guard type == S_IFDIR else { throw LedgerStoreError.notRegularFile }
        } else {
            guard type == S_IFREG else { throw LedgerStoreError.notRegularFile }
        }

        let owner = UInt32(st.st_uid)
        if policy.requireRootOwner {
            guard owner == 0 else { throw LedgerStoreError.wrongOwner }
        } else if let allowed = policy.allowedOwnerUID {
            guard owner == allowed else { throw LedgerStoreError.wrongOwner }
        }

        // Reject group/world writable on the final directory and file.
        if st.st_mode & (S_IWGRP | S_IWOTH) != 0 {
            throw LedgerStoreError.worldOrGroupWritable
        }
    }

    private func readAll(fd: Int32) throws -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            let n = read(fd, &buffer, buffer.count)
            if n < 0 {
                if errno == EINTR { continue }
                throw LedgerStoreError.corruptOrUnsupportedVersion
            }
            if n == 0 { break }
            data.append(contentsOf: buffer.prefix(n))
            if data.count > 1_048_576 {
                throw LedgerStoreError.corruptOrUnsupportedVersion
            }
        }
        return data
    }

    private func writeAll(fd: Int32, data: Data) throws {
        try data.withUnsafeBytes { raw in
            var written = 0
            let total = raw.count
            let base = raw.bindMemory(to: UInt8.self).baseAddress
            while written < total {
                let n = write(fd, base?.advanced(by: written), total - written)
                if n < 0 {
                    if errno == EINTR { continue }
                    throw LedgerStoreError.writeFailed
                }
                written += n
            }
        }
    }
}
