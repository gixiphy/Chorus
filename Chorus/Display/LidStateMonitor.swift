import ChorusCore
import Darwin
import Foundation
import IOKit

/// Lid / clamshell observation (spec §5.6 / §14.2 / W1-10 / W1-11).
@MainActor
protocol LidStateObserving: AnyObject {
    /// nil: no built-in display or unreadable.
    var isClosed: Bool? { get }
    /// Typed reading for policy (§14.2 / Fi A3).
    var reading: LidClosedReading { get }
    var onChange: (() -> Void)? { get set }
    func start()
    func stop()
    /// Armed/holding → 5s poll; otherwise off (spec §5.6).
    func setPollingEnabled(_ enabled: Bool)
}

/// Capability detection vs transient property failure (W1-11 / Fi A3 / research Q10).
enum LidCapability: Equatable, Sendable {
    /// IOPMrootDomain present and `AppleClamshellState` key exists.
    case hasLid
    /// IOPMrootDomain present and `AppleClamshellState` key confirmed absent (desktop).
    case noLid
    /// Could not open IOPMrootDomain or other transient failure — not evidence of noLid.
    case unknown
}

/// Parses `AppleClamshellState` CF property (V-C06 / tasks).
enum LidClamshellPropertyParser {
    static func reading(from value: CFTypeRef?) -> LidClosedReading {
        guard let value else { return .unknown }
        let typeID = CFGetTypeID(value)
        if typeID == CFBooleanGetTypeID() {
            let closed = CFBooleanGetValue(unsafeBitCast(value, to: CFBoolean.self))
            return closed ? .closed : .open
        }
        if typeID == CFNumberGetTypeID() {
            var number: Int32 = 0
            if CFNumberGetValue(unsafeBitCast(value, to: CFNumber.self), .sInt32Type, &number) {
                return number != 0 ? .closed : .open
            }
        }
        return .unknown
    }

    /// Legacy Bool? mapping for `isClosed` (nil = unknown / no lid).
    static func isClosedFlag(from reading: LidClosedReading, noLid: Bool) -> Bool? {
        if noLid { return nil }
        switch reading {
        case .open: return false
        case .closed: return true
        case .noLid: return nil
        case .unknown: return nil
        }
    }
}

/// Boot-anchored continuous seconds (advances across sleep; same across process restart).
/// No `systemUptime` fallback — unavailable clock is explicit failure (W1-10).
enum LidMonotonicTime {
    static func seconds() -> Double? {
        var ts = timespec()
        guard clock_gettime(CLOCK_MONOTONIC_RAW, &ts) == 0 else { return nil }
        return Double(ts.tv_sec) + Double(ts.tv_nsec) / 1_000_000_000.0
    }

    static func bootSessionUUID() -> String? {
        var size = 0
        sysctlbyname("kern.bootsessionuuid", nil, &size, nil, 0)
        guard size > 1 else { return nil }
        var buffer = [CChar](repeating: 0, count: Int(size))
        guard sysctlbyname("kern.bootsessionuuid", &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }
}

/// Explicit restore disposition for C08 (W1-10). `invalid` must be treated as conservative
/// closed-session (do not reset max-duration latch / do not begin a fresh open-ended duration).
enum LidSessionRestoreResult: Equatable, Sendable {
    case absent
    case valid(sinceContinuous: Double, latched: Bool)
    /// Corrupt, reboot mismatch, unknown boot, or non-finite clock — fail closed for policy.
    case invalid
}

/// Persists continuous lid-closed deadline across App restart / wake (Fi A3 / W1-10).
///
/// Uses monotonic continuous time + boot session UUID. Wall-clock changes cannot
/// extend or reset the deadline. Invalid / reboot persistence is **not** the same as absent.
///
/// PERF-1: semantic write-on-change + coalesced persistence via a shared coordinator
/// keyed by `(suiteName, key)` so monitor/controller wrappers share pending state.
struct LidClosedSessionStore: Equatable {
    struct Snapshot: Codable, Equatable, Sendable {
        var continuousClosedAt: Double
        var bootSessionUUID: String
        var maxDurationLatched: Bool
        /// Display-only; never used for deadline math.
        var wallClosedAt: Date?

