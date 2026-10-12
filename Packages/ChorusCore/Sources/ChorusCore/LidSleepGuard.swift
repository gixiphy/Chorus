import Foundation

// MARK: - Settings

/// 闔蓋防睡設定（spec §5.1）。讀取時呼叫 `normalized()`。
public struct LidSleepSettings: Sendable, Equatable, Codable {
    public var enabled: Bool
    public var batteryFloorPercent: Int
    public var maxLidClosedSeconds: Double
    public var limitDurationOnAC: Bool
    public var notificationsEnabled: Bool

    public static let allowedBatteryFloors = [30, 40, 50]
    public static let allowedMaxHours: [Double] = [2, 3, 4]

    public init(
        enabled: Bool = false,
        batteryFloorPercent: Int = 30,
        maxLidClosedSeconds: Double = 3 * 3600,
        limitDurationOnAC: Bool = true,
        notificationsEnabled: Bool = true
    ) {
        self.enabled = enabled
        self.batteryFloorPercent = batteryFloorPercent
        self.maxLidClosedSeconds = maxLidClosedSeconds
        self.limitDurationOnAC = limitDurationOnAC
        self.notificationsEnabled = notificationsEnabled
    }

    /// 產生有限且在允許範圍內的設定（§14.2：處理 NaN／infinity／負值／極端 Int）。
    public func normalized() -> LidSleepSettings {
        var copy = self
        // W0-9：不對極端 Int 做減法／abs（Int.min 溢位會 trap）
        let floors = Self.allowedBatteryFloors
        let lo = floors.first ?? 30
        let hi = floors.last ?? 50
        let floor: Int
        if floors.contains(batteryFloorPercent) {
            floor = batteryFloorPercent
        } else if batteryFloorPercent <= lo {
            floor = lo
        } else if batteryFloorPercent >= hi {
            floor = hi
        } else {
            floor = floors.min(by: { abs($0 - batteryFloorPercent) < abs($1 - batteryFloorPercent) }) ?? 30
        }
        copy.batteryFloorPercent = max(floor, 30)

        let hours = Self.allowedMaxHours
        let rawHours: Double
        if maxLidClosedSeconds.isFinite, maxLidClosedSeconds > 0 {
            rawHours = maxLidClosedSeconds / 3600
        } else {
            rawHours = 3
        }
        let nearest = hours.min(by: { abs($0 - rawHours) < abs($1 - rawHours) }) ?? 3
        copy.maxLidClosedSeconds = nearest * 3600
        return copy
    }
}

// MARK: - Inputs / state

/// Helper 可用性（App 端映射 SMAppService；policy 只看 `.ready`）。
public enum LidHelperAvailability: Sendable, Equatable {
    case notRegistered
    case requiresApproval
    case notFound
    case connecting
    case ready
    case versionMismatch(helper: String, app: String)
    case error(String)
}

public enum LidBlockReason: Sendable, Equatable, Codable {
    case lowBattery(percent: Int?, floor: Int)
    case thermal
    case maxDuration(limitSeconds: Double)
    case userPaused(untilUptime: Double)
    /// 確認無內建螢幕：Fi A3 禁止 arm（含已存設定與自動化）。
    case noLid
    /// 蓋子狀態讀取失敗：§14.2 不新建持有、既有持有保守解除。
    case lidUnknown
    /// 電源狀態未知（`onBattery == nil`）：Fi A3 拒絕新 acquire 並解除既有持有。
    case unknownPower
}

public enum LidSleepGuardPhase: Sendable, Equatable {
    case off
    case unavailable(LidHelperAvailability)
    case idle
    case armed
    case holdingLidClosed(sinceUptime: Double)
    case blocked(LidBlockReason)
}

/// 蓋子讀數（§14.2：no-lid 與讀取失敗分開；取代單純 `Bool?`）。
public enum LidClosedReading: Sendable, Equatable {
    case open
    case closed
    case noLid
    case unknown
}

public struct LidSleepGuardInput: Sendable, Equatable {
    public var settings: LidSleepSettings
    public var agentModeActive: Bool
    public var busy: Bool
    public var helper: LidHelperAvailability
    public var lid: LidClosedReading
    public var power: PowerSnapshot
    public var now: Double
    public var existingBatteryFloor: KeepAwakeBatteryFloor

    public init(
        settings: LidSleepSettings,
        agentModeActive: Bool,
        busy: Bool,
        helper: LidHelperAvailability,
        lid: LidClosedReading,
        power: PowerSnapshot,
        now: Double,
        existingBatteryFloor: KeepAwakeBatteryFloor
    ) {
        self.settings = settings
        self.agentModeActive = agentModeActive
        self.busy = busy
        self.helper = helper
        self.lid = lid
        self.power = power
        self.now = now
        self.existingBatteryFloor = existingBatteryFloor
    }
}

