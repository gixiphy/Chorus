import ChorusCore
import Foundation
import Network
import Synchronization

/// 自動化 HTTP 介面的連線層，**全部在自己的背景 queue 上**：接受、讀取、解析、
/// 驗證、限額、期限、事件流。只有真的要碰 App 狀態的路由（state／scenes／command）
/// 才切到主執行緒，而且那一段也有期限。
///
/// 為什麼要分出來：主執行緒卡住時，舊版連 401 都回不了，連線與事件流全部堆在
/// 主執行緒上。現在主執行緒卡住只影響那三個路由（回 504、額度照占），
/// `/v1/health` 仍然回得出來，而且回的是真話——主迴圈探針卡著就是 `responsive: false`。
///
/// 安全界線與 `ControlHTTPServer` 開頭的說明相同（loopback、Bearer、Host 檢查、大小上限），
/// 這裡只是換了執行緒。
final class AutomationHTTPTransport: @unchecked Sendable {
    struct Response: Sendable {
        let status: Int
        let json: String
    }

    struct Handlers: Sendable {
        let state: @Sendable () async -> Response
        let scenes: @Sendable () async -> Response
        /// `isBatch`：請求 body 是陣列（回應也要是陣列）。
        let execute: @Sendable (_ requests: [ControlRequest], _ isBatch: Bool) async -> Response
        /// 第一個事件流開啟（true）／最後一個關閉（false）。沒有訂閱者時不必編碼事件。
        let eventStreamsActive: @Sendable (Bool) -> Void
    }

    /// 從接受連線到請求讀完的絕對期限——慢慢送一點資料不能無限續命。
    static let requestDeadline: Duration = .seconds(10)
    /// 主執行緒路由的期限。逾時回 504，結果未知；指令額度等真的執行完才釋放。
    static let mainThreadDeadline: Duration = .seconds(10)
    static let heartbeatInterval: Duration = .seconds(15)
    static let maxHeaderBytes = 16 * 1024
    static let maxBodyBytes = 256 * 1024

    private enum Phase {
        case reading
        case responding
        case streaming
    }

    private struct Connection {
        let connection: NWConnection
        var phase: Phase = .reading
        var backlog: EventStreamBacklog?
    }

    private let queue = DispatchQueue(label: "com.hermes.Chorus.http", qos: .userInitiated)
    private let handlers: Handlers
    private let token: Mutex<String>
    private static let log = ChorusLog(category: "automation")

    // 以下只在 queue 上讀寫
    private var listener: NWListener?
    private var admission: AutomationAdmission
    private var connections: [ObjectIdentifier: Connection] = [:]
    private var heartbeat: DispatchSourceTimer?

    init(token: String, handlers: Handlers, limits: AutomationAdmission.Limits = .init()) {
        self.token = Mutex(token)
        self.handlers = handlers
        admission = AutomationAdmission(limits: limits)
    }

    /// 建立並啟動 listener。狀態變化在 queue 上回報。
    func start(port: NWEndpoint.Port, onState: @escaping @Sendable (NWListener.State) -> Void) throws {
        let parameters = NWParameters.tcp
        // 只在回送介面上聽——這是整個 HTTP 介面的安全前提
        parameters.requiredInterfaceType = .loopback
        parameters.allowLocalEndpointReuse = true
        let created = try NWListener(using: parameters, on: port)
        created.stateUpdateHandler = onState
        created.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        queue.async { [self] in
            listener = created
            created.start(queue: queue)
        }
    }

    func stop() {
        queue.async { [self] in
            listener?.cancel()
            listener = nil
            for entry in connections.values {
                entry.connection.cancel()
            }
            heartbeat?.cancel()
            heartbeat = nil
        }
    }

    func updateToken(_ value: String) {
        token.withLock { $0 = value }
    }

    /// 推一則事件給所有事件流訂閱者。
    func publish(_ json: String) {
        queue.async { [self] in
            for (id, entry) in connections where entry.phase == .streaming {
                sendEvent(id, text: "data: \(json)\n\n")
            }
        }
    }