        /// Semantic identity for write-on-change (ignores wallClosedAt).
        var semanticKey: SemanticKey {
            SemanticKey(
                continuousClosedAt: continuousClosedAt,
                bootSessionUUID: bootSessionUUID,
                maxDurationLatched: maxDurationLatched
            )
        }
    }

    struct SemanticKey: Equatable, Sendable {
        var continuousClosedAt: Double
        var bootSessionUUID: String
        var maxDurationLatched: Bool
    }

    private let suiteName: String?
    private let key: String
    private let coordinator: LidClosedSessionCoordinator

    init(
        suiteName: String? = nil,
        key: String = "lidClosedSession.v2",
        writeSink: LidClosedSessionCoordinator.WriteSink? = nil
    ) {
        self.suiteName = suiteName
        self.key = key
        self.coordinator = LidClosedSessionCoordinator.shared(
            suiteName: suiteName,
            key: key,
            writeSink: writeSink
        )
    }

    static func == (lhs: LidClosedSessionStore, rhs: LidClosedSessionStore) -> Bool {
        lhs.suiteName == rhs.suiteName && lhs.key == rhs.key
    }

    func save(
        continuousClosedAt: Double,
        bootSessionUUID: String,
        maxDurationLatched: Bool,
        wallClosedAt: Date = Date()
    ) {
        coordinator.requestSave(
            continuousClosedAt: continuousClosedAt,
            bootSessionUUID: bootSessionUUID,
            maxDurationLatched: maxDurationLatched,
            wallClosedAt: wallClosedAt
        )
    }

    func clear() {
        coordinator.requestClear()
    }

    func load() -> Snapshot? {
        coordinator.load()
    }

    /// Test/lifecycle: drain coalesced pending writes.
    func flushPending() async {
        await coordinator.flushPending()
    }

    /// True when defaults contain undecodable / structurally unusable bytes.
    func hasCorruptPayload() -> Bool {
        coordinator.hasCorruptPayload()
    }

    /// Explicit restore result for C08 (W1-10). Prefer this over the nil-collapsing helper.
    func restoreResult(
        nowContinuous: Double? = LidMonotonicTime.seconds(),
        bootSessionUUID: String? = LidMonotonicTime.bootSessionUUID()
    ) -> LidSessionRestoreResult {
        if hasCorruptPayload() { return .invalid }
        guard let snap = load() else { return .absent }
        guard let bootSessionUUID else { return .invalid }
        guard snap.bootSessionUUID == bootSessionUUID else {
            // Reboot — prior deadline must not reset the cap; surface invalid for latch.
            return .invalid
        }
        guard let nowContinuous, snap.continuousClosedAt.isFinite, nowContinuous.isFinite else {
            return .invalid
        }
        guard snap.continuousClosedAt <= nowContinuous + 0.5 else { return .invalid }
        return .valid(sinceContinuous: snap.continuousClosedAt, latched: snap.maxDurationLatched)
    }

    /// Compatibility helper preserves the conservative latch for invalid evidence.
    func restoredLidClosedSince(
        nowContinuous: Double? = LidMonotonicTime.seconds(),
        bootSessionUUID: String? = LidMonotonicTime.bootSessionUUID()
    ) -> (sinceContinuous: Double, latched: Bool)? {
        switch restoreResult(nowContinuous: nowContinuous, bootSessionUUID: bootSessionUUID) {
        case let .valid(since, latched):
            return (since, latched)
        case .invalid:
            return (sinceContinuous: 0, latched: true)
        case .absent:
            return nil
        }
    }
}

/// Shared serialized persistence for lid-closed sessions (PERF-1 Task 4).
final class LidClosedSessionCoordinator: @unchecked Sendable {
    struct WriteSink: Sendable {
        var set: @Sendable (Data, String) -> Void
        var remove: @Sendable (String) -> Void
        var data: @Sendable (String) -> Data?
    }