public struct LidSleepGuardState: Sendable, Equatable {
    public var phase: LidSleepGuardPhase
    public var lidClosedSince: Double?
    public var maxDurationLatched: Bool
    public var batteryLatched: Bool
    public var userPausedUntil: Double?

    public init(
        phase: LidSleepGuardPhase = .off,
        lidClosedSince: Double? = nil,
        maxDurationLatched: Bool = false,
        batteryLatched: Bool = false,
        userPausedUntil: Double? = nil
    ) {
        self.phase = phase
        self.lidClosedSince = lidClosedSince
        self.maxDurationLatched = maxDurationLatched
        self.batteryLatched = batteryLatched
        self.userPausedUntil = userPausedUntil
    }
}

public enum LidSleepGuardEvent: Sendable, Equatable {
    case armed
    case released(LidBlockReason?)
    case lidClosedWhileHolding
    case lidClosedWhileNotHolding
}

// MARK: - Policy

public enum LidSleepGuardPolicy {
    public static let batteryHysteresisPercent = PowerFloorPolicy.batteryHysteresisPercent

    /// 呼叫端合約（PowerSnapshot 無法表達「完全缺樣」時）：
    /// - `onBattery == nil`：未知電源 → 本 policy 阻擋（`.unknownPower`）。
    /// - `percent == nil` 且已知用電池：低電阻擋。
    /// - `thermal` 為非 optional；取樣失敗／未知 enum 時呼叫端應傳 `.serious` 或依賴 `@unknown default` 阻擋。
    /// - `hasInternalBattery == false`：無內建電池，跳過電量門檻（仍受未知電源以外規則約束）。
    public static func step(
        _ previous: LidSleepGuardState,
        input: LidSleepGuardInput
    ) -> (state: LidSleepGuardState, wantsSleepDisabled: Bool, events: [LidSleepGuardEvent]) {
        var state = previous
        let settings = input.settings.normalized()
        let now = input.now

        // §5.3.1 闔蓋計時（§14.2：只有確認開蓋才清 latch／since）
        switch input.lid {
        case .closed:
            if state.lidClosedSince == nil {
                state.lidClosedSince = now
            }
        case .open:
            state.lidClosedSince = nil
            state.maxDurationLatched = false
        case .noLid, .unknown:
            // 不清 lidClosedSince／maxDurationLatched
            break
        }

        // §14.2：off／非 Agent 優先於 userPaused（調整 §5.3.2–3 順序）
        if !settings.enabled || !input.agentModeActive {
            state.phase = .off
            return finish(previous: previous, state: state, wants: false, lid: input.lid)
        }

        // §5.3.2 使用者暫停
        if let until = state.userPausedUntil {
            if now < until {
                state.phase = .blocked(.userPaused(untilUptime: until))
                return finish(previous: previous, state: state, wants: false, lid: input.lid)
            }
            state.userPausedUntil = nil
        }

        // §5.3.4 helper
        if input.helper != .ready {
            state.phase = .unavailable(input.helper)
            return finish(previous: previous, state: state, wants: false, lid: input.lid)
        }

        // §5.3.5 !busy
        if !input.busy {
            state.phase = .idle
            return finish(previous: previous, state: state, wants: false, lid: input.lid)
        }

        // Fi A3 / §14.2：無蓋禁止 arm
        if input.lid == .noLid {
            state.phase = .blocked(.noLid)
            return finish(previous: previous, state: state, wants: false, lid: input.lid)
        }

        // §14.2：蓋子未知 — 不新建持有；既有持有保守解除
        if input.lid == .unknown {
            state.phase = .blocked(.lidUnknown)
            return finish(previous: previous, state: state, wants: false, lid: input.lid)
        }

        // §5.3.6 溫度（§14.2：未知 thermal 不得 arm）
        if isThermalBlocking(input.power.thermal) {
            state.phase = .blocked(.thermal)
            return finish(previous: previous, state: state, wants: false, lid: input.lid)
        }

        // §5.3.7 電量／電源（Fi A3：未知電源拒絕）
        if let batteryBlock = evaluateBattery(
            previous: &state,
            settings: settings,
            power: input.power,
            existingFloor: input.existingBatteryFloor
        ) {
            state.phase = .blocked(batteryBlock)
            return finish(previous: previous, state: state, wants: false, lid: input.lid)
        }

        // §5.3.8 時限（W0-2：既有 latch 優先於 AC 豁免）
        if let durationBlock = evaluateMaxDuration(
            state: &state,
            settings: settings,
            lid: input.lid,
            power: input.power,
            now: now
        ) {
            state.phase = .blocked(durationBlock)
            return finish(previous: previous, state: state, wants: false, lid: input.lid)
        }

        // §5.3.9 通過 → armed / holding
        if input.lid == .closed {
            let since = state.lidClosedSince ?? now
            state.lidClosedSince = since
            state.phase = .holdingLidClosed(sinceUptime: since)
        } else {
            state.phase = .armed
        }

        // §5.3.10
        return finish(previous: previous, state: state, wants: true, lid: input.lid)
    }

