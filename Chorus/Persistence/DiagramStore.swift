import CoreGraphics
import Foundation
import Observation

/// 照射設備配置圖的本地 UI 狀態：節點座標與背景照片。
/// 座標為 0–1 正規化（相對畫布），視窗縮放後佈局不變；
/// key 格式 "display:<uuid>"（本機顯示器）／"peer:<peerID>"（已配對裝置）。
/// 純本地狀態，不參與同步。
@MainActor
@Observable
final class DiagramStore {
    private static let positionsKey = "chorus.diagram.positions"
    private static let backgroundBaseName = "diagram-background"

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let supportDirectory: URL

    /// 節點座標（0–1 正規化）。
    private(set) var positions: [String: CGPoint] = [:]
    /// 背景照片檔案（無照片為 nil）。
    private(set) var backgroundImageURL: URL?

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
    }

    func position(for key: String) -> CGPoint? {
        positions[key]
    }

    /// 情境切換：整組座標取代（DeskScenarioStore 專用）。
    func replacePositions(_ new: [String: CGPoint]) {
        positions = new
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
        } catch {
            // 匯入失敗維持原狀（來源不可讀等）；UI 顯示現況即可
        }
    }

    func removeBackground() {
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
