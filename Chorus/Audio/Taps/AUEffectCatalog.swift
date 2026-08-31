import AVFAudio
import AudioToolbox
import ChorusCore
import Foundation
import Observation

/// 系統上可用的 AU effect 清單（B6-8 AU-2b）。
///
/// 只讀 component 註冊表、**不實例化任何東西**——掃描永遠安全
/// （DESIGN §1.1）。實例化在使用者把外掛加進鏈的那一刻才發生，
/// 而且包在隔離閂裡。
@MainActor
@Observable
final class AUEffectCatalog {
    struct Item: Identifiable, Sendable, Equatable {
        let component: AUEffectComponent
        let name: String
        let manufacturerName: String
        var id: String { component.key }
    }

    private(set) var items: [Item] = []

    /// 列出 v2 effect（≤2 聲道；AUv3 與多聲道第一版不列，DESIGN §3）。
    func refresh() {
        var description = AudioComponentDescription(
            componentType: kAudioUnitType_Effect, componentSubType: 0,
            componentManufacturer: 0, componentFlags: 0, componentFlagsMask: 0
        )
        items = AVAudioUnitComponentManager.shared()
            .components(matching: description)
            .filter { component in
                // AUv3 第一版跳過：載入模型完全不同（XPC／async），與同步
                // 建鏈流程不相容。**用型別化旗標**——手寫位元在這裡踩過雷：
                // 0x2 是 SandboxSafe 不是 IsV3AudioUnit（0x4），寫錯等於把
                // 幾乎所有 Apple 內建效果都濾掉、選單只剩一個 AUNetSend
                //（build 57 實機截圖）。
                !AudioComponentFlags(rawValue: component.audioComponentDescription.componentFlags)
                    .contains(.isV3AudioUnit)
            }
            .map { component in
                Item(
                    component: AUEffectComponent(
                        type: component.audioComponentDescription.componentType,
                        subtype: component.audioComponentDescription.componentSubType,
                        manufacturer: component.audioComponentDescription.componentManufacturer
                    ),
                    name: component.name,
                    manufacturerName: component.manufacturerName
                )
            }
            .sorted { lhs, rhs in
                (lhs.manufacturerName, lhs.name) < (rhs.manufacturerName, rhs.name)
            }
    }

    /// 由目錄項生成一格新的鏈上條目（名稱快取進存檔，外掛移除後仍能列出）。
    func makeEntry(_ item: Item) -> AUEffectEntry {
        AUEffectEntry(
            component: item.component,
            name: item.name,
            manufacturerName: item.manufacturerName
        )
    }
}
