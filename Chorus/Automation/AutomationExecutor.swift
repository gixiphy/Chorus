import AppKit
import ChorusCore
import CoreGraphics
import Foundation

/// 動詞層的執行端：把已驗證的請求解析成實體並套用到 manager。
///
/// 分工界線——ChorusCore 的 validator 只看語法與相容性矩陣（純函式、可測），
/// **實體解析在這裡**：`displayWithMouse` 在驗證階段永遠合法，
/// 到執行階段才知道它指向誰、或是不是根本找不到。
@MainActor
final class AutomationExecutor {
    private let settings: SettingsStore
    private unowned let displayManager: DisplayManager
    private unowned let audioManager: AudioDeviceManager
    private unowned let tapEngine: TapEngine
    private unowned let alertVolume: AlertVolumeController
    private unowned let autoBrightness: AutoBrightnessController
    private unowned let keepAwake: KeepAwakeController
    private unowned let coordinator: ControlCoordinator
    private unowned let pairedPeers: PairedPeersStore
    private unowned let sessionManager: SyncSessionManager
    private unowned let scenes: SceneStore
    /// 限時場景（B7-2）。**weak**：controller 反過來 unowned 持有 executor，
    /// 兩邊都強持有就是一個環。組裝順序上 controller 也比 executor 晚建立。
    weak var focus: FocusSessionController?

    init(
        settings: SettingsStore,
        displayManager: DisplayManager,
        audioManager: AudioDeviceManager,
        tapEngine: TapEngine,
        alertVolume: AlertVolumeController,
        autoBrightness: AutoBrightnessController,
        keepAwake: KeepAwakeController,
        coordinator: ControlCoordinator,
        pairedPeers: PairedPeersStore,
        sessionManager: SyncSessionManager,
        scenes: SceneStore
    ) {
        self.settings = settings
        self.displayManager = displayManager
        self.audioManager = audioManager
        self.tapEngine = tapEngine
        self.alertVolume = alertVolume
        self.autoBrightness = autoBrightness
        self.keepAwake = keepAwake
        self.coordinator = coordinator
        self.pairedPeers = pairedPeers
        self.sessionManager = sessionManager
        self.scenes = scenes
    }

    /// 單一入口。所有錯誤都轉成帶 hint 的回應，不往外拋——
    /// 呼叫端（HTTP／CLI／MCP／TestHooks）拿到的一律是可序列化的 ControlResponse。
    func execute(_ request: ControlRequest) -> ControlResponse {
        do {
            let validated = try ControlRequestValidator.validate(request)
            if let peer = validated.peer {
                return try forward(validated, toPeerNamed: peer)
            }
            return try .success(runLocally(validated))
        } catch let error as ControlError {
            return .failure(error)
        } catch {
            return .failure(.unsupported("\(error)"))
        }
    }

