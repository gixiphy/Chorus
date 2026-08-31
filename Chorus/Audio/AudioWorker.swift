import CoreAudio
import Foundation

/// 所有 CoreAudio 呼叫限制在單一 serial queue（AudioObjectSetPropertyData 有
/// 阻塞主執行緒的已知案例）。對外以 AsyncStream 送出完整 snapshot；
/// 任何屬性變更（含媒體鍵、其他 App 調整）都觸發重建，變更會自動合併。
final class AudioWorker: @unchecked Sendable {
    struct DeviceInfo: Sendable, Equatable {
        let id: AudioObjectID
        let uid: String
        let name: String
        let transportType: UInt32
        let canSetVolume: Bool
        let hasMute: Bool
        let volume: Double
        let muted: Bool
        /// 裝置有原生左右平衡：HAL 合成的 vmbc（逐聲道音量的裝置）或
        /// stereo pan control（內建喇叭）。兩者之一可寫就算。
        let canSetBalance: Bool
        /// 目前的平衡，正規化成 −1…+1（0＝置中）。不支援時恆為 0。
        let balance: Double
    }

    struct Snapshot: Sendable, Equatable {
        let devices: [DeviceInfo]
        let defaultDeviceID: AudioObjectID?
    }

    let snapshots: AsyncStream<Snapshot>
    private let continuation: AsyncStream<Snapshot>.Continuation

    private let queue = DispatchQueue(label: "com.hermes.Chorus.audio", qos: .userInitiated)
    private let systemObject = AudioObjectID(kAudioObjectSystemObject)

    // 以下狀態只在 queue 上讀寫
    private var listenedDevices: Set<AudioObjectID> = []
    private var snapshotScheduled = false

    private let listenerBlock: AudioObjectPropertyListenerBlock

    init() {
        var storedContinuation: AsyncStream<Snapshot>.Continuation!
        snapshots = AsyncStream(bufferingPolicy: .bufferingNewest(1)) { storedContinuation = $0 }
        continuation = storedContinuation

        // 先建一個弱參照盒，避免 listener block 與 self 循環持有
        let box = WeakBox()
        listenerBlock = { _, _ in
            box.worker?.scheduleSnapshotLocked()
        }
        box.worker = self
    }

    private final class WeakBox: @unchecked Sendable {
        weak var worker: AudioWorker?
    }

    func start() {
        queue.async {
            for selector in [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultOutputDevice] {
                var address = CoreAudioProperty.address(selector)
                AudioObjectAddPropertyListenerBlock(self.systemObject, &address, self.queue, self.listenerBlock)
            }
            self.scheduleSnapshotLocked()
        }
    }

    // MARK: - 控制（fire-and-forget，UI 端樂觀更新）

    func setVolume(_ deviceID: AudioObjectID, to value: Double) {
        queue.async {
            let clamped = Float32(min(max(value, 0), 1))
            let main = CoreAudioProperty.address(
                CoreAudioProperty.virtualMainVolume,
                scope: kAudioObjectPropertyScopeOutput
            )
            if CoreAudioProperty.isSettable(deviceID, main) {
                CoreAudioProperty.set(deviceID, main, to: clamped)
                return
            }
            // fallback：逐 channel 設 VolumeScalar
            for channel: AudioObjectPropertyElement in [1, 2] {
                let scalar = CoreAudioProperty.address(
                    kAudioDevicePropertyVolumeScalar,
                    scope: kAudioObjectPropertyScopeOutput,
                    element: channel
                )
                if CoreAudioProperty.isSettable(deviceID, scalar) {
                    CoreAudioProperty.set(deviceID, scalar, to: clamped)
                }
            }
        }
    }

    /// 原生左右平衡（−1…+1）。vmbc 優先（逐聲道音量的裝置），
    /// 退而寫 stereo pan（內建喇叭）。呼叫端已確認 `canSetBalance`。
    func setBalance(_ deviceID: AudioObjectID, to balance: Double) {
        queue.async {
            let halValue = Float32((min(max(balance, -1), 1) + 1) / 2) // −1…+1 → 0…1
            let vmbc = CoreAudioProperty.address(
                CoreAudioProperty.virtualMainBalance, scope: kAudioObjectPropertyScopeOutput
            )
            if CoreAudioProperty.isSettable(deviceID, vmbc) {
                CoreAudioProperty.set(deviceID, vmbc, to: halValue)
                return
            }
            let pan = CoreAudioProperty.address(
                kAudioDevicePropertyStereoPan, scope: kAudioObjectPropertyScopeOutput
            )
            if CoreAudioProperty.isSettable(deviceID, pan) {
                CoreAudioProperty.set(deviceID, pan, to: halValue)
            }
        }
    }

    func setMute(_ deviceID: AudioObjectID, muted: Bool) {
        queue.async {
            let address = CoreAudioProperty.address(
                kAudioDevicePropertyMute,
                scope: kAudioObjectPropertyScopeOutput
            )
            CoreAudioProperty.set(deviceID, address, to: UInt32(muted ? 1 : 0))
        }
    }

    func setDefaultOutputDevice(_ deviceID: AudioObjectID) {
        queue.async {
            let address = CoreAudioProperty.address(kAudioHardwarePropertyDefaultOutputDevice)
            CoreAudioProperty.set(self.systemObject, address, to: deviceID)
        }
    }

    // MARK: - Snapshot（queue 上執行）

