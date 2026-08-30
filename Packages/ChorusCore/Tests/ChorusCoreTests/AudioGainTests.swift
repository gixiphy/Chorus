import Foundation
import Testing
@testable import ChorusCore

@Suite("Soft clip")
struct SoftClipTests {
    @Test("線性區原樣通過——增益 ≤ 1 的一般訊號不該被染色")
    func linearRegionIsTransparent() {
        for sample in stride(from: Float(-0.7), through: 0.7, by: 0.05) {
            #expect(SoftClip.apply(sample) == sample)
        }
    }

    @Test("保護膝點（0.95）：滿刻度以下的母帶近乎透明——EQ-only 路徑不再持續失真")
    func protectKneeIsTransparentForMasteredMaterial() {
        // 0.95 以下完全原樣（0.7 膝點在這一段會持續壓＝D14 聽到的沙沙）
        for sample in stride(from: Float(-0.94), through: 0.94, by: 0.05) {
            #expect(SoftClip.apply(sample, threshold: SoftClip.protectThreshold) == sample)
        }
        // 仍然守住天花板
        for raw in stride(from: Float(-2), through: 2, by: 0.01) {
            let clipped = SoftClip.apply(raw, threshold: SoftClip.protectThreshold)
            #expect(clipped <= 1.0001 && clipped >= -1.0001)
        }
        // 接點連續：0.95 兩側值接得上
        let below = SoftClip.apply(0.9499, threshold: SoftClip.protectThreshold)
        let above = SoftClip.apply(0.9501, threshold: SoftClip.protectThreshold)
        #expect(abs(above - below) < 0.001)
    }

    @Test("永遠不超過 ±1：4x 增益打進滿刻度訊號也不會 clip 成方波")
    func neverExceedsFullScale() {
        for raw in stride(from: Float(-4), through: 4, by: 0.01) {
            let clipped = SoftClip.apply(raw)
            #expect(clipped <= 1.0001)
            #expect(clipped >= -1.0001)
        }
    }

    @Test("單調遞增——壓縮不能讓波形折返（折返＝聽得到的失真）")
    func isMonotonic() {
        var previous = SoftClip.apply(-4)
        for raw in stride(from: Float(-4), through: 4, by: 0.005) {
            let value = SoftClip.apply(raw)
            #expect(value >= previous - 1e-6)
            previous = value
        }
    }

    @Test("奇對稱：正負半週壓一樣多，不引入直流偏移")
    func isOddSymmetric() {
        for raw in stride(from: Float(0), through: 4, by: 0.01) {
            #expect(abs(SoftClip.apply(raw) + SoftClip.apply(-raw)) < 1e-6)
        }
    }

    @Test("接點連續：threshold 兩側的值與斜率都接得上（硬 knee 聽得出來）")
    func kneeIsContinuous() {
        let threshold = SoftClip.threshold
        let epsilon: Float = 1e-4
        let below = SoftClip.apply(threshold - epsilon)
        let above = SoftClip.apply(threshold + epsilon)
        #expect(abs(above - below) < 1e-3)
        // 斜率：線性側恆為 1，壓縮側在接點上也應該是 1
        let slope = (above - below) / (2 * epsilon)
        #expect(abs(slope - 1) < 0.05)
    }

    @Test("飽和函數：原點斜率 1、x=3 剛好到頂且斜率 0（貼著天花板停）")
    func saturationCurveHasTheRightGeometry() {
        #expect(SoftClip.saturate(0) == 0)
        // S'(0) = 1
        let epsilon: Float = 1e-4
        #expect(abs(SoftClip.saturate(epsilon) / epsilon - 1) < 1e-3)
        // S(3) = 1，且逼近時斜率趨近 0（不是撞上去）
        #expect(abs(SoftClip.saturate(3) - 1) < 1e-6)
        let slopeNearTop = (SoftClip.saturate(3) - SoftClip.saturate(3 - epsilon)) / epsilon
        #expect(slopeNearTop < 1e-3)
        #expect(SoftClip.saturate(50) <= 1)
    }

    @Test("天花板落在 1.6：更大的輸入就是真的限幅了")
    func reachesCeilingAtStatedInput() {
        #expect(abs(SoftClip.apply(SoftClip.ceilingInput) - 1) < 1e-5)
        #expect(SoftClip.apply(3) == 1)
    }
}

@Suite("Gain ramp")
struct GainRampTests {
    @Test("已在目標值就不動——不需要 epsilon 判斷的穩定狀態")
    func restsAtTarget() {
        #expect(GainRamp.advance(current: 1, target: 1, frames: 512) == 1)
    }

    @Test("大跳變被斜率限制住（緩衝小於 480 frames 時跨回呼才走得完）")
    func largeJumpIsRateLimited() {
        let next = GainRamp.advance(current: 0, target: 4, frames: 128)
        #expect(next > 0)
        #expect(next < 4)
    }

    @Test("全程 0 → 4x 約 480 frames（10 ms @ 48 kHz）")
    func reachesFullRangeInAboutTenMilliseconds() {
        var gain: Float = 0
        var frames = 0
        while gain < 4, frames < 4800 {
            gain = GainRamp.advance(current: gain, target: 4, frames: 64)
            frames += 64
        }
        #expect(gain == 4)
        #expect(frames == 512) // 480 無條件進位到 64 的倍數
    }

