import ChorusCore
import Foundation

/// `chorus` — 自動化介面的 CLI 外皮（B4-3）。
///
/// **不含任何控制邏輯**：把參數組成 `ControlRequest`、丟給 localhost HTTP
/// 介面、印出回應。動詞層在 ChorusCore、執行在 App，這裡只負責人機介面。
/// 因此 CLI 永遠不會和其他入口的語意漂移。
@main
struct ChorusCLI {
    static func main() async {
        var arguments = Array(CommandLine.arguments.dropFirst())
        let jsonOutput = arguments.removeFlag("--json")

        guard let subcommand = arguments.first else {
            printUsage()
            exit(2)
        }
        arguments.removeFirst()

        do {
            let config = try Config.load()
            switch subcommand {
            case "help", "-h", "--help":
                printUsage()
            case "state":
                let body = try await Client(config: config).get("/v1/state")
                print(body)
            case "scenes":
                let body = try await Client(config: config).get("/v1/scenes")
                if jsonOutput {
                    print(body)
                } else {
                    printScenes(body)
                }
            case "listen":
                try await Client(config: config).listen()
            case "scene":
                // `--end` 提前結束進行中的限時場景（等同 perform endScene）
                if arguments.removeFlag("--end") {
                    try await send(
                        ControlRequest(verb: .perform, target: .system, action: .endScene),
                        config: config, json: jsonOutput
                    )
                    break
                }
                // `--for <時長>` ＝ 限時場景：套用前先快照，時間到自動還原
                var duration: String?
                if let index = arguments.firstIndex(of: "--for") {
                    guard index + 1 < arguments.count else {
                        fail("「--for」少了時長，例如 25m")
                    }
                    duration = arguments[index + 1]
                    arguments.removeSubrange(index...(index + 1))
                }
                guard let name = arguments.first else {
                    fail("用法：chorus scene <名稱> [--for 25m]，或 chorus scene --end")
                }
                try await send(
                    ControlRequest(verb: .perform, target: .system, value: name,
                                   action: .runScene, duration: duration),
                    config: config, json: jsonOutput
                )
            case "get", "set", "toggle":
                let verb = ControlVerb(rawValue: subcommand)!
                try await send(try parse(verb: verb, arguments: arguments), config: config, json: jsonOutput)
            case "perform":
                guard let raw = arguments.first, let action = ControlAction(rawValue: raw) else {
                    fail("用法：chorus perform <\(ControlAction.allCases.map(\.rawValue).joined(separator: "|"))> [引數]")
                }
                let target = arguments.dropFirst().first { !$0.hasPrefix("--") }
                try await send(
                    ControlRequest(verb: .perform, target: .system, value: target, action: action),
                    config: config, json: jsonOutput
                )
            default:
                fail("未知的子指令「\(subcommand)」。執行 chorus help 看用法")
            }
        } catch let error as CLIError {
            FileHandle.standardError.write(Data("chorus: \(error.message)\n".utf8))
            exit(error.exitCode)
        } catch {
            FileHandle.standardError.write(Data("chorus: \(error)\n".utf8))
            exit(1)
        }
    }

    // MARK: - 參數 → 請求

    /// 需要帶值的目標旗標。長選項名與 `ControlTarget` 的語法一一對應，
    /// 使用者學會一邊就會另一邊。
    private static let valuedTargetFlags: Set<String> = [
        "--display", "--display-like", "--display-uuid",
        "--device", "--device-like", "--device-uid",
        "--app", "--app-like",
    ]
    private static let valuelessTargetFlags: Set<String> = [
        "--display-with-mouse", "--display-with-focus", "--builtin-display",
        "--all-displays", "--default-output", "--all-devices", "--all-apps", "--system",
    ]

    private static func targetFlag(_ flag: String, argument: String?) -> ControlTarget? {
        switch (flag, argument) {
        case let ("--display", name?): .display(name: name)
        case let ("--display-like", text?): .displayLike(text)
        case let ("--display-uuid", uuid?): .displayUUID(uuid)
        case ("--display-with-mouse", _): .displayWithMouse
        case ("--display-with-focus", _): .displayWithFocus
        case ("--builtin-display", _): .builtinDisplay
        case ("--all-displays", _): .allDisplays
        case let ("--device", name?): .device(name: name)
        case let ("--device-like", text?): .deviceLike(text)
        case let ("--device-uid", uid?): .deviceUID(uid)
        case ("--default-output", _): .defaultOutput
        case ("--all-devices", _): .allDevices
        case ("--all-apps", _): .allApps
        case let ("--app", bundleID?): .app(bundleID: bundleID)
        case let ("--app-like", text?): .appLike(text)
        case ("--system", _): .system
        default: nil
        }
    }

