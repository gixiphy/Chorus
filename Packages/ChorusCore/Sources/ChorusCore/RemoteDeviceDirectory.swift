import Foundation

/// 逐裝置遠端控制的資料型別。
///
/// 與既有的 `ControlKey`／`StateReport` 分開的理由：那一套回報的是**整機語意值**
/// （「這台 Mac 的亮度」＝第一台顯示器、「音量」＝預設輸出），拿來畫「客廳那台
/// Mac 的第二台螢幕」的滑桿是對不回去的。這裡的每一筆都帶所屬 Mac ＋ 裝置識別碼。
///
/// 三個刻意的設計：
/// 1. 型別化的 raw-string（`RemoteEndpointKind`／`Capability`）而非 Swift enum
///    ——未來多一種端點類型時，舊版解得開整包訊息、只是不認得那一筆，
///    而 enum 會讓整則 JSON 解碼失敗。
/// 2. 目錄是**完整替換**，不是逐 key 合併：拔掉的裝置必須真的消失。
/// 3. 每份目錄帶 `sessionID` ＋ `version`；晚到的舊快照與上一次連線的回報
///    都會被接收端丟掉，不會讓已移除的端點復活。

// MARK: - 識別

/// 端點類型。字串而非 enum：見檔頭第 1 點。
public struct RemoteEndpointKind: RawRepresentable, Codable, Sendable, Hashable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    /// 顯示器（識別碼是 display UUID）。
    public static let display = RemoteEndpointKind(rawValue: "display")
    /// 音訊輸出（識別碼是 CoreAudio device UID）。
    public static let audioOutput = RemoteEndpointKind(rawValue: "audioOutput")
}

/// 端點能力／可控項目。值域與 `ControlKey` 對齊，但永遠綁定一個具體端點。
public struct RemoteEndpointCapability: RawRepresentable, Codable, Sendable, Hashable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    /// 亮度 0–1。
    public static let brightness = RemoteEndpointCapability(rawValue: "brightness")
    /// 音量 0–1。
    public static let volume = RemoteEndpointCapability(rawValue: "volume")
    /// 靜音 0／1。
    public static let mute = RemoteEndpointCapability(rawValue: "mute")
    /// 逐螢幕亮度差異值 −0.5…+0.5（配置圖用）。
    public static let brightnessOffset = RemoteEndpointCapability(rawValue: "brightnessOffset")
}

/// 端點的完整索引：**Mac ＋ 類型 ＋ 裝置識別碼**。
///
/// 三段都要：同一個 UUID 可能出現在兩台 Mac 上（同一台螢幕換接），
/// display UUID 與 audio UID 也可能長得一樣。少任何一段都會跨機或跨類型碰撞。
public struct RemoteEndpointID: Codable, Sendable, Hashable {
    public let peerID: String
    public let kind: RemoteEndpointKind
    public let deviceID: String

    public init(peerID: String, kind: RemoteEndpointKind, deviceID: String) {
        self.peerID = peerID
        self.kind = kind
        self.deviceID = deviceID
    }

    /// 持久化用的扁平鍵（UserDefaults 的字典鍵、配置圖節點鍵）。
    /// `|` 不會出現在 peerID（UUID）與類型裡；裝置識別碼放最後，
    /// 就算它自己含 `|` 也能靠 `split(maxSplits:)` 還原。
    public var storageKey: String {
        "\(peerID)|\(kind.rawValue)|\(deviceID)"
    }

    /// `storageKey` 的反解。格式不符時回 nil（舊資料、手改過的 plist）。
    public init?(storageKey: String) {
        let parts = storageKey.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3, !parts[0].isEmpty, !parts[1].isEmpty, !parts[2].isEmpty else { return nil }
        peerID = String(parts[0])
        kind = RemoteEndpointKind(rawValue: String(parts[1]))
        deviceID = String(parts[2])
    }
}

// MARK: - 目錄

/// 一個可遙控的端點。
public struct RemoteEndpoint: Codable, Sendable, Equatable {
    public let deviceID: String
    public let kind: RemoteEndpointKind
    /// 人類可讀名稱（螢幕型號、音訊裝置名）。
    public let name: String
    /// 這個端點支援哪些控制項。不支援的項目在 UI 上停用而不是假裝可用。
    public let capabilities: [RemoteEndpointCapability]
    /// 螢幕音訊端點對應的 display UUID——**只在來源機器能確認時才帶**。
    /// 用於把音訊端點歸到「螢幕」而不是「設備」分類。
    public let linkedDisplayUUID: String?
    /// 目前現值（能力 rawValue → 值）。缺席＝尚未取得，UI 顯示「—」並停用，
    /// 不以 0.5 之類的猜測值初始化可操作滑桿。
    public var values: [String: Double]
    /// 同名裝置的區別資訊（序號末碼，取不到時是短識別碼）。
    public let discriminator: String?
    /// 這個音訊端點目前是該 Mac 的預設輸出。
    public let isDefaultOutput: Bool

