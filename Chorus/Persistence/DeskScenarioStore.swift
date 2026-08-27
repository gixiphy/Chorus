import ChorusCore
import CoreGraphics
import Foundation
import Observation

/// 一個桌面情境（家／公司…）：配置圖與自動亮度的完整快照，
/// 以「當時連接中的顯示器 UUID 組合」為指紋供自動切換。
struct DeskScenario: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    /// 指紋：建立或「更新情境」時連接中的顯示器 UUID。
    var displayUUIDs: Set<String>
    /// 配置圖節點座標（0–1 正規化，key 同 DiagramStore）。
    var positions: [String: [Double]]
    /// 情境資料夾內的背景照檔名；無照片為 nil。
    var photoFilename: String?
    var curve: AmbientCurve
    var displayOffsets: [String: Double]
    var deviceOffset: Double
    var excludedDisplays: Set<String>
}

/// 指紋匹配（純邏輯，可測）。
enum DeskScenarioMatcher {
    /// Jaccard 相似度：|交集|／|聯集|。
    static func score(_ a: Set<String>, _ b: Set<String>) -> Double {
        let union = a.union(b).count
        guard union > 0 else { return 0 }
        return Double(a.intersection(b).count) / Double(union)
    }

    static let switchThreshold = 0.5

    /// 應自動切換到的情境；nil ＝ 維持現狀。
    /// 規則：最佳分數需 ≥ 門檻，且**嚴格優於**現行情境的分數
    /// （並列最佳時不切，避免拔插瞬間來回抖動）。
    static func autoSwitchTarget(
        current: Set<String>,
        activeID: UUID?,
        scenarios: [(id: UUID, signature: Set<String>)]
    ) -> UUID? {
        guard !current.isEmpty, !scenarios.isEmpty else { return nil }
        let scored = scenarios.map { (id: $0.id, score: score($0.signature, current)) }
        guard let best = scored.max(by: { $0.score < $1.score }),
              best.score >= switchThreshold else { return nil }
        let activeScore = scored.first { $0.id == activeID }?.score ?? -1
        return best.score > activeScore ? best.id : nil
    }
}

/// 桌面情境的持久化與切換協調。
///
/// 存讀語意：live 狀態（DiagramStore＋SettingsStore）永遠是 active 情境的
/// 最新版——啟動時**不**回灌；只在「切換走」時把 live 存回原情境、
/// 「切換到」時把目標情境載入 live。App 結束前也存一次。
@MainActor
@Observable
final class DeskScenarioStore {
    private(set) var scenarios: [DeskScenario] = []
    private(set) var activeID: UUID?

    var activeScenario: DeskScenario? {
        scenarios.first { $0.id == activeID }
    }

    @ObservationIgnored private let settings: SettingsStore
    @ObservationIgnored private let diagram: DiagramStore
    @ObservationIgnored private weak var displayManager: DisplayManager?
    @ObservationIgnored private weak var autoBrightness: AutoBrightnessController?
    @ObservationIgnored private let directory: URL
    @ObservationIgnored private var fileURL: URL { directory.appendingPathComponent("scenarios.json") }
    @ObservationIgnored private var debounceTask: Task<Void, Never>?

    private struct FilePayload: Codable {
        var activeID: UUID?
        var scenarios: [DeskScenario]
    }

    init(
        instance: InstanceConfig,
        settings: SettingsStore,
        diagram: DiagramStore,
        displayManager: DisplayManager,
        autoBrightness: AutoBrightnessController
    ) {
        self.settings = settings
        self.diagram = diagram
        self.displayManager = displayManager
        self.autoBrightness = autoBrightness

        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        var dir = base.appendingPathComponent("Chorus", isDirectory: true)
        if let name = instance.name {
            dir = dir.appendingPathComponent("instance-\(name)", isDirectory: true)
        }
        directory = dir.appendingPathComponent("scenarios", isDirectory: true)

        if let data = try? Data(contentsOf: fileURL),
           let payload = try? JSONDecoder().decode(FilePayload.self, from: data) {
            scenarios = payload.scenarios
            activeID = payload.activeID
        }
    }

    // MARK: - 建立／更新／刪除

