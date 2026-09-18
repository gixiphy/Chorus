import Testing
@testable import ChorusCore

@Suite("LayoutEngine matrix")
struct LayoutEngineMatrixTests {
    private let engine = LayoutEngine()

    @Test("四角四分之一互不重疊且覆蓋內矩形（含間距）")
    func cornersCoverInner() {
        let visible = LayoutRect(x: -200, y: 100, width: 1920, height: 1080)
        let gap = 8.0
        let corners: [LayoutAction] = [.topLeft, .topRight, .bottomLeft, .bottomRight]
        let rects = corners.map { engine.frame(for: $0, visible: visible, gap: gap) }
        let inner = visible.insetBy(dx: gap, dy: gap)
        for rect in rects {
            #expect(rect.width > 0 && rect.height > 0)
            #expect(rect.x >= inner.x - 0.01)
            #expect(rect.maxX <= inner.maxX + 0.01)
            #expect(rect.y >= inner.y - 0.01)
            #expect(rect.maxY <= inner.maxY + 0.01)
        }
        // 對角線兩組應以 gap 分隔
        #expect(rects[0].maxX + gap == rects[1].x) // TL / TR
        #expect(rects[2].maxX + gap == rects[3].x) // BL / BR
        #expect(rects[2].maxY + gap == rects[0].y) // BL / TL
        #expect(rects[3].maxY + gap == rects[1].y) // BR / TR
    }

    @Test("直立螢幕上下三分")
    func portraitThirds() {
        let visible = LayoutRect(x: 0, y: 0, width: 1080, height: 1920)
        let top = engine.frame(for: .topThird, visible: visible, gap: 0)
        let mid = engine.frame(for: .middleThird, visible: visible, gap: 0)
        let bottom = engine.frame(for: .bottomThird, visible: visible, gap: 0)
        #expect(bottom.maxY == mid.y)
        #expect(mid.maxY == top.y)
        #expect(top.maxY == visible.maxY)
        #expect(bottom.y == visible.y)
        #expect(abs(top.height + mid.height + bottom.height - 1920) < 0.01)
    }

    @Test("負座標可見範圍的半屏仍落在內矩形")
    func negativeOriginHalf() {
        let visible = LayoutRect(x: -1280, y: -400, width: 1280, height: 800)
        let left = engine.frame(for: .leftHalf, visible: visible, gap: 10)
        #expect(left.x == visible.x + 10)
        #expect(left.maxX <= visible.midX + 0.01)
    }
}

@Suite("LayoutTemplate fixtures")
struct LayoutTemplateFixtureTests {
    private let fixtures: [(name: String, width: Double, height: Double)] = [
        ("2560x1080", 2560, 1080),
        ("3440x1440", 3440, 1440),
        ("3840x1600", 3840, 1600),
        ("5120x1440", 5120, 1440),
        ("7680x2160", 7680, 2160),
    ]

    @Test("超寬 fixture × 間距 0/8/24：分區在範圍內、無重疊、無累積偏移")
    func ultrawideInvariants() {
        for fixture in fixtures {
            for gap in [0.0, 8.0, 24.0] {
                // 側邊 Dock／非零原點
                let visible = LayoutRect(x: -120, y: 40, width: fixture.width, height: fixture.height)
                for id in LayoutTemplateID.allCases {
                    let zones = LayoutTemplateCatalog.template(id: id)
                        .resolvedZones(visible: visible, gap: gap)
                    #expect(!zones.isEmpty, "\(fixture.name) \(id) gap=\(gap)")
                    assertInside(zones.map(\.1), visible: visible, gap: gap, label: "\(fixture.name)/\(id)")
                    if !LayoutTemplateCatalog.template(id: id).isCenterReading {
                        assertNoUnexpectedOverlap(zones.map(\.1), gap: gap, label: "\(fixture.name)/\(id)")
                        assertWidthsSum(zones.map(\.1), visible: visible, gap: gap, id: id)
                    }
                }
            }
        }
    }

    @Test("中央閱讀在各 fixture 符合限寬公式")
    func centerReadingFormula() {
        for fixture in fixtures {
            let visible = LayoutRect(x: 10, y: -5, width: fixture.width, height: fixture.height)
            let gap = 8.0
            let rect = LayoutTemplateCatalog.template(id: .centerReading)
                .resolvedZones(visible: visible, gap: gap)[0].1
            let inner = visible.insetBy(dx: gap, dy: gap)
            let expectedW = min(inner.width, inner.height * 16.0 / 9.0)
            #expect(abs(rect.width - expectedW) < 1.0)
            #expect(abs(rect.midX - inner.midX) < 1.0)
            #expect(abs(rect.height - inner.height) < 0.01)
        }
    }

