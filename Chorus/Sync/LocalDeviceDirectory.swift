import ChorusCore
import Foundation

/// 把本機的顯示器與音訊裝置整理成一份可以送出去的端點目錄。
///
/// 刻意寫成純函式（輸入是值型別、沒有 manager 依賴）：
/// 「哪些裝置該出現、支援哪些能力、同名的怎麼區別」是這次改動最容易寫錯
/// 也最需要測試的一段，不該埋在 `@Observable` 類別裡靠跑 App 才驗得到。
enum LocalDeviceDirectory {
    struct DisplayInput: Sendable, Equatable {
        let uuid: String
        let name: String
        let isBuiltin: Bool
        let brightness: Double
        /// 這台螢幕的環境光差異值（−0.5…+0.5）。
        let offset: Double
    }

    struct AudioInput: Sendable, Equatable {
        let uid: String
        let name: String
        /// 音量有地方可寫（原生／DDC／軟體衰減任一條走得通）。
        let canControlVolume: Bool
        let canMute: Bool
        let volume: Double
        let muted: Bool
        /// 這個音訊端點屬於哪台螢幕（確認得了才帶）。
        let linkedDisplayUUID: String?
        let isDefaultOutput: Bool
    }

    /// 組出端點清單。
    ///
    /// 不可控的裝置也列出來（能力清單是空的）：遠端那頭要能看到「那台在，
    /// 只是動不了」，而不是以為它被拔掉了。
    static func endpoints(displays: [DisplayInput], audio: [AudioInput]) -> [RemoteEndpoint] {
        var result: [RemoteEndpoint] = []

        let displaySuffixes = ControlGrouping.disambiguationSuffixes(
            names: displays.map(\.name),
            discriminators: displays.map { ControlGrouping.shortIdentifier($0.uuid) }
        )
        for (input, suffix) in zip(displays, displaySuffixes) {
            result.append(RemoteEndpoint(
                deviceID: input.uuid,
                kind: .display,
                name: input.name,
                // 亮度與差異值兩件事都要能遠端做：配置圖調的是差異值，
                // 選單列調的是亮度本身。
                capabilities: [.brightness, .brightnessOffset],
                values: [
                    RemoteEndpointCapability.brightness.rawValue: input.brightness,
                    RemoteEndpointCapability.brightnessOffset.rawValue: input.offset,
                ],
                discriminator: suffix
            ))
        }

        let audioSuffixes = ControlGrouping.disambiguationSuffixes(
            names: audio.map(\.name),
            discriminators: audio.map { ControlGrouping.shortIdentifier($0.uid) }
        )
        for (input, suffix) in zip(audio, audioSuffixes) {
            var capabilities: [RemoteEndpointCapability] = []
            var values: [String: Double] = [:]
            if input.canControlVolume {
                capabilities.append(.volume)
                values[RemoteEndpointCapability.volume.rawValue] = input.volume
            }
            if input.canMute {
                capabilities.append(.mute)
                values[RemoteEndpointCapability.mute.rawValue] = input.muted ? 1 : 0
            }
            result.append(RemoteEndpoint(
                deviceID: input.uid,
                kind: .audioOutput,
                name: input.name,
                capabilities: capabilities,
                linkedDisplayUUID: input.linkedDisplayUUID,
                values: values,
                discriminator: suffix,
                isDefaultOutput: input.isDefaultOutput
            ))
        }
        return result
    }
}
