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
    /// 錯誤訊息旁的協助動作（複製登入指令／開設定）；隨訊息一起設定與清除。
    private(set) var lastErrorAssist: AdviceError.Assist?
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
        extraPhotosDirectory = directory.appendingPathComponent("advisor-extra-photos", isDirectory: true)
        loadExtraPhotos()
        loadExtraPhotoLabels()
    }

    // MARK: - 補充照片（多角度；第一張分析照恆為配置圖背景照）

    /// 補充視角照片（不含背景照）。持久化於 Application Support。
    private(set) var extraPhotos: [URL] = []
    @ObservationIgnored private let extraPhotosDirectory: URL
    /// 背景照＋補充照的總數上限（控制 CLI 呼叫成本）。
    static let maxPhotos = 4

    /// 補充照的照明情境標註，以檔名為鍵（檔名是匯入時生成的 UUID，不會撞號）。
    /// 情境切換只搬背景照、不動補充照，所以這組鍵不會錯位。
    private var extraPhotoLabels: [String: String] = [:] {
        didSet { defaults.set(extraPhotoLabels, forKey: Self.extraLabelsKey) }
    }

    private static let extraLabelsKey = "chorus.advisor.extraPhotoLabels"

    func label(for photo: URL) -> String {
        extraPhotoLabels[photo.lastPathComponent] ?? ""
    }

    /// 存使用者原本輸入的字串——邊打字邊 trim 會讓空白鍵按不出來；
    /// 送進 prompt 前才由 AdvicePrompt 統一 trim。
    func setLabel(_ label: String, for photo: URL) {
        if label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            extraPhotoLabels.removeValue(forKey: photo.lastPathComponent)
        } else {
            extraPhotoLabels[photo.lastPathComponent] = label
        }
    }

    /// 常用的照明情境，供 UI 一鍵填入。
    static let labelSuggestions = [
        String(localized: "白天，窗簾拉開"), String(localized: "白天，窗簾拉上"),
        String(localized: "夜晚，只開掛燈"), String(localized: "夜晚，開頂燈"), String(localized: "全部關燈"),
    ]

    func importExtraPhotos(from sources: [URL]) {
        let fm = FileManager.default
        try? fm.createDirectory(at: extraPhotosDirectory, withIntermediateDirectories: true)
        for source in sources {
            guard extraPhotos.count < Self.maxPhotos - 1 else { break }
            let ext = source.pathExtension.isEmpty ? "png" : source.pathExtension
            let destination = extraPhotosDirectory.appendingPathComponent("\(UUID().uuidString).\(ext)")
            if (try? fm.copyItem(at: source, to: destination)) != nil {
                extraPhotos.append(destination)
            }
        }
    }

    func clearExtraPhotos() {
        for url in extraPhotos {
            try? FileManager.default.removeItem(at: url)
        }
        extraPhotos = []
        extraPhotoLabels = [:]
    }

    private func loadExtraPhotoLabels() {
        extraPhotoLabels = defaults.dictionary(forKey: Self.extraLabelsKey) as? [String: String] ?? [:]
    }

    private func loadExtraPhotos() {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: extraPhotosDirectory, includingPropertiesForKeys: [.creationDateKey]
        )) ?? []
        extraPhotos = contents
            .sorted { url, other in
                let a = (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
                let b = (try? other.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
                return a < b
            }
            .prefix(Self.maxPhotos - 1)
            .map { $0 }
    }

    // MARK: - 分析

    var canAnalyze: Bool {
        diagram.backgroundImageURL != nil && registry.activeEngine(requiring: [.vision]) != nil
    }

    func analyze() {
        guard !isAnalyzing else { return }
        guard let photoURL = diagram.backgroundImageURL else {
            lastErrorMessage = String(localized: "請先匯入桌面照片")
            return
        }
        // 這位顧問送照片，引擎必須能看圖；調音顧問純文字、不設此要求。
        guard let engine = registry.activeEngine(requiring: [.vision]) else {
            lastErrorMessage = String(localized: "未找到可用的 AI 引擎（設定 → AI 引擎）")
            return
        }
        let provider = CLIAdviceProvider(
            engine: engine.engine,
            executable: engine.url,
            model: settings.advisorModelIDs[engine.id]
        )
        // 第一張恆為背景照（座標基準），標註各自跟著自己那張走。
        var photos = [(url: photoURL, label: diagram.backgroundLabel)]
        photos += extraPhotos.map { (url: $0, label: label(for: $0)) }
        run(provider: provider, photos: photos)
    }

    func cancelAnalysis() {
        analysisTask?.cancel()
    }

    private func run(provider: any LightingAdviceProvider, photos photoURLs: [(url: URL, label: String)]) {
        isAnalyzing = true
        lastErrorMessage = nil
        lastErrorAssist = nil
        let context = buildContext()
        analysisTask = Task { [weak self] in
            defer {
                self?.isAnalyzing = false
                self?.analysisTask = nil
            }
            // 每次分析一個專屬沙箱：縮圖與 schema 檔都只放這裡。
            // 需要明示授權才能讀檔的 CLI（agy --add-dir）以它為授權範圍，
            // 授權到的剛好是這幾張圖，而不是整個共用 temp 目錄。
            let sandbox = Self.makeSandbox()
            defer { if let sandbox { try? FileManager.default.removeItem(at: sandbox) } }
            do {
                var photos: [LabeledPhoto] = []
                for photo in photoURLs.prefix(Self.maxPhotos) {
                    let thumb = try Self.makeThumbnail(from: photo.url, in: sandbox)
                    photos.append(LabeledPhoto(path: thumb.path, label: photo.label))
                }
                if photos.isEmpty { photos = [LabeledPhoto(path: "(no photo)")] }
                let raw = try await provider.advise(photos: photos, context: context, sandbox: sandbox)
                guard let self, !Task.isCancelled else { return }
                let advice = raw.sanitized(for: context)
                let entry = AdviceResult(advice: advice, context: context, date: Date(), fromHistory: false)
                self.appendHistory(advice: advice, photoURL: photoURLs.first?.url)
                self.result = entry
            } catch is CancellationError {
                // 使用者取消：不顯示錯誤
            } catch let error as AdviceError {
                self?.lastErrorMessage = error.userMessage
                self?.lastErrorAssist = error.assist
            } catch {
                self?.lastErrorMessage = String(localized: "分析失敗：\(error.localizedDescription)")
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
    /// 本次分析的沙箱目錄。建不出來就回 nil——縮圖退回共用 temp 目錄，
    /// 分析照常進行（只有需要 --add-dir 的引擎會因此讀不到圖並誠實報錯）。
    private nonisolated static func makeSandbox() -> URL? {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("chorus-advisor-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: url,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            return url
        } catch {
            return nil
        }
    }

    private nonisolated static func makeThumbnail(from source: URL, in sandbox: URL?) throws -> URL {
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
        let directory = sandbox ?? FileManager.default.temporaryDirectory
        let url = directory.appendingPathComponent("photo-\(UUID().uuidString).jpg")
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
        run(provider: FakeAdviceProvider(advice: advice), photos: [])
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