    /// 非同步入口。**只有限時場景需要它**——套用前要先把場景涉及的 peer
    /// 現值問回來（跨機還原的原值來源）。其餘請求原封不動走同步路徑，
    /// 既有的四個入口與內部的逐條套用完全不受影響。
    func executeAsync(_ request: ControlRequest) async -> ControlResponse {
        guard request.verb == .perform, request.action == .runScene, request.duration != nil else {
            return execute(request)
        }
        do {
            let validated = try ControlRequestValidator.validate(request)
            guard validated.durationSeconds != nil else { return execute(request) }
            let name = (validated.actionArgument ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if let scene = scenes.scene(named: name) {
                await refreshPeerState(forScene: scene)
            }
            return execute(request)
        } catch let error as ControlError {
            return .failure(error)
        } catch {
            return .failure(.unsupported("\(error)"))
        }
    }

    // MARK: - 本機執行

    private func runLocally(_ request: ValidatedControlRequest) throws(ControlError) -> [ControlResult] {
        if request.verb == .perform {
            return try perform(request)
        }
        return switch request.target.kind {
        case .display: try runOnDisplays(request)
        case .audioDevice: try runOnDevices(request)
        case .system: try runOnSystem(request)
        case .app: try runOnApps(request)
        }
    }

    private func perform(_ request: ValidatedControlRequest) throws(ControlError) -> [ControlResult] {
        switch request.action {
        case .restoreAllPower:
            let count = displayManager.restoreAllDisplayPower()
            return [ControlResult(target: "system", property: "restoreAllPower", value: .number(Double(count)))]
        case .refresh:
            displayManager.scheduleRefresh()
            audioManager.refreshBridges()
            return [ControlResult(target: "system", property: "refresh", value: .bool(true))]
        case .runScene:
            // 帶時長＝限時場景（B7）：套用前先快照，時間到自動還原。
            // 沒帶就是一般場景，行為與 B4-5 完全一樣
            if let seconds = request.durationSeconds {
                return try startFocus(sceneName: request.actionArgument, duration: seconds)
            }
            return try runScene(named: request.actionArgument)
        case .endScene:
            return try endFocus()
        case .suggestOffsets:
            throw ControlError.unsupported("suggestOffsets 尚未接上顧問管線（B4-4）")
        case nil:
            throw ControlError.missingAction
        }
    }

    // MARK: - 限時場景（B7-2）

    /// `perform runScene` ＋ 時長。回傳的是**套用結果 ＋ 這次限時的資訊**：
    /// 呼叫端一次看完「套上了什麼、什麼時候會還原、什麼不會自己回來」。
    private func startFocus(sceneName: String?, duration: Double) throws(ControlError) -> [ControlResult] {
        guard let focus else {
            throw ControlError.unsupported("限時場景尚未就緒")
        }
        let query = (sceneName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            throw ControlError.badValue("", hint: "perform runScene 需要場景名稱")
        }
        var results = try focus.start(sceneName: query, duration: duration)
        guard let session = focus.session else { return results }
        results.append(ControlResult(
            target: "focus", property: "deadline",
            value: .string(session.deadline.formatted(.iso8601))
        ))
        results.append(ControlResult(
            target: "focus", property: "restorable",
            value: .number(Double(session.snapshot.restorableCount))
        ))
        // 不可還原的項目逐條列出而不是給個數字：使用者要知道**哪一項**
        // 不會自己回來，才決定要不要手動處理
        for item in session.snapshot.unrestorable {
            results.append(ControlResult(
                target: "focus", property: "unrestorable", value: .string(item)
            ))
        }
        return results
    }

    private func endFocus() throws(ControlError) -> [ControlResult] {
        guard let focus, let session = focus.session else {
            throw ControlError.unsupported("目前沒有限時場景")
        }
        let name = session.sceneName
        focus.end(reason: .manual)
        var results = [
            ControlResult(target: "focus", property: "ended", value: .string(name)),
            ControlResult(target: "focus", property: "restored",
                          value: .number(Double(focus.lastOutcome?.restored ?? 0))),
        ]
        for item in focus.lastOutcome?.failed ?? [] {
            results.append(ControlResult(target: "focus", property: "failed", value: .string(item)))
        }
        return results
    }

    // MARK: - 場景

    /// 逐條獨立套用。**一條失敗不放棄其餘**——場景建立時在的螢幕現在可能被
    /// 拔掉了，那不該讓「電影模式」整組不生效。失敗的那條以一筆 error 結果
    /// 回報，呼叫端看得到哪一項沒套上。
    private func runScene(named name: String?) throws(ControlError) -> [ControlResult] {
        let query = (name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            throw ControlError.badValue("", hint: "perform runScene 需要場景名稱")
        }
        guard let scene = scenes.scene(named: query) else {
            throw ControlError.targetNotFound(query, hint: scenes.scenes.isEmpty
                ? "還沒有任何場景"
                : "目前的場景：" + scenes.scenes.map(\.name).joined(separator: "、"))
        }
        var results: [ControlResult] = []
        for request in scene.requests {
            // 場景裡不執行 perform：場景包場景會無限遞迴，
            // 與其做迴圈偵測，不如一開始就不允許。
            guard request.verb != .perform else {
                results.append(ControlResult(
                    target: scene.name,
                    property: "skipped",
                    value: .string("場景內不支援 perform")
                ))
                continue
            }
            let response = execute(request)
            if let ok = response.results {
                results.append(contentsOf: ok)
            } else if let error = response.error {
                results.append(ControlResult(
                    target: request.target.stringValue,
                    property: "error",
                    value: .string(error.message)
                ))
            }
        }
        return results
    }

    /// 以目前狀態擷取成一個場景。
    ///
    /// 擷取的是「畫面與聲音現在長什麼樣」：每台顯示器的亮度（以 UUID 定位，
    /// 精準但機器專屬）、預設輸出的音量與靜音，外加**自動亮度開關**——
    /// 少了它，套用固定亮度後會被自動亮度立刻覆蓋，場景等於沒作用。
    /// 不擷取電源與防睡眠：那是動作不是外觀，使用者不會期待「套用電影模式」
    /// 順手把某台螢幕關掉。
    func captureCurrentScene(named name: String) -> ControlScene {
        var requests: [ControlRequest] = [
            ControlRequest(
                verb: .set, target: .system, property: .autoBrightness,
                value: settings.autoBrightnessEnabled ? "on" : "off"
            ),
        ]
        for display in displayManager.displays where !display.isPoweredOff {
            requests.append(ControlRequest(
                verb: .set,
                target: .displayUUID(display.uuid),
                property: .brightness,
                value: Self.percent(display.brightness)
            ))
        }
        if let device = audioManager.defaultDevice {
            if device.isVolumeControllable {
                requests.append(ControlRequest(
                    verb: .set, target: .defaultOutput, property: .volume,
                    value: Self.percent(device.volume)
                ))
            }
            requests.append(ControlRequest(
                verb: .set, target: .defaultOutput, property: .mute,
                value: device.muted ? "on" : "off"
            ))
        }
        // 提示音音量（B6-7）。ROADMAP 的「會議」場景＝關提示音但不動音樂，
        // 少了這一條那個場景就表達不出來
        alertVolume.refresh()
        requests.append(ControlRequest(
            verb: .set, target: .system, property: .alertVolume,
            value: Self.percent(alertVolume.volume)
        ))
        return ControlScene(name: name, requests: requests)
    }

    /// 存成 `"85%"`：與 CLI／HTTP 的收值規則同一套寫法，
    /// 場景 JSON 直接看得懂，也可以手改。
    private static func percent(_ value: Double) -> String {
        "\(Int((min(max(value, 0), 1) * 100).rounded()))%"
    }

    // MARK: - 顯示器

    private func runOnDisplays(_ request: ValidatedControlRequest) throws(ControlError) -> [ControlResult] {
        let displays = try resolveDisplays(request.target)
        var results: [ControlResult] = []
        for display in displays {
            guard let property = request.property else {
                results.append(contentsOf: describe(display))
                continue
            }
            results.append(try apply(property, request: request, to: display))
        }
        return results
    }

    private func apply(
        _ property: ControlProperty,
        request: ValidatedControlRequest,
        to display: DisplayModel
    ) throws(ControlError) -> ControlResult {
        switch property {
        case .brightness:
            if request.verb == .get {
                return result(display.name, property, .number(display.brightness))
            }
            let value = try resolved(request.value, current: display.brightness, range: 0...1)
            displayManager.setBrightness(value, for: display)
            return result(display.name, property, .number(value))

        case .contrast:
            guard let current = display.contrast else {
                throw ControlError.unsupported("「\(display.name)」沒有回報對比（VCP 0x12），無法控制")
            }
            if request.verb == .get {
                return result(display.name, property, .number(current))
            }
            let value = try resolved(request.value, current: current, range: 0...1)
            displayManager.setContrast(value, for: display)
            return result(display.name, property, .number(value))

        case .input:
            guard case let .rawCode(code)? = request.value else {
                throw ControlError.missingValue(.input)
            }
            displayManager.setInput(code, for: display)
            return result(display.name, property, .number(Double(code)))

        case .power:
            // 對外語意是「電源開著嗎」，內部存的是 isPoweredOff，兩者相反
            let isOn = !display.isPoweredOff
            if request.verb == .get {
                return result(display.name, property, .bool(isOn))
            }
            let target = request.verb == .toggle ? !isOn : try boolean(request.value, property: .power)
            displayManager.setDisplayPower(target, for: display)
            return result(display.name, property, .bool(target))

        case .ambientOffset:
            let current = settings.ambientDisplayOffsets[display.uuid] ?? 0
            if request.verb == .get {
                return result(display.name, property, .number(current))
            }
            let value = try resolved(request.value, current: current, range: -0.5...0.5)
            autoBrightness.setDisplayOffset(value, for: display.uuid)
            return result(display.name, property, .number(value))

        case .volume, .mute, .keepAwake, .autoBrightness, .alertVolume:
            // validator 的相容性矩陣已擋掉，這裡不可能走到
            throw ControlError.targetKindMismatch(property: property, target: request.target.stringValue)
        }
    }

    private func describe(_ display: DisplayModel) -> [ControlResult] {
        var results = [
            result(display.name, .brightness, .number(display.brightness)),
            result(display.name, .power, .bool(!display.isPoweredOff)),
            result(display.name, .ambientOffset,
                   .number(settings.ambientDisplayOffsets[display.uuid] ?? 0)),
            ControlResult(target: display.name, property: "uuid", value: .string(display.uuid)),
            ControlResult(target: display.name, property: "backend", value: .string(display.backend.rawValue)),
            ControlResult(target: display.name, property: "powerLayer",
                          value: .string(display.powerLayer.rawValue)),
            ControlResult(target: display.name, property: "builtin", value: .bool(display.isBuiltin)),
        ]
        if let contrast = display.contrast {
            results.append(result(display.name, .contrast, .number(contrast)))
        }
        return results
    }

    // MARK: - 音訊裝置

    private func runOnDevices(_ request: ValidatedControlRequest) throws(ControlError) -> [ControlResult] {
        let devices = try resolveDevices(request.target)
        var results: [ControlResult] = []
        for device in devices {
            guard let property = request.property else {
                results.append(contentsOf: describe(device))
                continue
            }
            switch property {
            case .volume:
                if request.verb == .get {
                    results.append(result(device.name, property, .number(device.volume)))
                    continue
                }
                guard device.isVolumeControllable else {
                    throw ControlError.unsupported("「\(device.name)」目前沒有可用的音量控制（無軟體音量且未橋接 DDC）")
                }
                let value = try resolved(request.value, current: device.volume, range: 0...1)
                audioManager.setVolume(value, for: device)
                results.append(result(device.name, property, .number(value)))

            case .mute:
                if request.verb == .get {
                    results.append(result(device.name, property, .bool(device.muted)))
                    continue
                }
                let target = request.verb == .toggle
                    ? !device.muted
                    : try boolean(request.value, property: .mute)
                audioManager.setMuted(target, for: device)
                results.append(result(device.name, property, .bool(target)))

            default:
                throw ControlError.targetKindMismatch(property: property, target: request.target.stringValue)
            }
        }
        return results
    }

    private func describe(_ device: AudioDeviceModel) -> [ControlResult] {
        [
            result(device.name, .volume, .number(device.volume)),
            result(device.name, .mute, .bool(device.muted)),
            ControlResult(target: device.name, property: "uid", value: .string(device.uid)),
            ControlResult(target: device.name, property: "isDefault", value: .bool(device.isDefault)),
            ControlResult(target: device.name, property: "volumeControllable",
                          value: .bool(device.isVolumeControllable)),
        ]
    }

    // MARK: - 逐 App 音訊（B6-6）

    /// per-app 音量／靜音。**引擎沒有權限時整組不可用**——回一個帶
    /// 指引的 unsupported，而不是靜靜地把指令吞掉（DESIGN §6 降級表：
    /// 這一組會消失，裝置音量與亮度完全不受影響）。
    private func runOnApps(_ request: ValidatedControlRequest) throws(ControlError) -> [ControlResult] {
        guard tapEngine.state == .active else {
            throw ControlError.unsupported(engineHint)
        }
        let bundles = try resolveApps(request.target)
        var results: [ControlResult] = []
        for bundleID in bundles {
            let name = tapEngine.registry.displayName(bundleID: bundleID)
            let setting = tapEngine.setting(for: bundleID)
            guard let property = request.property else {
                results.append(contentsOf: describeApp(bundleID: bundleID))
                continue
            }
            // 排除清單裡的 App：讀可以（誠實回存檔值＋excluded 旗標），
            // 寫要擋——設定會被收下卻永遠聽不到效果，那是陷阱不是功能
            if request.verb != .get, tapEngine.isExcluded(bundleID: bundleID) {
                throw ControlError.unsupported(
                    "「\(name)」已被排除於音訊處理之外——先在選單列的 App 列上取消排除"
                )
            }
            switch property {
            case .volume:
                if request.verb == .get {
                    results.append(result(name, property, .number(Double(setting.gain))))
                    continue
                }
                // 0–4x：per-app 可以 boost，>1 在 realtime 端過 soft limiter
                let value = try resolved(
                    request.value, current: Double(setting.gain), range: 0...Double(GainRamp.maxGain)
                )
                tapEngine.setGain(Float(value), bundleID: bundleID)
                results.append(result(name, property, .number(value)))

            case .mute:
                if request.verb == .get {
                    results.append(result(name, property, .bool(setting.muted)))
                    continue
                }
                let target = request.verb == .toggle
                    ? !setting.muted
                    : try boolean(request.value, property: .mute)
                tapEngine.setMuted(target, bundleID: bundleID)
                results.append(result(name, property, .bool(target)))

            default:
                throw ControlError.targetKindMismatch(property: property, target: request.target.stringValue)
            }
        }
        return results
    }

    private func describeApp(bundleID: String) -> [ControlResult] {
        let name = tapEngine.registry.displayName(bundleID: bundleID)
        let setting = tapEngine.setting(for: bundleID)
        var results = [
            result(name, .volume, .number(Double(setting.gain))),
            result(name, .mute, .bool(setting.muted)),
            ControlResult(target: name, property: "bundleID", value: .string(bundleID)),
            ControlResult(target: name, property: "audible",
                          value: .bool(tapEngine.registry.entry(bundleID: bundleID)?.isAudible ?? false)),
            ControlResult(target: name, property: "tapped",
                          value: .bool(tapEngine.tappedBundles.contains(bundleID))),
        ]
        if let route = setting.outputDeviceUID {
            results.append(ControlResult(target: name, property: "outputDevice", value: .string(route)))
        }
        if tapEngine.isExcluded(bundleID: bundleID) {
            results.append(ControlResult(target: name, property: "excluded", value: .bool(true)))
        }
        return results
    }

    /// 候選來源有兩份：**現在有音訊行程的 App**，以及**已經被調整過的 App**
    /// （可能已退出——設定還在，遙控端要改得回來）。
    private func resolveApps(_ target: ControlTarget) throws(ControlError) -> [String] {
        tapEngine.registry.refresh()
        let running = tapEngine.registry.listableApps
        let adjusted = settings.appAudio.adjustedBundleIDs
        var seen = Set<String>()
        let all = (running + adjusted).filter { seen.insert($0).inserted }

        let matches: [String] = switch target {
        case .allApps:
            // 批次操作略過排除清單——「所有 App 靜音」不該因為一個被排除的
            // App 整批失敗；點名操作（.app／.appLike）仍會誠實報 excluded
            all.filter { !tapEngine.isExcluded(bundleID: $0) }
        case let .app(bundleID):
            // 精確定位不要求 App 正在跑：先設定好、App 一開就生效
            [bundleID]
        case let .appLike(text):
            all.filter {
                Self.contains(tapEngine.registry.displayName(bundleID: $0), text) || Self.contains($0, text)
            }
        default:
            []
        }
        guard !matches.isEmpty else {
            throw ControlError.targetNotFound(
                target.stringValue,
                hint: all.isEmpty
                    ? "目前沒有任何有音訊的 App"
                    : "目前有音訊的 App：" + all
                        .map { tapEngine.registry.displayName(bundleID: $0) }
                        .joined(separator: "、")
            )
        }
        return matches.sorted()
    }

    /// 引擎沒到 active 時，各種原因的指引各不相同——照實講哪一種。
    private var engineHint: String {
        switch tapEngine.state {
        case .off:
            "逐 App 音訊未啟用。請到 Chorus 設定 → 音訊開啟「App 音訊接管」"
        case .probing:
            "正在確認系統音訊錄製權限——播放任何聲音即可完成檢查"
        case .denied:
            "系統音訊錄製權限被拒。請到系統設定 → 隱私權與安全性 → 螢幕與系統音訊錄製 開啟 Chorus"
        case let .failed(message):
            "逐 App 音訊目前不可用：\(message)"
        case .active:
            ""
        }
    }

    // MARK: - 整機

    private func runOnSystem(_ request: ValidatedControlRequest) throws(ControlError) -> [ControlResult] {
        guard let property = request.property else {
            return [
                result("system", .keepAwake, .number(KeepAwakePlanner.encode(keepAwake.mode))),
                result("system", .autoBrightness, .bool(settings.autoBrightnessEnabled)),
                result("system", .ambientOffset, .number(settings.ambientDeviceOffset)),
                result("system", .alertVolume, .number(alertVolume.volume)),
                ControlResult(target: "system", property: "keepAwakeHolding",
                              value: .bool(keepAwake.isHolding)),
            ] + focusState()
        }
        switch property {
        case .keepAwake:
            let current = KeepAwakePlanner.encode(keepAwake.mode)
            if request.verb == .get {
                return [result("system", property, .number(current))]
            }
            let target: Double
            if request.verb == .toggle {
                // 翻轉的語意是「沒開就開成無限期，開著就關掉」
                target = keepAwake.mode == .off ? -1 : 0
            } else if case let .duration(seconds)? = request.value {
                target = seconds
            } else {
                throw ControlError.missingValue(.keepAwake)
            }
            keepAwake.activate(KeepAwakePlanner.decode(target))
            return [result("system", property, .number(target))]

        case .autoBrightness:
            let current = settings.autoBrightnessEnabled
            if request.verb == .get {
                return [result("system", property, .bool(current))]
            }
            let target = request.verb == .toggle
                ? !current
                : try boolean(request.value, property: .autoBrightness)
            autoBrightness.setAutoEnabled(target)
            return [result("system", property, .bool(target))]

        case .ambientOffset:
            let current = settings.ambientDeviceOffset
            if request.verb == .get {
                return [result("system", property, .number(current))]
            }
            let value = try resolved(request.value, current: current, range: -0.5...0.5)
            autoBrightness.setDeviceOffset(value)
            return [result("system", property, .number(value))]

        case .alertVolume:
            alertVolume.refresh() // 系統設定可能剛被別人改過
            if request.verb == .get {
                return [result("system", property, .number(alertVolume.volume))]
            }
            let value = try resolved(request.value, current: alertVolume.volume, range: 0...1)
            alertVolume.setVolume(value)
            return [result("system", property, .number(value))]

        default:
            throw ControlError.targetKindMismatch(property: property, target: "system")
        }
    }

    /// 進行中的限時場景，附在 `get system` 的列舉尾端（`/v1/state` 因此自動
    /// 帶上）。**沒有 session 時一筆都不回**——回一串 null 只是讓呼叫端多寫
    /// 一組判斷。
    private func focusState() -> [ControlResult] {
        guard let session = focus?.session else { return [] }
        return [
            ControlResult(target: "system", property: "focusScene",
                          value: .string(session.sceneName)),
            ControlResult(target: "system", property: "focusRemaining",
                          value: .number((focus?.remainingSeconds ?? 0).rounded())),
            ControlResult(target: "system", property: "focusDeadline",
                          value: .string(session.deadline.formatted(.iso8601))),
        ]
    }

    // MARK: - 目標解析

    private func resolveDisplays(_ target: ControlTarget) throws(ControlError) -> [DisplayModel] {
        let all = displayManager.displays
        let matches: [DisplayModel] = switch target {
        case .allDisplays:
            all
        case let .display(name):
            all.filter { Self.matchesExactly($0.name, name) }
        case let .displayLike(text):
            all.filter { Self.contains($0.name, text) }
        case let .displayUUID(uuid):
            all.filter { $0.uuid == uuid }
        case .builtinDisplay:
            all.filter(\.isBuiltin)
        case .displayWithMouse:
            Self.screenID(containing: NSEvent.mouseLocation).map { id in all.filter { $0.id == id } } ?? []
        case .displayWithFocus:
            // NSScreen.main 的定義正是「有鍵盤焦點的視窗所在的螢幕」
            Self.displayID(of: NSScreen.main).map { id in all.filter { $0.id == id } } ?? []
        default:
            []
        }
        guard !matches.isEmpty else {
            throw ControlError.targetNotFound(
                target.stringValue,
                hint: all.isEmpty
                    ? "目前沒有偵測到任何顯示器"
                    : "目前的顯示器：" + all.map(\.name).joined(separator: "、")
            )
        }
        return matches
    }

    private func resolveDevices(_ target: ControlTarget) throws(ControlError) -> [AudioDeviceModel] {
        let all = audioManager.devices
        let matches: [AudioDeviceModel] = switch target {
        case .allDevices:
            all
        case let .device(name):
            all.filter { Self.matchesExactly($0.name, name) }
        case let .deviceLike(text):
            all.filter { Self.contains($0.name, text) }
        case let .deviceUID(uid):
            all.filter { $0.uid == uid }
        case .defaultOutput:
            audioManager.defaultDevice.map { [$0] } ?? []
        default:
            []
        }
        guard !matches.isEmpty else {
            throw ControlError.targetNotFound(
                target.stringValue,
                hint: all.isEmpty
                    ? "目前沒有偵測到任何音訊輸出裝置"
                    : "目前的輸出裝置：" + all.map(\.name).joined(separator: "、")
            )
        }
        return matches
    }

    /// 名稱比對一律忽略大小寫、變音符號與全半形——使用者與 LLM 打進來的
    /// 「dell」要能對上「DELL U2720Q」，全形「ＤＥＬＬ」也要能對上。
    private static let nameOptions: String.CompareOptions =
        [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]

    private static func contains(_ name: String, _ needle: String) -> Bool {
        name.range(of: needle, options: nameOptions) != nil
    }

    private static func matchesExactly(_ name: String, _ other: String) -> Bool {
        name.compare(other, options: nameOptions) == .orderedSame
    }

    private static func displayID(of screen: NSScreen?) -> CGDirectDisplayID? {
        guard let number = screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        else { return nil }
        return number.uint32Value
    }

    private static func screenID(containing point: NSPoint) -> CGDirectDisplayID? {
        displayID(of: NSScreen.screens.first { $0.frame.contains(point) })
    }

    // MARK: - 值

    /// 把 absolute／offset 解成最終的絕對值並夾在範圍內。
    private func resolved(
        _ value: ControlValue?,
        current: Double,
        range: ClosedRange<Double>
    ) throws(ControlError) -> Double {
        let raw: Double = switch value {
        case let .absolute(number): number
        case let .offset(delta): current + delta
        default: throw ControlError.badValue("\(value.map(String.init(describing:)) ?? "nil")",
                                             hint: "這個屬性需要數值或相對增減")
        }
        return min(max(raw, range.lowerBound), range.upperBound)
    }

    private func boolean(_ value: ControlValue?, property: ControlProperty) throws(ControlError) -> Bool {
        guard case let .boolean(flag)? = value else {
            throw ControlError.missingValue(property)
        }
        return flag
    }

    private func result(_ target: String, _ property: ControlProperty, _ value: ControlJSONValue) -> ControlResult {
        ControlResult(target: target, property: property.rawValue, value: value)
    }
}

// MARK: - 跨機轉發

extension AutomationExecutor {
    /// 帶 `peer` 的請求整包轉發到那台機器，**本機不動作**。
    ///
    /// 走既有的 command 通道（`ControlKey` ＋ Double），因此只支援能對應到
    /// 語意層或 UUID 定位的組合。名稱定位（`displayLike:DELL`）需要對方
    /// 幫我們解析，那要新增一個協定訊息——留到 B4-4（MCP 的 `list_devices`
    /// 本來就需要遠端列舉，一起做比較划算）。這裡誠實回 unsupported＋hint，
    /// 不假裝支援後靜靜失敗。
    ///
    /// MCP 的招牌情境「把客廳那台的螢幕關掉」＝ `peer:客廳` ＋ `allDisplays`
    /// ＋ `power off`，正好落在支援範圍內。
    func forward(
        _ request: ValidatedControlRequest,
        toPeerNamed name: String
    ) throws(ControlError) -> ControlResponse {
        let peerID = try resolvePeer(name)
        guard request.verb == .set else {
            throw ControlError.unsupported(
                "跨機目前只支援 set（\(request.verb.rawValue) 需要遠端回讀，留到 B4-4）"
            )
        }
        guard let property = request.property else {
            throw ControlError.missingProperty(.set)
        }
        let key = try remoteKey(property: property, target: request.target)
        let value = try remoteValue(request.value, property: property)
        coordinator.sendRemoteCommand(to: peerID, key: key, value: value)
        return .success([ControlResult(
            target: "peer:\(name)",
            property: property.rawValue,
            value: .number(value)
        )])
    }