    private func assertInside(_ rects: [LayoutRect], visible: LayoutRect, gap: Double, label: String) {
        let inner = visible.insetBy(dx: gap, dy: gap)
        for rect in rects {
            #expect(rect.width > 0 && rect.height > 0, "\(label) non-positive")
            #expect(rect.x >= inner.x - 0.5, "\(label) x")
            #expect(rect.maxX <= inner.maxX + 0.5, "\(label) maxX")
            #expect(rect.y >= inner.y - 0.5, "\(label) y")
            #expect(rect.maxY <= inner.maxY + 0.5, "\(label) maxY")
        }
    }

    private func assertNoUnexpectedOverlap(_ rects: [LayoutRect], gap: Double, label: String) {
        for i in 0..<rects.count {
            for j in (i + 1)..<rects.count {
                if let hit = rects[i].intersection(rects[j]) {
                    // 允許數值誤差；真實重疊面積應接近 0
                    #expect(hit.width * hit.height < 1.0, "\(label) overlap \(i)/\(j)")
                }
            }
        }
        _ = gap
    }

    private func assertWidthsSum(_ rects: [LayoutRect], visible: LayoutRect, gap: Double, id: LayoutTemplateID) {
        // 僅對全高直欄版型檢查水平寬度和
        let columnIDs: Set<LayoutTemplateID> = [
            .centerStage, .threeColumns, .fourColumns, .widePrimary, .widePrimaryMirrored
        ]
        guard columnIDs.contains(id) else { return }
        let innerW = visible.width - gap * 2
        let gapsBetween = Double(max(rects.count - 1, 0)) * gap
        let sum = rects.map(\.width).reduce(0, +)
        #expect(abs(sum + gapsBetween - innerW) < 1.5, "\(id) width sum")
    }
}

@Suite("SnapResolver matrix")
struct SnapResolverMatrixTests {
    private let resolver = SnapResolver()
    private let screen = SnapResolver.ScreenMetrics(
        frame: LayoutRect(x: 0, y: 0, width: 2000, height: 1000),
        isLandscape: true
    )

    @Test("下緣五段對應三分版型")
    func bottomEdgeSegments() {
        let y = 4.0
        // 可用下緣扣除角落 48pt：x ∈ [48, 1952]
        #expect(resolver.edgeCandidate(pointX: 100, pointY: y, screen: screen)?.action == .leftThird)
        #expect(resolver.edgeCandidate(pointX: 500, pointY: y, screen: screen)?.action == .leftTwoThirds)
        #expect(resolver.edgeCandidate(pointX: 1000, pointY: y, screen: screen)?.action == .centerThird)
        #expect(resolver.edgeCandidate(pointX: 1500, pointY: y, screen: screen)?.action == .rightTwoThirds)
        #expect(resolver.edgeCandidate(pointX: 1900, pointY: y, screen: screen)?.action == .rightThird)
    }

    @Test("上緣中段 → 填滿")
    func topEdgeMaximize() {
        #expect(resolver.edgeCandidate(pointX: 1000, pointY: 996, screen: screen)?.action == .maximize)
    }

    @Test("中央閱讀區外不產生候選")
    func centerReadingMiss() {
        let template = LayoutTemplateCatalog.template(id: .centerReading)
        let visible = LayoutRect(x: 0, y: 0, width: 5120, height: 1440)
        let miss = resolver.zoneCandidate(
            pointX: 40,
            pointY: 700,
            template: template,
            visible: visible,
            gap: 8
        )
        #expect(miss == nil)
        let zones = template.resolvedZones(visible: visible, gap: 8)
        let hit = resolver.zoneCandidate(
            pointX: zones[0].1.midX,
            pointY: zones[0].1.midY,
            template: template,
            visible: visible,
            gap: 8
        )
        #expect(hit?.zoneID == "reading")
    }

    @Test("直立螢幕不做下緣三分")
    func portraitSkipsBottomThirds() {
        let portrait = SnapResolver.ScreenMetrics(
            frame: LayoutRect(x: 0, y: 0, width: 1080, height: 1920),
            isLandscape: false
        )
        #expect(resolver.edgeCandidate(pointX: 540, pointY: 4, screen: portrait) == nil)
    }
}