    private struct StorageKey: Hashable {
        var suiteName: String?
        var key: String
    }

    private static let registryLock = NSLock()
    nonisolated(unsafe) private static var registry: [StorageKey: LidClosedSessionCoordinator] = [:]

    static func shared(
        suiteName: String?,
        key: String,
        writeSink: WriteSink? = nil
    ) -> LidClosedSessionCoordinator {
        // Injected sinks are test-only instances (not shared).
        if writeSink != nil {
            return LidClosedSessionCoordinator(suiteName: suiteName, key: key, writeSink: writeSink)
        }
        let storageKey = StorageKey(suiteName: suiteName, key: key)
        registryLock.lock()
        defer { registryLock.unlock() }
        if let existing = registry[storageKey] {
            return existing
        }
        let created = LidClosedSessionCoordinator(suiteName: suiteName, key: key, writeSink: nil)
        registry[storageKey] = created
        return created
    }

    /// Test helper: drop registry entry so a suite can start clean.
    static func resetRegistryForTesting(suiteName: String?, key: String = "lidClosedSession.v2") {
        registryLock.lock()
        registry.removeValue(forKey: StorageKey(suiteName: suiteName, key: key))
        registryLock.unlock()
    }

    private let suiteName: String?
    private let key: String
    private let queue = DispatchQueue(label: "com.hermes.Chorus.lidClosedSession")
    private let writeSink: WriteSink?
    private let coalesceNanoseconds: UInt64 = 100_000_000

    private var pendingSnapshot: LidClosedSessionStore.Snapshot?
    private var pendingClear = false
    private var committedSemantic: LidClosedSessionStore.SemanticKey?
    private var committedWallClosedAt: Date?
    private var loadedCorrupt = false
    private var didLoad = false
    private var revision: UInt64 = 0
    private var coalesceWorkItem: DispatchWorkItem?
    private var writeCountForTesting = 0
    private var removeCountForTesting = 0

    private init(suiteName: String?, key: String, writeSink: WriteSink?) {
        self.suiteName = suiteName
        self.key = key
        self.writeSink = writeSink
    }

    private var defaults: UserDefaults {
        if let suiteName, let suite = UserDefaults(suiteName: suiteName) {
            return suite
        }
        return .standard
    }

    var backendWriteCountForTesting: Int {
        queue.sync { writeCountForTesting }
    }

    var backendRemoveCountForTesting: Int {
        queue.sync { removeCountForTesting }
    }

