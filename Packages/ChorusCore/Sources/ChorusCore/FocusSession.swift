import Foundation

/// 限時場景（B7 專注模式）結束的原因。SSE 事件、選單提示與 log 都用它分辨。
public enum FocusEndReason: String, Codable, Sendable, Equatable, CaseIterable {
    /// 倒數走完。
    case elapsed
    /// 使用者提前結束。
    case manual
    /// 被另一個限時場景取代——一次只有一個 session。
    case replaced
    /// 結束 Chorus。與 B3「結束 Chorus 一定還原」同態度。
    case quit
    /// 上次沒有正常結束（崩潰／強制結束），重新啟動時發現已過期，立即還原。
    case relaunch
}

public extension FocusEndReason {
    /// 值得發系統通知的只有「使用者可能不在看」的兩種。
    ///
    /// 手動結束與被另一個限時場景取代都是使用者**當下的動作**，選單上立刻
    /// 看得到，再跳一則通知只是吵；結束 Chorus 更不必——App 正在關。
    var deservesNotification: Bool {
        self == .elapsed || self == .relaunch
    }
}

/// 套用限時場景**之前**的原值。
///
/// 涵蓋範圍由**場景內容**決定，不是固定清單。固定清單會漏——場景可以含
/// 對比、電源、提示音音量、亮度差異值，漏一項就是「結束後某個值沒回來」，
/// 而那正是這個功能唯一的承諾；固定清單也會多——場景沒碰音量，還原時卻
/// 把音量寫一次，會蓋掉使用者這 25 分鐘內手動調的值。**只還原我們動過的。**
public struct FocusSnapshot: Codable, Sendable, Equatable {
    /// 還原用的請求。**已展開成實體定位**（`displayUUID:`／`deviceUID:`／
    /// `app:`／`system`）且值一律是絕對值——場景裡的相對值（`+10%`）因此
    /// 天然安全，快照存的是套用前的那個絕對值。
    ///
    /// 順序＝套用順序；還原時**反向**執行（見 `restoreRequests`）。
    public var requests: [ControlRequest]

    /// 防睡眠的模式本身。**這是唯一不走 request 的一條。**
    ///
    /// `get system keepAwake` 回的是 `KeepAwakePlanner.encode(mode)`：
    /// duration 模式回的是**原始秒數**不是剩餘、綁定模式一律回 −1，
    /// 照著還原會失真——25 分鐘後把一個早該結束的長亮重新開滿。
    /// `nil` ＝ 場景沒碰防睡眠。
    public var keepAwake: KeepAwakeMode?

    /// 快照當下的剩餘秒數（只有 `.duration` 模式有值）。還原時以它重新起算。
    public var keepAwakeRemainingSeconds: Double?

    /// 套用了但**無法還原**的項目，人看得懂的描述。
    ///
    /// `input`（輸入源）是動作型 VCP、沒有 get，讀不回原值；跨機項目要等
    /// B7-4。**誠實列出，不假裝還原了**——UI 會照著講「輸入源不會自動切回」。
    public var unrestorable: [String]

    public init(
        requests: [ControlRequest] = [],
        keepAwake: KeepAwakeMode? = nil,
        keepAwakeRemainingSeconds: Double? = nil,
        unrestorable: [String] = []
    ) {
        self.requests = requests
        self.keepAwake = keepAwake
        self.keepAwakeRemainingSeconds = keepAwakeRemainingSeconds
        self.unrestorable = unrestorable
    }

    /// 沒有任何東西要還原（場景全是不可還原項，或根本是空場景）。
    public var isEmpty: Bool { requests.isEmpty && keepAwake == nil }

    /// 會還原幾項。UI 講「結束時還原 6 項」用的就是它。
    public var restorableCount: Int { requests.count + (keepAwake == nil ? 0 : 1) }
}

