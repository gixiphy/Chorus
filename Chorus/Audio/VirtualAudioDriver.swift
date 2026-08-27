import CoreAudio
import Foundation
import Observation

/// ChorusAudioDevice（HAL 虛擬輸出裝置，BV）的 App 端控制器：
/// 安裝狀態偵測、安裝／移除（admin 一次）、與 driver 的設定通道。
///
/// 設定通道沿用 proxy-audio-device 的 box-name 協議（HAL plugin 無法開自己的
/// IPC，只能借 CoreAudio 屬性當通道）：
///   - 寫值：把 box 的 name 屬性設為 "key=value" 字串
///   - 讀值：先對 box 設 identify = -ConfigType，再讀 box 的 name 屬性
///     （driver 只對送出 identify 的 process 回設定值）
@MainActor
@Observable
final class VirtualAudioDriverController {
    static let boxUID = "ChorusAudioBox_UID"
    static let deviceUID = "ChorusAudioDevice_UID"
    static let driverPath = "/Library/Audio/Plug-Ins/HAL/ChorusAudioDevice.driver"

    /// driver 的 ConfigType 序號（見 ProxyAudioDevice.h；讀值以負數 identify 選擇）。
    private enum ConfigType: Int32 {
        case outputDevice = 1
        case outputDeviceBufferFrameSize = 2
        case deviceName = 3
        case deviceActiveCondition = 4
        case deviceHideWhenUnavailable = 5
        case applyVolume = 6
    }

    enum Status: Equatable {
        /// driver 檔不在 /Library/Audio/Plug-Ins/HAL。
        case notInstalled
        /// 檔在但 coreaudiod 還沒載入（剛裝完或載入失敗）。
        case installedNotLoaded
        /// box 出現，設定通道可用。
        case active
    }

    private(set) var status: Status = .notInstalled
    /// 目前 driver 轉送的目標裝置 UID（讀自 driver 設定）。
    private(set) var targetUID: String?
    /// 目前是否為 DDC 鏡射模式（applyVolume=0）。nil = 尚未讀到。
    private(set) var mirrorMode: Bool?

    /// CoreAudio 呼叫可能阻塞——全部走這條 serial queue。
    @ObservationIgnored private let queue = DispatchQueue(label: "com.hermes.Chorus.virtualDriver", qos: .userInitiated)

    /// App 內附的 driver bundle（打包時由 package.sh 放進 Resources；開發版可能沒有）。
    nonisolated static var bundledDriverURL: URL? {
        Bundle.main.url(forResource: "ChorusAudioDevice", withExtension: "driver")
    }

    // MARK: - 狀態

    func refreshStatus() {
        let installed = FileManager.default.fileExists(atPath: Self.driverPath)
        Task {
            let box = await findBox()
            if box != kAudioObjectUnknown {
                status = .active
                await refreshConfig(box: box)
            } else {
                status = installed ? .installedNotLoaded : .notInstalled
                targetUID = nil
                mirrorMode = nil
            }
        }
    }

    private func refreshConfig(box: AudioObjectID) async {
        targetUID = await readConfig(box: box, type: .outputDevice)
        mirrorMode = await readConfig(box: box, type: .applyVolume).map { $0 == "0" }
    }

    // MARK: - 設定

    /// 指定轉送目標（裝置 UID）。
    func setTarget(uid: String) {
        targetUID = uid
        writeConfig("outputDevice=\(uid)")
    }

    /// DDC 鏡射模式開關：鏡射時 driver 不做數位衰減（樣本原樣通過）。
    /// 只在值真的改變時打設定通道。
    func setMirrorMode(_ mirror: Bool) {
        guard mirrorMode != mirror else { return }
        mirrorMode = mirror
        writeConfig("applyVolume=\(mirror ? 0 : 1)")
    }

