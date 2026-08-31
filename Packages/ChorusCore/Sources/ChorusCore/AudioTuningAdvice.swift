import Foundation

/// 音訊調音顧問的輸入 context（DESIGN-20260831-audio-tuning-advisor §1.1）。
/// 全部是可公開層級的資訊：目標身分、需求描述、可用資源清單——
/// 不含金鑰材料、不含音訊內容。
public struct AudioTuningContext: Sendable, Equatable {
    /// 本機掃描到的一個可用 AU（模型只能從這份清單挑）。
    public struct EffectOption: Sendable, Equatable {
        public var key: String
        public var name: String
        public var manufacturerName: String

        public init(key: String, name: String, manufacturerName: String) {
            self.key = key
            self.name = name
            self.manufacturerName = manufacturerName
        }
    }

    /// "app" 或 "device"——prompt 的措辭與套用路徑由它分流。
    public var targetKind: String
    public var targetName: String
    /// App：bundle id；裝置：transport／AutoEq 等補充描述。
    public var targetDetail: String
    /// 使用者需求一句話（可空）。與照片標註同一個角色：補模型
    /// 看不到的使用情境。
    public var request: String
    /// 手動 10 段的中心頻率（Hz），順序即 bandsGainDB 的順序。
    public var bandFrequencies: [Double]
    public var availableEffects: [EffectOption]
    /// 現行 EQ／效果鏈摘要（空字串＝沒有）。
    public var currentEQDescription: String
    public var currentEffectsDescription: String

    public init(
        targetKind: String, targetName: String, targetDetail: String,
        request: String, bandFrequencies: [Double],
        availableEffects: [EffectOption],
        currentEQDescription: String = "", currentEffectsDescription: String = ""
    ) {
        self.targetKind = targetKind
        self.targetName = targetName
        self.targetDetail = targetDetail
        self.request = request
        self.bandFrequencies = bandFrequencies
        self.availableEffects = availableEffects
        self.currentEQDescription = currentEQDescription
        self.currentEffectsDescription = currentEffectsDescription
    }
}

/// 模型回報的調音建議。解析後**必須**過 `sanitized(for:)` 才可用
/// （與 LightingAdvice 同一條紀律：schema 擋第一線，本地保底）。
public struct AudioTuningAdvice: Codable, Sendable, Equatable {
    public struct EQAdvice: Codable, Sendable, Equatable {
        /// 依 context.bandFrequencies 順序的增益（dB）。
        public var bandsGainDB: [Double]
        public var reason: String

        public init(bandsGainDB: [Double], reason: String) {
            self.bandsGainDB = bandsGainDB
            self.reason = reason
        }
    }

    public struct EffectAdvice: Codable, Sendable, Equatable {
        /// 必須來自 context.availableEffects 的 key。
        public var componentKey: String
        public var name: String
        public var reason: String

        public init(componentKey: String, name: String, reason: String) {
            self.componentKey = componentKey
            self.name = name
            self.reason = reason
        }
    }

    public var summary: String
    public var eq: EQAdvice?
    public var effects: [EffectAdvice]
    public var warnings: [String]

    public init(
        summary: String, eq: EQAdvice? = nil,
        effects: [EffectAdvice] = [], warnings: [String] = []
    ) {
        self.summary = summary
        self.eq = eq
        self.effects = effects
        self.warnings = warnings
    }

    /// 欄位缺漏容錯：effects／warnings 缺就是空，不是解析失敗。
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        summary = try container.decodeIfPresent(String.self, forKey: .summary) ?? ""
        eq = try container.decodeIfPresent(EQAdvice.self, forKey: .eq)
        effects = try container.decodeIfPresent([EffectAdvice].self, forKey: .effects) ?? []
        warnings = try container.decodeIfPresent([String].self, forKey: .warnings) ?? []
    }

    /// 增益夾值範圍（schema 與 prompt 要求更保守，這裡是硬上限）。
    public static let gainClampDB: ClosedRange<Double> = -12...12
    /// 效果建議上限（鏈太長徒增延遲與風險，UI 也擺不下理由）。
    public static let maxEffectSuggestions = 3

    /// 本地保底（DESIGN §1.2）：
    /// - 增益夾 ±12、段數對齊 bandFrequencies（不足補 0、多的裁掉）
    /// - 全零 EQ 視同無建議
    /// - effects 只留 context 清單裡的 key、去重、上限 3 格、
    ///   名稱以本機目錄為準（key 才是身分，名稱寫錯不該影響建鏈）
    public func sanitized(for context: AudioTuningContext) -> AudioTuningAdvice {
        var cleaned = self

        if var advice = cleaned.eq {
            let bandCount = context.bandFrequencies.count
            var gains = advice.bandsGainDB.prefix(bandCount).map {
                min(max($0, Self.gainClampDB.lowerBound), Self.gainClampDB.upperBound)
            }
            if gains.count < bandCount {
                gains += Array(repeating: 0, count: bandCount - gains.count)
            }
            advice.bandsGainDB = gains
            cleaned.eq = gains.contains(where: { $0 != 0 }) ? advice : nil
        }

        let options = Dictionary(
            uniqueKeysWithValues: context.availableEffects.map { ($0.key, $0) }
        )
        var seen = Set<String>()
        cleaned.effects = cleaned.effects.compactMap { suggestion in
            guard let option = options[suggestion.componentKey],
                  seen.insert(suggestion.componentKey).inserted else { return nil }
            var fixed = suggestion
            fixed.name = option.name
            return fixed
        }
        if cleaned.effects.count > Self.maxEffectSuggestions {
            cleaned.effects = Array(cleaned.effects.prefix(Self.maxEffectSuggestions))
        }
        return cleaned
    }
}