    private func resolvePeer(_ name: String) throws(ControlError) -> String {
        let peers = pairedPeers.peers
        guard let peer = peers.first(where: { Self.matchesPeer($0.deviceName, name) }) else {
            throw ControlError.peerNotFound(
                name,
                hint: peers.isEmpty
                    ? "尚未配對任何裝置"
                    : "已配對：" + peers.map(\.deviceName).joined(separator: "、")
            )
        }
        guard sessionManager.connectionStates[peer.peerID] == .connected else {
            throw ControlError.peerOffline(peer.deviceName)
        }
        return peer.peerID
    }

    private static func matchesPeer(_ deviceName: String, _ needle: String) -> Bool {
        deviceName.range(
            of: needle,
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]
        ) != nil
    }

    private func remoteKey(
        property: ControlProperty,
        target: ControlTarget
    ) throws(ControlError) -> ControlKey {
        switch (property, target) {
        case (.brightness, .allDisplays): .brightness(displayUUID: nil)
        case let (.brightness, .displayUUID(uuid)): .brightness(displayUUID: uuid)
        case (.power, .allDisplays): .displayPower(displayUUID: nil)
        case let (.power, .displayUUID(uuid)): .displayPower(displayUUID: uuid)
        case let (.input, .displayUUID(uuid)): .input(displayUUID: uuid)
        case let (.contrast, .displayUUID(uuid)): .contrast(displayUUID: uuid)
        case (.volume, .defaultOutput): .volume(deviceUID: nil)
        case let (.volume, .deviceUID(uid)): .volume(deviceUID: uid)
        case (.mute, .defaultOutput): .mute(deviceUID: nil)
        case let (.mute, .deviceUID(uid)): .mute(deviceUID: uid)
        case (.keepAwake, .system): .keepAwake(displayUUID: nil)
        // per-app 是遙控不是鏡射：走 command 通道、不進 LWW 收斂
        case let (.volume, .app(bundleID)): .appVolume(bundleID: bundleID)
        case let (.mute, .app(bundleID)): .appMute(bundleID: bundleID)
        default:
            throw ControlError.unsupported(
                "跨機的「\(property.rawValue)」不支援「\(target.stringValue)」這種定位。"
                    + "可用組合：allDisplays／displayUUID:<uuid> 配 brightness・power・input・contrast，"
                    + "defaultOutput／deviceUID:<uid> 配 volume・mute，app:<bundle id> 配 volume・mute，"
                    + "system 配 keepAwake"
            )
        }
    }

