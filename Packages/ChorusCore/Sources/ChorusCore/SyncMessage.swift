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
}

public struct Hello: Codable, Sendable, Equatable {
    public let peerID: String
    public let deviceName: String
    public let protocolVersion: Int

    public init(peerID: String, deviceName: String, protocolVersion: Int) {
        self.peerID = peerID
        self.deviceName = deviceName
        self.protocolVersion = protocolVersion
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
