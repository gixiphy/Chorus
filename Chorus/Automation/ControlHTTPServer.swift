import ChorusCore
import Foundation
import Network

/// localhost 自動化 HTTP 介面（B4-2）。CLI 與 MCP server 都只是它的外皮。
///
/// **安全界線**（這幾條不可放寬）：
/// - `requiredInterfaceType = .loopback`：只在回送介面上聽，同網段的其他機器
///   連不上。跨機一律走既有的 TLS-PSK mesh——那條路有配對、有 PSK；
///   HTTP 這條沒有，一旦綁 0.0.0.0 就是同網段任何人都能關你的螢幕。
/// - **強制 Bearer token**：這同時是 CSRF 防線。網頁可以對 localhost 發出
///   「簡單請求」而不觸發 preflight，但**不能**在簡單請求裡帶
///   `Authorization` 標頭；一帶就會先送 preflight，而我們不回任何
///   CORS 標頭，瀏覽器就擋下了。
/// - **檢查 Host 標頭**：擋 DNS rebinding（把某個網域解析到 127.0.0.1
///   再從網頁打過來）。
/// - 標頭與 body 都有大小上限，避免單一連線把記憶體吃光。
/// - 連線數、事件流數、批次指令數、待處理指令數都有上限；請求有絕對期限
///   （見 `AutomationHTTPTransport`，連線層在背景 queue 上）。
/// - 預設關閉（PLAN §8-6 的權限功能紀律）。
/// `installCLISymlink` 的結果。
enum CLIInstallOutcome {
    case installed(String)
    /// 目錄不可寫：給出使用者可自行貼進終端機的指令。
    case needsManualCommand(String)
}

@MainActor
@Observable
final class ControlHTTPServer {
    private(set) var isRunning = false
    /// 最近一次啟動失敗的原因（設定頁顯示；例如 port 被佔用）。
    private(set) var lastError: String?

    @ObservationIgnored private let settings: SettingsStore
    @ObservationIgnored private let keychain: KeychainStore
    @ObservationIgnored private unowned let executor: AutomationExecutor
    @ObservationIgnored private unowned let events: AutomationEventHub
    @ObservationIgnored private unowned let scenes: SceneStore
    /// 連線層（背景 queue）。nil ＝ 介面沒開。
    @ObservationIgnored private var transport: AutomationHTTPTransport?
    @ObservationIgnored private var eventSubscription: UUID?

    private static let tokenAccount = "automation-token"
    /// CLI 讀 token 的位置。權限 600——內容等同介面的鑰匙。
    private static var configURL: URL {
        URL(fileURLWithPath: NSString(string: "~/.config/chorus/config.json").expandingTildeInPath)
    }

    init(
        settings: SettingsStore,
        keychain: KeychainStore,
        executor: AutomationExecutor,
        events: AutomationEventHub,
        scenes: SceneStore
    ) {
        self.settings = settings
        self.keychain = keychain
        self.executor = executor
        self.events = events
        self.scenes = scenes
    }

    // MARK: - Token

    /// 目前的 token；沒有就生一個。32 bytes 隨機、存 Keychain。
    @discardableResult
    func currentToken() -> String {
        if let data = keychain.data(forAccount: Self.tokenAccount),
           let token = String(data: data, encoding: .utf8), !token.isEmpty {
            return token
        }
        return regenerateToken()
    }

