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

/// 套用光環境建議**之前**的原始配置，逐螢幕記錄、跨多次套用累積。
///
/// 每個 `record…` 都只在該項目還沒記過時寫入——保留第一次套用前的原值。
/// 除了 `displayOffsets`（舊版快照一定有）其餘欄位都是 Optional：合成的
/// `Decodable` 不會套用屬性預設值，少一個鍵就整筆解不開；舊版存下的快照
/// （曲線兩欄必填、沒有 remoteOffsets）照樣解得開。
struct AdviceBaseline: Codable, Equatable {
    /// 本機：display UUID → 原差異值。
    var displayOffsets: [String: Double] = [:]
    /// 遠端：`RemoteEndpointID.storageKey` → 原差異值。
    var remoteOffsets: [String: Double]?
    var minBrightness: Double?
    var maxLux: Double?

    mutating func recordLocal(_ uuid: String, original: Double) {
        if displayOffsets[uuid] == nil { displayOffsets[uuid] = original }
    }

    mutating func recordRemote(_ storageKey: String, original: Double) {
        var remote = remoteOffsets ?? [:]
        if remote[storageKey] == nil { remote[storageKey] = original }
        remoteOffsets = remote
    }

    mutating func recordMinBrightness(_ original: Double) {
        if minBrightness == nil { minBrightness = original }
    }

    mutating func recordMaxLux(_ original: Double) {
        if maxLux == nil { maxLux = original }
    }

    /// 以配置圖節點鍵表示（`display:<UUID>`／`remote:<storageKey>`），排序固定。
    var displayIDs: [String] {
        displayOffsets.keys.map { "display:" + $0 }.sorted()
            + (remoteOffsets ?? [:]).keys.map { "remote:" + $0 }.sorted()
    }

    var hasCurve: Bool { minBrightness != nil || maxLux != nil }

    var isEmpty: Bool { displayIDs.isEmpty && !hasCurve }
}

