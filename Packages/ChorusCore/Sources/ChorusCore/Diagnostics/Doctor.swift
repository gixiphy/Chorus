import Foundation

/// `chorus doctor` 的一個檢查項目。
public struct DoctorCheck: Codable, Sendable, Equatable {
    /// raw-string 而非 enum：CLI 與 App 版本不一致時仍解得開（未知值視為 warning）。
    public struct Status: RawRepresentable, Codable, Sendable, Hashable {
        public let rawValue: String

        public init(rawValue: String) {
            self.rawValue = rawValue
        }

        public static let ok = Status(rawValue: "ok")
        public static let info = Status(rawValue: "info")
        public static let warning = Status(rawValue: "warning")
        public static let error = Status(rawValue: "error")

        /// 排序與結束碼用。不認得的值當 warning：看得到，但不會讓腳本誤判成失敗。
        public var severity: Int {
            switch self {
            case .ok: 0
            case .info: 1
            case .error: 3
            default: 2
            }
        }
    }

    /// 穩定識別碼（`sync.discovery`、`peer.<peerID 前 8 碼>.connection`…），給腳本比對用。
    public let id: String
    public let status: Status
    public let title: String
    public let detail: String?
    /// 下一步。`ok` 不帶。
    public let remedy: String?

    public init(id: String, status: Status, title: String, detail: String? = nil, remedy: String? = nil) {
        self.id = id
        self.status = status
        self.title = title
        self.detail = detail
        self.remedy = remedy
    }
}

public struct DoctorReport: Codable, Sendable, Equatable {
    public let generatedAt: Date
    public let checks: [DoctorCheck]

    public init(generatedAt: Date, checks: [DoctorCheck]) {
        self.generatedAt = generatedAt
        self.checks = checks
    }

    public var hasErrors: Bool {
        checks.contains { $0.status.severity >= DoctorCheck.Status.error.severity }
    }
}

/// 某一刻的 App 狀態快照。App 端在主執行緒收集，規則本身不碰任何系統 API。
public struct DoctorInputs: Sendable, Equatable {
    public enum TapState: String, Sendable, Equatable {
        case off, probing, active, denied, failed
    }

    public struct Peer: Sendable, Equatable {
        public enum Phase: Sendable, Equatable {
            case connected
            case connecting
            case backoff(secondsRemaining: Int)
            case idle
        }

        /// 配對金鑰在 Keychain 的狀態。「讀不到」和「不存在」要分開：
        /// 鑰匙圈鎖住或存取被拒時金鑰其實還在，叫人重新配對會白白丟掉權限設定。
        public enum KeyState: Sendable, Equatable {
            case present
            case missing
            case unreadable(status: Int32)
        }

        public var peerID: String
        public var deviceName: String
        public var phase: Phase
        /// peerID 較小的一方負責撥號（`PeerSessionSlots.isDialer`）。
        public var isDialer: Bool
        public var key: KeyState
        /// 撥號候選（已依優先序、去重），以 `String(describing:)` 表示。
        public var candidates: [String]
        public var nextCandidate: String?
        public var consecutiveFailures: Int
        public var permissions: PeerPermissionPolicy
        public var lastHeardSecondsAgo: Int?

        public init(
            peerID: String, deviceName: String, phase: Phase, isDialer: Bool, key: KeyState,
            candidates: [String], nextCandidate: String?, consecutiveFailures: Int,
            permissions: PeerPermissionPolicy, lastHeardSecondsAgo: Int?
        ) {
            self.peerID = peerID
            self.deviceName = deviceName
            self.phase = phase
            self.isDialer = isDialer
            self.key = key
            self.candidates = candidates
            self.nextCandidate = nextCandidate
            self.consecutiveFailures = consecutiveFailures
            self.permissions = permissions
            self.lastHeardSecondsAgo = lastHeardSecondsAgo
        }
    }

    public var browserState: String
    public var listenerState: String
    public var accessibilityTrusted: Bool
    public var tapState: TapState
    public var tapError: String?
    public var mainLoopResponsive: Bool
    public var lastExitWasCrash: Bool
    public var peers: [Peer]
    /// 闔蓋防睡快照（spec §8.4）。nil = 舊呼叫端未提供，規則略過此檢查（舊 JSON／舊 App 相容）。
    public var lidKeepAwake: LidKeepAwake?

    /// 闔蓋防睡診斷輸入。欄位皆 optional／字串化，避免綁死 C02／C03 具體型別。
    public struct LidKeepAwake: Sendable, Equatable {
        /// helper availability 的穩定字串（如 `ready`、`notRegistered`、`requiresApproval`）。
        public var helperAvailability: String
        /// 目前 SleepDisabled；nil 表示讀不到。
        public var sleepDisabled: Bool?
        public var setByHelper: Bool?
        /// 殘留分類 wire 值；nil = 無殘留。
        public var leftover: String?
        /// 各來源 health（已消毒，不含 path／uid／pid／token）。
        public var sources: [SourceHealth]

        public struct SourceHealth: Sendable, Equatable {
            public var id: String
            public var health: String
            public var reason: String?

            public init(id: String, health: String, reason: String? = nil) {
                self.id = id
                self.health = health
                self.reason = reason
            }
        }

        public init(
            helperAvailability: String,
            sleepDisabled: Bool? = nil,
            setByHelper: Bool? = nil,
            leftover: String? = nil,
            sources: [SourceHealth] = []
        ) {
            self.helperAvailability = helperAvailability
            self.sleepDisabled = sleepDisabled
            self.setByHelper = setByHelper
            self.leftover = leftover
            self.sources = sources
        }
    }

    public init(
        browserState: String, listenerState: String, accessibilityTrusted: Bool,
        tapState: TapState, tapError: String?, mainLoopResponsive: Bool,
        lastExitWasCrash: Bool, peers: [Peer],
        lidKeepAwake: LidKeepAwake? = nil
    ) {
        self.browserState = browserState
        self.listenerState = listenerState
        self.accessibilityTrusted = accessibilityTrusted
        self.tapState = tapState
        self.tapError = tapError
        self.mainLoopResponsive = mainLoopResponsive
        self.lastExitWasCrash = lastExitWasCrash
        self.peers = peers
        self.lidKeepAwake = lidKeepAwake
    }
}

public extension DoctorInputs.Peer.Phase {
    /// 由連線槽的階段換算。`hasSession` 是「真的有一條通過 hello 的 session」：
    /// slot 說 connected 但 session 已收掉的瞬間，對使用者而言就是沒連上。
    /// 退避秒數無條件進位：剩 0.3 秒時說「0 秒後重撥」沒有意義。
    init(slot: PeerSessionSlots.Phase, hasSession: Bool, now: Duration) {
        switch slot {
        case .connected:
            self = hasSession ? .connected : .idle
        case .dialing, .awaitingHello:
            self = .connecting
        case let .backoff(until):
            let seconds = max(0, (until - now).millis / 1_000)
            self = .backoff(secondsRemaining: Int(seconds.rounded(.up)))
        case .idle:
            self = .idle
        }
    }
}
