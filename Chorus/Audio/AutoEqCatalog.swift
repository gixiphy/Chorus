import ChorusCore
import Foundation
import Observation

/// AutoEq 耳機校正的取得層（B6-5）。
///
/// **來源：AutoEq**（https://github.com/jaakkopasanen/AutoEq，MIT 授權）。
/// 量測資料由 oratory1990、Crinacle、Rtings 等提供，AutoEq 據此算出
/// 參數式 EQ。授權允許使用，需標註來源——設定頁的面板會把來源顯示出來。
///
/// **為什麼是內建清單而不是抓整份索引**：AutoEq 有幾千個型號，索引檔的
/// 格式又不是穩定介面（它是給人看的 Markdown）。硬解析它等於把一個
/// 隨時會壞的相依塞進主線功能。內建清單涵蓋常見型號，其餘型號走
/// 「貼上校正檔」——那條路離線可用、任何型號都可用，而且永遠不會壞。
@MainActor
@Observable
final class AutoEqCatalog {
    struct Entry: Identifiable, Sendable, Hashable {
        /// 顯示名稱。
        let name: String
        /// AutoEq repo 內的目錄（不含檔名）。
        let path: String
        var id: String { path }

        /// `<目錄>/<型號> ParametricEQ.txt`——AutoEq 的檔名慣例是
        /// 「目錄名 ＋ 空格 ＋ ParametricEQ.txt」。
        var fileName: String {
            let model = path.split(separator: "/").last.map(String.init) ?? name
            return "\(model) ParametricEQ.txt"
        }
    }

    private(set) var isDownloading = false
    private(set) var lastError: String?

    @ObservationIgnored private let cacheDirectory: URL
    @ObservationIgnored private let session: URLSession

    /// GitHub raw。走 raw 而不是 API：沒有 rate limit、沒有 token、
    /// 回來的就是檔案本身。
    private static let base = "https://raw.githubusercontent.com/jaakkopasanen/AutoEq/master/results/"

    init(instance: InstanceConfig, session: URLSession = .shared) {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        var directory = base.appendingPathComponent("Chorus", isDirectory: true)
        if let name = instance.name {
            directory = directory.appendingPathComponent("instance-\(name)", isDirectory: true)
        }
        cacheDirectory = directory.appendingPathComponent("autoeq", isDirectory: true)
        self.session = session
    }

