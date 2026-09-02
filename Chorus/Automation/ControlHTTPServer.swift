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
    @ObservationIgnored private var listener: NWListener?
    @ObservationIgnored private var eventConnections: [ObjectIdentifier: (NWConnection, UUID)] = [:]

    private static let tokenAccount = "automation-token"
    /// CLI 讀 token 的位置。權限 600——內容等同介面的鑰匙。
    private static var configURL: URL {
        URL(fileURLWithPath: NSString(string: "~/.config/chorus/config.json").expandingTildeInPath)
    }
    /// 標頭區上限 16 KB、body 上限 256 KB——自動化請求都是小 JSON，
    /// 給到這個量已經很寬鬆，再多就是有人在灌。
    private static let maxHeaderBytes = 16 * 1024
    private static let maxBodyBytes = 256 * 1024

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
        guard listener == nil else { return }
        lastError = nil
        currentToken() // 開啟即確保 token 存在
        guard let port = NWEndpoint.Port(rawValue: settings.automationServerPort) else {
            lastError = "無效的 port"
            return
        }
        let parameters = NWParameters.tcp
        // 只在回送介面上聽——這是整個 HTTP 介面的安全前提
        parameters.requiredInterfaceType = .loopback
        parameters.allowLocalEndpointReuse = true
        do {
            let created = try NWListener(using: parameters, on: port)
            created.stateUpdateHandler = { state in
                Task { @MainActor [weak self] in self?.handleListenerState(state) }
            }
            created.newConnectionHandler = { connection in
                Task { @MainActor [weak self] in self?.accept(connection) }
            }
            created.start(queue: .main)
            listener = created
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
        for (connection, token) in eventConnections.values {
            events.unsubscribe(token)
            connection.cancel()
        }
        eventConnections = [:]
        listener?.cancel()
        listener = nil
        isRunning = false
        removeConfigFile()
    }

    private func handleListenerState(_ state: NWListener.State) {
        switch state {
        case .ready:
            isRunning = true
        case let .failed(error):
            lastError = "\(error)"
            isRunning = false
            listener?.cancel()
            listener = nil
        case .cancelled:
            isRunning = false
        default:
            break
        }
    }

    // MARK: - 連線處理

    private func accept(_ connection: NWConnection) {
        connection.start(queue: .main)
        receive(connection, buffer: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { chunk, _, isComplete, error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard error == nil else {
                    self.close(connection)
                    return
                }
                var accumulated = buffer
                if let chunk { accumulated.append(chunk) }
                if accumulated.count > Self.maxHeaderBytes + Self.maxBodyBytes {
                    self.respond(connection, status: 413, json: #"{"ok":false,"error":{"code":"tooLarge","message":"請求過大"}}"#)
                    return
                }
                switch HTTPRequestParser.parse(accumulated) {
                case .incomplete:
                    if isComplete {
                        self.close(connection)
                    } else {
                        self.receive(connection, buffer: accumulated)
                    }
                case let .malformed(reason):
                    self.respond(connection, status: 400, json: Self.errorJSON("badRequest", reason))
                case let .complete(request):
                    self.handle(request, on: connection)
                }
            }
        }
    }

    private func handle(_ request: HTTPRequestParser.Request, on connection: NWConnection) {
        // DNS rebinding 防線：只接受指向本機的 Host
        guard Self.isLocalHost(request.headers["host"]) else {
            respond(connection, status: 403, json: Self.errorJSON("badHost", "Host 標頭不是本機位址"))
            return
        }
        guard let provided = Self.bearerToken(request.headers["authorization"]),
              Self.constantTimeEquals(provided, currentToken())
        else {
            respond(connection, status: 401, json: Self.errorJSON("unauthorized", "缺少或錯誤的 Bearer token"))
            return
        }

        switch (request.method, request.path) {
        case ("GET", "/v1/state"):
            respondJSON(connection, encodable: executor.execute(
                ControlRequest(verb: .get, target: .allDisplays)
            ).merging(with: [
                executor.execute(ControlRequest(verb: .get, target: .allDevices)),
                // 逐 App 音訊未啟用時這一則會失敗——merging 只收成功的結果，
                // 所以功能沒開的機器拿到的 state 就是少了這一段，不是整包壞掉
                executor.execute(ControlRequest(verb: .get, target: .allApps)),
                executor.execute(ControlRequest(verb: .get, target: .system)),
            ]))

        case ("POST", "/v1/command"):
            handleCommand(request.body, on: connection)

        case ("GET", "/v1/scenes"):
            // 場景清單給 CLI 的 `chorus scenes`；內容一併回，
            // 呼叫端想看某個場景到底會做什麼不必再問一次。
            respondJSON(connection, encodable: scenes.scenes)

        case ("GET", "/v1/events"):
            startEventStream(on: connection)

        default:
            respond(connection, status: 404, json: Self.errorJSON(
                "notFound",
                "可用端點：POST /v1/command、GET /v1/state、GET /v1/scenes、GET /v1/events"
            ))
        }
    }

    private func handleCommand(_ body: Data, on connection: NWConnection) {
        let decoder = JSONDecoder()
        // 單筆或陣列都收——場景與批次操作要能一次送完
        if let requests = try? decoder.decode([ControlRequest].self, from: body) {
            // executeAsync：限時場景要先把 peer 現值問回來，其餘請求原樣同步
            Task { @MainActor in
                var responses: [ControlResponse] = []
                for request in requests {
                    responses.append(await executor.executeAsync(request))
                }
                respondJSON(connection, encodable: responses)
            }
            return
        }
        do {
            let request = try decoder.decode(ControlRequest.self, from: body)
            Task { @MainActor in
                respondJSON(connection, encodable: await executor.executeAsync(request))
            }
        } catch {
            respond(connection, status: 400, json: Self.errorJSON(
                "badRequest",
                "無法解析的請求：\(error.localizedDescription)"
            ))
        }
    }

    // MARK: - SSE

    private func startEventStream(on connection: NWConnection) {
        let head = """
        HTTP/1.1 200 OK\r
        Content-Type: text/event-stream\r
        Cache-Control: no-cache\r
        Connection: keep-alive\r
        \r

        """
        connection.send(content: Data(head.utf8), completion: .contentProcessed { _ in })
        let token = events.subscribe { [weak self] json in
            guard let self else { return }
            self.sendEvent(json, on: connection)
        }
        eventConnections[ObjectIdentifier(connection)] = (connection, token)
        // 對端關閉時要收掉訂閱，否則會一直對死連線寫入
        connection.stateUpdateHandler = { state in
            Task { @MainActor [weak self] in
                switch state {
                case .cancelled, .failed:
                    self?.closeEventStream(connection)
                default:
                    break
                }
            }
        }
    }

    private func sendEvent(_ json: String, on connection: NWConnection) {
        connection.send(content: Data("data: \(json)\n\n".utf8), completion: .contentProcessed { error in
            guard error != nil else { return }
            Task { @MainActor [weak self] in self?.closeEventStream(connection) }
        })
    }

    private func closeEventStream(_ connection: NWConnection) {
        guard let (_, token) = eventConnections.removeValue(forKey: ObjectIdentifier(connection)) else { return }
        events.unsubscribe(token)
        connection.cancel()
    }

    // MARK: - 回應

    private func respondJSON(_ connection: NWConnection, encodable: some Encodable) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        let data = (try? encoder.encode(encodable)) ?? Data("{}".utf8)
        respond(connection, status: 200, json: String(decoding: data, as: UTF8.self))
    }

    private func respond(_ connection: NWConnection, status: Int, json: String) {
        let body = Data(json.utf8)
        let head = """
        HTTP/1.1 \(status) \(Self.reason(status))\r
        Content-Type: application/json; charset=utf-8\r
        Content-Length: \(body.count)\r
        Connection: close\r
        \r

        """
        var payload = Data(head.utf8)
        payload.append(body)
        connection.send(content: payload, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func close(_ connection: NWConnection) {
        closeEventStream(connection)
        connection.cancel()
    }

    // MARK: - 小工具

    private static func reason(_ status: Int) -> String {
        switch status {
        case 200: "OK"
        case 400: "Bad Request"
        case 401: "Unauthorized"
        case 403: "Forbidden"
        case 404: "Not Found"
        case 413: "Payload Too Large"
        default: "Error"
        }
    }

    private static func errorJSON(_ code: String, _ message: String) -> String {
        let payload = ["ok": false, "error": ["code": code, "message": message]] as [String: Any]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) else {
            return #"{"ok":false}"#
        }
        return String(decoding: data, as: UTF8.self)
    }

    private static func isLocalHost(_ host: String?) -> Bool {
        guard let host else { return false }
        // 去掉 port
        let name = host.split(separator: ":").first.map(String.init)?.lowercased() ?? ""
        return name == "127.0.0.1" || name == "localhost" || name == "[::1]" || name == "::1"
    }

    private static func bearerToken(_ header: String?) -> String? {
        guard let header else { return nil }
        let parts = header.split(separator: " ", maxSplits: 1)
        guard parts.count == 2, parts[0].lowercased() == "bearer" else { return nil }
        return String(parts[1]).trimmingCharacters(in: .whitespaces)
    }

    /// 定時比對：避免以回應時間逐字元猜出 token。
    private static func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
        let left = Array(lhs.utf8)
        let right = Array(rhs.utf8)
        guard left.count == right.count else { return false }
        var difference: UInt8 = 0
        for index in left.indices {
            difference |= left[index] ^ right[index]
        }
        return difference == 0
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
