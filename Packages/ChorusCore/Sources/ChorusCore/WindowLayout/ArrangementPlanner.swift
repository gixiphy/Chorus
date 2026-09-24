import Foundation

public enum ArrangementPlanner {
    public struct Ranked: Sendable, Equatable {
        public let arrangement: WindowArrangement
        public let overflow: Double
        public let comfortableCount: Int
    }

    /// 依視窗數給候選（順序＝偏好）。1 → []；≥4 只用 4 格版型。
    public static func candidates(forWindowCount count: Int) -> [WindowArrangement] {
        switch count {
        case ...1:
            return []
        case 2:
            return [.leftRight, .widePrimary, .widePrimaryMirrored, .quarterSide, .quarterSideMirrored]
        case 3:
            return [.threeColumns, .mainLeft, .mainRight, .centerStage, .primaryStack, .primaryStackMirrored]
        default:
            return [.quarters, .fourColumns]
        }
    }

    public static func fits(
        _ a: WindowArrangement,
        visible: LayoutRect,
        gap: Double,
        minSizes: [LayoutSize?]
    ) -> Bool {
        overflow(a, visible: visible, gap: gap, minSizes: minSizes) == 0
    }

    public static func overflow(
        _ a: WindowArrangement,
        visible: LayoutRect,
        gap: Double,
        minSizes: [LayoutSize?]
    ) -> Double {
        let frames = a.frames(visible: visible, gap: gap)
        var total = 0.0
        for (index, frame) in frames.enumerated() {
            guard index < minSizes.count, let min = minSizes[index] else { continue }
            total += max(0, min.width - frame.width)
            total += max(0, min.height - frame.height)
        }
        return total
    }

    public static func rank(
        candidates: [WindowArrangement],
        visible: LayoutRect,
        gap: Double,
        minSizes: [LayoutSize?],
        comfortable: LayoutSize = .comfortable
    ) -> [Ranked] {
        candidates.map { arrangement in
            let frames = arrangement.frames(visible: visible, gap: gap)
            let overflow = overflow(arrangement, visible: visible, gap: gap, minSizes: minSizes)
            let comfortableCount = frames.dropFirst().reduce(0) { count, frame in
                count + (comfortable.fits(in: frame) ? 1 : 0)
            }
            return Ranked(arrangement: arrangement, overflow: overflow, comfortableCount: comfortableCount)
        }
    }

    /// 先取 overflow == 0，再比 comfortableCount 多者，再依候選順序；都放不下取 overflow 最小。
    public static func choose(
        minSizes: [LayoutSize?],
        visible: LayoutRect,
        gap: Double,
        candidates: [WindowArrangement]? = nil,
        comfortable: LayoutSize = .comfortable
    ) -> WindowArrangement? {
        let list = candidates ?? Self.candidates(forWindowCount: minSizes.count)
        guard !list.isEmpty else { return nil }
        let ranked = rank(
            candidates: list,
            visible: visible,
            gap: gap,
            minSizes: minSizes,
            comfortable: comfortable
        )
        let fitting = ranked.filter { $0.overflow == 0 }
        if let best = fitting.max(by: { a, b in
            if a.comfortableCount != b.comfortableCount {
                return a.comfortableCount < b.comfortableCount
            }
            // 同 comfortableCount：保持候選順序（較早者優先）
            let ai = list.firstIndex(of: a.arrangement) ?? 0
            let bi = list.firstIndex(of: b.arrangement) ?? 0
            return ai > bi
        }) {
            return best.arrangement
        }
        // 都放不下：overflow 最小；平手依候選順序
        return ranked.min(by: { a, b in
            if a.overflow != b.overflow { return a.overflow < b.overflow }
            let ai = list.firstIndex(of: a.arrangement) ?? 0
            let bi = list.firstIndex(of: b.arrangement) ?? 0
            return ai < bi
        })?.arrangement
    }
}
