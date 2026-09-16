import Foundation

/// 一棵 agent 行程樹的一次取樣。
///
/// CPU 要**整棵樹**一起算：`claude` 自己多半在等模型回應，真正燒 CPU 的是它 spawn
/// 出來的 ripgrep／node／編譯器。只看根行程會把工作中的 session 看成閒置。
public struct AgentProcessSample: Sendable, Hashable {
    public let pid: Int32
    public let engine: String
    public let agentID: String
    /// 根行程 own ＋ 根已回收子行程 ＋ 存活子孫 own 的累計 CPU 秒數（單調遞增）。
    public let treeCPUSeconds: Double
    /// 存活子孫的 pid。短命的子行程來去本身就是「有人在工作」的跡證。
    public let descendantPIDs: Set<Int32>

    public init(
        pid: Int32,
        engine: String,
        agentID: String,
        treeCPUSeconds: Double,
        descendantPIDs: Set<Int32> = []
    ) {
        self.pid = pid
        self.engine = engine
        self.agentID = agentID
        self.treeCPUSeconds = treeCPUSeconds
        self.descendantPIDs = descendantPIDs
    }
}

public struct AgentProcessSnapshot: Sendable, Equatable {
    public let samples: [AgentProcessSample]
    public let sampledAt: Date

    public init(samples: [AgentProcessSample], sampledAt: Date) {
        self.samples = samples
        self.sampledAt = sampledAt
    }
}

/// 從「兩次行程樹取樣」判斷這棵樹是不是在工作（第二層偵測）。
///
/// 累計 CPU 秒數是單調遞增的，所以判斷只需要相鄰兩次的差除以間隔。
/// 判定「有活動」後就交給 `AgentActivityPlanner` 的 5 分鐘 grace 收尾——
/// agent 等模型回應時整棵樹確實會安靜好幾十秒，門檻不該自己扛這件事。
public enum AgentProcessActivityPlanner {
    /// 算「在工作」的 CPU 佔比：30 秒視窗裡 0.5 秒（≈ 1.67%）。
    ///
    /// 本機 30 秒實測：claude 工作中 6.4%、cursor-agent 工作中 13.6%、
    /// claude 停在 prompt 0.8%、無終端機的常駐 helper 0.7% 與 0。
    /// 線放在 1.67% 是離兩群都遠的位置，不是硬湊出來的中點。
    public static let defaultActiveCPUFraction: Double = 0.5 / 30

    /// 間隔短於這個秒數就不下新判斷：取樣本身有抖動，除以極小的間隔會炸出假活動。
    public static let minimumIntervalSeconds: Double = 1

    public struct State: Sendable, Equatable {
        /// 上一輪每個 pid 的取樣。
        public var previous: [Int32: AgentProcessSample]
        /// 每個 pid 最後一次被判定有活動的時刻。
        public var lastActive: [Int32: Date]
        /// 上一輪的取樣時間。nil ＝ 還沒有上一輪。
        public var previousAt: Date?

        public init() {
            previous = [:]
            lastActive = [:]
            previousAt = nil
        }
    }

    /// 吃一次快照，回新狀態與這一輪的活動樣本。
    ///
    /// - 首次見到的 pid 一律算活動：存疑就保持清醒，代價只是多醒一個 grace。
    /// - CPU 差 ÷ 間隔 ≥ `activeCPUFraction`，或子孫集合有變 → 活動。
    /// - 都沒有 → 沿用上次的 `lastActive`（讓 grace 自己走完）。
    /// - CPU 負差（rusage 讀失敗、pid 重用）視為 0，不算活動也不當異常。
    /// - 間隔不足 `minimumIntervalSeconds` → 這一輪不下新判斷。
    /// - 快照裡沒有的 pid 直接消失：行程結束就不該再撐著 assertion。
    public static func step(
        _ state: State,
        snapshot: AgentProcessSnapshot,
        activeCPUFraction: Double = defaultActiveCPUFraction
    ) -> (state: State, samples: [AgentSessionSample]) {
        let interval = state.previousAt.map { snapshot.sampledAt.timeIntervalSince($0) }
        var next = State()
        next.previousAt = snapshot.sampledAt
        var samples: [AgentSessionSample] = []

        for sample in snapshot.samples {
            let lastActive: Date
            if let previous = state.previous[sample.pid] {
                let carried = state.lastActive[sample.pid] ?? snapshot.sampledAt
                if let interval, interval >= minimumIntervalSeconds {
                    let delta = max(0, sample.treeCPUSeconds - previous.treeCPUSeconds)
                    let treeChanged = previous.descendantPIDs != sample.descendantPIDs
                    lastActive = (treeChanged || delta / interval >= activeCPUFraction)
                        ? snapshot.sampledAt
                        : carried
                } else {
                    lastActive = carried
                }
            } else {
                lastActive = snapshot.sampledAt
            }
            next.previous[sample.pid] = sample
            next.lastActive[sample.pid] = lastActive
            samples.append(
                AgentSessionSample(id: "pid:\(sample.pid)", engine: sample.engine, lastWrite: lastActive)
            )
        }
        return (next, samples)
    }
}

/// 把兩層偵測的樣本併成一份。
public enum AgentActivityMerger {
    /// log 樣本優先：同一個 engine 只要有 grace 內的 log 樣本，就丟掉它的 pid 樣本。
    ///
    /// 不是因為 pid 樣本比較差，而是同一個 session 會同時被兩層看到，
    /// 選單上「3 個 Claude Code 在工作中」會變成 6 個。log 是精確到 session 的那一層，
    /// 留它。沒有 log 跡證的 engine（或 log 已經冷掉的）才用 pid 樣本。
    public static func merge(
        logSamples: [AgentSessionSample],
        processSamples: [AgentSessionSample],
        now: Date,
        graceSeconds: Double = AgentActivityPlanner.defaultGraceSeconds
    ) -> [AgentSessionSample] {
        let covered = Set(
            logSamples
                .filter { now.timeIntervalSince($0.lastWrite) < graceSeconds }
                .map(\.engine)
        )
        return logSamples + processSamples.filter { !covered.contains($0.engine) }
    }
}