    func requestSave(
        continuousClosedAt: Double,
        bootSessionUUID: String,
        maxDurationLatched: Bool,
        wallClosedAt: Date
    ) {
        // Durability barriers run synchronously on the persistence queue so load/restore
        // immediately sees the new closed-session start / latch (PERF-1).
        queue.sync {
            self.ensureLoadedLocked()
            let semantic = LidClosedSessionStore.SemanticKey(
                continuousClosedAt: continuousClosedAt,
                bootSessionUUID: bootSessionUUID,
                maxDurationLatched: maxDurationLatched
            )
            // Preserve first wallClosedAt for the same closedAt/boot session (incl. latch changes).
            let wall: Date
            if let committed = self.committedSemantic,
               committed.continuousClosedAt == semantic.continuousClosedAt,
               committed.bootSessionUUID == semantic.bootSessionUUID,
               let priorWall = self.committedWallClosedAt
            {
                wall = priorWall
            } else if let pending = self.pendingSnapshot,
                      pending.continuousClosedAt == semantic.continuousClosedAt,
                      pending.bootSessionUUID == semantic.bootSessionUUID,
                      let priorWall = pending.wallClosedAt
            {
                wall = priorWall
            } else {
                wall = wallClosedAt
            }

            if let committed = self.committedSemantic, committed == semantic, !self.pendingClear {
                // Unchanged reevaluate — no encode/write.
                return
            }
            if let pending = self.pendingSnapshot, pending.semanticKey == semantic, !self.pendingClear {
                return
            }

            let snap = LidClosedSessionStore.Snapshot(
                continuousClosedAt: continuousClosedAt,
                bootSessionUUID: bootSessionUUID,
                maxDurationLatched: maxDurationLatched,
                wallClosedAt: wall
            )
            self.pendingClear = false
            self.pendingSnapshot = snap
            self.revision &+= 1
            let rev = self.revision

            let isNewStart = self.committedSemantic?.continuousClosedAt != semantic.continuousClosedAt
                || self.committedSemantic?.bootSessionUUID != semantic.bootSessionUUID
                || self.committedSemantic == nil
            let latchBarrier = (self.committedSemantic?.maxDurationLatched == false && semantic.maxDurationLatched)
            let barrier = isNewStart || latchBarrier
            if barrier {
                self.coalesceWorkItem?.cancel()
                self.performSaveLocked(snap, revision: rev)
            } else {
                self.scheduleCoalescedCommitLocked(revision: rev)
            }
        }
    }

    func requestClear() {
        // Open-lid clear is a durability barrier.
        queue.sync {
            self.ensureLoadedLocked()
            self.coalesceWorkItem?.cancel()
            self.pendingSnapshot = nil
            self.revision &+= 1
            let rev = self.revision
            if self.committedSemantic == nil, !self.loadedCorrupt, self.loadBytesLocked() == nil {
                // Repeated clear of absent store — zero removals.
                self.pendingClear = false
                return
            }
            self.pendingClear = true
            self.performClearLocked(revision: rev)
        }
    }

    func load() -> LidClosedSessionStore.Snapshot? {
        queue.sync {
            ensureLoadedLocked()
            if pendingClear { return nil }
            if let pending = pendingSnapshot { return pending }
            return loadDecodedLocked()
        }
    }

    func hasCorruptPayload() -> Bool {
        queue.sync {
            ensureLoadedLocked()
            return loadedCorrupt
        }
    }

    func flushPending() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            queue.async {
                self.coalesceWorkItem?.cancel()
                self.coalesceWorkItem = nil
                if self.pendingClear {
                    self.performClearLocked(revision: self.revision)
                } else if let snap = self.pendingSnapshot {
                    self.performSaveLocked(snap, revision: self.revision)
                }
                cont.resume()
            }
        }
    }

    private func scheduleCoalescedCommitLocked(revision: UInt64) {
        coalesceWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.queue.async {
                guard revision == self.revision, let snap = self.pendingSnapshot, !self.pendingClear else { return }
                self.performSaveLocked(snap, revision: revision)
            }
        }
        coalesceWorkItem = work
        queue.asyncAfter(deadline: .now() + .milliseconds(100), execute: work)
    }

    private func performSaveLocked(_ snap: LidClosedSessionStore.Snapshot, revision: UInt64) {
        guard revision == self.revision else { return }
        guard let data = try? JSONEncoder().encode(snap) else { return }
        if let writeSink {
            writeSink.set(data, key)
        } else {
            defaults.set(data, forKey: key)
        }
        writeCountForTesting += 1
        committedSemantic = snap.semanticKey
        committedWallClosedAt = snap.wallClosedAt
        pendingSnapshot = nil
        pendingClear = false
        loadedCorrupt = false
        didLoad = true
    }

    private func performClearLocked(revision: UInt64) {
        guard revision == self.revision else { return }
        if let writeSink {
            writeSink.remove(key)
        } else {
            defaults.removeObject(forKey: key)
        }
        removeCountForTesting += 1
        committedSemantic = nil
        committedWallClosedAt = nil
        pendingSnapshot = nil
        pendingClear = false
        loadedCorrupt = false
        didLoad = true
    }

    private func ensureLoadedLocked() {
        guard !didLoad else { return }
        didLoad = true
        if let data = loadBytesLocked() {
            if let snap = try? JSONDecoder().decode(LidClosedSessionStore.Snapshot.self, from: data) {
                committedSemantic = snap.semanticKey
                committedWallClosedAt = snap.wallClosedAt
                loadedCorrupt = false
            } else {
                loadedCorrupt = true
            }
        }
    }

    private func loadBytesLocked() -> Data? {
        if let writeSink {
            return writeSink.data(key)
        }
        return defaults.data(forKey: key)
    }

    private func loadDecodedLocked() -> LidClosedSessionStore.Snapshot? {
        guard let data = loadBytesLocked() else { return nil }
        return try? JSONDecoder().decode(LidClosedSessionStore.Snapshot.self, from: data)
    }
}

