import Foundation

/// 電量底線選項。`off` 關掉電量判斷；其餘為觸發百分比。
public enum KeepAwakeBatteryFloor: Int, Sendable, Codable, CaseIterable, Equatable, Hashable {
    case off = 0
    case percent10 = 10
    case percent20 = 20
    case percent30 = 30

    public static let `default` = KeepAwakeBatteryFloor.percent20
}

/// 目前電源／溫度快照。讀不到的欄位用 nil，政策層會維持上一次判斷。
public struct PowerSnapshot: Sendable, Equatable {
    public var hasInternalBattery: Bool
    /// `true` = 用電池、`false` = 接電源、`nil` = 讀不到。
    public var onBattery: Bool?
    public var percent: Int?
    public var thermal: ProcessInfo.ThermalState

    public init(
        hasInternalBattery: Bool,
        onBattery: Bool?,
        percent: Int?,
        thermal: ProcessInfo.ThermalState
    ) {
        self.hasInternalBattery = hasInternalBattery
        self.onBattery = onBattery
        self.percent = percent
        self.thermal = thermal
    }
}

/// 電量／溫度底線的評估結果。`.ok` 與「溫度偏高但未暫停」無關——
/// `.serious` 只在 App 層當警告，不進這個 enum。
public enum PowerFloorState: Sendable, Equatable {
    case ok
    case lowBattery(percent: Int)
    case critical

    public var isTripped: Bool {
        switch self {
        case .ok: false
        case .lowBattery, .critical: true
        }
    }
}

public enum PowerFloorPolicy {
    /// 觸發後要回到「底線 + 這幾個百分點」才恢復，避免在門檻附近抖動。
    public static let batteryHysteresisPercent = 5

    /// 純函式：依快照、設定與上一次狀態算出這一次該不該暫停。
    public static func evaluate(
        snapshot: PowerSnapshot,
        floor: KeepAwakeBatteryFloor,
        previous: PowerFloorState
    ) -> PowerFloorState {
        if snapshot.thermal == .critical {
            return .critical
        }

        if case .critical = previous {
            switch snapshot.thermal {
            case .nominal, .fair:
                break
            case .serious, .critical:
                return .critical
            @unknown default:
                return .critical
            }
        }

        return evaluateBattery(snapshot: snapshot, floor: floor, previous: previous)
    }

    private static func evaluateBattery(
        snapshot: PowerSnapshot,
        floor: KeepAwakeBatteryFloor,
        previous: PowerFloorState
    ) -> PowerFloorState {
        guard floor != .off, snapshot.hasInternalBattery else { return .ok }

        if snapshot.onBattery == false { return .ok }

        let wasLow: Bool
        if case .lowBattery = previous {
            wasLow = true
        } else {
            wasLow = false
        }

        guard let percent = snapshot.percent else {
            return wasLow ? previous : .ok
        }

        let threshold = floor.rawValue
        let recovery = threshold + batteryHysteresisPercent

        if wasLow {
            return percent >= recovery ? .ok : .lowBattery(percent: percent)
        }

        guard snapshot.onBattery == true, percent < threshold else { return .ok }
        return .lowBattery(percent: percent)
    }
}
