import ChorusCore
import CoreGraphics
import Foundation
import Observation

/// 照射設備配置圖的本地 UI 狀態：節點座標與背景照片。
/// 座標為 0–1 正規化（相對畫布），視窗縮放後佈局不變；純本地狀態，不參與同步。
///
/// key 格式：
/// - `display:<uuid>`——本機顯示器。
/// - `remote:<peerID>|display|<uuid>`——遠端的**單一螢幕**（`RemoteEndpointID.storageKey`）。
/// - `peer:<peerID>`——舊格式，整台 Mac 一個節點。只保留給遷移用。
///
/// 從整機節點改成逐螢幕節點的理由：一台 Mac 接兩台螢幕時，「整台 Mac 在房間
/// 的哪個位置」這個問題沒有答案——兩台螢幕可能一台朝窗、一台背光。
@MainActor
@Observable
final class DiagramStore {
    private static let positionsKey = "chorus.diagram.positions"
    private static let backgroundLabelKey = "chorus.diagram.backgroundLabel"
    private static let backgroundBaseName = "diagram-background"

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let supportDirectory: URL

    /// 節點座標（0–1 正規化）。
    private(set) var positions: [String: CGPoint] = [:]
    /// 背景照片檔案（無照片為 nil）。
    private(set) var backgroundImageURL: URL?
    /// 背景照的照明情境標註（例：「白天，窗簾拉開」）；換照片時一律清空，
    /// 免得標註留在原地描述一張已經不存在的照片。
    var backgroundLabel: String = "" {
        didSet { defaults.set(backgroundLabel, forKey: Self.backgroundLabelKey) }
    }

    init(instance: InstanceConfig) {
        defaults = instance.defaults
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        var directory = base.appendingPathComponent("Chorus", isDirectory: true)
        if let name = instance.name {
            directory = directory.appendingPathComponent("instance-\(name)", isDirectory: true)
        }
        supportDirectory = directory

        if let stored = defaults.dictionary(forKey: Self.positionsKey) as? [String: [Double]] {
            positions = stored.compactMapValues { pair in
                guard pair.count == 2 else { return nil }
                return CGPoint(x: pair[0], y: pair[1])
            }
        }
        backgroundImageURL = Self.findBackground(in: directory)
        backgroundLabel = defaults.string(forKey: Self.backgroundLabelKey) ?? ""
    }

    func position(for key: String) -> CGPoint? {
        positions[key]
    }

    /// 遠端螢幕節點的鍵。`nonisolated`：`DiagramNode.key` 是個純計算，
    /// 不該為了組一個字串把節點型別綁到 MainActor 上。
    nonisolated static func nodeKey(_ id: RemoteEndpointID) -> String {
        "remote:" + id.storageKey
    }

    /// 舊格式的整機節點鍵。
    nonisolated static func legacyPeerKey(_ peerID: String) -> String {
        "peer:" + peerID
    }

    /// 舊的整機座標 → 逐螢幕座標。
    ///
    /// **只有那台 Mac 回報唯一一台螢幕時才遷移**。有多台時保留舊記錄（管理用）
    /// 但各螢幕從預設位置開始：把兩三台螢幕全部疊到同一個點，比讓使用者重新
    /// 擺一次更糟——疊在一起的節點連拖都拖不開。
    ///
    /// 舊的整機**差異值**刻意不一併複製成每台螢幕的差異值：那個值是疊加在
    /// 整機上的，複製 N 份就會重複疊加 N 次。
    func migrateLegacyPeerPosition(peerID: String, displayUUIDs: [String]) {
        let legacy = Self.legacyPeerKey(peerID)
        guard let point = positions[legacy], displayUUIDs.count == 1 else { return }
        let key = Self.nodeKey(
            RemoteEndpointID(peerID: peerID, kind: .display, deviceID: displayUUIDs[0])
        )
        guard positions[key] == nil else { return }
        positions[key] = point
        positions.removeValue(forKey: legacy)
        persistPositions()
    }

    /// 拖拉結束後保存座標（夾在 0–1）。
    func setPosition(_ point: CGPoint, for key: String) {
        let clamped = CGPoint(
            x: min(max(point.x, 0), 1),
            y: min(max(point.y, 0), 1)
        )
        positions[key] = clamped
        persistPositions()
    }

    /// 匯入桌面照片：複製到 Application Support（保留副檔名），取代舊照片。
    func importBackground(from source: URL) {
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
            removeBackground()
            let ext = source.pathExtension.isEmpty ? "png" : source.pathExtension
            let destination = supportDirectory.appendingPathComponent("\(Self.backgroundBaseName).\(ext)")
            try fileManager.copyItem(at: source, to: destination)
            backgroundImageURL = destination
            backgroundLabel = ""
        } catch {
            // 匯入失敗維持原狀（來源不可讀等）；UI 顯示現況即可
        }
    }

    func removeBackground() {
        backgroundLabel = ""
        guard let url = backgroundImageURL ?? Self.findBackground(in: supportDirectory) else { return }
        try? FileManager.default.removeItem(at: url)
        backgroundImageURL = nil
    }

    private func persistPositions() {
        let encoded = positions.mapValues { [Double($0.x), Double($0.y)] }
        defaults.set(encoded, forKey: Self.positionsKey)
    }

    private static func findBackground(in directory: URL) -> URL? {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )) ?? []
        return contents.first { $0.deletingPathExtension().lastPathComponent == backgroundBaseName }
    }
}