    @Test("實測的 512-frame 回呼一次就吃得完全程——斜坡由回呼內的插值完成")
    func typicalCallbackCoversFullRange() {
        // DESIGN §1 實測：512 frames ≈ 10.7 ms。回呼「之間」不再有階躍，
        // 平滑度由 render block 在緩衝內線性插值提供
        #expect(GainRamp.advance(current: 0, target: 4, frames: 512) == 4)
    }

    @Test("小跳變一次到位，不會反覆逼近")
    func smallStepSnaps() {
        #expect(GainRamp.advance(current: 1, target: 1.05, frames: 512) == 1.05)
    }

    @Test("往下也一樣受限：靜音是「目標 0」，同樣走斜坡不喀噠")
    func rampsDownwardToo() {
        let next = GainRamp.advance(current: 4, target: 0, frames: 64)
        #expect(next < 4)
        #expect(next > 0)
    }
}

@Suite("Per-app audio settings")
struct AppAudioSettingTests {
    @Test("gain 夾在 0–4x")
    func gainIsClamped() {
        #expect(AppAudioSetting(gain: -1).gain == 0)
        #expect(AppAudioSetting(gain: 9).gain == 4)
    }

    @Test("沒調整就是 neutral——這是「要不要建 tap」的判準")
    func neutralMeansNoTap() {
        #expect(AppAudioSetting().isNeutral)
        #expect(!AppAudioSetting(gain: 0.5).isNeutral)
        #expect(!AppAudioSetting(muted: true).isNeutral)
        #expect(!AppAudioSetting(outputDeviceUID: "uid").isNeutral)
    }

    /// 2026-08-30 mini 實機：Vivaldi 的 gain 存成 0.995621（−0.038 dB），
    /// 因為 0–4x 的滑桿在選單列寬度下一個 pixel 約 0.027，拖到「看起來是
    /// 100%」永遠停不在 1.0。舊判準 `gain != 1` 於是為了聽不出來的
    /// −0.038 dB 永久多建一條 tap，把那個 App 推進另一個時鐘域。
    @Test("滑桿碰不到的 unity 有頓點——幾乎等於 1 就是 1")
    func nearUnityGainSnapsToUnity() {
        #expect(AppAudioSetting.snapGain(0.995621) == 1)
        #expect(AppAudioSetting.snapGain(1.015) == 1)
        // 頓點只吃 ±0.17 dB，真正的調整原樣通過
        #expect(AppAudioSetting.snapGain(0.9) == 0.9)
        #expect(AppAudioSetting.snapGain(2) == 2)
        // 夾限仍然先發生
        #expect(AppAudioSetting.snapGain(9) == 4)
        #expect(AppAudioSetting.snapGain(-1) == 0)
    }

    @Test("幾乎等於 1 不建 tap，也不值得保存")
    func nearUnityGainNeedsNoTap() {
        let almost = AppAudioSetting(gain: 0.995621)
        #expect(almost.isNeutral)
        #expect(!almost.needsTap)
        // 但真的調小了就要接管
        #expect(AppAudioSetting(gain: 0.9).needsTap)
        // 幾乎等於 1 但另有理由（靜音／路由）時照樣接管
        #expect(AppAudioSetting(gain: 0.995621, muted: true).needsTap)
    }

    @Test("舊存檔裡的近似 1 在解碼當下就清掉，不用等使用者再動滑桿")
    func decodingDropsStaleNearUnityEntries() throws {
        // 這串就是 2026-08-30 mini 上 chorus.audio.appSettings 的實際內容
        let json = Data(#"{"entries":{"com.vivaldi.Vivaldi":{"muted":false,"gain":0.995621},"com.colliderli.iina":{"muted":false,"gain":0}}}"#.utf8)
        let decoded = try JSONDecoder().decode(AppAudioSettings.self, from: json)
        #expect(decoded.adjustedBundleIDs == ["com.colliderli.iina"])
        #expect(decoded.bundleIDsNeedingTap == ["com.colliderli.iina"])
    }

    @Test("靜音的目標增益是 0——與音量走同一條斜坡")
    func mutedTargetsZero() {
        #expect(AppAudioSetting(gain: 2, muted: true).targetGain == 0)
        #expect(AppAudioSetting(gain: 2).targetGain == 2)
    }

    @Test("設回 neutral 會從表裡消失，不留空紀錄（否則留下沒必要的 tap）")
    func neutralEntriesAreDropped() {
        var settings = AppAudioSettings()
        settings["com.apple.Music"] = AppAudioSetting(gain: 0.5)
        #expect(settings.adjustedBundleIDs == ["com.apple.Music"])
        settings["com.apple.Music"] = AppAudioSetting()
        #expect(settings.isEmpty)
    }

    @Test("adjustedBundleIDs 排序穩定")
    func adjustedBundlesAreSorted() {
        var settings = AppAudioSettings()
        settings["com.apple.Safari"] = AppAudioSetting(muted: true)
        settings["com.apple.Music"] = AppAudioSetting(gain: 2)
        #expect(settings.adjustedBundleIDs == ["com.apple.Music", "com.apple.Safari"])
    }

    @Test("編碼往返保值（持久化用）")
    func roundTripsThroughCoding() throws {
        var settings = AppAudioSettings()
        settings["com.apple.Music"] = AppAudioSetting(gain: 2.5, muted: true, outputDeviceUID: "uid-1")
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(AppAudioSettings.self, from: data)
        #expect(decoded == settings)
    }
}
