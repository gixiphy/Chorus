import Foundation

/// 把一個行程（名稱或 argv）認回是哪一家 agent。
///
/// 規則移植自 Orca 的 `agent-process-recognition.ts`（MIT，只搬邏輯不搬碼）。
/// 難的地方在**別把不是 agent 的東西認成 agent**：
/// - 打包過的 binary 帶架構後綴（`codex-aarch64-apple-darwin`），而 `kinfo_proc.p_comm`
///   只有 16 個字，會截成 `codex-aarch64-ap`——所以要有前綴與截斷比對。
/// - npm 安裝的 agent 行程名是 `node`，真身在 argv 的 entrypoint 路徑裡。
/// - prompt 文字本身常常含 agent 名（`node cli.js "fix the codex bug"`），
///   所以只認「像路徑或有副檔名」的 token，而且遇到 `-e/-p` 這種吃程式碼的旗標就直接放棄。
public struct AgentProcessMatcher: Sendable, Equatable {
    public struct Match: Sendable, Hashable {
        /// 註冊表的 id，或使用者自訂名的 `custom:<name>`。
        public let agentID: String
        /// 顯示名。
        public let engine: String

        public init(agentID: String, engine: String) {
            self.agentID = agentID
            self.engine = engine
        }
    }

    private let definitions: [AgentDefinition]
    private let customProcessNames: [String]

    /// 精確名 → 命中（註冊表）。
    private let registryNames: [String: Match]
    /// 自訂名 → 命中。註冊表優先，這裡不覆蓋。
    private let customNames: [String: Match]
    /// `p_comm` 被截成 16 字後的名字 → 命中。
    private let truncatedNames: [String: Match]
    /// 前綴規則，照註冊表順序。
    private let prefixRules: [(prefix: String, match: Match)]
    /// 只用來快速判斷「這個行程值不值得再花錢讀 argv／rusage」。
    private let candidateNames: Set<String>

    /// Darwin `kinfo_proc.p_comm` 的長度上限（含結尾的 NUL 之前的可用字元數）。
    private static let commLimit = 16

    public init(definitions: [AgentDefinition] = AgentRegistry.all, customProcessNames: [String] = []) {
        self.definitions = definitions
        self.customProcessNames = customProcessNames

        var registryNames: [String: Match] = [:]
        var truncatedNames: [String: Match] = [:]
        var prefixRules: [(prefix: String, match: Match)] = []
        var candidates = AgentRegistry.interpreterNames

        for definition in definitions {
            let match = Match(agentID: definition.id, engine: definition.engine)
            for name in definition.processNames.sorted() {
                let key = Self.normalize(name, stripScriptExtension: true)
                guard !key.isEmpty else { continue }
                if registryNames[key] == nil { registryNames[key] = match }
                candidates.insert(key)
                if let truncated = Self.truncatedComm(key), truncatedNames[truncated] == nil {
                    truncatedNames[truncated] = match
                    candidates.insert(truncated)
                }
            }
            for prefix in definition.processPrefixes {
                let key = Self.normalize(prefix)
                guard !key.isEmpty else { continue }
                prefixRules.append((prefix: key, match: match))
            }
        }

        var customNames: [String: Match] = [:]
        for name in customProcessNames {
            let key = Self.normalize(name, stripScriptExtension: true)
            guard !key.isEmpty, registryNames[key] == nil, customNames[key] == nil else { continue }
            // engine 顯示使用者打的原字（`parseCustomNames` 已經正規化過的話就一樣）。
            let match = Match(agentID: "custom:\(key)", engine: name)
            customNames[key] = match
            candidates.insert(key)
            if let truncated = Self.truncatedComm(key), truncatedNames[truncated] == nil {
                truncatedNames[truncated] = match
                candidates.insert(truncated)
            }
        }

        self.registryNames = registryNames
        self.customNames = customNames
        self.truncatedNames = truncatedNames
        self.prefixRules = prefixRules
        self.candidateNames = candidates
    }