@MainActor
final class LidStateMonitor: LidStateObserving {
    private(set) var reading: LidClosedReading = .unknown
    var isClosed: Bool? {
        LidClamshellPropertyParser.isClosedFlag(from: reading, noLid: confirmedNoLid)
    }

    var onChange: (() -> Void)?

    private var running = false
    private var pollingEnabled = false
    private var pollTimer: Timer?
    private var notifyPort: IONotificationPortRef?
    private var notifier: io_object_t = 0
    private var rootDomain: io_service_t = 0
    private var confirmedNoLid = false
    private let readProperty: @MainActor () -> CFTypeRef?
    private let detectCapability: @MainActor () -> LidCapability
    let sessionStore: LidClosedSessionStore

    init(
        readProperty: @escaping @MainActor () -> CFTypeRef? = { LidStateMonitor.readAppleClamshellState() },
        detectCapability: @escaping @MainActor () -> LidCapability = { LidStateMonitor.detectLidCapability() },
        sessionStore: LidClosedSessionStore = LidClosedSessionStore()
    ) {
        self.readProperty = readProperty
        self.detectCapability = detectCapability
        self.sessionStore = sessionStore
    }

    func start() {
        guard !running else { return }
        running = true
        switch detectCapability() {
        case .noLid:
            confirmedNoLid = true
            apply(.noLid)
            return
        case .hasLid:
            confirmedNoLid = false
        case .unknown:
            // Transient failure — do not claim noLid; policy sees .unknown (W1-11).
            confirmedNoLid = false
            apply(.unknown)
            // Still attempt notifications/polling so a later success can recover.
        }
        refresh()
        installInterestNotification()
        updatePolling()
    }

    func stop() {
        guard running else { return }
        running = false
        pollTimer?.invalidate()
        pollTimer = nil
        tearDownNotification()
    }

    func setPollingEnabled(_ enabled: Bool) {
        pollingEnabled = enabled
        updatePolling()
    }

    /// Test seam.
    func ingestForTesting(_ reading: LidClosedReading) {
        apply(reading)
    }

    private func refresh() {
        if confirmedNoLid {
            apply(.noLid)
            return
        }
        // Re-check capability if previously unknown.
        if reading == .unknown || reading == .noLid {
            switch detectCapability() {
            case .noLid:
                confirmedNoLid = true
                apply(.noLid)
                return
            case .hasLid:
                confirmedNoLid = false
            case .unknown:
                break
            }
            // continue to property read below
        }
        apply(LidClamshellPropertyParser.reading(from: readProperty()))
    }

