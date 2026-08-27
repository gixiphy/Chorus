import AppKit
import ChorusCore
import CryptoKit
import Foundation
import Observation

/// 一次完成的分析結果（sheet 的資料源）。advice 已過 `sanitized(for:)`。
struct AdviceResult: Identifiable {
    let id = UUID()
    let advice: LightingAdvice
    let context: AdviceContext
    let date: Date
    /// 從歷史重看（非新分析）。
    let fromHistory: Bool
}

/// 光環境顧問協調者：產縮圖暫存檔、組 AdviceContext、呼叫引擎、
/// sanitize、歷史 5 筆、套用／單層還原（設計文件 §2、§4）。
@MainActor
@Observable
final class LightingAdvisor {
    private(set) var isAnalyzing = false
    private(set) var lastErrorMessage: String?
    /// 設定後 UI 開建議 sheet；關閉時清 nil。
    var result: AdviceResult?

    @ObservationIgnored private let settings: SettingsStore
    @ObservationIgnored private weak var displayManager: DisplayManager?
    @ObservationIgnored private let pairedPeers: PairedPeersStore
    @ObservationIgnored private weak var autoBrightness: AutoBrightnessController?
    @ObservationIgnored private weak var coordinator: ControlCoordinator?
    @ObservationIgnored private let diagram: DiagramStore
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let historyURL: URL
    @ObservationIgnored private var analysisTask: Task<Void, Never>?

    let registry: AdviceEngineRegistry

    private static let snapshotKey = "chorus.advisor.lastSnapshot"
    private static let historyLimit = 5
    /// 縮圖長邊上限與 JPEG 品質（設計文件 §3）。
    private nonisolated static let thumbnailMaxEdge: CGFloat = 1344
    private nonisolated static let thumbnailQuality = 0.7

    init(
        instance: InstanceConfig,
        settings: SettingsStore,
        displayManager: DisplayManager,
        pairedPeers: PairedPeersStore,
        autoBrightness: AutoBrightnessController,
        coordinator: ControlCoordinator,
        diagram: DiagramStore
    ) {
        self.settings = settings
        self.displayManager = displayManager
        self.pairedPeers = pairedPeers
        self.autoBrightness = autoBrightness
        self.coordinator = coordinator
        self.diagram = diagram
        defaults = instance.defaults
        registry = AdviceEngineRegistry(settings: settings)

        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        var directory = base.appendingPathComponent("Chorus", isDirectory: true)
        if let name = instance.name {
            directory = directory.appendingPathComponent("instance-\(name)", isDirectory: true)
        }
        historyURL = directory.appendingPathComponent("advisor-history.json")
    }

    // MARK: - 分析

    var canAnalyze: Bool {
        diagram.backgroundImageURL != nil && registry.activeEngine != nil
    }

    func analyze() {
        guard !isAnalyzing else { return }
        guard let photoURL = diagram.backgroundImageURL else {
            lastErrorMessage = "請先匯入桌面照片"
            return
        }
        guard let engine = registry.activeEngine else {
            lastErrorMessage = "未找到可用的分析引擎（設定 → 分析引擎）"
            return
        }
        let provider = CLIAdviceProvider(engine: engine.engine, executable: engine.url)
        run(provider: provider, photoURL: photoURL)
    }

    func cancelAnalysis() {
        analysisTask?.cancel()
    }

    private func run(provider: any LightingAdviceProvider, photoURL: URL?) {
        isAnalyzing = true
        lastErrorMessage = nil
        let context = buildContext()
        analysisTask = Task { [weak self] in
            defer {
                self?.isAnalyzing = false
                self?.analysisTask = nil
            }
            var thumbnailURL: URL?
            defer { if let thumbnailURL { try? FileManager.default.removeItem(at: thumbnailURL) } }
            do {
                let photoPath: String
                if let photoURL {
                    let thumb = try Self.makeThumbnail(from: photoURL)
                    thumbnailURL = thumb
                    photoPath = thumb.path
                } else {
                    photoPath = "(無照片)"
                }
                let raw = try await provider.advise(photoPath: photoPath, context: context)
                guard let self, !Task.isCancelled else { return }
                let advice = raw.sanitized(for: context)
                let entry = AdviceResult(advice: advice, context: context, date: Date(), fromHistory: false)
                self.appendHistory(advice: advice, photoURL: photoURL)
                self.result = entry
            } catch is CancellationError {
                // 使用者取消：不顯示錯誤
            } catch let error as AdviceError {
                self?.lastErrorMessage = error.userMessage
            } catch {
                self?.lastErrorMessage = "分析失敗：\(error.localizedDescription)"
            }
        }
    }

