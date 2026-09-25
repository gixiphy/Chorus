import Foundation
import Testing
@testable import ChorusCore

@Suite("VolumeModePolicy")
struct VolumeModeTests {
    /// 三條路都通的螢幕：DDC 可寫、裝置有原生音量、driver 正在轉送。
    private let allAvailable = VolumeModePolicy.Availability(
        hasDDCBridge: true,
        ddcResponsive: true,
        hasNativeVolume: true,
        hasDigitalPath: true
    )

    /// 典型的 HDMI 螢幕音訊：沒有原生音量，靠 DDC 或數位衰減。
    private let screenOnly = VolumeModePolicy.Availability(
        hasDDCBridge: true,
        ddcResponsive: true,
        hasNativeVolume: false,
        hasDigitalPath: true
    )

    /// 什麼都沒有（DDC 無回應、無原生音量、也沒經過 driver）。
    private let nothing = VolumeModePolicy.Availability(
        hasDDCBridge: false,
        ddcResponsive: true,
        hasNativeVolume: false,
        hasDigitalPath: false
    )

    // MARK: - 自動

    @Test("自動照優先序：DDC → 原生 → 數位")
    func automaticPriority() {
        #expect(VolumeModePolicy.automaticChoice(given: allAvailable) == .ddc)
        #expect(VolumeModePolicy.automaticChoice(given: VolumeModePolicy.Availability(
            hasDDCBridge: false, hasNativeVolume: true, hasDigitalPath: true
        )) == .native)
        #expect(VolumeModePolicy.automaticChoice(given: nothing) == .digital)
    }

    @Test("DDC 被判定無回應時，自動不再選它")
    func automaticSkipsUnresponsiveDDC() {
        var availability = allAvailable
        availability.ddcResponsive = false
        #expect(VolumeModePolicy.automaticChoice(given: availability) == .native)
    }

    // MARK: - 手動

    @Test("手動指定的模式可用時就照用，不被自動優先序蓋過")
    func manualWins() {
        // 自動會選 DDC，但使用者要的是數位衰減
        let resolution = VolumeModePolicy.resolve(preference: .digital, availability: allAvailable)
        #expect(resolution.effective == .digital)
        #expect(!resolution.isDegraded)

        let native = VolumeModePolicy.resolve(preference: .native, availability: allAvailable)
        #expect(native.effective == .native)
        #expect(!native.isDegraded)
    }

    @Test("不支援的選項有明確原因")
    func unavailabilityReasons() {
        #expect(VolumeModePolicy.unavailability(of: .ddc, given: nothing) == .noDDCDisplay)
        #expect(VolumeModePolicy.unavailability(of: .native, given: screenOnly) == .noNativeVolume)
        #expect(VolumeModePolicy.unavailability(of: .digital, given: nothing) == .noDigitalPath)
        // 自動永遠可選
        #expect(VolumeModePolicy.unavailability(of: .auto, given: nothing) == nil)

        var unresponsive = allAvailable
        unresponsive.ddcResponsive = false
        // 「沒有對應螢幕」與「螢幕不理指令」要分得出來：前者是接線問題、
        // 後者是螢幕韌體的問題，使用者的下一步完全不同。
        #expect(VolumeModePolicy.unavailability(of: .ddc, given: unresponsive) == .ddcUnresponsive)
    }

    // MARK: - 降級與恢復

    @Test("手動模式在運作中失效 → 自動接手、保留偏好、講明原因")
    func degradesWithReason() {
        var availability = allAvailable
        availability.ddcResponsive = false
        let resolution = VolumeModePolicy.resolve(preference: .ddc, availability: availability)
        #expect(resolution.effective == .native)
        #expect(resolution.degradedFrom == .ddc)
        #expect(resolution.reason == .ddcUnresponsive)
    }

    @Test("能力恢復後自己接回原本選的模式")
    func recoversWhenCapabilityReturns() {
        var availability = allAvailable
        availability.ddcResponsive = false
        #expect(VolumeModePolicy.resolve(preference: .ddc, availability: availability).effective == .native)
        // 偏好沒有被改寫，所以同一個 preference 再解一次就回來了
        availability.ddcResponsive = true
        let recovered = VolumeModePolicy.resolve(preference: .ddc, availability: availability)
        #expect(recovered.effective == .ddc)
        #expect(!recovered.isDegraded)
    }

    @Test("退路剛好等於偏好時不算降級")
    func fallbackEqualToPreferenceIsNotDegraded() {
        // 數位是自動優先序的保底：「數位路徑不可用」時退路仍然是數位。
        // 標成降級的話，UI 會對著正在運作的模式說它無法使用。
        let resolution = VolumeModePolicy.resolve(preference: .digital, availability: nothing)
        #expect(resolution.effective == .digital)
        #expect(!resolution.isDegraded)
        #expect(resolution.reason == nil)
    }

    // MARK: - 互斥

    @Test("driver 衰減與硬體鏡射永遠互斥")
    func attenuationIsMutuallyExclusive() {
        for mode in [EffectiveVolumeMode.ddc, .native, .digital] {
            // 同一個控制值被套用兩次（硬體一次、數位一次）是這次改動最容易
            // 出現的 bug，兩個開關必須永遠相反。
            #expect(
                VolumeModePolicy.driverAppliesVolume(for: mode)
                    != VolumeModePolicy.mirrorsToHardware(for: mode)
            )
        }
        #expect(VolumeModePolicy.driverAppliesVolume(for: .digital))
        #expect(!VolumeModePolicy.driverAppliesVolume(for: .ddc))
        #expect(!VolumeModePolicy.driverAppliesVolume(for: .native))
    }

    @Test("四種模式 × 可用性矩陣都有確定的生效模式")
    func fullMatrixResolves() {
        let matrix = [allAvailable, screenOnly, nothing]
        for availability in matrix {
            for preference in VolumeMode.allCases {
                let resolution = VolumeModePolicy.resolve(preference: preference, availability: availability)
                // 生效模式一定是三條路徑之一，而且降級時一定講得出原因
                #expect(resolution.isDegraded == (resolution.reason != nil))
                if resolution.isDegraded {
                    #expect(resolution.degradedFrom == preference)
                }
            }
        }
    }
}