    private func apply(_ next: LidClosedReading) {
        let previous = reading
        reading = next
        switch next {
        case .closed:
            // W1-10: keep valid same-boot sessions; replace absent/invalid (never retain corrupt).
            switch sessionStore.restoreResult() {
            case .valid:
                break
            case .absent:
                if let boot = LidMonotonicTime.bootSessionUUID(),
                   let continuous = LidMonotonicTime.seconds()
                {
                    sessionStore.save(
                        continuousClosedAt: continuous,
                        bootSessionUUID: boot,
                        maxDurationLatched: false,
                        wallClosedAt: Date() // display only
                    )
                }
            case .invalid:
                // Conservative: replace invalid bytes with a latch when persistence is possible.
                // Keep invalid evidence if clock/boot identity is unavailable.
                if let boot = LidMonotonicTime.bootSessionUUID(),
                   let continuous = LidMonotonicTime.seconds()
                {
                    sessionStore.save(
                        continuousClosedAt: continuous,
                        bootSessionUUID: boot,
                        maxDurationLatched: true,
                        wallClosedAt: Date()
                    )
                }
            }
        case .open:
            sessionStore.clear()
        case .noLid, .unknown:
            break
        }
        guard next != previous else { return }
        onChange?()
    }

    private func updatePolling() {
        pollTimer?.invalidate()
        pollTimer = nil
        guard running, pollingEnabled, !confirmedNoLid else { return }
        let timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    private func installInterestNotification() {
        // Research Q10: kIOPMMessageClamshellStateChange on IOPMrootDomain.
        // M1 lid behavior UNCONFIRMED on this host; polling covers gaps.
        rootDomain = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard rootDomain != 0 else { return }
        let port = IONotificationPortCreate(kIOMainPortDefault)
        notifyPort = port
        if let runLoopSource = IONotificationPortGetRunLoopSource(port)?.takeUnretainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .defaultMode)
        }
        let callback: IOServiceInterestCallback = { refcon, _, _, _ in
            guard let refcon else { return }
            let monitor = Unmanaged<LidStateMonitor>.fromOpaque(refcon).takeUnretainedValue()
            MainActor.assumeIsolated {
                monitor.refresh()
            }
        }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let kr = IOServiceAddInterestNotification(
            port,
            rootDomain,
            kIOGeneralInterest,
            callback,
            refcon,
            &notifier
        )
        if kr != KERN_SUCCESS {
            tearDownNotification()
        }
    }

    private func tearDownNotification() {
        if notifier != 0 {
            IOObjectRelease(notifier)
            notifier = 0
        }
        if rootDomain != 0 {
            IOObjectRelease(rootDomain)
            rootDomain = 0
        }
        if let notifyPort {
            if let runLoopSource = IONotificationPortGetRunLoopSource(notifyPort)?.takeUnretainedValue() {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .defaultMode)
            }
            IONotificationPortDestroy(notifyPort)
            self.notifyPort = nil
        }
    }

    static func readAppleClamshellState() -> CFTypeRef? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        return IORegistryEntryCreateCFProperty(
            service,
            "AppleClamshellState" as CFString,
            kCFAllocatorDefault,
            0
        )?.takeRetainedValue()
    }

    /// Confirmed desktop = IOPMrootDomain reachable and `AppleClamshellState` key absent (Q10).
    /// Service lookup failure → `.unknown` (transient MacBook / IOKit blip), never `.noLid`.
    /// M1 lid notification timing remains UNCONFIRMED pending hardware tests.
    nonisolated static func detectLidCapability() -> LidCapability {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != 0 else { return .unknown }
        defer { IOObjectRelease(service) }
        let present = IORegistryEntryCreateCFProperty(
            service,
            "AppleClamshellState" as CFString,
            kCFAllocatorDefault,
            0
        )?.takeRetainedValue() != nil
        return LidCapabilityClassifier.classify(serviceOK: true, clamshellPropertyPresent: present)
    }
}

/// Pure lid capability classification (W1-11); not MainActor-bound.
enum LidCapabilityClassifier {
    static func classify(serviceOK: Bool, clamshellPropertyPresent: Bool) -> LidCapability {
        guard serviceOK else { return .unknown }
        return clamshellPropertyPresent ? .hasLid : .noLid
    }
}