/// 光環境顧問協調者：產縮圖暫存檔、組 AdviceContext、呼叫引擎、
/// sanitize、歷史 5 筆、套用／逐螢幕還原到套用前（設計文件 §2、§4）。
@MainActor
@Observable
final class LightingAdvisor {
    private(set) var isAnalyzing = false
    private(set) var lastErrorMessage: String?
    /// 錯誤訊息旁的協助動作（複製登入指令／開設定）；隨訊息一起設定與清除。
    private(set) var lastErrorAssist: AdviceError.Assist?
    /// 設定後 UI 開建議 sheet；關閉時清 nil。
    var result: AdviceResult?
    /// 套用建議之前的原始配置；沒套用過（或已全部還原）時為 nil。
    /// 存成 stored property 而不是每次讀 UserDefaults，UI 才追蹤得到變化。
    private(set) var baseline: AdviceBaseline? {
        didSet {
            if let baseline, let data = try? JSONEncoder().encode(baseline) {
                defaults.set(data, forKey: Self.snapshotKey)
            } else {
                defaults.removeObject(forKey: Self.snapshotKey)
            }
        }
    }

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
        baseline = defaults.data(forKey: Self.snapshotKey)
            .flatMap { try? JSONDecoder().decode(AdviceBaseline.self, from: $0) }
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
        guard !MemoryPressureMonitor.shared.blocksHeavyWork else {
            lastErrorMessage = String(localized: "記憶體壓力過高，AI 引擎會再佔用幾百 MB——先關掉一些 App 再試")
            return
        }
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
            executable: engine.url
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
        // 遠端是**逐螢幕**，不是整台 Mac：分析要建議的是「那台朝窗的螢幕
        // 調暗一點」，而不是「客廳那台 Mac 調暗一點」——後者在接兩台螢幕時
        // 根本無從套用。
        for peer in pairedPeers.peers {
            for endpoint in coordinator?.remoteDevices.endpoints(of: peer.peerID, kind: .display) ?? [] {
                let id = RemoteEndpointID(peerID: peer.peerID, kind: .display, deviceID: endpoint.deviceID)
                let key = DiagramStore.nodeKey(id)
                infos.append(.init(
                    id: key,
                    name: "\(endpoint.name)（\(peer.deviceName)）",
                    backend: "remote",
                    normalizedPosition: diagram.position(for: key).map { [Double($0.x), Double($0.y)] },
                    // 回讀得到的現值才填；讀不到時填 0 會讓模型以為「沒有偏移」
                    currentOffset: endpoint.value(.brightnessOffset)
                        ?? settings.remoteDisplayOffsets[id.storageKey] ?? 0
                ))
            }
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
    /// 曲線參數進 SettingsStore。
    ///
    /// 套用前把**套用建議之前**的原始配置記進 `baseline`，逐螢幕累積：連續
    /// 套用多次時，已記過的螢幕與曲線參數保留第一次的原值，只補記這次新碰到
    /// 的項目。否則第二次套用會把第一次的建議值當成「原值」，還原只退到一半。
    func apply(
        _ advice: LightingAdvice,
        selectedOffsetIDs: Set<String>,
        applyMaxLux: Bool,
        applyMinBrightness: Bool
    ) {
        var next = baseline ?? AdviceBaseline()
        for suggestion in advice.offsets where selectedOffsetIDs.contains(suggestion.displayID) {
            if let uuid = localDisplayUUID(from: suggestion.displayID) {
                next.recordLocal(uuid, original: settings.ambientDisplayOffsets[uuid] ?? 0)
                autoBrightness?.setDisplayOffset(suggestion.offset, for: uuid)
            } else if let id = remoteEndpointID(from: suggestion.displayID) {
                // 讀不到現值就整筆跳過：沒有原值的套用是還原不了的單向操作。
                guard let current = coordinator?.remoteDevices.displayValue(id, .brightnessOffset) else {
                    ChorusLog.app.notice("光環境套用跳過 \(id.storageKey)：尚未取得現值")
                    continue
                }
                next.recordRemote(id.storageKey, original: current)
                coordinator?.sendEndpointCommand(id, capability: .brightnessOffset, value: suggestion.offset)
            }
        }
        var curveChanged = false
        if applyMaxLux, let maxLux = advice.maxLux {
            next.recordMaxLux(settings.ambientCurve.maxLux)
            settings.ambientCurve.maxLux = maxLux
            curveChanged = true
        }
        if applyMinBrightness, let minBrightness = advice.minBrightness {
            next.recordMinBrightness(settings.ambientCurve.minBrightness)
            settings.ambientCurve.minBrightness = minBrightness
            curveChanged = true
        }
        if curveChanged { autoBrightness?.reapplyTargets() }
        baseline = next.isEmpty ? nil : next
    }

    var canUndo: Bool { baseline != nil }

    /// 還原到套用建議之前：每台套用過的螢幕與曲線參數，一律回到第一次套用前
    /// 記下的原值。
    ///
    /// 遠端螢幕已離線或已移除時跳過，但**原值保留**在 baseline 裡——等它
    /// 重新連上還能再還原；硬送指令給不存在的端點只會換回一則 unavailable。
    func restoreBaseline() {
        guard var next = baseline else { return }
        for id in next.displayIDs {
            restoreDisplay(id, in: &next)
        }
        restoreCurve(in: &next)
        baseline = next.isEmpty ? nil : next
    }

    /// 只還原單一螢幕（`display:<UUID>` 或 `remote:<storageKey>`）。
    func restoreDisplay(_ displayID: String) {
        guard var next = baseline else { return }
        restoreDisplay(displayID, in: &next)
        baseline = next.isEmpty ? nil : next
    }

    /// 只還原自動亮度曲線（最暗亮度與全亮環境光）。
    func restoreCurve() {
        guard var next = baseline else { return }
        restoreCurve(in: &next)
        baseline = next.isEmpty ? nil : next
    }

    /// baseline 裡某台螢幕的顯示名稱。已離線或已移除的螢幕不在目前的
    /// context 裡，改用通用說法，不把 UUID 秀給使用者。
    func baselineDisplayName(_ displayID: String) -> String {
        buildContext().displays.first { $0.id == displayID }?.name
            ?? String(localized: "已離線或移除的螢幕")
    }

    private func restoreDisplay(_ displayID: String, in next: inout AdviceBaseline) {
        if let uuid = localDisplayUUID(from: displayID), let original = next.displayOffsets[uuid] {
            autoBrightness?.setDisplayOffset(original, for: uuid)
            next.displayOffsets.removeValue(forKey: uuid)
        } else if let id = remoteEndpointID(from: displayID),
                  let original = next.remoteOffsets?[id.storageKey] {
            guard coordinator?.remoteDevices.endpoint(id) != nil else {
                ChorusLog.app.notice("光環境還原跳過 \(id.storageKey)：裝置已離線或已移除，原值保留")
                return
            }
            coordinator?.sendEndpointCommand(id, capability: .brightnessOffset, value: original)
            next.remoteOffsets?.removeValue(forKey: id.storageKey)
        }
    }

    private func restoreCurve(in next: inout AdviceBaseline) {
        guard next.hasCurve else { return }
        if let minBrightness = next.minBrightness {
            settings.ambientCurve.minBrightness = minBrightness
        }
        if let maxLux = next.maxLux {
            settings.ambientCurve.maxLux = maxLux
        }
        next.minBrightness = nil
        next.maxLux = nil
        autoBrightness?.reapplyTargets()
    }

    private func localDisplayUUID(from id: String) -> String? {
        id.hasPrefix("display:") ? String(id.dropFirst("display:".count)) : nil
    }

    private func remoteEndpointID(from id: String) -> RemoteEndpointID? {
        guard id.hasPrefix("remote:") else { return nil }
        return RemoteEndpointID(storageKey: String(id.dropFirst("remote:".count)))
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
