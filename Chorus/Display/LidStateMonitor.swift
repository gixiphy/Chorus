import ChorusCore
import Darwin
import Foundation
import IOKit
import Synchronization

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
    /// Backend restoration has not completed; never begin a replacement deadline.
    case loading
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
struct LidClosedSessionStore: Equatable, Sendable {
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

    /// Returns true when this save starts a new closed session (await `flushPending` before acquire).
    @discardableResult
    func save(
        continuousClosedAt: Double,
        bootSessionUUID: String,
        maxDurationLatched: Bool,
        wallClosedAt: Date = Date()
    ) -> Bool {
        coordinator.requestSave(
            continuousClosedAt: continuousClosedAt,
            bootSessionUUID: bootSessionUUID,
            maxDurationLatched: maxDurationLatched,
            wallClosedAt: wallClosedAt
        )
    }

    /// Bounded shutdown drain (PERF1-R5).
    func drainPendingBounded(timeout: TimeInterval = 0.2) async {
        await coordinator.drainPendingBounded(timeout: timeout)
    }

    /// Submit now; completion is signaled on the backend queue without an actor hop.
    func beginPendingDrain() -> DispatchGroup { coordinator.beginPendingDrain() }

    func awaitLoaded() async { await coordinator.awaitLoaded() }

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

    /// Wait until the off-main preload has finished (PERF1-R5 tests).
    func awaitLoadedForTesting(timeout: TimeInterval = 1) async {
        await coordinator.awaitLoaded(timeout: timeout)
    }

    /// Test seam: committed backend write count for the shared coordinator.
    var backendWriteCountForTesting: Int { coordinator.backendWriteCountForTesting }
    var hasPendingDurability: Bool { coordinator.hasPendingDurability }

    /// True when defaults contain undecodable / structurally unusable bytes.
    func hasCorruptPayload() -> Bool {
        coordinator.hasCorruptPayload()
    }

    /// Explicit restore result for C08 (W1-10). Prefer this over the nil-collapsing helper.
    func restoreResult(
        nowContinuous: Double? = LidMonotonicTime.seconds(),
        bootSessionUUID: String? = LidMonotonicTime.bootSessionUUID()
    ) -> LidSessionRestoreResult {
        if coordinator.isRestorationLoading { return .loading }
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
        case .absent, .loading:
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
    /// Backend I/O only — never `sync` onto this queue from MainActor (PERF1-R5).
    private let queue = DispatchQueue(label: "com.hermes.Chorus.lidClosedSession")
    /// In-memory semantic state for MainActor-safe compare without queue.sync.
    private let lock = NSLock()
    private let writeSink: WriteSink?

    private var pendingSnapshot: LidClosedSessionStore.Snapshot?
    private var pendingClear = false
    private var committedSemantic: LidClosedSessionStore.SemanticKey?
    private var committedWallClosedAt: Date?
    private var loadedCorrupt = false
    private var didLoad = false
    /// PERF1-R5 round3: never sync-read the backend on the caller; preload off-main.
    private enum LoadState { case unloaded, loading, loaded }
    private var loadState: LoadState = .unloaded
    private var revision: UInt64 = 0
    private var coalesceWorkItem: DispatchWorkItem?
    private var writeCountForTesting = 0
    private var removeCountForTesting = 0
    private var inFlightBackendOps = 0
    /// Last revision handed to the backend queue (save or clear). PERF1-NEW-2.
    private var enqueuedRevisionForBackend: UInt64?
    private var durabilityWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]

    private init(suiteName: String?, key: String, writeSink: WriteSink?) {
        self.suiteName = suiteName
        self.key = key
        self.writeSink = writeSink
        // Kick off-main preload immediately so restore sees disk without MainActor I/O.
        lock.lock()
        ensureLoadStartedLocked()
        lock.unlock()
    }

    private var defaults: UserDefaults {
        if let suiteName, let suite = UserDefaults(suiteName: suiteName) {
            return suite
        }
        return .standard
    }

