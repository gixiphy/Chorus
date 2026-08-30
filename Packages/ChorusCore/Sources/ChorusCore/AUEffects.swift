import Foundation

/// AU 效果鏈（B6-8）的純模型層。裁決見 `DESIGN-20260830-au-hosting.md`：
/// 裝置級效果鏈、in-process AUv2、generic UI、隔離閂。
/// 這裡只有可測的資料與決策；碰 AudioToolbox 的實作在 app 層。

/// 一個 AU 元件的識別（AudioComponentDescription 的可存檔子集）。
public struct AUEffectComponent: Codable, Sendable, Hashable {
    public var type: UInt32
    public var subtype: UInt32
    public var manufacturer: UInt32

    public init(type: UInt32, subtype: UInt32, manufacturer: UInt32) {
        self.type = type
        self.subtype = subtype
        self.manufacturer = manufacturer
    }

    /// 隔離閂與設定裡用的穩定字串識別。十六進位而不是 fourcc 文字——
    /// fourcc 不保證是可列印字元，塞進 JSON/檔名會出事。
    public var key: String {
        String(format: "%08x-%08x-%08x", type, subtype, manufacturer)
    }
}

/// 效果鏈裡的一格：元件＋使用者狀態＋參數存檔。
public struct AUEffectEntry: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var component: AUEffectComponent
    /// 顯示用快取——外掛被移除後清單仍要能列出它（並說明找不到）。
    public var name: String
    public var manufacturerName: String
    public var enabled: Bool
    /// `kAudioUnitProperty_ClassInfo` 的序列化內容＝標準 aupreset，
    /// 可攜到其他宿主。nil＝外掛預設狀態。
    public var classInfo: Data?

    public init(
        id: UUID = UUID(),
        component: AUEffectComponent,
        name: String,
        manufacturerName: String,
        enabled: Bool = true,
        classInfo: Data? = nil
    ) {
        self.id = id
        self.component = component
        self.name = name
        self.manufacturerName = manufacturerName
        self.enabled = enabled
        self.classInfo = classInfo
    }
}

/// 隔離閂（crash 態度，DESIGN §1.1）的純決策。
///
/// 流程：實例化前把元件 key 寫進「載入中」閂；成功後清掉。
/// 啟動時發現閂裡有殘留＝上次載它時整個 App 被帶走 → 進隔離名單，
/// 之後不自動載入，要使用者明確點「再試一次」才解除。
public enum EffectQuarantine {
    /// App 啟動時的收養：殘留的載入中 key 併進隔離名單。
    public static func adopt(
        pendingLoadKey: String?, into quarantined: Set<String>
    ) -> Set<String> {
        guard let pendingLoadKey, !pendingLoadKey.isEmpty else { return quarantined }
        return quarantined.union([pendingLoadKey])
    }

    /// 這一格現在能不能自動實例化。
    public static func mayLoad(
        _ component: AUEffectComponent, quarantined: Set<String>
    ) -> Bool {
        !quarantined.contains(component.key)
    }
}