    /// 把目前 live 狀態存為新情境並設為 active。
    func createFromCurrent(named name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var scenario = DeskScenario(
            id: UUID(),
            name: trimmed,
            displayUUIDs: currentDisplayUUIDs(),
            positions: [:],
            photoFilename: nil,
            curve: settings.ambientCurve,
            displayOffsets: settings.ambientDisplayOffsets,
            deviceOffset: settings.ambientDeviceOffset,
            excludedDisplays: settings.ambientExcludedDisplays
        )
        captureLive(into: &scenario)
        scenarios.append(scenario)
        activeID = scenario.id
        persist()
    }

    /// 把 live 狀態存回 active 情境；`refreshSignature` 一併更新螢幕指紋。
    func saveLiveIntoActive(refreshSignature: Bool = false) {
        guard let index = scenarios.firstIndex(where: { $0.id == activeID }) else { return }
        captureLive(into: &scenarios[index])
        if refreshSignature {
            scenarios[index].displayUUIDs = currentDisplayUUIDs()
        }
        persist()
    }

    func deleteActive() {
        guard let id = activeID else { return }
        if let scenario = scenarios.first(where: { $0.id == id }), let photo = scenario.photoFilename {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(photo))
        }
        scenarios.removeAll { $0.id == id }
        activeID = nil
        persist()
    }

    // MARK: - 切換

    func switchTo(_ id: UUID) {
        guard id != activeID, scenarios.contains(where: { $0.id == id }) else { return }
        saveLiveIntoActive()
        activeID = id
        loadActiveIntoLive()
        persist()
    }

    /// DisplayManager 每次 refresh 完成後呼叫；防抖 2 秒後依指紋自動切換
    /// （dock／undock 時螢幕會連環變動）。
    func displaysDidChange(_ uuids: Set<String>) {
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, let self else { return }
            let target = DeskScenarioMatcher.autoSwitchTarget(
                current: uuids,
                activeID: self.activeID,
                scenarios: self.scenarios.map { ($0.id, $0.displayUUIDs) }
            )
            if let target { self.switchTo(target) }
        }
    }

    /// App 結束前（applicationWillTerminate）保存 live。
    func saveOnTerminate() {
        guard activeID != nil else { return }
        saveLiveIntoActive()
    }

    // MARK: - live ↔ 情境

    private func captureLive(into scenario: inout DeskScenario) {
        scenario.positions = diagram.positions.mapValues { [Double($0.x), Double($0.y)] }
        scenario.curve = settings.ambientCurve
        scenario.displayOffsets = settings.ambientDisplayOffsets
        scenario.deviceOffset = settings.ambientDeviceOffset
        scenario.excludedDisplays = settings.ambientExcludedDisplays

        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let live = diagram.backgroundImageURL {
            let filename = "\(scenario.id.uuidString).\(live.pathExtension)"
            let destination = directory.appendingPathComponent(filename)
            try? FileManager.default.removeItem(at: destination)
            if (try? FileManager.default.copyItem(at: live, to: destination)) != nil {
                if let old = scenario.photoFilename, old != filename {
                    try? FileManager.default.removeItem(at: directory.appendingPathComponent(old))
                }
                scenario.photoFilename = filename
            }
        } else {
            if let old = scenario.photoFilename {
                try? FileManager.default.removeItem(at: directory.appendingPathComponent(old))
            }
            scenario.photoFilename = nil
        }
    }

    private func loadActiveIntoLive() {
        guard let scenario = activeScenario else { return }
        diagram.replacePositions(scenario.positions.compactMapValues { pair in
            pair.count == 2 ? CGPoint(x: pair[0], y: pair[1]) : nil
        })
        if let photo = scenario.photoFilename {
            diagram.importBackground(from: directory.appendingPathComponent(photo))
        } else {
            diagram.removeBackground()
        }
        settings.ambientCurve = scenario.curve
        settings.ambientDisplayOffsets = scenario.displayOffsets
        settings.ambientDeviceOffset = scenario.deviceOffset
        settings.ambientExcludedDisplays = scenario.excludedDisplays
        autoBrightness?.reapplyTargets()
    }

    private func currentDisplayUUIDs() -> Set<String> {
        Set(displayManager?.displays.map(\.uuid) ?? [])
    }

    private func persist() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let payload = FilePayload(activeID: activeID, scenarios: scenarios)
        if let data = try? JSONEncoder().encode(payload) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}