    private func remoteValue(
        _ value: ControlValue?,
        property: ControlProperty
    ) throws(ControlError) -> Double {
        switch value {
        case let .absolute(number): return number
        case let .boolean(flag): return flag ? 1 : 0
        case let .duration(seconds): return seconds
        case let .rawCode(code): return Double(code)
        case .offset:
            // 相對增減要先知道對方的現值。peerKnownControls 只涵蓋語意層
            // 亮度／音量，覆蓋不全且可能過時——寧可誠實拒絕，也不要算錯後
            // 把對方的螢幕調到意料之外的亮度。
            throw ControlError.unsupported(
                "跨機不支援相對增減（+10% 這種寫法）；請給絕對值"
            )
        case nil:
            throw ControlError.missingValue(property)
        }
    }
}

// MARK: - 限時場景的快照與還原（B7-1）

extension AutomationExecutor: FocusExecuting {
    /// 套用場景前，把它**會動到的每一個值**的現況擷取成一份快照。
    ///
    /// 與 `captureCurrentScene` 的差別：那個擷取的是「畫面與聲音現在長什麼樣」
    /// （固定的一組屬性），這個擷取的是「**這個場景會碰到什麼**」——涵蓋範圍
    /// 由場景內容決定。理由見 `FocusSnapshot` 的註解。
    ///
    /// 讀現值一律走 `execute(get)`，也就是與套用**完全同一條路**。這讓
    /// 「不可還原」自動浮現而不必特判：`input` 的 `allowedVerbs` 沒有 `get`，
    /// 送進去就回 `verbNotAllowed`，我們照實記進 `unrestorable`。
    func snapshot(forScene scene: ControlScene) -> FocusSnapshot {
        var requests: [ControlRequest] = []
        var unrestorable: [String] = []
        var keepAwakeMode: KeepAwakeMode?
        var keepAwakeRemaining: Double?

        for request in scene.requests {
            // 場景內不執行 perform（runScene 已擋），快照也不看它
            guard request.verb == .set || request.verb == .toggle,
                  let property = request.property
            else { continue }

            // 跨機項目（B7-4）：`forward` 只支援 set、沒有遠端 get，所以原值
            // 來自對方主動回報的 `stateReport`（start 之前已經問過一輪）。
            // 問不到就誠實說它不會自己回來，不假裝還原得了。
            if let peer = request.peer {
                guard let value = peerSnapshotValue(
                    property: property, target: request.target, peerName: peer
                ) else {
                    unrestorable.append("\(peer)：\(property.rawValue)（原值未知）")
                    continue
                }
                requests.append(ControlRequest(
                    verb: .set, target: request.target, property: property,
                    value: value, peer: peer
                ))
                continue
            }

            // 防睡眠是唯一不走 request 的一條，理由見 FocusSnapshot.keepAwake
            if property == .keepAwake {
                if keepAwakeMode == nil {
                    keepAwakeMode = keepAwake.mode
                    keepAwakeRemaining = keepAwake.remainingSeconds
                }
                continue
            }

            for entity in snapshotEntities(request.target) {
                guard let value = snapshotValue(property, target: entity.target) else {
                    unrestorable.append("\(entity.name) 的 \(property.rawValue)")
                    continue
                }
                requests.append(ControlRequest(
                    verb: .set, target: entity.target, property: property, value: value
                ))
            }
        }

        return FocusSnapshot(
            requests: FocusPlanner.deduplicated(requests),
            keepAwake: keepAwakeMode,
            keepAwakeRemainingSeconds: keepAwakeRemaining,
            unrestorable: unrestorable
        )
    }

