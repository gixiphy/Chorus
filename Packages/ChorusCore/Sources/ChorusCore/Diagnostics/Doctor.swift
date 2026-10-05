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

        public var peerID: String
        public var deviceName: String
        public var phase: Phase
        /// peerID 較小的一方負責撥號（`PeerSessionSlots.isDialer`）。
        public var isDialer: Bool
        public var hasPSK: Bool
        /// 撥號候選（已依優先序、去重），以 `String(describing:)` 表示。
        public var candidates: [String]
        public var nextCandidate: String?
        public var consecutiveFailures: Int
        public var permissions: PeerPermissionPolicy
        public var lastHeardSecondsAgo: Int?

        public init(
            peerID: String, deviceName: String, phase: Phase, isDialer: Bool, hasPSK: Bool,
            candidates: [String], nextCandidate: String?, consecutiveFailures: Int,
            permissions: PeerPermissionPolicy, lastHeardSecondsAgo: Int?
        ) {
            self.peerID = peerID
            self.deviceName = deviceName
            self.phase = phase
            self.isDialer = isDialer
            self.hasPSK = hasPSK
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

    public init(
        browserState: String, listenerState: String, accessibilityTrusted: Bool,
        tapState: TapState, tapError: String?, mainLoopResponsive: Bool,
        lastExitWasCrash: Bool, peers: [Peer]
    ) {
        self.browserState = browserState
        self.listenerState = listenerState
        self.accessibilityTrusted = accessibilityTrusted
        self.tapState = tapState
        self.tapError = tapError
        self.mainLoopResponsive = mainLoopResponsive
        self.lastExitWasCrash = lastExitWasCrash
        self.peers = peers
    }
}