    // MARK: - Context 組裝

    /// 本機顯示器＋已配對裝置節點；只含名稱／backend／座標／offset，
    /// 不含金鑰材料與網路資訊（設計文件 §5）。
    func buildContext() -> AdviceContext {
        var infos: [AdviceContext.DisplayInfo] = []
        for display in displayManager?.displays ?? [] {
            let key = "display:\(display.uuid)"
            infos.append(.init(
                id: key,
                name: display.name,
                backend: backendString(display.backend),
                normalizedPosition: diagram.position(for: key).map { [Double($0.x), Double($0.y)] },
                currentOffset: settings.ambientDisplayOffsets[display.uuid] ?? 0
            ))
        }
        for peer in pairedPeers.peers {
            let key = "peer:\(peer.peerID)"
            infos.append(.init(
                id: key,
                name: peer.deviceName,
                backend: "remote",
                normalizedPosition: diagram.position(for: key).map { [Double($0.x), Double($0.y)] },
                currentOffset: 0
            ))
        }
        return AdviceContext(
            displays: infos,
            curve: settings.ambientCurve,
            recentLux: autoBrightness?.recentLuxStats()
        )
    }

    private func backendString(_ backend: BrightnessBackend) -> String {
        switch backend {
        case .ddc: "ddc"
        case .displayServices: "displayServices"
        case .gammaOnly: "gamma"
        }
    }

    // MARK: - 套用與還原

    /// 套用勾選項：offset 走既有路徑（本機直接設、peer 送 command）、
    /// 曲線參數進 SettingsStore；套用前 snapshot 舊值供單層還原。
    func apply(
        _ advice: LightingAdvice,
        selectedOffsetIDs: Set<String>,
        applyMaxLux: Bool,
        applyMinBrightness: Bool
    ) {
        var snapshot = ApplySnapshot(
            displayOffsets: [:],
            minBrightness: settings.ambientCurve.minBrightness,
            maxLux: settings.ambientCurve.maxLux
        )
        for suggestion in advice.offsets where selectedOffsetIDs.contains(suggestion.displayID) {
            if let uuid = localDisplayUUID(from: suggestion.displayID) {
                snapshot.displayOffsets[uuid] = settings.ambientDisplayOffsets[uuid] ?? 0
                autoBrightness?.setDisplayOffset(suggestion.offset, for: uuid)
            } else if let peerID = peerID(from: suggestion.displayID) {
                // peer 的舊值讀不到（已知限制），還原時跳過
                coordinator?.sendDeviceOffset(to: peerID, offset: suggestion.offset)
            }
        }
        var curveChanged = false
        if applyMaxLux, let maxLux = advice.maxLux {
            settings.ambientCurve.maxLux = maxLux
            curveChanged = true
        }
        if applyMinBrightness, let minBrightness = advice.minBrightness {
            settings.ambientCurve.minBrightness = minBrightness
            curveChanged = true
        }
        if curveChanged { autoBrightness?.reapplyTargets() }
        saveSnapshot(snapshot)
    }

    var canUndo: Bool { defaults.data(forKey: Self.snapshotKey) != nil }

    /// 還原上次套用（單層）：本機 offset 與曲線；peer offset 無舊值可還原。
    func undoLastApply() {
        guard let data = defaults.data(forKey: Self.snapshotKey),
              let snapshot = try? JSONDecoder().decode(ApplySnapshot.self, from: data) else { return }
        for (uuid, offset) in snapshot.displayOffsets {
            autoBrightness?.setDisplayOffset(offset, for: uuid)
        }
        settings.ambientCurve.minBrightness = snapshot.minBrightness
        settings.ambientCurve.maxLux = snapshot.maxLux
        autoBrightness?.reapplyTargets()
        defaults.removeObject(forKey: Self.snapshotKey)
    }

    private func saveSnapshot(_ snapshot: ApplySnapshot) {
        if let data = try? JSONEncoder().encode(snapshot) {
            defaults.set(data, forKey: Self.snapshotKey)
        }
    }

    private func localDisplayUUID(from id: String) -> String? {
        id.hasPrefix("display:") ? String(id.dropFirst("display:".count)) : nil
    }