    // MARK: helpers

    private static func isThermalBlocking(_ thermal: ProcessInfo.ThermalState) -> Bool {
        switch thermal {
        case .nominal, .fair:
            return false
        case .serious, .critical:
            return true
        @unknown default:
            return true
        }
    }

    private static func evaluateBattery(
        previous state: inout LidSleepGuardState,
        settings: LidSleepSettings,
        power: PowerSnapshot,
        existingFloor: KeepAwakeBatteryFloor
    ) -> LidBlockReason? {
        guard power.hasInternalBattery else {
            state.batteryLatched = false
            return nil
        }

        // Fi A3 / W0-3：未知電源獨立阻擋，不論百分比
        if power.onBattery == nil {
            return .unknownPower
        }

        // 接上電源：清 latch
        if power.onBattery == false {
            state.batteryLatched = false
            return nil
        }

        // onBattery == true → 用電池
        let floor = max(settings.batteryFloorPercent, 30, existingFloor.rawValue)

        guard let percent = power.percent else {
            return .lowBattery(percent: nil, floor: floor)
        }

        if state.batteryLatched {
            if percent >= floor + batteryHysteresisPercent {
                state.batteryLatched = false
                return nil
            }
            return .lowBattery(percent: percent, floor: floor)
        }

        if percent < floor {
            state.batteryLatched = true
            return .lowBattery(percent: percent, floor: floor)
        }
        return nil
    }

    private static func evaluateMaxDuration(
        state: inout LidSleepGuardState,
        settings: LidSleepSettings,
        lid: LidClosedReading,
        power: PowerSnapshot,
        now: Double
    ) -> LidBlockReason? {
        let limit = settings.maxLidClosedSeconds

        // W0-2 / §14.2：既有 latch 在確認開蓋前持續有效，AC 豁免不可繞過
        if state.maxDurationLatched {
            return .maxDuration(limitSeconds: limit)
        }

        guard lid == .closed else { return nil }
        // 僅豁免「新」達到時限；未知電源已在電量步驟擋下
        if power.onBattery == false && !settings.limitDurationOnAC {
            return nil
        }

        let since = state.lidClosedSince ?? now
        if (now - since) >= limit {
            state.maxDurationLatched = true
            return .maxDuration(limitSeconds: limit)
        }
        return nil
    }

    private static func finish(
        previous: LidSleepGuardState,
        state: LidSleepGuardState,
        wants: Bool,
        lid: LidClosedReading
    ) -> (state: LidSleepGuardState, wantsSleepDisabled: Bool, events: [LidSleepGuardEvent]) {
        // §5.3.10：只有 armed／holding 才 wants=true（呼叫端已保證）
        let wantsSleepDisabled = wants && isHoldingPhase(state.phase)
        let events = emitEvents(from: previous.phase, to: state.phase, lid: lid)
        return (state, wantsSleepDisabled, events)
    }

    private static func isHoldingPhase(_ phase: LidSleepGuardPhase) -> Bool {
        switch phase {
        case .armed, .holdingLidClosed:
            return true
        default:
            return false
        }
    }

    /// §5.3.11 事件
    private static func emitEvents(
        from previous: LidSleepGuardPhase,
        to next: LidSleepGuardPhase,
        lid: LidClosedReading
    ) -> [LidSleepGuardEvent] {
        var events: [LidSleepGuardEvent] = []

        let wasHolding = isHoldingPhase(previous)
        let isHolding = isHoldingPhase(next)

        if !wasHolding && isHolding {
            events.append(.armed)
        }

        if wasHolding && !isHolding {
            let reason: LidBlockReason?
            if case let .blocked(r) = next {
                reason = r
            } else {
                reason = nil
            }
            events.append(.released(reason))
        }

        // 闔蓋事件：比較「上一 phase 是否已在 holding／armed」與本輪是否 closed
        if lid == .closed {
            switch previous {
            case .armed:
                events.append(.lidClosedWhileHolding)
            case .holdingLidClosed:
                break
            default:
                events.append(.lidClosedWhileNotHolding)
            }
        }

        return events
    }
}
