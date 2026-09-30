import Foundation

/// 藍牙耳機電量。來源是 `system_profiler SPBluetoothDataType` 的字串百分比。
public struct HeadsetBattery: Sendable, Equatable {
    public var main: Int?
    public var left: Int?
    public var right: Int?
    public var chargingCase: Int?

    public enum Level: Sendable, Equatable {
        case normal
        case low
        case critical
    }

    public init(main: Int?, left: Int?, right: Int?, chargingCase: Int?) {
        self.main = main
        self.left = left
        self.right = right
        self.chargingCase = chargingCase
    }

    /// 頂端與列上顯示的單一數字：main ?? min(left, right) ?? left ?? right；充電盒不算。
    public var displayPercent: Int? {
        if let main { return main }
        switch (left, right) {
        case let (l?, r?): return min(l, r)
        case let (l?, nil): return l
        case let (nil, r?): return r
        case (nil, nil): return nil
        }
    }

    /// 分級：≤10 critical、≤20 low、其餘 normal（給選單著色與電池符號用）。
    public var level: Level? {
        guard let percent = displayPercent else { return nil }
        if percent <= 10 { return .critical }
        if percent <= 20 { return .low }
        return .normal
    }

    /// 四欄都沒有有效百分比時為空——報告裡不該收錄這種裝置。
    public var isEmpty: Bool {
        main == nil && left == nil && right == nil && chargingCase == nil
    }
}

/// CoreAudio 藍牙輸出 UID ↔ system_profiler 的 MAC。
public enum BluetoothAddress {
    /// `"94-16-25-48-CC-A9:output"` → `"94:16:25:48:CC:A9"`；不是這個格式就回 nil。
    public static func fromAudioUID(_ uid: String) -> String? {
        let parts = uid.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, parts[1] == "output" || parts[1] == "input" else { return nil }
        let hex = parts[0].split(separator: "-")
        guard hex.count == 6, hex.allSatisfy({ $0.count == 2 && $0.allSatisfy(\.isHexDigit) }) else {
            return nil
        }
        return hex.map { $0.uppercased() }.joined(separator: ":")
    }

    /// 正規化成大寫冒號格式，方便當字典 key。
    public static func normalize(_ address: String) -> String {
        address.replacingOccurrences(of: "-", with: ":").uppercased()
    }
}

/// 解析 `system_profiler SPBluetoothDataType -json` 的電量欄。
public enum BluetoothBatteryReport {
    /// 只讀 `device_connected`；key 是正規化（大寫、冒號）的 MAC。
    /// 百分比解析失敗、超出 0–100 → 該欄 nil；四欄都 nil → 不收錄。0% 是有效值。
    public static func parse(_ json: Data) -> [String: HeadsetBattery]? {
        guard let root = try? JSONSerialization.jsonObject(with: json) else { return nil }
        var result: [String: HeadsetBattery] = [:]
        collectConnected(from: root, into: &result)
        return result
    }

    private static func collectConnected(from node: Any, into result: inout [String: HeadsetBattery]) {
        if let dict = node as? [String: Any] {
            if let connected = dict["device_connected"] as? [Any] {
                for entry in connected {
                    guard let named = entry as? [String: Any] else { continue }
                    for (_, value) in named {
                        guard let info = value as? [String: Any],
                              let address = info["device_address"] as? String
                        else { continue }
                        let battery = HeadsetBattery(
                            main: percent(info["device_batteryLevelMain"]),
                            left: percent(info["device_batteryLevelLeft"]),
                            right: percent(info["device_batteryLevelRight"]),
                            chargingCase: percent(info["device_batteryLevelCase"])
                        )
                        guard !battery.isEmpty else { continue }
                        result[BluetoothAddress.normalize(address)] = battery
                    }
                }
            }
            for value in dict.values {
                collectConnected(from: value, into: &result)
            }
        } else if let array = node as? [Any] {
            for value in array {
                collectConnected(from: value, into: &result)
            }
        }
    }

    private static func percent(_ raw: Any?) -> Int? {
        guard let text = raw as? String else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasSuffix("%") else { return nil }
        let number = trimmed.dropLast()
        guard let value = Int(number), (0...100).contains(value) else { return nil }
        return value
    }
}

/// 輪詢節奏與過期判斷——放 Core 方便測，App 層只負責執行。
public enum HeadsetBatteryPolicy {
    public static let pollInterval: Duration = .seconds(60)
    public static let staleAfter: Duration = .seconds(180)
    public static let menuOpenRefreshAfter: Duration = .seconds(30)
    public static let connectRetries: [Duration] = [.seconds(3), .seconds(10)]

    public static func shouldPoll(hasTarget: Bool, menuBarEnabled: Bool, menuOpen: Bool) -> Bool {
        hasTarget && (menuBarEnabled || menuOpen)
    }

    public static func isStale(age: Duration) -> Bool {
        age >= staleAfter
    }

    public static func shouldRefreshOnMenuOpen(age: Duration?) -> Bool {
        guard let age else { return true }
        return age >= menuOpenRefreshAfter
    }
}