    /// 套用具名場景。走 `perform runScene` 這條**公開**路徑，不另開後門——
    /// 限時場景與一般場景套用的是同一段程式碼，逐條獨立、一條失敗不放棄其餘。
    func applyScene(named name: String) -> [ControlResult] {
        let response = execute(ControlRequest(
            verb: .perform, target: .system, value: name, action: .runScene
        ))
        if let results = response.results { return results }
        return [ControlResult(
            target: name, property: "error",
            value: .string(response.error?.message ?? "場景套用失敗")
        )]
    }

    /// 把快照放回去。同樣逐條獨立——某台螢幕這 25 分鐘內被拔掉了，
    /// 不該讓其餘項目跟著不還原。
    ///
    /// `retryable` 是**對方離線**的跨機項目：那不是壞掉，只是現在送不到。
    /// 其餘失敗（裝置不在、沒配對）重試也不會變好，不進這個清單。
    func restore(_ snapshot: FocusSnapshot) -> (restored: Int, failed: [String], retryable: [ControlRequest]) {
        var restored = 0
        var failed: [String] = []
        var retryable: [ControlRequest] = []
        for request in FocusPlanner.restoreRequests(snapshot) {
            let response = execute(request)
            if response.ok {
                restored += 1
            } else {
                let label = request.peer.map { "\($0)（跨機）" } ?? request.target.stringValue
                failed.append("\(label)：\(response.error?.message ?? "未知錯誤")")
                if response.error?.code == ControlError.peerOffline("").code {
                    retryable.append(request)
                }
            }
        }
        if let mode = snapshot.keepAwake {
            restoreKeepAwake(mode: mode, remaining: snapshot.keepAwakeRemainingSeconds)
            restored += 1
        }
        return (restored, failed, retryable)
    }

