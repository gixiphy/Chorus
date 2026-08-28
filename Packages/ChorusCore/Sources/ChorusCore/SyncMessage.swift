import Foundation

/// 同步協定訊息。全部走 Codable JSON，單筆 <1KB。
public enum SyncMessage: Codable, Sendable {
    /// 連線後首發：身分與版本。
    case hello(Hello)
    /// 狀態變更廣播（origin 直發所有 peer，收到者永不轉發）。
    case stateUpdate(StateUpdate)
    /// 遙控指令：要求對方套用變更（對方套用後以自己為 origin 廣播結果）。
    case command(Command)
    /// 完整狀態快照（新 peer 連上或重連後互換）。
    case fullState(FullState)
    /// 心跳。
    case ping(UInt64)
    case pong(UInt64)
    /// 環境光基準回報（感器來源 → 全 mesh；v1 舊版 peer 會逐則丟棄，安全）。
    case ambientReport(AmbientReport)
    /// 要求對方調整整機亮度差異值（配置圖遠端編輯用；舊版 peer 靜默忽略）。
    case setDeviceOffset(DeviceOffsetCommand)
    /// 要求對方回報現值（打開遙控滑桿時；舊版 peer 靜默忽略）。
    case stateQuery(StateQuery)
    /// 現值回報：**純資訊**，收到者只更新顯示，永不套用到硬體、也不進 LWW。
    case stateReport(StateReport)
}

/// 「你現在的亮度／音量是多少？」——遙控滑桿要顯示對方的實際值，
/// 而 stateUpdate 只在對方**變更**時才發（同步關掉時連發都不發）。
public struct StateQuery: Codable, Sendable, Equatable {
    public let id: UUID

    public init(id: UUID = UUID()) {
        self.id = id
    }
}

/// 現值回報。刻意與 FullState 分開：FullState 是 LWW 狀態的一部分，
/// 收到會套用到硬體；這個只是「我現在長這樣」，拿來畫遙控滑桿的位置。
public struct StateReport: Codable, Sendable, Equatable {
    public struct Entry: Codable, Sendable, Equatable {
        public let key: ControlKey
        /// 0–1 正規化值（mute 用 0/1）。
        public let value: Double

        public init(key: ControlKey, value: Double) {
            self.key = key
            self.value = value
        }
    }

    public let entries: [Entry]

    public init(entries: [Entry]) {
        self.entries = entries
    }
}

public struct Hello: Codable, Sendable, Equatable {
    public let peerID: String
    public let deviceName: String
    public let protocolVersion: Int
    /// 裝置類型："mac"；未來 iOS 伴侶 App 為 "iphone"/"ipad"。舊版無此欄 → nil。
    public let deviceKind: String?
    /// 能力清單（如 ["als","display","audio"]；"als" 僅在實際偵測到光感器時帶）。
    public let capabilities: [String]?

    public init(
        peerID: String,
        deviceName: String,
        protocolVersion: Int,
        deviceKind: String? = nil,
        capabilities: [String]? = nil
    ) {
        self.peerID = peerID
        self.deviceName = deviceName
        self.protocolVersion = protocolVersion
        self.deviceKind = deviceKind
        self.capabilities = capabilities
    }
}

/// 環境光基準回報。狀態獨立於 SyncEngineCore／fullState（見 AmbientSyncCore 註解）。
public struct AmbientReport: Codable, Sendable, Equatable {
    /// 產出此讀值的感器裝置。
    public let originID: String
    /// 同一 origin 去舊用；跨來源排序不使用（選源是 sticky，非 LWW）。
    public let hlc: HLCTimestamp
    /// 平滑後的環境光（≥ 0）。
    public let lux: Double

    public init(originID: String, hlc: HLCTimestamp, lux: Double) {
        self.originID = originID
        self.hlc = hlc
        self.lux = lux
    }
}

/// 遠端調整整機亮度差異值。接收端負責 clamp 到 -0.5…+0.5。
public struct DeviceOffsetCommand: Codable, Sendable, Equatable {
    public let id: UUID
    public let offset: Double

    public init(id: UUID = UUID(), offset: Double) {
        self.id = id
        self.offset = offset
    }
}

public struct StateUpdate: Codable, Sendable, Equatable {
    /// 最初發起變更的裝置（非轉發者；本協定禁止轉發）。
    public let originID: String
    /// 該 origin 的單調遞增序號（與 originID 組成去重 key）。
    public let seq: UInt64
    public let hlc: HLCTimestamp
    public let key: ControlKey
    /// 0–1 正規化值。
    public let value: Double

    public init(originID: String, seq: UInt64, hlc: HLCTimestamp, key: ControlKey, value: Double) {
        self.originID = originID
        self.seq = seq
        self.hlc = hlc
        self.key = key
        self.value = value
    }
}

public struct Command: Codable, Sendable, Equatable {
    public let id: UUID
    public let key: ControlKey
    public let value: Double

    public init(id: UUID = UUID(), key: ControlKey, value: Double) {
        self.id = id
        self.key = key
        self.value = value
    }
}

public struct FullState: Codable, Sendable, Equatable {
    public struct Entry: Codable, Sendable, Equatable {
        public let key: ControlKey
        public let value: Double
        public let hlc: HLCTimestamp

        public init(key: ControlKey, value: Double, hlc: HLCTimestamp) {
            self.key = key
            self.value = value
            self.hlc = hlc
        }
    }

    public let entries: [Entry]

    public init(entries: [Entry]) {
        self.entries = entries
    }
}
