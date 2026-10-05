import Foundation

/// 某個已配對裝置可以對**這台** Mac 做什麼。
///
/// 檢查一律在接收端：發送端把按鈕藏起來只是體驗，不是安全邊界。
/// `Hello.capabilities` 說的是對方**能**做什麼；這裡說的是我們**允許**它做什麼。
public struct PeerPermissionPolicy: Codable, Sendable, Equatable {
    /// 控制類別。raw-string struct 而非 enum：新版多一個類別時，
    /// 舊版仍解得開整份配對記錄，只是不認得那一筆。
    public struct Control: RawRepresentable, Codable, Sendable, Hashable {
        public let rawValue: String

        public init(rawValue: String) {
            self.rawValue = rawValue
        }

        /// 亮度、對比、整機亮度差異值。
        public static let brightness = Control(rawValue: "brightness")
        /// 音量、靜音、逐 App 音量與靜音。
        public static let audio = Control(rawValue: "audio")
        /// 螢幕電源與輸入源——會讓畫面消失，所以單獨一類。
        public static let displayPower = Control(rawValue: "displayPower")
        /// 防睡眠。
        public static let keepAwake = Control(rawValue: "keepAwake")

        public static let all: [Control] = [.brightness, .audio, .displayPower, .keepAwake]
    }

    /// 是否接受對方的同步狀態與環境光基準（stateUpdate／fullState／ambientReport）。
    /// 與 `allowedControls` 無關：同步是「兩台收斂到同一個值」，遙控是「替我改一次」。
    public var acceptsSync: Bool
    public var allowedControls: Set<Control>

    public init(acceptsSync: Bool, allowedControls: Set<Control>) {
        self.acceptsSync = acceptsSync
        self.allowedControls = allowedControls
    }

    /// 舊記錄沒有權限欄位時的預設：與升級前行為一致。
    public static let full = PeerPermissionPolicy(acceptsSync: true, allowedControls: Set(Control.all))
    /// 只能查看：可以查詢現值與裝置目錄，不能改任何東西。
    public static let viewOnly = PeerPermissionPolicy(acceptsSync: false, allowedControls: [])

    public func allows(_ key: ControlKey) -> Bool {
        allowedControls.contains(Control(key))
    }

    /// 入站訊息怎麼處理。switch 刻意不寫 default：日後新增 `SyncMessage` case
    /// 時編譯器會逼人在這裡做決定，而不是預設放行。
    public func admission(for message: SyncMessage) -> PeerAdmission {
        switch message {
        case .stateUpdate, .fullState, .ambientReport:
            return acceptsSync ? .allow : .drop
        case let .command(command):
            return allows(command.key) ? .allow : .drop
        case .setDeviceOffset:
            return allowedControls.contains(.brightness) ? .allow : .drop
        case let .endpointCommand(command):
            guard let control = Control(command.capability), allowedControls.contains(control) else {
                return .rejectEndpointCommand(id: command.id)
            }
            return .allow
        case .hello, .ping, .pong, .stateQuery, .stateReport,
             .deviceDirectoryQuery, .deviceDirectory, .endpointState, .endpointCommandResult:
            return .allow
        }
    }
}

/// 入站訊息的判斷結果。
public enum PeerAdmission: Sendable, Equatable {
    case allow
    /// 靜默丟棄：同步訊息與舊版 `command` 沒有回覆管道。
    case drop
    /// 逐端點指令被拒：要回 `denied` 結果，對方的滑桿才不會卡在待套用。
    case rejectEndpointCommand(id: UUID)
}

public extension PeerPermissionPolicy.Control {
    init(_ key: ControlKey) {
        switch key {
        case .brightness, .contrast: self = .brightness
        case .volume, .mute, .appVolume, .appMute: self = .audio
        case .displayPower, .input: self = .displayPower
        case .keepAwake: self = .keepAwake
        }
    }

    /// 不認得的能力回傳 nil，呼叫端要當成拒絕：新版發來、我們不認得的控制不放行。
    init?(_ capability: RemoteEndpointCapability) {
        switch capability {
        case .brightness, .brightnessOffset: self = .brightness
        case .volume, .mute: self = .audio
        default: return nil
        }
    }
}
