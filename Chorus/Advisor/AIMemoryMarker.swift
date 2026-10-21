import Foundation

/// 自動啟動的 agent session 不讀取或貢獻使用者的習慣學習。
enum AIMemoryMarker {
    static let originEnvironmentKey = "FI_AGENT_ORIGIN"
    static let origin = "chorus"

    struct Session: Sendable {
        let directory: URL
        let project: String
    }

    static func contents(project: String) -> String {
        """
        workspace = "app-agents"
        project = "\(project)"
        drop_subagent_captures = "true"

        [profile]
        contribute = false
        consume = false

        """
    }

    static func write(to directory: URL, project: String) throws {
        try Data(contents(project: project).utf8).write(
            to: directory.appendingPathComponent(".ai-memory.toml"), options: .atomic
        )
    }
}