    var backendWriteCountForTesting: Int {
        withCoordinatorLock { writeCountForTesting }
    }

    var backendRemoveCountForTesting: Int {
        withCoordinatorLock { removeCountForTesting }
    }

    var hasPendingDurability: Bool {
        withCoordinatorLock { pendingSnapshot != nil || pendingClear || inFlightBackendOps > 0 }
    }

    /// Sync helper — NSLock must not be taken directly from `async` functions (Swift 6).
    private func withCoordinatorLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    /// True when the latest requestSave was a new closed-session start (await durability before acquire).
    @discardableResult
    func requestSave(
        continuousClosedAt: Double,
        bootSessionUUID: String,
        maxDurationLatched: Bool,
        wallClosedAt: Date
    ) -> Bool {
        lock.lock()
        ensureLoadStartedLocked()
        let semantic = LidClosedSessionStore.SemanticKey(
            continuousClosedAt: continuousClosedAt,
            bootSessionUUID: bootSessionUUID,
            maxDurationLatched: maxDurationLatched
        )
        // Preserve first wallClosedAt for the same closedAt/boot session (incl. latch changes).
        let wall: Date
        if let committed = committedSemantic,
           committed.continuousClosedAt == semantic.continuousClosedAt,
           committed.bootSessionUUID == semantic.bootSessionUUID,
           let priorWall = committedWallClosedAt
        {
            wall = priorWall
        } else if let pending = pendingSnapshot,
                  pending.continuousClosedAt == semantic.continuousClosedAt,
                  pending.bootSessionUUID == semantic.bootSessionUUID,
                  let priorWall = pending.wallClosedAt
        {
            wall = priorWall
        } else {
            wall = wallClosedAt
        }

        if let committed = committedSemantic, committed == semantic, !pendingClear {
            // PERF1-NEW-2: identical-to-committed is a no-op only when pending agrees.
            // An in-flight latch/new-start may have pending ahead of committed; a coalesce
            // back to the committed semantic must still replace that pending revision.
            if pendingSnapshot == nil || pendingSnapshot?.semanticKey == semantic {
                lock.unlock()
                return false
            }
        }
        if let pending = pendingSnapshot, pending.semanticKey == semantic, !pendingClear {
            lock.unlock()
            return false
        }

        let snap = LidClosedSessionStore.Snapshot(
            continuousClosedAt: continuousClosedAt,
            bootSessionUUID: bootSessionUUID,
            maxDurationLatched: maxDurationLatched,
            wallClosedAt: wall
        )
        pendingClear = false
        pendingSnapshot = snap
        revision &+= 1
        let rev = revision

        let isNewStart = committedSemantic?.continuousClosedAt != semantic.continuousClosedAt
            || committedSemantic?.bootSessionUUID != semantic.bootSessionUUID
            || committedSemantic == nil
        let latchBarrier = (committedSemantic?.maxDurationLatched == false && semantic.maxDurationLatched)
        let barrier = isNewStart || latchBarrier
        coalesceWorkItem?.cancel()
        coalesceWorkItem = nil
        lock.unlock()

        if barrier {
            enqueueBackendSave(snap, revision: rev)
        } else {
            scheduleCoalescedCommit(revision: rev)
        }
        return isNewStart
    }

    func requestClear() {
        lock.lock()
        ensureLoadStartedLocked()
        coalesceWorkItem?.cancel()
        coalesceWorkItem = nil
        pendingSnapshot = nil
        revision &+= 1
        let rev = revision
        // PERF1-NEW-1 / R5 round3: memory-only absence check — never sync-read backend here.
        // Pending/in-flight still order a removal. Unloaded/loading also enqueues clear so
        // disk data discovered by preload cannot revive after a clear intent.
        let knownAbsentLoaded =
            loadState == .loaded
            && committedSemantic == nil
            && !loadedCorrupt
            && inFlightBackendOps == 0
        if knownAbsentLoaded {
            pendingClear = false
            lock.unlock()
            return
        }
        pendingClear = true
        lock.unlock()
        enqueueBackendClear(revision: rev)
    }

