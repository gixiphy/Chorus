import ChorusCore
import Foundation

/// All time inputs are supplied by the caller. No helper or wall-clock reads in presentation tests.
enum LidMenuStatusFormatter {
    enum Action: Equatable { case allow, pause, resume, manage }
    struct Presentation: Equatable {
        let symbol: String
        let text: String
        let help: String
        let action: Action?
        let showsHoldingBadge: Bool
    }

    /// A holder is not ownership: a foreign pre-existing 1 may have a caller holder too.
    /// Never hide that warning behind an unconfirmed own-hold request.
    static func visibleLeftover(_ explicit: LeftoverSleepDisabled?, helperStatus: PowerHelperStatus?) -> LeftoverSleepDisabled? {
        if let explicit { return explicit }
        guard let status = helperStatus else { return nil }
        if status.recoveryBlocked || status.pendingRestore || status.persistRetryNeeded { return .recoveryBlocked }
        if status.sleepDisabled == true && !status.setByHelper { return .foreign }
        return nil
    }

    static func format(
        phase: LidSleepGuardPhase, enabled: Bool, agentModeActive: Bool,
        confirmedHolding: Bool, leftover: LeftoverSleepDisabled?, sources: [KeepAwakeSourceReport],
        nowUptime: Double, wallNow: Date, maxDurationSeconds: Double, releaseAt: Date?,
        timeZone: TimeZone = .current
    ) -> Presentation? {
        let help = sources.map { report in
            let name = sourceName(report)
            let health: String
            switch report.health {
            case .ok: health = String(localized: "正常")
            case let .degraded(reason): health = String(localized: "降級：\(reason)")
            case let .unavailable(reason): health = String(localized: "來源無法使用：\(reason)")
            }
            return "\(name) — \(health)"
        }.joined(separator: "\n")
        func row(_ symbol: String, _ text: String, _ action: Action? = nil, held: Bool = false) -> Presentation {
            Presentation(symbol: symbol, text: text, help: help, action: action, showsHoldingBadge: held)
        }
        // Recovery / other live holders remain visible even with the feature and Agent mode off (§14.2).
        if let leftover {
            let text: String
            switch leftover {
            case .foreign, .unknownOwner:
                text = String(localized: "系統目前不會睡眠（SleepDisabled=1）")
            case .ownResidual:
                text = String(localized: "Chorus 的睡眠設定尚未還原")
            case .otherUserHolding:
                text = String(localized: "其他 Chorus 連線正保持系統清醒")
            case .recoveryBlocked:
                text = String(localized: "睡眠設定還原尚未確認，請處理")
            }
            return row("exclamationmark.triangle", text, .manage)
        }
        guard enabled, agentModeActive else { return nil }
        switch phase {
        case .off: return nil
        case .unavailable(.requiresApproval):
            return row("exclamationmark.triangle", String(localized: "闔蓋會睡：輔助程序待允許"), .allow)
        case let .unavailable(availability):
            let reason = helperReason(availability)
            return row("exclamationmark.triangle", String(localized: "闔蓋會睡：輔助程序無法使用（\(reason)）"), .manage)
        case .idle:
            return row("laptopcomputer", String(localized: "闔蓋會睡（沒有工作中的來源）"))
        case .armed:
            guard confirmedHolding else { return row("laptopcomputer", String(localized: "正在啟用闔蓋防睡…"), .pause) }
            let summary = sourceSummary(sources)
            var text = summary.isEmpty ? String(localized: "闔蓋也不睡") : String(localized: "闔蓋也不睡 · \(summary)")
            if let releaseAt {
                let remaining = countdown(releaseAt.timeIntervalSince(wallNow))
                text += String(localized: "（收工後 \(remaining) 解除）")
            }
            return row("laptopcomputer", text, .pause, held: true)
        case let .holdingLidClosed(sinceUptime):
            guard confirmedHolding else { return row("laptopcomputer", String(localized: "正在啟用闔蓋防睡…"), .pause) }
            let remaining = countdown(maxDurationSeconds - max(0, nowUptime - sinceUptime))
            return row("laptopcomputer", String(localized: "闔蓋中保持清醒 · 剩 \(remaining)（時限）"), .pause, held: true)
        case let .blocked(.lowBattery(percent, floor)):
            if let percent {
                return row("battery.25", String(localized: "闔蓋會睡：電量 \(percent)%（底線 \(floor)%）"))
            }
            return row("battery.25", String(localized: "闔蓋會睡：讀不到電量（底線 \(floor)%）"))
        case .blocked(.thermal):
            return row("thermometer.high", String(localized: "闔蓋會睡：溫度過高"))
        case let .blocked(.maxDuration(limitSeconds)):
            let hours = Int(min(3, max(0, limitSeconds.isFinite ? limitSeconds / 3600 : 3)))
            return row("timer", String(localized: "闔蓋已達 \(hours) 小時上限，開蓋後重新計算"))
        case let .blocked(.userPaused(untilUptime)):
            let offset = untilUptime - nowUptime
            let date = wallNow.addingTimeInterval(offset.isFinite ? max(0, offset) : 0)
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = timeZone
            formatter.dateFormat = "HH:mm"
            let until = formatter.string(from: date)
            return row("pause.circle", String(localized: "闔蓋防睡已暫停（至 \(until)）"), .resume)
        case .blocked(.noLid):
            return row("laptopcomputer", String(localized: "此 Mac 沒有螢幕蓋，無法啟用闔蓋防睡"))
        case .blocked(.lidUnknown):
            return row("questionmark.circle", String(localized: "闔蓋會睡：讀不到螢幕蓋狀態"))
        case .blocked(.unknownPower):
            return row("battery.0", String(localized: "闔蓋會睡：讀不到電源狀態"))
        }
    }

    static func sourceSummary(_ sources: [KeepAwakeSourceReport]) -> String {
        let summary = sources.prefix(3).map(sourceName).joined(separator: String(localized: "、"))
        return sources.count > 3 ? String(localized: "\(summary) 等 \(sources.count) 個") : summary
    }
    private static func sourceName(_ report: KeepAwakeSourceReport) -> String {
        guard let detail = report.detail, !detail.isEmpty else { return report.displayName }
        return String(localized: "\(report.displayName)（\(detail)）")
    }
    private static func countdown(_ seconds: Double) -> String {
        // Bound conversions defensively; real values are <=3h / 300s.
        StatusIcon.countdownText(remainingSeconds: seconds.isFinite ? min(86_400, max(0, seconds)) : 0)
    }
    private static func helperReason(_ value: LidHelperAvailability) -> String {
        switch value {
        case .notRegistered: String(localized: "尚未安裝")
        case .requiresApproval: String(localized: "等待允許")
        case .notFound: String(localized: "找不到輔助程序")
        case .connecting: String(localized: "正在連線…")
        case .ready: String(localized: "等待確認")
        case .versionMismatch: String(localized: "版本不相容")
        case let .error(message): message
        }
    }
}