    /// 補送一批先前因為對方離線而沒送出去的還原請求（B7-4）。
    /// 回傳仍然失敗的那些——對方剛連上又斷了的話還會留在清單裡。
    func retry(_ requests: [ControlRequest]) -> (restored: Int, stillFailing: [ControlRequest]) {
        var restored = 0
        var stillFailing: [ControlRequest] = []
        for request in requests {
            if execute(request).ok {
                restored += 1
            } else {
                stillFailing.append(request)
            }
        }
        return (restored, stillFailing)
    }

    /// 場景裡涉及的每台 peer 都問一次現值，等回報回來。
    ///
    /// **上限 1 秒**：既有的 200ms 回報合併 ＋ 一趟區網 RTT 綽綽有餘。等不到
    /// 就用手上已知的值（可能過期），再不然就是 `unrestorable`——寧可慢一秒
    /// 也不要拿三天前的音量當「原值」放回去。
    func refreshPeerState(forScene scene: ControlScene) async {
        let peerNames = Set(scene.requests.compactMap(\.peer))
        guard !peerNames.isEmpty else { return }
        var asked = false
        for name in peerNames {
            guard let peerID = try? resolvePeer(name) else { continue }
            coordinator.requestPeerState(from: peerID)
            asked = true
        }
        guard asked else { return }
        try? await Task.sleep(for: .seconds(1))
    }