    private static func parse(verb: ControlVerb, arguments: [String]) throws(CLIError) -> ControlRequest {
        var target: ControlTarget?
        var property: ControlProperty?
        var value: String?
        var peer: String?

        var index = 0
        while index < arguments.count {
            let token = arguments[index]
            index += 1
            func nextValue() throws(CLIError) -> String {
                guard index < arguments.count else {
                    throw CLIError("「\(token)」少了值")
                }
                defer { index += 1 }
                return arguments[index]
            }

            if token == "--peer" {
                peer = try nextValue()
            } else if valuedTargetFlags.contains(token) || valuelessTargetFlags.contains(token) {
                let argument = valuelessTargetFlags.contains(token) ? nil : try nextValue()
                target = targetFlag(token, argument: argument)
            } else if token.hasPrefix("--"),
                      let matched = ControlProperty(rawValue: String(token.dropFirst(2))) {
                property = matched
                // set 才吃值；get/toggle 的屬性旗標是單獨出現的
                if verb == .set {
                    value = try nextValue()
                }
            } else {
                throw CLIError("無法辨識的參數「\(token)」")
            }
        }

        if verb != .get, property == nil {
            throw CLIError(
                "需要指定屬性，例如 --brightness。可用："
                    + ControlProperty.allCases.map { "--\($0.rawValue)" }.joined(separator: " ")
            )
        }
        // 沒給目標就依屬性推斷（chorus set --brightness 50% 直接可用）
        let resolved = target ?? property?.defaultTarget ?? .allDisplays
        return ControlRequest(
            verb: verb, target: resolved, property: property, value: value, peer: peer
        )
    }

    // MARK: - 送出與輸出

    private static func send(_ request: ControlRequest, config: Config, json: Bool) async throws {
        let response = try await Client(config: config).post("/v1/command", request: request)
        if json {
            print(response.rawJSON)
            if !response.ok { exit(1) }
            return
        }
        if let error = response.decoded?.error {
            var line = "錯誤（\(error.code)）：\(error.message)"
            if let hint = error.hint { line += "\n提示：\(hint)" }
            FileHandle.standardError.write(Data((line + "\n").utf8))
            exit(1)
        }
        for result in response.decoded?.results ?? [] {
            let property = result.property.map { " \($0)" } ?? ""
            print("\(result.target)\(property) = \(describe(result))")
        }
    }

    /// 印法依**屬性的值種類**決定，不用「數值落在 0–1」去猜——
    /// keepAwake 的 0（關閉）與 brightness 的 0（全暗）都是 0，猜不出來。
    /// `chorus scenes` 的人類可讀輸出：一行一個場景，附動作數。
    private static func printScenes(_ json: String) {
        guard let data = json.data(using: .utf8),
              let scenes = try? JSONDecoder().decode([ControlScene].self, from: data)
        else {
            print(json)
            return
        }
        if scenes.isEmpty {
            print("（尚無場景。可在 Chorus 選單列以目前狀態建立）")
            return
        }
        for scene in scenes {
            print("\(scene.name)  — \(scene.requests.count) 個動作")
        }
    }

    private static func describe(_ result: ControlResult) -> String {
        let kind = result.property.flatMap(ControlProperty.init(rawValue:))?.valueKind
        switch result.value {
        case let .number(number):
            return switch kind {
            case .unitInterval, .signedUnit, .gain: "\(Int((number * 100).rounded()))%"
            default: trimmed(number)
            }
        case let .bool(flag): return flag ? "on" : "off"
        case let .string(text): return text
        case .null, nil: return "—"
        }
    }

    private static func trimmed(_ number: Double) -> String {
        number == number.rounded() ? String(Int(number)) : String(number)
    }

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("chorus: \(message)\n".utf8))
        exit(2)
    }

    private static func printUsage() {
        print("""
        chorus — Chorus 的命令列控制介面

        用法：
          chorus set    [目標] --<屬性> <值>
          chorus get    [目標] [--<屬性>]
          chorus toggle [目標] --<屬性>
          chorus perform <動作> [引數]
          chorus scene  <名稱> [--for 25m]
          chorus scene  --end
          chorus scenes
          chorus state
          chorus listen

        目標（省略時依屬性推斷）：
          --display <名稱>        --display-like <片段>   --display-uuid <uuid>
          --display-with-mouse    --display-with-focus    --builtin-display
          --all-displays          --device <名稱>         --device-like <片段>
          --device-uid <uid>      --default-output        --all-devices
          --app <bundle id>       --app-like <片段>       --all-apps
          --system                --peer <已配對裝置名稱>

        屬性：
          \(ControlProperty.allCases.map { "--\($0.rawValue)" }.joined(separator: "  "))

        值：0.8、80%、+10%、-0.1、on/off、30m／1h／forever、MCCS 代碼
            逐 App 音量最高 400%（超過 100% 的部分會過 soft limiter）

        選項：
          --json    輸出原始 JSON（給腳本用）

        範例：
          chorus set --brightness 50%
          chorus set --display-like DELL --brightness +10%
          chorus set --peer 客廳 --all-displays --power off
          chorus toggle --mute
          chorus get --all-apps
          chorus set --app com.apple.Music --volume 40%
          chorus toggle --app-like Music --mute
          chorus set --peer 客廳 --app com.spotify.client --mute on
          chorus listen
          chorus scene 工作 --for 25m
          chorus scene --end

        限時場景（`--for`）：套用前先記住場景會動到的每一個值，時間到
        自動放回去。提前結束（`--end`）與結束 Chorus 走同一條還原路。
        `chorus state` 會列出 focusScene／focusRemaining／focusDeadline。

        介面需在 Chorus 設定頁「自動化介面」開啟。token 由 App 寫入
        ~/.config/chorus/config.json（權限 600），亦可用 CHORUS_TOKEN 覆寫。
        """)
    }
}