    // MARK: - 連線（queue 上）

    private func accept(_ connection: NWConnection) {
        guard admission.admitConnection() else {
            // 連線數滿了：不讀任何資料，直接回 503
            connection.start(queue: queue)
            Self.sendAndClose(connection, status: 503, json: Self.errorJSON("overloaded", "連線數已達上限"))
            return
        }
        let id = ObjectIdentifier(connection)
        connections[id] = Connection(connection: connection)
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .cancelled, .failed:
                self?.cleanup(id)
            default:
                break
            }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + Self.requestDeadline.millis / 1_000) { [weak self] in
            guard let self, connections[id]?.phase == .reading else { return }
            respond(id, status: 408, json: Self.errorJSON("requestTimeout", "請求沒有在期限內送完"))
        }
        receive(id, buffer: Data())
    }

    private func cleanup(_ id: ObjectIdentifier) {
        guard let entry = connections.removeValue(forKey: id) else { return }
        admission.releaseConnection()
        guard entry.phase == .streaming else { return }
        admission.releaseEventStream()
        if admission.eventStreams == 0 {
            heartbeat?.cancel()
            heartbeat = nil
            handlers.eventStreamsActive(false)
        }
    }

    private func receive(_ id: ObjectIdentifier, buffer: Data) {
        guard let connection = connections[id]?.connection else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] chunk, _, isComplete, error in
            guard let self, connections[id]?.phase == .reading else { return }
            guard error == nil else {
                connection.cancel()
                return
            }
            var accumulated = buffer
            if let chunk { accumulated.append(chunk) }
            if accumulated.count > Self.maxHeaderBytes + Self.maxBodyBytes {
                respond(id, status: 413, json: Self.errorJSON("tooLarge", "請求過大"))
                return
            }
            switch HTTPRequestParser.parse(accumulated) {
            case .incomplete:
                if isComplete {
                    connection.cancel()
                } else {
                    receive(id, buffer: accumulated)
                }
            case let .malformed(reason):
                respond(id, status: 400, json: Self.errorJSON("badRequest", reason))
            case let .complete(request):
                connections[id]?.phase = .responding
                handle(id, request)
            }
        }
    }

    private func handle(_ id: ObjectIdentifier, _ request: HTTPRequestParser.Request) {
        // DNS rebinding 防線：只接受指向本機的 Host
        guard Self.isLocalHost(request.headers["host"]) else {
            respond(id, status: 403, json: Self.errorJSON("badHost", "Host 標頭不是本機位址"))
            return
        }
        guard let provided = Self.bearerToken(request.headers["authorization"]),
              Self.constantTimeEquals(provided, token.withLock { $0 })
        else {
            respond(id, status: 401, json: Self.errorJSON("unauthorized", "缺少或錯誤的 Bearer token"))
            return
        }

        switch (request.method, request.path) {
        case ("GET", "/v1/health"):
            respond(id, status: 200, json: Self.healthJSON())
        case ("GET", "/v1/state"):
            callMainThread(id) { [handlers] in await handlers.state() }
        case ("GET", "/v1/scenes"):
            callMainThread(id) { [handlers] in await handlers.scenes() }
        case ("POST", "/v1/command"):
            handleCommand(id, body: request.body)
        case ("GET", "/v1/events"):
            startEventStream(id)
        default:
            respond(id, status: 404, json: Self.errorJSON(
                "notFound",
                "可用端點：POST /v1/command、GET /v1/state、GET /v1/scenes、GET /v1/events、GET /v1/health"
            ))
        }
    }

    private func handleCommand(_ id: ObjectIdentifier, body: Data) {
        let decoder = JSONDecoder()
        let requests: [ControlRequest]
        let isBatch: Bool
        // 單筆或陣列都收——場景與批次操作要能一次送完
        if let batch = try? decoder.decode([ControlRequest].self, from: body) {
            requests = batch
            isBatch = true
        } else {
            do {
                requests = [try decoder.decode(ControlRequest.self, from: body)]
                isBatch = false
            } catch {
                respond(id, status: 400, json: Self.errorJSON(
                    "badRequest", "無法解析的請求：\(error.localizedDescription)"
                ))
                return
            }
        }
        switch admission.admitCommands(requests.count) {
        case let .batchTooLarge(limit):
            respond(id, status: 413, json: Self.errorJSON("tooManyCommands", "一次最多 \(limit) 筆指令"))
        case .overloaded:
            respond(id, status: 503, json: Self.errorJSON("overloaded", "待處理的指令太多，稍後再試"))
        case nil:
            let count = requests.count
            callMainThread(id, releasingCommands: count) { [handlers] in
                await handlers.execute(requests, isBatch)
            }
        }
    }

    /// 切到主執行緒做事，期限內沒回來就先回 504。指令額度等工作真的結束才還。
    private func callMainThread(
        _ id: ObjectIdentifier,
        releasingCommands commands: Int = 0,
        _ work: @escaping @Sendable () async -> Response
    ) {
        let gate = AnswerGate()
        let queue = queue
        Task { [weak self] in
            let response = await work()
            queue.async { [weak self] in
                guard let self else { return }
                if commands > 0 { self.admission.releaseCommands(commands) }
                if gate.claim() { self.respond(id, status: response.status, json: response.json) }
            }
        }
        queue.asyncAfter(deadline: .now() + Self.mainThreadDeadline.millis / 1_000) { [weak self] in
            guard let self, gate.claim() else { return }
            Self.log.notice("自動化請求在主執行緒上逾時，回 504")
            self.respond(id, status: 504, json: Self.errorJSON(
                "timeout", "沒有在期限內完成；指令可能仍會執行，結果未知"
            ))
        }
    }

    private func respond(_ id: ObjectIdentifier, status: Int, json: String) {
        guard let connection = connections[id]?.connection else { return }
        connections[id]?.phase = .responding
        Self.sendAndClose(connection, status: status, json: json)
    }

    private static func sendAndClose(_ connection: NWConnection, status: Int, json: String) {
        let body = Data(json.utf8)
        let head = """
        HTTP/1.1 \(status) \(reason(status))\r
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

    // MARK: - 事件流（queue 上）

    private func startEventStream(_ id: ObjectIdentifier) {
        guard let connection = connections[id]?.connection else { return }
        guard admission.admitEventStream() else {
            respond(id, status: 503, json: Self.errorJSON("overloaded", "事件流數已達上限"))
            return
        }
        connections[id]?.phase = .streaming
        connections[id]?.backlog = EventStreamBacklog()
        let head = """
        HTTP/1.1 200 OK\r
        Content-Type: text/event-stream\r
        Cache-Control: no-cache\r
        Connection: keep-alive\r
        \r

        """
        connection.send(content: Data(head.utf8), completion: .contentProcessed { _ in })
        watchForEOF(id)
        if admission.eventStreams == 1 {
            startHeartbeat()
            handlers.eventStreamsActive(true)
        }
    }

    /// 對方正常關閉（FIN）也要收掉訂閱，不能只等 `.failed`／`.cancelled`。
    private func watchForEOF(_ id: ObjectIdentifier) {
        guard let connection = connections[id]?.connection else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1024) { [weak self] _, _, isComplete, error in
            guard let self, connections[id] != nil else { return }
            if isComplete || error != nil {
                connection.cancel()
            } else {
                watchForEOF(id)
            }
        }
    }

    private func sendEvent(_ id: ObjectIdentifier, text: String) {
        guard let connection = connections[id]?.connection,
              var backlog = connections[id]?.backlog
        else { return }
        let data = Data(text.utf8)
        guard backlog.reserve(bytes: data.count) else {
            Self.log.notice("事件流訂閱者讀得太慢（待送 \(backlog.events) 則），斷線")
            connection.cancel()
            return
        }
        connections[id]?.backlog = backlog
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            self?.connections[id]?.backlog?.complete(bytes: data.count)
            if error != nil { connection.cancel() }
        })
    }

    private func startHeartbeat() {
        guard heartbeat == nil else { return }
        let seconds = Self.heartbeatInterval.millis / 1_000
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + seconds, repeating: seconds)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            for (id, entry) in connections where entry.phase == .streaming {
                sendEvent(id, text: ": ping\n\n")
            }
        }
        timer.resume()
        heartbeat = timer
    }

    // MARK: - 健康狀態

    /// 背景組出的健康快照，不經主執行緒。`responsive` 看的是主迴圈探針：
    /// 主執行緒正卡著時這裡照樣回得出來，而且說的是 false。
    static func healthJSON() -> String {
        let watchdog = MainLoopWatchdog.shared
        let loop = watchdog.snapshot()
        let metrics = OperationMetrics.shared.snapshot()
        let pendingAge = loop.pendingAge
        let responsive = loop.running && (pendingAge ?? .zero) < watchdog.configuration.thresholds.hang
        func upper(_ histogram: LatencyHistogram) -> Any {
            histogram.percentile(0.95).map { $0 as Any } ?? NSNull()
        }
        let operations = Dictionary(uniqueKeysWithValues: metrics.operations.map { name, stats in
            (name, [
                "inFlight": stats.inFlight,
                "oldestInFlightMs": metrics.oldestInFlight[name].map { $0.millis as Any } ?? NSNull(),
                "completed": stats.completed,
                "failures": stats.completed - (stats.outcomes[.success] ?? 0),
                "p95UpperMs": upper(stats.latency),
                "maxMs": stats.latency.maxMillis,
            ] as [String: Any])
        })
        let crashes = CrashReportCollector.shared.snapshot()
        let iso = ISO8601DateFormatter()
        let recentCrashes: [[String: Any]] = crashes.recent.map { summary in
            [
                "kind": summary.kind.rawValue,
                "occurredAt": iso.string(from: summary.occurredAt),
                "appVersion": summary.appVersion.map { $0 as Any } ?? NSNull(),
                "exception": summary.exception.map { $0 as Any } ?? NSNull(),
                "topFrames": summary.topFrames,
                "file": summary.fileName,
            ]
        }
        let payload: [String: Any] = [
            "ok": true,
            "generatedAt": ISO8601DateFormatter().string(from: Date()),
            "mainLoop": [
                "responsive": responsive,
                "running": loop.running,
                "pendingProbeMs": pendingAge.map { $0.millis as Any } ?? NSNull(),
                "lagCount": loop.lifetime.lagCount,
                "hangCount": loop.lifetime.hangCount,
                "longestStallMs": loop.lifetime.longestStall.millis,
                "p95UpperMs": upper(loop.lifetime.latency),
            ] as [String: Any],
            "memoryPressure": MemoryPressureMonitor.name(MemoryPressureMonitor.shared.level),
            "lastExit": crashes.lastExit?.rawValue ?? "unknown",
            "crashReports": ["count": crashes.count, "recent": recentCrashes] as [String: Any],
            "operations": operations,
            "gauges": metrics.gauges.mapValues { ["current": $0.current, "highWater": $0.highWater] },
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) else {
            return #"{"ok":false}"#
        }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - 小工具

    /// 正常回應與逾時兩條路只有先到的那條能回。
    private final class AnswerGate: Sendable {
        private let answered = Atomic(false)

        func claim() -> Bool {
            answered.compareExchange(expected: false, desired: true, ordering: .sequentiallyConsistent).exchanged
        }
    }

    private static func reason(_ status: Int) -> String {
        switch status {
        case 200: "OK"
        case 400: "Bad Request"
        case 401: "Unauthorized"
        case 403: "Forbidden"
        case 404: "Not Found"
        case 408: "Request Timeout"
        case 413: "Payload Too Large"
        case 503: "Service Unavailable"
        case 504: "Gateway Timeout"
        default: "Error"
        }
    }

    static func errorJSON(_ code: String, _ message: String) -> String {
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
