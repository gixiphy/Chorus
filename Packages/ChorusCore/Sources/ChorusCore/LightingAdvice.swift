import Foundation

/// 光環境顧問的輸入脈絡：桌面照片之外，模型判讀所需的裝置與現況資訊。
/// 純資料、可序列化；由 app 層收集後隨照片送出。
public struct AdviceContext: Codable, Sendable, Equatable {
    /// 一台顯示器（本機或已配對裝置的）在配置圖上的狀態。
    public struct DisplayInfo: Codable, Sendable, Equatable {
        /// 配置圖 key："display:<uuid>"（本機顯示器）／"peer:<peerID>"（已配對裝置）。
        public var id: String
        public var name: String
        /// 亮度 backend："ddc"、"displayServices"、"gamma"。
        public var backend: String
        /// 節點在背景照片上的 0–1 正規化座標 [x, y]；未擺放為 nil。
        public var normalizedPosition: [Double]?
        public var currentOffset: Double

        public init(
            id: String,
            name: String,
            backend: String,
            normalizedPosition: [Double]? = nil,
            currentOffset: Double = 0
        ) {
            self.id = id
            self.name = name
            self.backend = backend
            self.normalizedPosition = normalizedPosition
            self.currentOffset = currentOffset
        }
    }

    public var displays: [DisplayInfo]
    public var curve: AmbientCurve
    /// 近期環境光統計；無 ALS 的機器為 nil。
    public var recentLux: LuxStats?
    /// 使用者標注「桌面有螢幕掛燈」；nil 表示未標注，由模型自行從照片判斷。
    public var hasLightBarHint: Bool?

    public init(
        displays: [DisplayInfo],
        curve: AmbientCurve,
        recentLux: LuxStats? = nil,
        hasLightBarHint: Bool? = nil
    ) {
        self.displays = displays
        self.curve = curve
        self.recentLux = recentLux
        self.hasLightBarHint = hasLightBarHint
    }
}

/// 近期環境光統計（lux）。
public struct LuxStats: Codable, Sendable, Equatable {
    public var minLux: Double
    public var medianLux: Double
    public var maxLux: Double

    public init(minLux: Double, medianLux: Double, maxLux: Double) {
        self.minLux = minLux
        self.medianLux = medianLux
        self.maxLux = maxLux
    }
}

/// 模型產出的調光策略建議。
/// LLM 輸出視為不可信輸入：套用前一律先過 `sanitized(for:)`，永不直接落地。
public struct LightingAdvice: Codable, Sendable, Equatable {
    public struct OffsetSuggestion: Codable, Sendable, Equatable {
        public var displayID: String
        /// 絕對建議值（非增量），套用端語意同 per-display offset。
        public var offset: Double
        /// 繁中一句話理由，顯示在建議清單。
        public var reason: String

        public init(displayID: String, offset: Double, reason: String) {
            self.displayID = displayID
            self.offset = offset
            self.reason = reason
        }
    }

    public var offsets: [OffsetSuggestion]
    public var maxLux: Double?
    public var minBrightness: Double?
    /// 無套用動作的提醒（掛燈自動模式、反光、OSD 硬體上限…），純顯示。
    public var warnings: [String]
    /// 模型對照片光環境的整體描述，顯示在建議 sheet 頂部。
    public var sceneSummary: String

    public static let offsetRange: ClosedRange<Double> = -0.3 ... 0.3
    public static let maxLuxRange: ClosedRange<Double> = 100 ... 20000
    public static let minBrightnessRange: ClosedRange<Double> = 0 ... 0.5

    public init(
        offsets: [OffsetSuggestion],
        maxLux: Double? = nil,
        minBrightness: Double? = nil,
        warnings: [String] = [],
        sceneSummary: String = ""
    ) {
        self.offsets = offsets
        self.maxLux = maxLux
        self.minBrightness = minBrightness
        self.warnings = warnings
        self.sceneSummary = sceneSummary
    }

    /// 驗證並收斂模型輸出：
    /// - offset 建議：displayID 必須存在於 context、同一顯示器只留第一筆、
    ///   非有限值剔除、夾進 `offsetRange`
    /// - maxLux／minBrightness：非有限值視為未提供，其餘夾進允許範圍
    /// - warnings：去頭尾空白、剔除空字串
    public func sanitized(for context: AdviceContext) -> LightingAdvice {
        let knownIDs = Set(context.displays.map(\.id))
        var seenIDs = Set<String>()
        let cleanOffsets = offsets.compactMap { suggestion -> OffsetSuggestion? in
            guard knownIDs.contains(suggestion.displayID),
                  suggestion.offset.isFinite,
                  seenIDs.insert(suggestion.displayID).inserted else { return nil }
            var clean = suggestion
            clean.offset = Self.offsetRange.clamp(suggestion.offset)
            clean.reason = suggestion.reason.trimmingCharacters(in: .whitespacesAndNewlines)
            return clean
        }
        return LightingAdvice(
            offsets: cleanOffsets,
            maxLux: maxLux.flatMap { $0.isFinite ? Self.maxLuxRange.clamp($0) : nil },
            minBrightness: minBrightness.flatMap { $0.isFinite ? Self.minBrightnessRange.clamp($0) : nil },
            warnings: warnings
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty },
            sceneSummary: sceneSummary.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }
}

extension ClosedRange where Bound == Double {
    fileprivate func clamp(_ value: Double) -> Double {
        Swift.min(Swift.max(value, lowerBound), upperBound)
    }
}