// MARK: - 設定與連線

struct CLIError: Error {
    let message: String
    var exitCode: Int32 = 1
    init(_ message: String, exitCode: Int32 = 1) {
        self.message = message
        self.exitCode = exitCode
    }
}

struct Config {
    let port: UInt16
    let token: String

    static func load() throws(CLIError) -> Config {
        let environment = ProcessInfo.processInfo.environment
        let path = environment["CHORUS_CONFIG"]
            ?? NSString(string: "~/.config/chorus/config.json").expandingTildeInPath
        var port: UInt16 = 55780
        var token = environment["CHORUS_TOKEN"]
        if let data = FileManager.default.contents(atPath: path),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let filePort = object["port"] as? Int, let value = UInt16(exactly: filePort) {
                port = value
            }
            if token == nil { token = object["token"] as? String }
        }
        guard let token, !token.isEmpty else {
            throw CLIError(
                "找不到 token。請在 Chorus 設定頁開啟「自動化介面」，"
                    + "或設定 CHORUS_TOKEN 環境變數。",
                exitCode: 3
            )
        }
        if let override = environment["CHORUS_PORT"], let value = UInt16(override) {
            port = value
        }
        return Config(port: port, token: token)
    }
}

struct Client {
    let config: Config

    struct Response {
        let rawJSON: String
        let decoded: ControlResponse?
        let ok: Bool
    }

    private var base: String { "http://127.0.0.1:\(config.port)" }

    private func request(_ path: String, method: String, body: Data?) -> URLRequest {
        var request = URLRequest(url: URL(string: base + path)!)
        request.httpMethod = method
        request.setValue("Bearer \(config.token)", forHTTPHeaderField: "Authorization")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    func get(_ path: String) async throws -> String {
        let (data, response) = try await URLSession.shared.data(for: request(path, method: "GET", body: nil))
        try checkStatus(response, data: data)
        return String(decoding: data, as: UTF8.self)
    }

    func post(_ path: String, request payload: ControlRequest) async throws -> Response {
        let body = try JSONEncoder().encode(payload)
        let (data, response) = try await URLSession.shared.data(
            for: request(path, method: "POST", body: body)
        )
        try checkStatus(response, data: data)
        let decoded = try? JSONDecoder().decode(ControlResponse.self, from: data)
        return Response(
            rawJSON: String(decoding: data, as: UTF8.self),
            decoded: decoded,
            ok: decoded?.ok ?? false
        )
    }

    /// SSE 事件流：一行一個 JSON，方便 `chorus listen | jq` 直接接管線。
    func listen() async throws {
        let (stream, response) = try await URLSession.shared.bytes(
            for: request("/v1/events", method: "GET", body: nil)
        )
        try checkStatus(response, data: nil)
        for try await line in stream.lines where line.hasPrefix("data: ") {
            print(String(line.dropFirst(6)))
            fflush(stdout)
        }
    }

    private func checkStatus(_ response: URLResponse, data: Data?) throws(CLIError) {
        guard let http = response as? HTTPURLResponse else { return }
        switch http.statusCode {
        case 200...299:
            return
        case 401:
            throw CLIError("token 不正確。請到設定頁重新產生，或檢查 CHORUS_TOKEN。", exitCode: 3)
        default:
            let detail = data.map { String(decoding: $0, as: UTF8.self) } ?? ""
            throw CLIError("HTTP \(http.statusCode) \(detail)")
        }
    }
}

private extension Array where Element == String {
    mutating func removeFlag(_ flag: String) -> Bool {
        guard let index = firstIndex(of: flag) else { return false }
        remove(at: index)
        return true
    }
}