    /// 查表都是從 `definitions` 與 `customProcessNames` 推出來的，比這兩個就夠。
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.definitions == rhs.definitions && lhs.customProcessNames == rhs.customProcessNames
    }

    // MARK: - 正規化

    /// trim → 去首尾成對引號 → 取 basename（`/` 與 `\` 都算分隔）→ 小寫
    /// →（選用）去掉 `.exe`／`.cmd`／`.bat`／`.ps1` 這類包裝腳本副檔名。
    public static func normalize(_ name: String, stripScriptExtension: Bool = false) -> String {
        var value = Substring(name).trimmed()
        if value.count >= 2, let first = value.first, let last = value.last,
           first == last, first == "\"" || first == "'" {
            value = value.dropFirst().dropLast()
        }
        if let separator = value.lastIndex(where: { $0 == "/" || $0 == "\\" }) {
            value = value[value.index(after: separator)...]
        }
        var result = value.lowercased()
        if stripScriptExtension {
            for suffix in ["exe", "cmd", "bat", "ps1"] where result.hasSuffix(".\(suffix)") {
                result = String(result.dropLast(suffix.count + 1))
                break
            }
        }
        return result
    }

    /// 這個名字在 `p_comm` 裡會被截成什麼（沒超過長度上限就回 nil）。
    private static func truncatedComm(_ name: String) -> String? {
        guard name.count > commLimit else { return nil }
        return String(name.prefix(commLimit))
    }

    /// `python`、`python3.12`、`node`… 這類要再看 argv 的行程名。
    public static func isInterpreterName(_ normalized: String) -> Bool {
        if AgentRegistry.interpreterNames.contains(normalized) { return true }
        // 等價於 regex `python\d(\.\d)*`。
        guard normalized.hasPrefix("python") else { return false }
        let version = normalized.dropFirst("python".count)
        guard !version.isEmpty else { return false }
        return version.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { part in
            !part.isEmpty && part.allSatisfy { $0.isASCII && $0.isNumber }
        }
    }

    // MARK: - 比對

    /// 值不值得為這個行程再讀 argv 與 rusage。
    ///
    /// 便宜的第一關：`p_comm` 全機器都拿得到，argv／rusage 是逐個 syscall。
    /// 前綴也算候選——不然打包成 `codex-aarch64-ap` 的 Codex 永遠進不了下一關。
    public func isCandidate(comm: String) -> Bool {
        let name = Self.normalize(comm, stripScriptExtension: true)
        guard !name.isEmpty else { return false }
        if candidateNames.contains(name) { return true }
        if Self.isInterpreterName(name) { return true }
        return prefixRules.contains { name.hasPrefix($0.prefix) }
    }

    /// 精確名 → 自訂名 → 截斷名 → 前綴。
    public func match(processName: String) -> Match? {
        let name = Self.normalize(processName, stripScriptExtension: true)
        guard !name.isEmpty else { return nil }
        if let match = registryNames[name] { return match }
        if let match = customNames[name] { return match }
        if let match = truncatedNames[name] { return match }
        return prefixRules.first { name.hasPrefix($0.prefix) }?.match
    }

    /// argv[0] 直接命中；否則若 argv[0] 是直譯器，再找 entrypoint。
    public func match(arguments: [String]) -> Match? {
        guard let executable = arguments.first else { return nil }
        if let match = match(processName: executable) { return match }
        let interpreter = Self.normalize(executable, stripScriptExtension: true)
        guard Self.isInterpreterName(interpreter) else { return nil }
        let isPython = interpreter.hasPrefix("python")
        switch Self.entrypoint(of: arguments, isPython: isPython) {
        case .none:
            return nil
        case .module(let module):
            let head = module.split(separator: ".").first.map(String.init) ?? module
            let name = Self.normalize(head)
            return definitions.first { $0.pythonModules.contains(name) }
                .map { Match(agentID: $0.id, engine: $0.engine) }
        case .script(let token):
            return match(scriptToken: token, arguments: arguments, isPython: isPython)
        }
    }

    /// 整行 command line（`ps -o args` 那種）。
    public func match(commandLine: String) -> Match? {
        match(arguments: Self.tokenize(commandLine))
    }

    private func match(scriptToken token: String, arguments: [String], isPython: Bool) -> Match? {
        let lowered = token.lowercased()
        // python 的腳本很容易撞到隨手寫的檔名，只認裝在標準位置的。
        if isPython {
            let allowed = ["/bin/", "/scripts/", "/site-packages/"]
            guard allowed.contains(where: { lowered.contains($0) }) else { return nil }
        }
        if let match = match(processName: token) { return match }
        for definition in definitions {
            if definition.nodeEntrypointPatterns.contains(where: { Self.matches(pattern: $0, path: lowered) }) {
                return Match(agentID: definition.id, engine: definition.engine)
            }
        }
        // 套件路徑片段可以出現在任何 token（`--import` 帶的 loader 也算）。
        for definition in definitions {
            for marker in definition.nodePackageMarkers {
                let needle = marker.lowercased()
                if arguments.contains(where: { $0.lowercased().contains(needle) }) {
                    return Match(agentID: definition.id, engine: definition.engine)
                }
            }
        }
        return nil
    }

    /// `*` 配一段路徑，且要對齊路徑的最後一段（樣式指的是 entrypoint 檔案本身）。
    static func matches(pattern: String, path: String) -> Bool {
        let expected = pattern.lowercased().split(separator: "/").map(String.init)
        let actual = path.split(separator: "/").map(String.init)
        guard !expected.isEmpty, actual.count >= expected.count else { return false }
        let tail = actual.suffix(expected.count)
        return zip(expected, tail).allSatisfy { $0 == "*" || $0 == $1 }
    }

    // MARK: - entrypoint

    private enum Entrypoint {
        case none
        case script(String)
        case module(String)
    }

    /// 直譯器 argv 裡的 entrypoint。
    ///
    /// 規則（§1.4）：略過 `--`；`-r/--require/--import/--loader/--experimental-loader`
    /// 要跳過它的值；遇到吃程式碼的 `-e/--eval/-p/--print/--check` 直接放棄
    /// （那些 argv 裡的字是程式碼或 prompt，不是 agent）；python 的 `-m` 取模組名。
    /// 第一個非旗標 token 就是 entrypoint 的位置——它不像路徑就放棄，不再往後找，
    /// 免得把 prompt 裡的 agent 名當成 entrypoint。
    private static func entrypoint(of arguments: [String], isPython: Bool) -> Entrypoint {
        let valueFlags: Set<String> = ["-r", "--require", "--import", "--loader", "--experimental-loader"]
        let codeFlags: Set<String> = ["-e", "--eval", "-p", "--print", "--check", "-c"]
        var index = 1
        while index < arguments.count {
            let token = arguments[index]
            if token == "--" { index += 1; continue }
            if token.hasPrefix("-"), token.count > 1 {
                if codeFlags.contains(token) { return .none }
                if valueFlags.contains(token) { index += 2; continue }
                if isPython, token == "-m" {
                    guard index + 1 < arguments.count else { return .none }
                    return .module(arguments[index + 1])
                }
                index += 1
                continue
            }
            return looksLikePath(token) ? .script(token) : .none
        }
        return .none
    }

    /// 含路徑分隔或副檔名才當可執行檔——`node claude` 這種只是文字。
    private static func looksLikePath(_ token: String) -> Bool {
        if token.contains("/") || token.contains("\\") { return true }
        let name = normalize(token)
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return false }
        return name.index(after: dot) < name.endIndex
    }

    // MARK: - 文字處理

    /// 切 command line：雙引號、單引號、反斜線跳脫（單引號內的反斜線是字面值）。
    public static func tokenize(_ commandLine: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var started = false
        var quote: Character?
        var escaped = false
        for character in commandLine {
            if escaped {
                current.append(character)
                escaped = false
                continue
            }
            if character == "\\", quote != "'" {
                escaped = true
                started = true
                continue
            }
            if let open = quote {
                if character == open {
                    quote = nil
                } else {
                    current.append(character)
                }
                continue
            }
            if character == "\"" || character == "'" {
                quote = character
                started = true
                continue
            }
            if character.isWhitespace {
                if started { tokens.append(current) }
                current = ""
                started = false
                continue
            }
            current.append(character)
            started = true
        }
        if started { tokens.append(current) }
        return tokens
    }

    /// 逗號分隔的自訂行程名：正規化、去空、去重，並拒收直譯器名。
    ///
    /// 拒收 `node`／`python3` 是因為它們一定會有一堆非 agent 的行程在跑，
    /// 收下去等於「只要有人在跑 node 就別睡」。
    public static func parseCustomNames(_ text: String) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for raw in text.split(separator: ",") {
            let name = normalize(String(raw), stripScriptExtension: true)
            guard !name.isEmpty, !isInterpreterName(name), seen.insert(name).inserted else { continue }
            result.append(name)
        }
        return result
    }
}

private extension Substring {
    func trimmed() -> Substring {
        var value = self
        while let first = value.first, first.isWhitespace { value = value.dropFirst() }
        while let last = value.last, last.isWhitespace { value = value.dropLast() }
        return value
    }
}