    private func writeConfig(_ keyValue: String) {
        Task {
            let box = await findBox()
            guard box != kAudioObjectUnknown else { return }
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                queue.async {
                    Self.registerConfiguratorLocked(box: box)
                    var address = CoreAudioProperty.address(kAudioObjectPropertyName)
                    var name = Unmanaged.passRetained(keyValue as CFString)
                    _ = withUnsafeMutablePointer(to: &name) { pointer in
                        AudioObjectSetPropertyData(
                            box, &address, 0, nil,
                            UInt32(MemoryLayout<Unmanaged<CFString>>.size), pointer
                        )
                    }
                    name.release()
                    continuation.resume()
                }
            }
        }
    }

    private func readConfig(box: AudioObjectID, type: ConfigType) async -> String? {
        await withCheckedContinuation { continuation in
            queue.async {
                Self.registerConfiguratorLocked(box: box)
                // identify = -ConfigType 之後，本 process 讀 name 得到的是設定值
                let identify = CoreAudioProperty.address(kAudioObjectPropertyIdentify)
                CoreAudioProperty.set(box, identify, to: Int32(-type.rawValue))
                let value = CoreAudioProperty.getString(box, CoreAudioProperty.address(kAudioObjectPropertyName))
                continuation.resume(returning: value)
            }
        }
    }

    /// driver 只理會已註冊 pid 的 configurator：每次操作前先把自己的 pid
    /// 寫進 identify（正值）。每次都寫——coreaudiod 重啟後記憶會消失。
    private static func registerConfiguratorLocked(box: AudioObjectID) {
        let identify = CoreAudioProperty.address(kAudioObjectPropertyIdentify)
        CoreAudioProperty.set(box, identify, to: Int32(ProcessInfo.processInfo.processIdentifier))
    }

    private func findBox() async -> AudioObjectID {
        await withCheckedContinuation { continuation in
            queue.async {
                let boxes = CoreAudioProperty.getArray(
                    AudioObjectID(kAudioObjectSystemObject),
                    CoreAudioProperty.address(kAudioHardwarePropertyBoxList),
                    of: AudioObjectID.self
                ) ?? []
                for box in boxes {
                    let uid = CoreAudioProperty.getString(box, CoreAudioProperty.address(kAudioBoxPropertyBoxUID))
                    if uid == Self.boxUID {
                        continuation.resume(returning: box)
                        return
                    }
                }
                continuation.resume(returning: kAudioObjectUnknown)
            }
        }
    }

    // MARK: - 安裝／移除（admin 一次，會重啟 coreaudiod、音訊短暫中斷）

    enum InstallError: LocalizedError {
        case driverMissing
        case adminFailed(String)

        var errorDescription: String? {
            switch self {
            case .driverMissing:
                "App 內沒有附 driver（開發版）。請在專案目錄執行 scripts/build-audio-driver.sh 後 sudo scripts/install-audio-driver.sh。"
            case let .adminFailed(message):
                "安裝失敗：\(message)"
            }
        }
    }

    func install() async throws {
        guard let source = Self.bundledDriverURL else { throw InstallError.driverMissing }
        let src = source.path
        let dst = Self.driverPath
        try await runAsAdmin(
            "/bin/mkdir -p '/Library/Audio/Plug-Ins/HAL' && /bin/rm -rf '\(dst)' && /usr/bin/ditto '\(src)' '\(dst)' && /usr/sbin/chown -R root:wheel '\(dst)' && (/usr/bin/killall coreaudiod || true)"
        )
        // coreaudiod 重啟需要一點時間才會註冊 box
        try? await Task.sleep(for: .seconds(2))
        refreshStatus()
    }

    func uninstall() async throws {
        try await runAsAdmin("/bin/rm -rf '\(Self.driverPath)' && (/usr/bin/killall coreaudiod || true)")
        try? await Task.sleep(for: .seconds(1))
        refreshStatus()
    }

    /// osascript 的 administrator privileges 對話框：使用者輸入一次密碼。
    /// 指令內容全部是我們自己組的常數路徑，不經手任何使用者輸入。
    private func runAsAdmin(_ command: String) async throws {
        let escaped = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script = "do shell script \"\(escaped)\" with administrator privileges"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        let stderrPipe = Pipe()
        process.standardError = stderrPipe
        try process.run()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            process.terminationHandler = { _ in continuation.resume() }
        }
        guard process.terminationStatus == 0 else {
            let data = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            throw InstallError.adminFailed(String(data: data, encoding: .utf8) ?? "未知錯誤")
        }
    }
}