    private func peerID(from id: String) -> String? {
        id.hasPrefix("peer:") ? String(id.dropFirst("peer:".count)) : nil
    }

    private struct ApplySnapshot: Codable {
        var displayOffsets: [String: Double]
        var minBrightness: Double
        var maxLux: Double
    }

    // MARK: - 歷史（最近 5 筆，照片重拍前不必重花呼叫）

    struct HistoryEntry: Codable {
        var date: Date
        var photoHash: String?
        var advice: LightingAdvice
    }

    private(set) var history: [HistoryEntry] = []
    @ObservationIgnored private var historyLoaded = false

    func loadHistoryIfNeeded() {
        guard !historyLoaded else { return }
        historyLoaded = true
        guard let data = try? Data(contentsOf: historyURL),
              let entries = try? JSONDecoder().decode([HistoryEntry].self, from: data) else { return }
        history = entries
    }

    /// 重看最近一次分析（不重呼叫引擎；以目前裝置狀態重新 sanitize）。
    func showLatestHistory() {
        loadHistoryIfNeeded()
        guard let latest = history.first else { return }
        let context = buildContext()
        result = AdviceResult(
            advice: latest.advice.sanitized(for: context),
            context: context,
            date: latest.date,
            fromHistory: true
        )
    }

    private func appendHistory(advice: LightingAdvice, photoURL: URL?) {
        loadHistoryIfNeeded()
        let hash = photoURL.flatMap { url -> String? in
            guard let data = try? Data(contentsOf: url) else { return nil }
            return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
        history.insert(HistoryEntry(date: Date(), photoHash: hash, advice: advice), at: 0)
        if history.count > Self.historyLimit {
            history.removeLast(history.count - Self.historyLimit)
        }
        do {
            try FileManager.default.createDirectory(
                at: historyURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(history)
            try data.write(to: historyURL, options: .atomic)
        } catch {
            // 歷史寫入失敗不影響本次結果
        }
    }

    // MARK: - 縮圖

    /// 背景照 → 長邊 ≤1344px、JPEG q0.7 的暫存檔；分析完即刪（呼叫端 defer）。
    private nonisolated static func makeThumbnail(from source: URL) throws -> URL {
        guard let image = NSImage(contentsOf: source) else {
            throw AdviceError.processFailed(status: 0, stderr: "無法讀取背景照片")
        }
        var rect = CGRect(origin: .zero, size: image.size)
        guard let cgImage = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else {
            throw AdviceError.processFailed(status: 0, stderr: "無法解碼背景照片")
        }
        let width = CGFloat(cgImage.width)
        let height = CGFloat(cgImage.height)
        let scale = min(1, thumbnailMaxEdge / max(width, height))
        let targetWidth = Int(width * scale)
        let targetHeight = Int(height * scale)

        let finalImage: CGImage
        if scale < 1, let context = CGContext(
            data: nil, width: targetWidth, height: targetHeight,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) {
            context.interpolationQuality = .high
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))
            finalImage = context.makeImage() ?? cgImage
        } else {
            finalImage = cgImage
        }

        let rep = NSBitmapImageRep(cgImage: finalImage)
        guard let jpeg = rep.representation(
            using: .jpeg,
            properties: [.compressionFactor: thumbnailQuality]
        ) else {
            throw AdviceError.processFailed(status: 0, stderr: "無法產生縮圖")
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("chorus-advisor-\(UUID().uuidString).jpg")
        try jpeg.write(to: url)
        return url
    }

    // MARK: - DEBUG 注入（TestHooks）

    #if DEBUG
    /// injectAdvice：以 FakeAdviceProvider 走完整管線（context → sanitize → sheet）。
    func debugInject(adviceJSON: String) {
        guard !isAnalyzing,
              let data = adviceJSON.data(using: .utf8),
              let advice = try? JSONDecoder().decode(LightingAdvice.self, from: data) else { return }
        run(provider: FakeAdviceProvider(advice: advice), photoURL: nil)
    }

    /// applyAdvice：無頭套用目前結果的全部建議（E2E 斷言用）。
    func debugApplyAll() {
        guard let result else { return }
        apply(
            result.advice,
            selectedOffsetIDs: Set(result.advice.offsets.map(\.displayID)),
            applyMaxLux: result.advice.maxLux != nil,
            applyMinBrightness: result.advice.minBrightness != nil
        )
    }
    #endif
}
