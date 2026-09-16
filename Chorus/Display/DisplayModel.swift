import ChorusCore
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
final class DisplayModel: @MainActor Identifiable {
    /// 跨重啟穩定的識別碼（同步協定與設定都以此為 key）。
    let uuid: String
    let name: String
    let isBuiltin: Bool
    /// 執行期 display ID；拓撲不變但系統重編號時由 DisplayManager 更新綁定。
    private(set) var id: CGDirectDisplayID

    func rebind(displayID: CGDirectDisplayID) {
        id = displayID
    }
    /// DDC 持續失敗時會被 DisplayManager 降級為 .gammaOnly。
    private(set) var backend: BrightnessBackend
    /// 螢幕自報的 VCP 0x10 值域上限。多數螢幕是 100，但協定允許任意值
    /// （有螢幕用 255）；寫入一律以此縮放，不能假設 100。
    /// 讀不到（停用讀取）時依 MCCS 慣例取 100。
    let ddcBrightnessMax: UInt16
    /// 對比 0–1（VCP 0x12）。nil = 讀不到（不支援、停用讀取或非 DDC）→ 不顯示對比 UI。
    var contrast: Double?
    /// VCP 0x12 值域上限（同亮度：以螢幕自報值縮放）。
    let ddcContrastMax: UInt16

    /// 螢幕自報支援 VCP 0xD6（讀得回電源模式）。
    let supportsDDCPower: Bool
    /// 這台目前會用哪一層關閉（refresh 時依能力與顯示器數量重算）。
    /// 顯示器數量會變（拔掉一台後剩最後一台就不能再 soft-disconnect），
    /// 所以這是 var 不是 let。
    var powerLayer: DisplayPowerLayer
    /// **我們**把它關掉了。使用者按螢幕實體電源鍵關掉的偵測不到，
    /// 這個旗標只代表 Chorus 這邊的狀態，用來決定電源鈕的樣子與復原範圍。
    var isPoweredOff: Bool = false

    func demoteToGammaOnly() {
        backend = .gammaOnly
    }
    /// 使用者強制軟體調光（apply 時視同無硬體控制）。
    var forceSoftwareDimming: Bool
    /// Sub-zero dimming：滑桿下段硬體到底後接續 gamma（外接螢幕硬體 0 仍亮時用）。
    var subZeroDimming: Bool

    /// UI 顯示的 0–1 亮度值（樂觀更新：先動 UI 再寫硬體）。
    var brightness: Double

    /// 目前顯示模式摘要（D4 唯讀；nil＝尚未探測）。
    var modeSummary: String?
    /// 目前模式描述（供設定窗比對）。
    var currentMode: DisplayModeDescriptor?
    /// 是否處於鏡像組（第一版禁止寫入模式）。
    var isMirrored: Bool = false
    /// HDR 狀態字串（unsupported／unknown／on／off）；僅供顯示。
    var hdrStatus: String?

    init(
        id: CGDirectDisplayID,
        uuid: String,
        name: String,
        isBuiltin: Bool,
        backend: BrightnessBackend,
        forceSoftwareDimming: Bool,
        subZeroDimming: Bool = false,
        brightness: Double,
        ddcBrightnessMax: UInt16 = 100,
        contrast: Double? = nil,
        ddcContrastMax: UInt16 = 100,
        supportsDDCPower: Bool = false,
        powerLayer: DisplayPowerLayer = .gammaBlackout,
        modeSummary: String? = nil,
        currentMode: DisplayModeDescriptor? = nil,
        isMirrored: Bool = false,
        hdrStatus: String? = nil
    ) {
        self.id = id
        self.uuid = uuid
        self.name = name
        self.isBuiltin = isBuiltin
        self.backend = backend
        self.forceSoftwareDimming = forceSoftwareDimming
        self.subZeroDimming = subZeroDimming
        self.brightness = brightness
        self.ddcBrightnessMax = max(ddcBrightnessMax, 1)
        self.contrast = contrast
        self.ddcContrastMax = max(ddcContrastMax, 1)
        self.supportsDDCPower = supportsDDCPower
        self.powerLayer = powerLayer
        self.modeSummary = modeSummary
        self.currentMode = currentMode
        self.isMirrored = isMirrored
        self.hdrStatus = hdrStatus
    }

    var hasHardwareControl: Bool {
        backend != .gammaOnly && !forceSoftwareDimming
    }
}
