import ChorusCore
import Foundation
import Observation

/// 場景的儲存與查找（B4-5）。純持久層——擷取目前狀態與執行都在
/// `AutomationExecutor`，因為那裡才拿得到各個 manager。
@MainActor
@Observable
final class SceneStore {
    private(set) var scenes: [ControlScene] = []

    @ObservationIgnored private let defaults: UserDefaults
    private static let key = "chorus.automation.scenes"

    init(defaults: UserDefaults) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.key),
           let stored = try? JSONDecoder().decode([ControlScene].self, from: data) {
            scenes = stored
        }
    }

    func scene(named name: String) -> ControlScene? {
        scenes.scene(named: name)
    }

    /// 新增或覆寫同名場景。名稱去頭尾空白後為空即忽略。
    func save(_ scene: ControlScene) {
        let name = scene.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        var updated = scene
        updated.name = name
        if let index = scenes.firstIndex(where: { $0.matches(name: name) }) {
            // 同名視為覆寫，但保留原本的 id——CLI／HTTP 用名稱定位，
            // 換 id 會讓已經記著 id 的地方指到空的。
            updated.id = scenes[index].id
            scenes[index] = updated
        } else {
            scenes.append(updated)
        }
        persist()
    }

    /// 整份換掉（B8 匯入備份用）。名稱去頭尾空白後為空的條目一併丟掉，
    /// 與 `save` 同一條規則。
    func replaceAll(_ incoming: [ControlScene]) {
        scenes = incoming.compactMap { scene in
            var copy = scene
            copy.name = scene.name.trimmingCharacters(in: .whitespacesAndNewlines)
            return copy.name.isEmpty ? nil : copy
        }
        persist()
    }

    func delete(id: UUID) {
        scenes.removeAll { $0.id == id }
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(scenes) else { return }
        defaults.set(data, forKey: Self.key)
    }
}
