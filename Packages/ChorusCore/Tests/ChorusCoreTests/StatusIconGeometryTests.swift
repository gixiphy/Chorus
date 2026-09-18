import Testing
@testable import ChorusCore

@Suite("選單列圖示幾何：頂部開口的弧")
struct StatusIconGeometryTests {
    @Test("沒有開口：一段從 0 到進度的弧")
    func noGap() {
        #expect(StatusIconGeometry.arcSegments(progress: 0.7, gapFraction: 0) == [.init(from: 0, to: 0.7)])
        #expect(StatusIconGeometry.arcSegments(progress: 1, gapFraction: 0) == [.init(from: 0, to: 1)])
    }

    @Test("進度 0 不畫任何段")
    func zeroProgress() {
        #expect(StatusIconGeometry.arcSegments(progress: 0, gapFraction: 0).isEmpty)
        #expect(StatusIconGeometry.arcSegments(progress: 0, gapFraction: 0.3).isEmpty)
    }

    @Test("開口置中在頂端（進度 0.5）：進度沒到開口就只有一段")
    func belowGap() {
        #expect(StatusIconGeometry.arcSegments(progress: 0.2, gapFraction: 0.3) == [.init(from: 0, to: 0.2)])
    }

    @Test("進度落在開口裡：第一段停在開口起點")
    func insideGap() {
        #expect(StatusIconGeometry.arcSegments(progress: 0.5, gapFraction: 0.3) == [.init(from: 0, to: 0.35)])
    }

    @Test("進度越過開口：兩段，第二段從開口終點接到進度")
    func beyondGap() {
        #expect(StatusIconGeometry.arcSegments(progress: 1, gapFraction: 0.3)
                == [.init(from: 0, to: 0.35), .init(from: 0.65, to: 1)])
        #expect(StatusIconGeometry.arcSegments(progress: 0.8, gapFraction: 0.3)
                == [.init(from: 0, to: 0.35), .init(from: 0.65, to: 0.8)])
    }

    @Test("進度與開口都會被夾在合理範圍")
    func clamps() {
        #expect(StatusIconGeometry.arcSegments(progress: 1.7, gapFraction: -1) == [.init(from: 0, to: 1)])
        // 開口最多吃掉六成，剩下的弧兩端至少各留兩成
        #expect(StatusIconGeometry.arcSegments(progress: 1, gapFraction: 0.95)
                == [.init(from: 0, to: 0.2), .init(from: 0.8, to: 1)])
    }

    @Test("開口寬度由文字寬換算成弧長比例")
    func gapFromText() {
        // 弧長 = 半徑 × 掃角；文字 10 加兩側各 1 的留白，弧長 40 → 0.3
        let fraction = StatusIconGeometry.gapFraction(contentWidth: 10, padding: 1, radius: 40 / StatusIconGeometry.brightnessSweep)
        #expect(abs(fraction - 0.3) < 1e-9)
        #expect(StatusIconGeometry.gapFraction(contentWidth: 0, padding: 0, radius: 10) == 0)
    }

    @Test("底部音量弧：靜音、無裝置、零音量都不畫；其餘照比例")
    func volumeArc() {
        #expect(StatusIconGeometry.volumeArcProgress(volume: nil, muted: false) == nil)
        #expect(StatusIconGeometry.volumeArcProgress(volume: 0, muted: false) == nil)
        #expect(StatusIconGeometry.volumeArcProgress(volume: 0.6, muted: true) == nil)
        #expect(StatusIconGeometry.volumeArcProgress(volume: 0.6, muted: false) == 0.6)
        #expect(StatusIconGeometry.volumeArcProgress(volume: 1.4, muted: false) == 1)
    }
}
