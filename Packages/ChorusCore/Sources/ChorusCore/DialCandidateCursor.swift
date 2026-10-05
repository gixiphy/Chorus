/// 撥號端點輪替：Bonjour 端點失效時改試手動位址，而不是對同一個死端點一路退避到 30 秒。
///
/// 只記「這個 peer 連續失敗幾次」；候選清單每次由呼叫端現算（探索結果隨時會變），
/// 失敗次數對候選數取餘數，所以清單變長變短都不會越界。
public struct DialCandidateCursor: Sendable, Equatable {
    private var failures: [String: Int] = [:]

    public init() {}

    /// 這次該撥哪一個。純讀取：同一次撥號流程內多次呼叫結果一致。
    public func pick<Candidate>(_ peer: String, from candidates: [Candidate]) -> Candidate? {
        guard !candidates.isEmpty else { return nil }
        return candidates[(failures[peer] ?? 0) % candidates.count]
    }

    /// 撥號或 hello 階段失敗：下次換下一個候選。
    public mutating func failed(_ peer: String) {
        failures[peer, default: 0] += 1
    }

    /// 連上了：下次從第一個候選（最新探索結果）開始。
    public mutating func succeeded(_ peer: String) {
        failures[peer] = nil
    }

    /// 睡醒或網路整個重來：全部歸零。
    public mutating func reset() {
        failures = [:]
    }

    /// 依優先序組候選清單：去掉 nil 與重複，保留第一次出現的位置。
    public static func ordered<Candidate: Equatable>(_ candidates: [Candidate?]) -> [Candidate] {
        var result: [Candidate] = []
        for case let candidate? in candidates where !result.contains(candidate) {
            result.append(candidate)
        }
        return result
    }
}