    func load() -> LidClosedSessionStore.Snapshot? {
        lock.lock()
        ensureLoadStartedLocked()
        if pendingClear {
            lock.unlock()
            return nil
        }
        if let pending = pendingSnapshot {
            lock.unlock()
            return pending
        }
        let committed = committedSnapshotLocked()
        lock.unlock()
        return committed
    }

    func hasCorruptPayload() -> Bool {
        lock.lock()
        ensureLoadStartedLocked()
        let corrupt = loadState == .loaded && loadedCorrupt
        lock.unlock()
        return corrupt
    }

    private func submitPending() {
        // PERF1-NEW-2: submit or chain the latest revision before waiting —
        // skipping while in-flight strands durability waiters on a newer pending snap.
        enum FlushSubmit {
            case clear(UInt64)
            case save(LidClosedSessionStore.Snapshot, UInt64)
            case idle
            case waitOnly
        }
        let submit = withCoordinatorLock { () -> FlushSubmit in
            coalesceWorkItem?.cancel()
            coalesceWorkItem = nil
            if pendingClear {
                if enqueuedRevisionForBackend == revision, inFlightBackendOps > 0 {
                    return .waitOnly
                }
                return .clear(revision)
            }
            if let snap = pendingSnapshot {
                if enqueuedRevisionForBackend == revision, inFlightBackendOps > 0 {
                    return .waitOnly
                }
                return .save(snap, revision)
            }
            if inFlightBackendOps == 0 {
                return .idle
            }
            return .waitOnly
        }

        switch submit {
        case .clear(let rev):
            enqueueBackendClear(revision: rev)
        case .save(let snap, let rev):
            enqueueBackendSave(snap, revision: rev)
        case .idle:
            return
        case .waitOnly:
            break
        }
    }

    func flushPending() async {
        guard !Task.isCancelled else { return }
        submitPending()
        await waitForDurability()
    }

    func beginPendingDrain() -> DispatchGroup {
        submitPending()
        let group = DispatchGroup()
        group.enter()
        queue.async { group.leave() }
        return group
    }

    /// Bounded drain for shutdown — never blocks MainActor on the I/O queue (PERF1-R5).
    /// Returns when persistence finishes or `timeout` elapses; flush may continue in the background.
    func drainPendingBounded(timeout: TimeInterval = 0.2) async {
        let group = beginPendingDrain()
        let completed = Mutex(false)
        group.notify(queue: .global()) { completed.withLock { $0 = true } }
        let deadline = ContinuousClock.now + .seconds(max(timeout, 0))
        while !Task.isCancelled, ContinuousClock.now < deadline {
            if completed.withLock({ $0 }) { return }
            do { try await Task.sleep(for: .milliseconds(2)) } catch { return }
        }
    }

