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
    ///
    /// P4 現況（driver v7 盤點）：七種設定 App 端接了三種——outputDevice、
    /// applyVolume、deviceActiveCondition。其餘三種是刻意不接：
    /// deviceName／deviceHideWhenUnavailable 的預設值就是產品要的行為、
    /// outputDeviceBufferFrameSize 沒有調整的需求（512 即預設）。
    private enum ConfigType: Int32 {
        case outputDevice = 1
        case outputDeviceBufferFrameSize = 2
        case deviceName = 3
        case deviceActiveCondition = 4
        case deviceHideWhenUnavailable = 5
        case applyVolume = 6
    }

    /// 實體輸出裝置的運轉條件（driver 端 ActiveCondition，序號一致）。
    ///
    /// driver 預設 `.userActive`：使用者閒置滿 30 秒**且**沒有播放中的 IO，
    /// 就停掉實體裝置的 IOProc（省電、讓系統能睡）；使用者回來或有聲音要播
    /// 會再啟動——代價是 HDMI 這類喚醒慢的裝置可能吃掉開頭一小段聲音。
    /// `.always` 會讓 coreaudiod 一直持有裝置、可能擋系統睡眠，勿輕用。
    enum ActiveCondition: Int32 {
        /// 只在有聲音經過 proxy 裝置時運轉實體裝置。
        case proxiedDeviceActive = 0
        /// 使用者活動中或有播放中 IO 就運轉（driver 預設）。
        case userActive = 1
        /// 永遠運轉。會讓 coreaudiod 一直持有實體裝置，可能擋系統睡眠。
        case always = 2
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
    /// 實體裝置的運轉條件。nil = 尚未讀到。
    private(set) var activeCondition: ActiveCondition?
    /// 已安裝的 driver 版本落後 App 內嵌版本（Info.plist CFBundleVersion 比對）。
    private(set) var updateAvailable = false
    /// 已安裝的 driver 版本號。nil = 沒裝或讀不到。
    ///
    /// 給「這個行為要 driver ≥ N 才有」的 UI 用（例如鏡射模式下的左右平衡
    /// 要 v8）。**不要改用 `updateAvailable`**——那個在未來出 v9 時對已經
    /// 裝了 v8 的使用者也會成立，提示會錯誤地跑回來。
    private(set) var installedDriverVersion: Int?

    /// CoreAudio 呼叫可能阻塞——全部走這條 serial queue。
    @ObservationIgnored private let queue = DispatchQueue(label: "com.hermes.Chorus.virtualDriver", qos: .userInitiated)

    /// App 內嵌的 driver bundle（ChorusAudioDevice target 隨 App 建置、
    /// 內嵌在 Contents/PlugIns——安裝就是把它複製到系統 HAL 目錄）。
    nonisolated static var bundledDriverURL: URL? {
        guard let url = Bundle.main.builtInPlugInsURL?
            .appendingPathComponent("ChorusAudioDevice.driver"),
            FileManager.default.fileExists(atPath: url.path)
        else { return nil }
        return url
    }

    // MARK: - 狀態

    func refreshStatus() {
        let installed = FileManager.default.fileExists(atPath: Self.driverPath)
        let installedVersion = installed ? Self.driverBundleVersion(at: Self.driverPath) : nil
        installedDriverVersion = installedVersion.flatMap { Int($0) }
        if installed, let bundled = Self.bundledDriverURL {
            let bundledVersion = Self.driverBundleVersion(at: bundled.path)
            updateAvailable = bundledVersion != nil && installedVersion != bundledVersion
        } else {
            updateAvailable = false
        }
        Task {
            let box = await findBox()
            if box != kAudioObjectUnknown {
                status = .active
                await refreshConfig(box: box)
            } else {
                status = installed ? .installedNotLoaded : .notInstalled
                targetUID = nil
                mirrorMode = nil
                activeCondition = nil
            }
        }
    }

    nonisolated private static func driverBundleVersion(at path: String) -> String? {
        guard let data = FileManager.default.contents(atPath: path + "/Contents/Info.plist"),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return nil }
        return plist["CFBundleVersion"] as? String
    }

    private func refreshConfig(box: AudioObjectID) async {
        targetUID = await readConfig(box: box, type: .outputDevice)
        // driver v6 以前讀值有跨程序競態（P3），可能拿回 box 名稱之類的
        // 非設定值——布林／enum 型設定一律驗證再收，解析不了就當沒讀到。
        mirrorMode = await readConfig(box: box, type: .applyVolume).flatMap {
            switch $0 {
            case "0": true
            case "1": false
            default: nil
            }
        }
        activeCondition = await readConfig(box: box, type: .deviceActiveCondition)
            .flatMap { Int32($0) }
            .flatMap { ActiveCondition(rawValue: $0) }
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

    /// 實體裝置運轉條件。目前沒有 UI，維持 driver 預設 `.userActive`；
    /// 這條通道是為了讓政策成為明確的 API 而不是 driver 裡的隱藏行為
    /// （P4）。只在值真的改變時打設定通道。
    func setActiveCondition(_ condition: ActiveCondition) {
        guard activeCondition != condition else { return }
        activeCondition = condition
        writeConfig("outputDeviceActiveCondition=\(condition.rawValue)")
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
        // ditto 保留來源權限，而 App bundle 裡的檔案不保證 world-readable。
        // HAL plugin 是 coreaudiod（以 _coreaudiod 身分，非 root、非 wheel）去讀的：
        // 少了 go+r 就會安靜地載不進去，狀態永遠停在 installedNotLoaded。
        try await runAsAdmin(
            "/bin/mkdir -p '/Library/Audio/Plug-Ins/HAL' && /bin/rm -rf '\(dst)' && /usr/bin/ditto '\(src)' '\(dst)' && /usr/sbin/chown -R root:wheel '\(dst)' && /bin/chmod -R go+rX '\(dst)' && (/usr/bin/killall coreaudiod || true)"
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
