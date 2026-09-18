import Foundation

/// 具名的狀態組合（B4-5）。選單列、CLI 與 localhost HTTP 觸發的是同一份。
///
/// 這是「使用者具名、**手動或被程式觸發**的動作組」——描述意圖，不描述環境。
/// 每台螢幕與輸出裝置各自的設定（差異值、排除、配置圖位置）本來就以裝置
/// UUID 為 key 記在 live 狀態裡，接上哪台就用哪台的，不需要另一層「情境」。
public struct ControlScene: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var name: String
    /// 依序執行的請求。**逐條獨立套用**——某一條失敗（例如場景建立時在的
    /// 螢幕現在拔掉了）不該讓整個場景放棄。
    public var requests: [ControlRequest]

    public init(id: UUID = UUID(), name: String, requests: [ControlRequest]) {
        self.id = id
        self.name = name
        self.requests = requests
    }

    /// 名稱比對：忽略大小寫、變音符號與全半形，並去頭尾空白。
    /// CLI 打 `chorus scene 電影` 不該因為存的是「電影 」而找不到。
    public func matches(name query: String) -> Bool {
        Self.normalized(name) == Self.normalized(query)
    }

    static func normalized(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                     locale: nil)
    }
}

public extension Array where Element == ControlScene {
    /// 依名稱找場景（先精確，再退回前綴比對——CLI 打前幾個字就能中）。
    func scene(named query: String) -> ControlScene? {
        if let exact = first(where: { $0.matches(name: query) }) { return exact }
        let needle = ControlScene.normalized(query)
        guard !needle.isEmpty else { return nil }
        let prefixed = filter { ControlScene.normalized($0.name).hasPrefix(needle) }
        // 只有唯一一個前綴相符才算數；兩個以上是歧義，寧可讓呼叫端報錯
        return prefixed.count == 1 ? prefixed[0] : nil
    }
}