/// 進行中的限時場景。
///
/// 快照是一份**獨立副本**，不是對 `SceneStore` 的參照：session 進行中場景被
/// 刪除、改名或被另一個入口覆寫，都不影響還原。
public struct FocusSession: Codable, Sendable, Equatable {
    /// 顯示用。session 不依賴 `SceneStore` 裡那份還在不在。
    public var sceneName: String
    /// 時間基準是 **wall clock**，不是 `systemUptime`。
    ///
    /// `KeepAwakeController` 用 uptime 是因為它問的是「持有 assertion 多久」，
    /// 機器睡著時本來就沒在持有；限時場景問的是「到幾點幾分把東西放回去」
    /// ——闔上筆電睡 10 分鐘再打開，使用者期待倒數照走，不是延長 10 分鐘。
    public var startedAt: Date
    public var deadline: Date
    /// 套用前的原值。
    public var snapshot: FocusSnapshot
    /// 套用當下的結果（幾項生效、哪幾項失敗）。UI 與事件流要講得出來。
    public var applied: [ControlResult]

    public init(
        sceneName: String,
        startedAt: Date,
        deadline: Date,
        snapshot: FocusSnapshot,
        applied: [ControlResult] = []
    ) {
        self.sceneName = sceneName
        self.startedAt = startedAt
        self.deadline = deadline
        self.snapshot = snapshot
        self.applied = applied
    }

    private enum CodingKeys: String, CodingKey {
        case sceneName, startedAt, deadline, snapshot, applied
    }

    /// 手寫而不是讓編譯器合成：**合成的版本不會用屬性預設值**，欄位缺一個
    /// 就整份解不開。session 檔會跨版本被讀回（崩潰後接續那條路），
    /// 舊版寫下的檔案沒有後來才加的欄位——那不是損壞，是正常的。
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sceneName = try container.decode(String.self, forKey: .sceneName)
        startedAt = try container.decode(Date.self, forKey: .startedAt)
        deadline = try container.decode(Date.self, forKey: .deadline)
        snapshot = try container.decode(FocusSnapshot.self, forKey: .snapshot)
        applied = try container.decodeIfPresent([ControlResult].self, forKey: .applied) ?? []
    }
}

/// 限時場景的純邏輯：倒數、到期判定、還原請求的組裝。
///
/// 全部是純函式——時間由呼叫端傳進來，這一層不知道「現在」是什麼，
/// 測試才不必真的等 25 分鐘。
public enum FocusPlanner {
    /// 剩餘秒數，永不為負。
    public static func remainingSeconds(session: FocusSession, now: Date) -> Double {
        max(0, session.deadline.timeIntervalSince(now))
    }

    public static func isExpired(session: FocusSession, now: Date) -> Bool {
        now >= session.deadline
    }

    /// 同一實體的同一屬性只留**第一次**——那才是套用前的原值。
    ///
    /// 場景可能對同一個實體寫兩次（`allDisplays` 30% 之後又對某台寫 50%），
    /// 兩條展開後都指向同一台；留第二次的話還原成的是「第一次套用之後」的值。
    public static func deduplicated(_ requests: [ControlRequest]) -> [ControlRequest] {
        var seen = Set<String>()
        return requests.filter { request in
            let key = "\(request.target.stringValue)|\(request.property?.rawValue ?? "")"
            return seen.insert(key).inserted
        }
    }

    /// 還原請求：去重後**反向**執行。
    ///
    /// 反向的第一個理由是自動亮度（B4-5 的教訓）：場景通常是「關掉自動亮度
    /// ＋設固定亮度」，還原必須「先放回亮度、再開回自動亮度」，否則自動亮度
    /// 一開就把剛放回去的亮度覆蓋掉。反向順序剛好做到。
    ///
    /// 第二個理由是一般性的：「先關 A 再開 B」型的場景以「先關 B 再開 A」
    /// 還原，是最不會踩到彼此的順序。
    public static func restoreRequests(_ snapshot: FocusSnapshot) -> [ControlRequest] {
        deduplicated(snapshot.requests).reversed()
    }
}
