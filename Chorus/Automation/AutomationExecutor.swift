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
    private unowned let autoBrightness: AutoBrightnessController
    private unowned let keepAwake: KeepAwakeController
    private unowned let coordinator: ControlCoordinator
    private unowned let pairedPeers: PairedPeersStore
    private unowned let sessionManager: SyncSessionManager
    private unowned let scenes: SceneStore

    init(
        settings: SettingsStore,
        displayManager: DisplayManager,
        audioManager: AudioDeviceManager,
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

    // MARK: - 本機執行

    private func runLocally(_ request: ValidatedControlRequest) throws(ControlError) -> [ControlResult] {
        if request.verb == .perform {
            return try perform(request)
        }
        return switch request.target.kind {
        case .display: try runOnDisplays(request)
        case .audioDevice: try runOnDevices(request)
        case .system: try runOnSystem(request)
        case .app: throw ControlError.unsupported(
            "per-app 音訊控制尚未啟用（M12/B6-6）；目前可用的目標種類：顯示器、音訊裝置、system"
        )
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
            return try runScene(named: request.actionArgument)
        case .suggestOffsets:
            throw ControlError.unsupported("suggestOffsets 尚未接上顧問管線（B4-4）")
        case nil:
            throw ControlError.missingAction
        }
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

        case .volume, .mute, .keepAwake, .autoBrightness:
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

    // MARK: - 整機

    private func runOnSystem(_ request: ValidatedControlRequest) throws(ControlError) -> [ControlResult] {
        guard let property = request.property else {
            return [
                result("system", .keepAwake, .number(KeepAwakePlanner.encode(keepAwake.mode))),
                result("system", .autoBrightness, .bool(settings.autoBrightnessEnabled)),
                result("system", .ambientOffset, .number(settings.ambientDeviceOffset)),
                ControlResult(target: "system", property: "keepAwakeHolding",
                              value: .bool(keepAwake.isHolding)),
            ]
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

        default:
            throw ControlError.targetKindMismatch(property: property, target: "system")
        }
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
        default:
            throw ControlError.unsupported(
                "跨機的「\(property.rawValue)」不支援「\(target.stringValue)」這種定位。"
                    + "可用組合：allDisplays／displayUUID:<uuid> 配 brightness・power・input・contrast，"
                    + "defaultOutput／deviceUID:<uid> 配 volume・mute，system 配 keepAwake"
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
