import CoreGraphics
import Foundation
import Observation

/// 亮度控制的後端類型。
enum BrightnessBackend: String, Sendable {
    /// 外接螢幕，DDC/CI（VCP 0x10）。
    case ddc
    /// 內建面板或 Apple 認可顯示器，DisplayServices private API。
    case displayServices
    /// 都不可用（或使用者強制），gamma 軟體調光。
    case gammaOnly
}

/// 單一顯示器的可觀察狀態。
@MainActor
@Observable
final class DisplayModel: Identifiable {
    let id: CGDirectDisplayID
    /// 跨重啟穩定的識別碼（同步協定與設定都以此為 key）。
    let uuid: String
    let name: String
    let isBuiltin: Bool
    /// DDC 持續失敗時會被 DisplayManager 降級為 .gammaOnly。
    private(set) var backend: BrightnessBackend

    func demoteToGammaOnly() {
        backend = .gammaOnly
    }
    /// 使用者強制軟體調光（apply 時視同無硬體控制）。
    var forceSoftwareDimming: Bool

    /// UI 顯示的 0–1 亮度值（樂觀更新：先動 UI 再寫硬體）。
    var brightness: Double

    init(
        id: CGDirectDisplayID,
        uuid: String,
        name: String,
        isBuiltin: Bool,
        backend: BrightnessBackend,
        forceSoftwareDimming: Bool,
        brightness: Double
    ) {
        self.id = id
        self.uuid = uuid
        self.name = name
        self.isBuiltin = isBuiltin
        self.backend = backend
        self.forceSoftwareDimming = forceSoftwareDimming
        self.brightness = brightness
    }

    var hasHardwareControl: Bool {
        backend != .gammaOnly && !forceSoftwareDimming
    }
}