    /// peer 的原值。來源是對方主動回報並記在 `peerKnownControls` 的那一份。
    private func peerSnapshotValue(
        property: ControlProperty,
        target: ControlTarget,
        peerName: String
    ) -> String? {
        guard let peerID = try? resolvePeer(peerName),
              let known = settings.peerKnownControls[peerID], !known.isEmpty,
              let key = try? remoteKey(property: property, target: target)
        else { return nil }
        if let field = key.peerKnownField, let value = known[field] {
            return property.valueKind == .boolean
                ? (value > 0.5 ? "on" : "off")
                : ControlValue.snapshotString(value)
        }
        // 對方有回報過（表非空）卻沒有這個 App 的欄位＝那個 App 在對方那裡
        // **沒有被調整過**，也就是預設值。`AppAudioSettings` 對未知 bundle
        // 回的正是 gain 1／不靜音，所以這不是猜，是同一條語意。
        switch key {
        case .appVolume: return ControlValue.snapshotString(1)
        case .appMute: return "off"
        default: return nil
        }
    }

    /// 防睡眠的還原。`.duration` 以**剩餘秒數**重新起算：存的是原始秒數，
    /// 照著 activate 會把一個早該結束的長亮重新開滿 30 分鐘。
    /// 剩餘已歸零就是關掉——那正是它在快照當下的下一秒會走到的狀態。
    private func restoreKeepAwake(mode: KeepAwakeMode, remaining: Double?) {
        if case .duration = mode {
            guard let remaining, remaining > 0 else { return keepAwake.activate(.off) }
            return keepAwake.activate(.duration(seconds: remaining))
        }
        keepAwake.activate(mode)
    }