    /// 只能在 queue 上呼叫。合併密集的屬性變更，一輪只重建一次 snapshot。
    private func scheduleSnapshotLocked() {
        guard !snapshotScheduled else { return }
        snapshotScheduled = true
        queue.asyncAfter(deadline: .now() + .milliseconds(50)) {
            self.snapshotScheduled = false
            self.rebuildSnapshotLocked()
        }
    }

    private func rebuildSnapshotLocked() {
        let deviceIDs = CoreAudioProperty.getArray(
            systemObject,
            CoreAudioProperty.address(kAudioHardwarePropertyDevices),
            of: AudioObjectID.self
        ) ?? []

        var devices: [DeviceInfo] = []
        var currentIDs: Set<AudioObjectID> = []
        for id in deviceIDs where CoreAudioProperty.hasStreams(id, scope: kAudioObjectPropertyScopeOutput) {
            guard let uid = CoreAudioProperty.getString(id, CoreAudioProperty.address(kAudioDevicePropertyDeviceUID)),
                  let name = CoreAudioProperty.getString(id, CoreAudioProperty.address(kAudioObjectPropertyName))
            else { continue }
            // 自家 tap 的 private aggregate 只有建立者看得到——偏偏那就是
            // 我們自己。列出來會多一條與底下裝置搶同一顆音量的假裝置
            guard !uid.hasPrefix(CoreAudioTapBackend.aggregateUIDPrefix) else { continue }

            let transport = CoreAudioProperty.get(
                id, CoreAudioProperty.address(kAudioDevicePropertyTransportType), as: UInt32.self
            ) ?? 0
            // AirPlay 這類「聚合曝露」裝置與虛擬裝置照樣列出，由 UI 決定呈現
            let mainVolume = CoreAudioProperty.address(
                CoreAudioProperty.virtualMainVolume, scope: kAudioObjectPropertyScopeOutput
            )
            let channelVolume = CoreAudioProperty.address(
                kAudioDevicePropertyVolumeScalar, scope: kAudioObjectPropertyScopeOutput, element: 1
            )
            let canSetVolume = CoreAudioProperty.isSettable(id, mainVolume)
                || CoreAudioProperty.isSettable(id, channelVolume)
            let volume = CoreAudioProperty.get(id, mainVolume, as: Float32.self)
                ?? CoreAudioProperty.get(id, channelVolume, as: Float32.self)
                ?? 0
            let muteAddress = CoreAudioProperty.address(
                kAudioDevicePropertyMute, scope: kAudioObjectPropertyScopeOutput
            )
            let hasMute = CoreAudioProperty.isSettable(id, muteAddress)
            let muted = (CoreAudioProperty.get(id, muteAddress, as: UInt32.self) ?? 0) != 0

            let balanceAddress = CoreAudioProperty.address(
                CoreAudioProperty.virtualMainBalance, scope: kAudioObjectPropertyScopeOutput
            )
            let panAddress = CoreAudioProperty.address(
                kAudioDevicePropertyStereoPan, scope: kAudioObjectPropertyScopeOutput
            )
            let canSetBalance = CoreAudioProperty.isSettable(id, balanceAddress)
                || CoreAudioProperty.isSettable(id, panAddress)
            let rawBalance = CoreAudioProperty.get(id, balanceAddress, as: Float32.self)
                ?? CoreAudioProperty.get(id, panAddress, as: Float32.self)
            let balance = canSetBalance ? Double(rawBalance ?? 0.5) * 2 - 1 : 0 // 0…1 → −1…+1

            devices.append(DeviceInfo(
                id: id,
                uid: uid,
                name: name,
                transportType: transport,
                canSetVolume: canSetVolume,
                hasMute: hasMute,
                volume: Double(volume),
                muted: muted,
                canSetBalance: canSetBalance,
                balance: balance
            ))
            currentIDs.insert(id)
        }

        updateDeviceListenersLocked(currentIDs: currentIDs)

        let defaultID = CoreAudioProperty.get(
            systemObject,
            CoreAudioProperty.address(kAudioHardwarePropertyDefaultOutputDevice),
            as: AudioObjectID.self
        )
        continuation.yield(Snapshot(devices: devices, defaultDeviceID: defaultID))
    }

    /// 只能在 queue 上呼叫。對新裝置註冊音量/mute listener，移除消失裝置的。
    private func updateDeviceListenersLocked(currentIDs: Set<AudioObjectID>) {
        let watchedAddresses = [
            CoreAudioProperty.address(CoreAudioProperty.virtualMainVolume, scope: kAudioObjectPropertyScopeOutput),
            CoreAudioProperty.address(kAudioDevicePropertyVolumeScalar, scope: kAudioObjectPropertyScopeOutput, element: 1),
            CoreAudioProperty.address(kAudioDevicePropertyMute, scope: kAudioObjectPropertyScopeOutput),
            // 平衡的兩種原生形態（系統設定的平衡滑桿動了也要跟上）
            CoreAudioProperty.address(CoreAudioProperty.virtualMainBalance, scope: kAudioObjectPropertyScopeOutput),
            CoreAudioProperty.address(kAudioDevicePropertyStereoPan, scope: kAudioObjectPropertyScopeOutput),
        ]
        for id in currentIDs.subtracting(listenedDevices) {
            for address in watchedAddresses where CoreAudioProperty.has(id, address) {
                var address = address
                AudioObjectAddPropertyListenerBlock(id, &address, queue, listenerBlock)
            }
        }
        // 消失的裝置：AudioObjectID 已失效，聽器隨物件消失，不需顯式移除
        listenedDevices = currentIDs
    }
}