    public init(
        deviceID: String,
        kind: RemoteEndpointKind,
        name: String,
        capabilities: [RemoteEndpointCapability],
        linkedDisplayUUID: String? = nil,
        values: [String: Double] = [:],
        discriminator: String? = nil,
        isDefaultOutput: Bool = false
    ) {
        self.deviceID = deviceID
        self.kind = kind
        self.name = name
        self.capabilities = capabilities
        self.linkedDisplayUUID = linkedDisplayUUID
        self.values = values
        self.discriminator = discriminator
        self.isDefaultOutput = isDefaultOutput
    }

    public func supports(_ capability: RemoteEndpointCapability) -> Bool {
        capabilities.contains(capability)
    }

    public func value(_ capability: RemoteEndpointCapability) -> Double? {
        values[capability.rawValue]
    }
}

/// 一台 Mac 的完整端點快照。**完整替換語意**：收到就整份換掉，
/// 不與前一份逐 key 合併——否則拔掉的裝置會永遠留在清單裡。
public struct DeviceDirectory: Codable, Sendable, Equatable {
    /// 產生這份快照的 Mac。
    public let peerID: String
    /// 這條連線的識別。重連換一個新的——上一次連線晚到的回報因此可以丟掉。
    public let sessionID: UUID
    /// 同一 session 內單調遞增。舊版本的快照與回報一律忽略。
    public let version: UInt64
    /// `var` 只為了讓接收端就地更新某個端點的現值——**整份替換的語意不變**，
    /// 沒有任何路徑會往裡面新增或移除端點。
    public var endpoints: [RemoteEndpoint]

    public init(peerID: String, sessionID: UUID, version: UInt64, endpoints: [RemoteEndpoint]) {
        self.peerID = peerID
        self.sessionID = sessionID
        self.version = version
        self.endpoints = endpoints
    }

    public func endpoint(kind: RemoteEndpointKind, deviceID: String) -> RemoteEndpoint? {
        endpoints.first { $0.kind == kind && $0.deviceID == deviceID }
    }
}

/// 「把你的端點清單給我」。連上線、或使用者打開管理介面時送。
public struct DeviceDirectoryQuery: Codable, Sendable, Equatable {
    public let id: UUID

    public init(id: UUID = UUID()) {
        self.id = id
    }
}

/// 單一端點的現值變化。**純資訊**：收到只更新顯示，不套用到本機硬體、不進 LWW。
public struct EndpointStateUpdate: Codable, Sendable, Equatable {
    public let sessionID: UUID
    /// 這筆回報對應的目錄版本。比手上的目錄舊就丟掉。
    public let version: UInt64
    public let deviceID: String
    public let kind: RemoteEndpointKind
    public let capability: RemoteEndpointCapability
    public let value: Double

    public init(
        sessionID: UUID,
        version: UInt64,
        deviceID: String,
        kind: RemoteEndpointKind,
        capability: RemoteEndpointCapability,
        value: Double
    ) {
        self.sessionID = sessionID
        self.version = version
        self.deviceID = deviceID
        self.kind = kind
        self.capability = capability
        self.value = value
    }
}

/// 對單一端點下指令。與 `Command` 分開：那個走整機語意層並且會進 LWW 廣播，
/// 這個**只動指定的端點**，不因整機同步開關擴散到其他端點。
public struct EndpointCommand: Codable, Sendable, Equatable {
    public let id: UUID
    public let deviceID: String
    public let kind: RemoteEndpointKind
    public let capability: RemoteEndpointCapability
    public let value: Double

    public init(
        id: UUID = UUID(),
        deviceID: String,
        kind: RemoteEndpointKind,
        capability: RemoteEndpointCapability,
        value: Double
    ) {
        self.id = id
        self.deviceID = deviceID
        self.kind = kind
        self.capability = capability
        self.value = value
    }
}

/// 指令結果。`id` 對應發出的 `EndpointCommand`——滑桿才知道該把待套用值
/// 換成確認值、還是回復並顯示錯誤。
public struct EndpointCommandResult: Codable, Sendable, Equatable {
    /// 結果類別。字串而非 enum：見檔頭第 1 點。
    public struct Outcome: RawRepresentable, Codable, Sendable, Hashable {
        public let rawValue: String

        public init(rawValue: String) {
            self.rawValue = rawValue
        }

        /// 已套用，`value` 是硬體確認後的值。
        public static let applied = Outcome(rawValue: "applied")
        /// 指令到達時端點已不存在（拔掉了）。**不退回控制其他裝置**。
        public static let unavailable = Outcome(rawValue: "unavailable")
        /// 端點還在但寫入失敗。
        public static let failed = Outcome(rawValue: "failed")
    }

    public let id: UUID
    public let outcome: Outcome
    /// 確認後的值（`applied` 時必有）。
    public let value: Double?
    /// 失敗原因的簡短說明（已在來源機器本地化）。
    public let message: String?

    public init(id: UUID, outcome: Outcome, value: Double? = nil, message: String? = nil) {
        self.id = id
        self.outcome = outcome
        self.value = value
        self.message = message
    }
}