    /// 把目標展開成**實體定位**（UUID／UID／bundle id）。
    ///
    /// 快照不能存 `allDisplays` 或 `displayWithMouse` 這種意圖：25 分鐘後
    /// 滑鼠早就在別台螢幕上了，還原會寫到錯的地方。名稱只拿來寫給人看的
    /// 「哪一項不可還原」，定位一律用穩定識別碼。
    private func snapshotEntities(_ target: ControlTarget) -> [(target: ControlTarget, name: String)] {
        switch target.kind {
        case .display:
            ((try? resolveDisplays(target)) ?? []).map { (.displayUUID($0.uuid), $0.name) }
        case .audioDevice:
            ((try? resolveDevices(target)) ?? []).map { (.deviceUID($0.uid), $0.name) }
        case .app:
            ((try? resolveApps(target)) ?? []).map {
                (.app(bundleID: $0), tapEngine.registry.displayName(bundleID: $0))
            }
        case .system:
            [(.system, "system")]
        }
    }

    /// 讀一個實體的現值，寫成**還原時解得回同一個數**的值字串。
    ///
    /// 數值的寫法由 `ControlValue.snapshotString` 決定——那裡有收值規則
    /// 逼出來的兩條路（|值| > 1 必須寫成百分比，否則 per-app 增益 2.0
    /// 會被讀回 0.02）。
    private func snapshotValue(_ property: ControlProperty, target: ControlTarget) -> String? {
        let response = execute(ControlRequest(verb: .get, target: target, property: property))
        guard let value = response.results?.first?.value else { return nil }
        switch value {
        case let .number(number): return ControlValue.snapshotString(number)
        case let .bool(flag): return flag ? "on" : "off"
        case let .string(text): return text
        case .null: return nil
        }
    }
}