    func search(_ query: String) -> [Entry] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return Self.builtIn }
        return Self.builtIn.filter {
            $0.name.range(of: trimmed, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }

    /// 取得某個型號的校正。**先看快取**——同一支耳機不該每次開設定頁
    /// 都打一次網路，而且快取讓離線時仍然套得上已經下載過的型號。
    func settings(for entry: Entry) async -> EQSettings? {
        if let cached = cachedText(for: entry),
           let parsed = AutoEqParser.parse(cached, sourceName: "AutoEq · \(entry.name)") {
            return parsed
        }
        isDownloading = true
        lastError = nil
        defer { isDownloading = false }

        let path = entry.path + "/" + entry.fileName
        guard let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: Self.base + encoded)
        else {
            lastError = "無法組出下載網址"
            return nil
        }
        do {
            let (data, response) = try await session.data(from: url)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                lastError = "下載失敗（HTTP \(http.statusCode)）——AutoEq 可能已移動這個型號的路徑"
                return nil
            }
            let text = String(decoding: data, as: UTF8.self)
            guard let parsed = AutoEqParser.parse(text, sourceName: "AutoEq · \(entry.name)") else {
                lastError = "下載到的內容不是有效的 ParametricEQ 檔"
                return nil
            }
            cache(text, for: entry)
            return parsed
        } catch {
            lastError = "下載失敗：\(error.localizedDescription)"
            return nil
        }
    }

    /// 使用者自己貼上的校正檔（離線、任何型號都適用的那條路）。
    func settings(fromPastedText text: String) -> EQSettings? {
        AutoEqParser.parse(text, sourceName: "貼上的校正檔")
    }

    // MARK: - 快取

    private func cacheURL(for entry: Entry) -> URL {
        let slug = entry.path.replacingOccurrences(of: "/", with: "_")
        return cacheDirectory.appendingPathComponent("\(slug).txt")
    }

    private func cachedText(for entry: Entry) -> String? {
        try? String(contentsOf: cacheURL(for: entry), encoding: .utf8)
    }

    private func cache(_ text: String, for entry: Entry) {
        try? FileManager.default.createDirectory(
            at: cacheDirectory, withIntermediateDirectories: true
        )
        try? text.write(to: cacheURL(for: entry), atomically: true, encoding: .utf8)
    }

    // MARK: - 內建清單

    /// 常見型號。路徑是 AutoEq repo 的 `results/` 之下的目錄。
    /// 找不到想要的型號時走「貼上校正檔」——那條路涵蓋全部。
    static let builtIn: [Entry] = [
        .init(name: "AirPods Pro 2", path: "rtings/harman_in-ear_2019v2/Apple AirPods Pro 2"),
        .init(name: "AirPods Max", path: "rtings/harman_over-ear_2018/Apple AirPods Max"),
        .init(name: "AirPods 3", path: "rtings/harman_in-ear_2019v2/Apple AirPods 3"),
        .init(name: "Sony WH-1000XM5", path: "rtings/harman_over-ear_2018/Sony WH-1000XM5"),
        .init(name: "Sony WH-1000XM4", path: "oratory1990/harman_over-ear_2018/Sony WH-1000XM4"),
        .init(name: "Sony WF-1000XM4", path: "oratory1990/harman_in-ear_2019v2/Sony WF-1000XM4"),
        .init(name: "Bose QuietComfort 45", path: "rtings/harman_over-ear_2018/Bose QuietComfort 45"),
        .init(name: "Bose QuietComfort Ultra", path: "rtings/harman_over-ear_2018/Bose QuietComfort Ultra Headphones"),
        .init(name: "Sennheiser HD 600", path: "oratory1990/harman_over-ear_2018/Sennheiser HD 600"),
        .init(name: "Sennheiser HD 650", path: "oratory1990/harman_over-ear_2018/Sennheiser HD 650"),
        .init(name: "Sennheiser HD 800 S", path: "oratory1990/harman_over-ear_2018/Sennheiser HD 800 S"),
        .init(name: "Sennheiser HD 660S", path: "oratory1990/harman_over-ear_2018/Sennheiser HD 660 S"),
        .init(name: "Beyerdynamic DT 770 Pro 80 Ohm", path: "oratory1990/harman_over-ear_2018/Beyerdynamic DT 770 PRO 80 Ohm"),
        .init(name: "Beyerdynamic DT 990 Pro", path: "oratory1990/harman_over-ear_2018/Beyerdynamic DT 990 PRO 250 Ohm"),
        .init(name: "Audio-Technica ATH-M50x", path: "oratory1990/harman_over-ear_2018/Audio-Technica ATH-M50x"),
        .init(name: "AKG K371", path: "oratory1990/harman_over-ear_2018/AKG K371"),
        .init(name: "AKG K702", path: "oratory1990/harman_over-ear_2018/AKG K702"),
        .init(name: "HIFIMAN Sundara", path: "oratory1990/harman_over-ear_2018/HIFIMAN Sundara"),
        .init(name: "HIFIMAN HE400se", path: "crinacle/harman_over-ear_2018/HIFIMAN HE400se"),
        .init(name: "Focal Clear", path: "oratory1990/harman_over-ear_2018/Focal Clear"),
        .init(name: "Moondrop Aria", path: "crinacle/harman_in-ear_2019v2/Moondrop Aria"),
        .init(name: "Moondrop Chu", path: "crinacle/harman_in-ear_2019v2/Moondrop Chu"),
        .init(name: "7Hz Salnotes Zero", path: "crinacle/harman_in-ear_2019v2/7Hz Salnotes Zero"),
        .init(name: "Etymotic ER2XR", path: "crinacle/harman_in-ear_2019v2/Etymotic ER2XR"),
        .init(name: "Samsung Galaxy Buds2 Pro", path: "rtings/harman_in-ear_2019v2/Samsung Galaxy Buds2 Pro"),
        .init(name: "Bose QuietComfort Earbuds II", path: "rtings/harman_in-ear_2019v2/Bose QuietComfort Earbuds II"),
        .init(name: "Nothing Ear (2)", path: "rtings/harman_in-ear_2019v2/Nothing Ear (2)"),
        .init(name: "Shure SE215", path: "oratory1990/harman_in-ear_2019v2/Shure SE215"),
    ]
}