    private func waitForDurability() async {
        let id = UUID()
        await withTaskCancellationHandler {
          await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            let shouldResume = withCoordinatorLock {
                if Task.isCancelled || (inFlightBackendOps == 0 && pendingSnapshot == nil && !pendingClear) {
                    return true
                }
                durabilityWaiters[id] = cont
                return false
            }
            if shouldResume {
                cont.resume()
            }
          }
        } onCancel: {
            self.withCoordinatorLock { self.durabilityWaiters.removeValue(forKey: id) }?.resume()
        }
    }

    private func scheduleCoalescedCommit(revision: UInt64) {
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.lock.lock()
            guard revision == self.revision, let snap = self.pendingSnapshot, !self.pendingClear else {
                self.lock.unlock()
                return
            }
            self.lock.unlock()
            self.enqueueBackendSave(snap, revision: revision)
        }
        lock.lock()
        coalesceWorkItem = work
        lock.unlock()
        queue.asyncAfter(deadline: .now() + .milliseconds(100), execute: work)
    }

    private func enqueueBackendSave(_ snap: LidClosedSessionStore.Snapshot, revision: UInt64) {
        lock.lock()
        inFlightBackendOps += 1
        enqueuedRevisionForBackend = revision
        lock.unlock()
        // Strong self: weak capture can drop the write before tests/await observe it (PERF1-R5).
        queue.async {
            let data = try? JSONEncoder().encode(snap)
            // PERF1-NEW-1: reject obsolete revisions before any backend mutation.
            // Do not hold `lock` across sink I/O — gated test sinks would deadlock flush/clear.
            let obsolete: Bool = {
                self.lock.lock()
                defer { self.lock.unlock() }
                return revision != self.revision || data == nil
            }()
            if obsolete {
                self.lock.lock()
                self.inFlightBackendOps -= 1
                let followUp = self.finishBackendOpLocked()
                self.lock.unlock()
                self.applyBackendFollowUp(followUp)
                return
            }
            if let data {
                if let writeSink = self.writeSink {
                    writeSink.set(data, self.key)
                } else {
                    self.defaults.set(data, forKey: self.key)
                }
            }
            self.lock.lock()
            if revision == self.revision, data != nil {
                self.writeCountForTesting += 1
                self.committedSemantic = snap.semanticKey
                self.committedWallClosedAt = snap.wallClosedAt
                if self.pendingSnapshot?.semanticKey == snap.semanticKey {
                    self.pendingSnapshot = nil
                }
                self.pendingClear = false
                self.loadedCorrupt = false
                self.didLoad = true
            }
            let needsCorrection = revision != self.revision && data != nil
            self.lock.unlock()
            if needsCorrection {
                // PERF1-NEW-1: revision advanced during I/O — undo obsolete mutation so a
                // clear that raced after the pre-check cannot leave disk populated.
                if let writeSink = self.writeSink {
                    writeSink.remove(self.key)
                } else {
                    self.defaults.removeObject(forKey: self.key)
                }
            }
            self.lock.lock()
            self.inFlightBackendOps -= 1
            let followUp = self.finishBackendOpLocked()
            self.lock.unlock()
            self.applyBackendFollowUp(followUp)
        }
    }

    private func enqueueBackendClear(revision: UInt64) {
        lock.lock()
        inFlightBackendOps += 1
        enqueuedRevisionForBackend = revision
        lock.unlock()
        queue.async {
            let obsolete: Bool = {
                self.lock.lock()
                defer { self.lock.unlock() }
                return revision != self.revision
            }()
            if obsolete {
                self.lock.lock()
                self.inFlightBackendOps -= 1
                let followUp = self.finishBackendOpLocked()
                self.lock.unlock()
                self.applyBackendFollowUp(followUp)
                return
            }
            if let writeSink = self.writeSink {
                writeSink.remove(self.key)
            } else {
                self.defaults.removeObject(forKey: self.key)
            }
            self.lock.lock()
            if revision == self.revision {
                self.removeCountForTesting += 1
                self.committedSemantic = nil
                self.committedWallClosedAt = nil
                self.pendingSnapshot = nil
                self.pendingClear = false
                self.loadedCorrupt = false
                self.didLoad = true
            }
            self.inFlightBackendOps -= 1
            let followUp = self.finishBackendOpLocked()
            self.lock.unlock()
            self.applyBackendFollowUp(followUp)
        }
    }

    private struct BackendFollowUp {
        var chainClear: UInt64?
        var chainSave: (LidClosedSessionStore.Snapshot, UInt64)?
        var waiters: [CheckedContinuation<Void, Never>] = []
    }

    /// PERF1-NEW-2: when the last in-flight op finishes, chain a still-pending revision
    /// or resume durability waiters — never leave waiters stranded.
    private func finishBackendOpLocked() -> BackendFollowUp {
        var followUp = BackendFollowUp()
        guard inFlightBackendOps == 0 else { return followUp }
        enqueuedRevisionForBackend = nil
        if pendingClear {
            followUp.chainClear = revision
        } else if let snap = pendingSnapshot {
            followUp.chainSave = (snap, revision)
        } else {
            followUp.waiters = Array(durabilityWaiters.values)
            durabilityWaiters.removeAll()
        }
        return followUp
    }

    private func applyBackendFollowUp(_ followUp: BackendFollowUp) {
        if let rev = followUp.chainClear {
            enqueueBackendClear(revision: rev)
        } else if let (snap, rev) = followUp.chainSave {
            enqueueBackendSave(snap, revision: rev)
        }
        for waiter in followUp.waiters { waiter.resume() }
    }

    /// Kick an off-main preload; never performs backend I/O under the caller lock (PERF1-R5).
    private func ensureLoadStartedLocked() {
        guard loadState == .unloaded else { return }
        loadState = .loading
        queue.async { self.finishPreloadFromBackend() }
    }

    /// Wait for the off-main preload to finish (or `timeout`). Never calls the sink on the caller.
    func awaitLoaded(timeout: TimeInterval = 1) async {
        let deadline = ContinuousClock.now + .seconds(timeout)
        while ContinuousClock.now < deadline {
            guard !Task.isCancelled else { return }
            let state = withCoordinatorLock { loadState }
            if state == .loaded { return }
            await Task.yield()
            do { try await Task.sleep(nanoseconds: 2_000_000) } catch { return }
        }
    }

    func awaitLoaded() async {
        while !Task.isCancelled {
            if withCoordinatorLock({ loadState == .loaded }) { return }
            do { try await Task.sleep(for: .milliseconds(2)) } catch { return }
        }
    }

    var isRestorationLoading: Bool {
        withCoordinatorLock { loadState != .loaded && pendingSnapshot == nil && !pendingClear }
    }

    var isLoadedForTesting: Bool { withCoordinatorLock { loadState == .loaded } }

    private func finishPreloadFromBackend() {
        let data = loadBytesLocked()
        let decoded = data.flatMap { try? JSONDecoder().decode(LidClosedSessionStore.Snapshot.self, from: $0) }
        lock.lock()
        defer { lock.unlock() }
        guard loadState == .loading else { return }
        if data != nil {
            if let snap = decoded {
                // Do not clobber a newer in-memory pending/committed session.
                if committedSemantic == nil, pendingSnapshot == nil, !pendingClear {
                    committedSemantic = snap.semanticKey
                    committedWallClosedAt = snap.wallClosedAt
                }
                loadedCorrupt = false
            } else if committedSemantic == nil, pendingSnapshot == nil, !pendingClear {
                loadedCorrupt = true
            }
        }
        loadState = .loaded
        didLoad = true
    }

    private func loadBytesLocked() -> Data? {
        if let writeSink {
            return writeSink.data(key)
        }
        return defaults.data(forKey: key)
    }

    private func committedSnapshotLocked() -> LidClosedSessionStore.Snapshot? {
        guard let semantic = committedSemantic else { return nil }
        return LidClosedSessionStore.Snapshot(
            continuousClosedAt: semantic.continuousClosedAt,
            bootSessionUUID: semantic.bootSessionUUID,
            maxDurationLatched: semantic.maxDurationLatched,
            wallClosedAt: committedWallClosedAt
        )
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
    private var restorationTask: Task<Void, Never>?
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
        restorationTask?.cancel()
        restorationTask = nil
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
            case .loading:
                if restorationTask == nil {
                    let store = sessionStore
                    restorationTask = Task { @MainActor [weak self] in
                        await store.awaitLoaded()
                        guard let self, !Task.isCancelled else { return }
                        self.restorationTask = nil
                        guard self.reading == .closed else { return }
                        self.apply(.closed)
                        self.onChange?()
                    }
                }
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
