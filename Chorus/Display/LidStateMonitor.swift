import ChorusCore
import Foundation
import IOKit

/// Lid / clamshell observation (spec §5.6 / §14.2).
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

/// Persists continuous lid-closed deadline across App restart / wake (Fi A3).
///
/// Policy uses uptime-based `lidClosedSince`. Across process restart uptime resets,
/// so we anchor on wall clock and re-project into the current uptime domain.
struct LidClosedSessionStore: Equatable {
    struct Snapshot: Codable, Equatable {
        var wallClosedAt: Date
        var maxDurationLatched: Bool
    }

    private let suiteName: String?
    private let key: String

    init(suiteName: String? = nil, key: String = "lidClosedSession.v1") {
        self.suiteName = suiteName
        self.key = key
    }

    private var defaults: UserDefaults {
        if let suiteName, let suite = UserDefaults(suiteName: suiteName) {
            return suite
        }
        return .standard
    }

    func save(wallClosedAt: Date, maxDurationLatched: Bool) {
        let snap = Snapshot(wallClosedAt: wallClosedAt, maxDurationLatched: maxDurationLatched)
        if let data = try? JSONEncoder().encode(snap) {
            defaults.set(data, forKey: key)
        }
    }

    func clear() {
        defaults.removeObject(forKey: key)
    }

    func load() -> Snapshot? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(Snapshot.self, from: data)
    }

    /// Convert persisted wall closed-at into current uptime `lidClosedSince`.
    /// Returns nil when no session or elapsed would be negative (clock skew).
    func restoredLidClosedSince(nowUptime: Double, wallNow: Date = Date()) -> (sinceUptime: Double, latched: Bool)? {
        guard let snap = load() else { return nil }
        let elapsed = wallNow.timeIntervalSince(snap.wallClosedAt)
        guard elapsed.isFinite, elapsed >= 0 else { return nil }
        let since = nowUptime - elapsed
        return (since, snap.maxDurationLatched)
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
    private let detectNoLid: @MainActor () -> Bool
    let sessionStore: LidClosedSessionStore

    init(
        readProperty: @escaping @MainActor () -> CFTypeRef? = { LidStateMonitor.readAppleClamshellState() },
        detectNoLid: @escaping @MainActor () -> Bool = { LidStateMonitor.defaultDetectNoLid() },
        sessionStore: LidClosedSessionStore = LidClosedSessionStore()
    ) {
        self.readProperty = readProperty
        self.detectNoLid = detectNoLid
        self.sessionStore = sessionStore
    }

    func start() {
        guard !running else { return }
        running = true
        confirmedNoLid = detectNoLid()
        if confirmedNoLid {
            apply(.noLid)
            return
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
        apply(LidClamshellPropertyParser.reading(from: readProperty()))
    }

    private func apply(_ next: LidClosedReading) {
        let previous = reading
        reading = next
        // Persist continuous closed session for restart (Fi A3). Only confirmed open clears.
        switch next {
        case .closed:
            if sessionStore.load() == nil {
                sessionStore.save(wallClosedAt: Date(), maxDurationLatched: false)
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
        // Best-effort; constant availability is UNCONFIRMED (Q10). Polling covers gaps.
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

    /// Heuristic: no built-in display / clamshell property absent persistently.
    static func defaultDetectNoLid() -> Bool {
        // Prefer explicit absence of AppleClamshellState on machines without a lid.
        // Reading nil once is not enough (transient failure → .unknown, not .noLid).
        // C08 / Fi A3: policy still refuses arm on .noLid; this flag is opt-in via settings later.
        false
    }
}