    @discardableResult
    func regenerateToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let token = Data(bytes).base64EncodedString()
        keychain.set(Data(token.utf8), forAccount: Self.tokenAccount)
        transport?.updateToken(token)
        if isRunning { writeConfigFile() }
        return token
    }

    /// 內嵌的 chorus 執行檔位置（設定頁的「安裝到 /usr/local/bin」用）。
    var bundledCLIPath: String {
        Bundle.main.bundleURL
            .appendingPathComponent("Contents/SharedSupport/chorus")
            .path
    }

    /// 在 /usr/local/bin 建 symlink。多數機器上這個目錄使用者可寫，
    /// 不可寫時**不要求 admin**——回傳失敗讓 UI 顯示可自行執行的指令，
    /// 為了一個方便的捷徑去要密碼並不划算。
    func installCLISymlink() -> CLIInstallOutcome {
        let destination = "/usr/local/bin/chorus"
        let manager = FileManager.default
        do {
            if manager.fileExists(atPath: destination) || isSymlink(destination) {
                try manager.removeItem(atPath: destination)
            }
            try manager.createSymbolicLink(atPath: destination, withDestinationPath: bundledCLIPath)
            return .installed(destination)
        } catch {
            return .needsManualCommand("sudo ln -sf '\(bundledCLIPath)' \(destination)")
        }
    }

    private func isSymlink(_ path: String) -> Bool {
        (try? FileManager.default.destinationOfSymbolicLink(atPath: path)) != nil
    }

    // MARK: - 生命週期

    func updateActivation() {
        if settings.automationServerEnabled {
            start()
        } else {
            stop()
        }
    }

    private func start() {
        guard transport == nil else { return }
        lastError = nil
        let token = currentToken() // 開啟即確保 token 存在
        guard let port = NWEndpoint.Port(rawValue: settings.automationServerPort) else {
            lastError = "無效的 port"
            return
        }
        let handlers = AutomationHTTPTransport.Handlers(
            state: { @MainActor [weak self] in
                self?.stateResponse() ?? Self.unavailable
            },
            scenes: { @MainActor [weak self] in
                self?.scenesResponse() ?? Self.unavailable
            },
            execute: { @MainActor [weak self] requests, isBatch in
                await self?.executeResponse(requests, isBatch: isBatch) ?? Self.unavailable
            },
            eventStreamsActive: { [weak self] active in
                Task { @MainActor in self?.setEventStreamsActive(active) }
            }
        )
        let created = AutomationHTTPTransport(token: token, handlers: handlers)
        do {
            try created.start(port: port) { [weak self] state in
                Task { @MainActor in self?.handleListenerState(state) }
            }
            transport = created
            writeConfigFile()
        } catch {
            lastError = "\(error)"
        }
    }

    /// 寫出 CLI 用的設定檔。**權限 600**：檔案內容就是這個介面的鑰匙，
    /// 同機其他使用者不該讀得到。停用時刪除——留著一把過期的鑰匙沒有意義，
    /// 只會讓人以為介面還開著。
    private func writeConfigFile() {
        let url = Self.configURL
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let payload: [String: Any] = [
                "port": Int(settings.automationServerPort),
                "token": currentToken(),
            ]
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
            try data.write(to: url, options: [.atomic])
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: url.path
            )
        } catch {
            lastError = "無法寫出 CLI 設定檔：\(error.localizedDescription)"
        }
    }

    private func removeConfigFile() {
        try? FileManager.default.removeItem(at: Self.configURL)
    }

    private func stop() {
        setEventStreamsActive(false)
        transport?.stop()
        transport = nil
        isRunning = false
        removeConfigFile()
    }

    private func handleListenerState(_ state: NWListener.State) {
        switch state {
        case .ready:
            isRunning = transport != nil
        case let .failed(error):
            lastError = "\(error)"
            isRunning = false
            transport?.stop()
            transport = nil
        case .cancelled:
            isRunning = false
        default:
            break
        }
    }

    // MARK: - 路由（主執行緒；連線層在 AutomationHTTPTransport）

    private static let unavailable = AutomationHTTPTransport.Response(
        status: 503, json: AutomationHTTPTransport.errorJSON("unavailable", "自動化介面正在關閉")
    )

    private func stateResponse() -> AutomationHTTPTransport.Response {
        jsonResponse(executor.execute(
            ControlRequest(verb: .get, target: .allDisplays)
        ).merging(with: [
            executor.execute(ControlRequest(verb: .get, target: .allDevices)),
            // 逐 App 音訊未啟用時這一則會失敗——merging 只收成功的結果，
            // 所以功能沒開的機器拿到的 state 就是少了這一段，不是整包壞掉
            executor.execute(ControlRequest(verb: .get, target: .allApps)),
            executor.execute(ControlRequest(verb: .get, target: .system)),
        ]))
    }

    /// 場景清單給 CLI 的 `chorus scenes`；內容一併回，
    /// 呼叫端想看某個場景到底會做什麼不必再問一次。
    private func scenesResponse() -> AutomationHTTPTransport.Response {
        jsonResponse(scenes.scenes)
    }

    /// executeAsync：限時場景要先把 peer 現值問回來，其餘請求原樣同步。
    private func executeResponse(_ requests: [ControlRequest], isBatch: Bool) async -> AutomationHTTPTransport.Response {
        var responses: [ControlResponse] = []
        for request in requests {
            responses.append(await executor.executeAsync(request))
        }
        return isBatch ? jsonResponse(responses) : jsonResponse(responses.first ?? .failure(.unsupported("空請求")))
    }

    private func jsonResponse(_ encodable: some Encodable) -> AutomationHTTPTransport.Response {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        let data = (try? encoder.encode(encodable)) ?? Data("{}".utf8)
        return .init(status: 200, json: String(decoding: data, as: UTF8.self))
    }

    /// 有事件流訂閱者時才接上事件來源——沒人聽就不必每次變更都編碼一次 JSON。
    private func setEventStreamsActive(_ active: Bool) {
        if active, eventSubscription == nil, let transport {
            eventSubscription = events.subscribe { [weak transport] json in
                transport?.publish(json)
            }
        } else if !active, let token = eventSubscription {
            events.unsubscribe(token)
            eventSubscription = nil
        }
    }
}

private extension ControlResponse {
    /// `/v1/state` 要把顯示器／音訊／整機三次查詢併成一份。
    func merging(with others: [ControlResponse]) -> ControlResponse {
        var combined = results ?? []
        for other in others {
            combined.append(contentsOf: other.results ?? [])
        }
        return ControlResponse(ok: true, results: combined, error: nil)
    }
}
