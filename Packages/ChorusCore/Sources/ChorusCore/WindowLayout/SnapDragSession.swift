import Foundation

/// 單次視窗拖曳的吸附狀態機：dwell、Shift 切換基本型／特型、Esc 取消後本趟失效。
public struct SnapDragSession: Sendable, Equatable {
    public struct ZoneContext: Sendable, Equatable {
        public var template: LayoutTemplate
        public var visible: LayoutRect
        public var gap: Double

        public init(template: LayoutTemplate, visible: LayoutRect, gap: Double) {
            self.template = template
            self.visible = visible
            self.gap = gap
        }
    }

    public struct Update: Sendable, Equatable {
        public var preview: SnapResolver.Candidate?
        public var isStable: Bool

        public init(preview: SnapResolver.Candidate? = nil, isStable: Bool = false) {
            self.preview = preview
            self.isStable = isStable
        }
    }

    public var dwell: Duration
    public var resolver: SnapResolver
    public private(set) var isActive = false
    public private(set) var isCancelled = false

    private var pending: SnapResolver.Candidate?
    private var pendingSince: Duration?

    public init(
        dwell: Duration = .milliseconds(150),
        resolver: SnapResolver = SnapResolver()
    ) {
        self.dwell = dwell
        self.resolver = resolver
    }

    public mutating func beginDrag(at now: Duration) {
        _ = now
        isActive = true
        isCancelled = false
        pending = nil
        pendingShift = false
        pendingSince = nil
    }

    public mutating func cancel() {
        isCancelled = true
        pending = nil
        pendingShift = false
        pendingSince = nil
    }

    public mutating func endDrag() {
        isActive = false
        isCancelled = false
        pending = nil
        pendingShift = false
        pendingSince = nil
    }

    public mutating func updatePointer(
        x: Double,
        y: Double,
        shiftDown: Bool,
        now: Duration,
        edgeScreen: SnapResolver.ScreenMetrics?,
        zoneContext: ZoneContext?
    ) -> Update {
        guard isActive, !isCancelled else {
            return Update()
        }

        // Shift 是「按住才有」的模式鍵：放開立即回基本型，不殘留、不整趟作廢
        let candidate: SnapResolver.Candidate?
        if shiftDown {
            let special = edgeScreen.flatMap {
                resolver.edgeCandidate(pointX: x, pointY: y, screen: $0, mode: .special)
            }
            if let special {
                candidate = special
            } else if let zoneContext {
                candidate = resolver.zoneCandidate(
                    pointX: x,
                    pointY: y,
                    template: zoneContext.template,
                    visible: zoneContext.visible,
                    gap: zoneContext.gap
                )
            } else {
                // Shift 按住但無可用分區（例如直立螢幕）：不回落基本邊緣
                candidate = nil
            }
        } else if let edgeScreen {
            candidate = resolver.edgeCandidate(pointX: x, pointY: y, screen: edgeScreen, mode: .basic)
        } else {
            candidate = nil
        }

        if candidate != pending || shiftDown != pendingShift {
            pending = candidate
            pendingShift = shiftDown
            pendingSince = candidate == nil ? nil : now
        }

        let stable: Bool
        if pending != nil, let since = pendingSince {
            stable = now - since >= dwell
        } else {
            stable = false
        }

        return Update(preview: pending, isStable: stable && pending != nil)
    }

    /// 滑鼠放開：僅在穩定候選且未取消時提交。
    public mutating func mouseUp(now: Duration, shiftDown: Bool) -> SnapResolver.Candidate? {
        defer { endDrag() }
        guard isActive, !isCancelled else { return nil }
        guard let pending, let since = pendingSince, now - since >= dwell else { return nil }
        // 候選是在哪個模式下選出來的，放開滑鼠時就得還在那個模式
        guard pendingShift == shiftDown else { return nil }
        return pending
    }

    private var pendingShift = false
}
