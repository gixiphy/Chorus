import AVFAudio
import AudioToolbox
import ChorusCore
import Foundation
import Observation
import os

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

    /// 過濾掉第三方外掛時記一筆——使用者裝了外掛卻沒出現在選單裡時，
    /// 這是唯一的線索（TapEngine 開頭那條紀律：不要靜靜地什麼都不做）。
    private static let log = Logger(subsystem: "com.hermes.Chorus", category: "taps")

    private(set) var items: [Item] = []

    /// 列出 **Apple 內建**的 v2 effect（≤2 聲道；AUv3 與多聲道第一版不列，
    /// 第三方外掛整個不支援，DESIGN §3／§4）。
    func refresh() {
        let description = AudioComponentDescription(
            componentType: kAudioUnitType_Effect, componentSubType: 0,
            componentManufacturer: 0, componentFlags: 0, componentFlagsMask: 0
        )
        let v2 = AVAudioUnitComponentManager.shared()
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

        // 第三方外掛不支援（DESIGN §4）。列出來也沒用：Chorus 以 Hardened
        // Runtime 執行且不豁免 library validation，別家開發者簽的程式碼在
        // dlopen 就被擋下，`AudioComponentInstanceNew` 只回一個什麼都沒說的
        // OSStatus -1（2026-09-01 E7 實測）。與其讓使用者選一個必定失敗的
        // 項目，不如不列——但要留下 log，不然「我裝的外掛去哪了」無從查起。
        let apple = v2.filter {
            $0.audioComponentDescription.componentManufacturer == kAudioUnitManufacturer_Apple
        }
        if apple.count < v2.count {
            let names = v2
                .filter { $0.audioComponentDescription.componentManufacturer != kAudioUnitManufacturer_Apple }
                .map { "\($0.manufacturerName)/\($0.name)" }
                .sorted()
                .joined(separator: "、")
            Self.log.notice("AU 目錄略過 \(v2.count - apple.count, privacy: .public) 個第三方效果（只支援 Apple 內建）：\(names, privacy: .public)")
        }

        items = apple
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
