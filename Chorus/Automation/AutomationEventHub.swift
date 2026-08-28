import ChorusCore
import Foundation

/// 自動化事件流的來源（`GET /v1/events` 的 SSE 與 CLI `chorus listen`）。
///
/// 訂閱者拿到的是**任何來源**的本機變更——UI 滑桿、鍵盤媒體鍵、其他 App
/// 改音量、遠端同步套用後的結果都算。這正是 `ControlCoordinator` 的
/// local-change 回呼已經在做的事，所以直接搭在那條線上，不另外輪詢。
@MainActor
final class AutomationEventHub {
    private var subscribers: [UUID: (String) -> Void] = [:]

    /// 回傳的 token 用來取消訂閱（連線關閉時務必呼叫，否則會對死掉的
    /// NWConnection 一直寫入）。
    func subscribe(_ handler: @escaping (String) -> Void) -> UUID {
        let token = UUID()
        subscribers[token] = handler
        return token
    }

    func unsubscribe(_ token: UUID) {
        subscribers.removeValue(forKey: token)
    }

    var hasSubscribers: Bool { !subscribers.isEmpty }

    /// 發佈一則事件。payload 是已編碼的 JSON 物件字串。
    func publish(kind: String, payload: [String: Any]) {
        guard !subscribers.isEmpty else { return }
        var object = payload
        object["kind"] = kind
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8)
        else { return }
        for handler in subscribers.values {
            handler(json)
        }
    }

    func publishControlChange(key: ControlKey, value: Double) {
        let (property, target): (String, String) = switch key {
        case let .brightness(uuid): ("brightness", uuid ?? "allDisplays")
        case let .volume(uid): ("volume", uid ?? "defaultOutput")
        case let .mute(uid): ("mute", uid ?? "defaultOutput")
        case let .input(uuid): ("input", uuid ?? "allDisplays")
        case let .contrast(uuid): ("contrast", uuid ?? "allDisplays")
        case let .displayPower(uuid): ("power", uuid ?? "allDisplays")
        case .keepAwake: ("keepAwake", "system")
        // 目標寫成動詞層的定位語法，訂閱者拿到就能直接回一個請求
        case let .appVolume(bundleID): ("volume", "app:\(bundleID)")
        case let .appMute(bundleID): ("mute", "app:\(bundleID)")
        }
        publish(kind: "change", payload: ["property": property, "target": target, "value": value])
    }
}
