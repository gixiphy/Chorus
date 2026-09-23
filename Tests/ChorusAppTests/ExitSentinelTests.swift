import Foundation
import Testing
@testable import Chorus

@Suite("乾淨結束哨兵")
struct ExitSentinelTests {
    private func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("chorus-sentinel-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("第一次啟動 → 正常結束後再啟動是 clean → 沒結束就再啟動是 crash")
    func stateMachine() throws {
        let directory = try makeDirectory()
        let sentinel = ExitSentinel(directory: directory, instance: InstanceConfig(arguments: []))
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)

        let first = sentinel.markRunning(build: "116", now: t0)
        #expect(first == ExitSentinel.Outcome(lastExit: .firstLaunch, previousBuild: nil, previousLaunchedAt: nil))
        #expect(FileManager.default.fileExists(atPath: sentinel.fileURL.path))

        sentinel.markClean(build: "116", now: t0 + 60)
        let second = sentinel.markRunning(build: "117", now: t0 + 120)
        #expect(second.lastExit == .clean)
        #expect(second.previousBuild == "116")

        // 沒有 markClean 就再啟動：上次是異常結束，帶上次的 build 與啟動時間
        let third = sentinel.markRunning(build: "117", now: t0 + 300)
        #expect(third.lastExit == .crash)
        #expect(third.previousBuild == "117")
        #expect(third.previousLaunchedAt == t0 + 120)
    }

    @Test("檔案內容壞掉當作 crash（有檔但讀不懂）")
    func corruptFile() throws {
        let directory = try makeDirectory()
        let sentinel = ExitSentinel(directory: directory, instance: InstanceConfig(arguments: []))
        try "garbage".write(to: sentinel.fileURL, atomically: true, encoding: .utf8)
        let outcome = sentinel.markRunning(build: "1")
        #expect(outcome.lastExit == .crash)
        #expect(outcome.previousBuild == nil)
    }

    @Test("多實例各用各的檔名")
    func instanceFileName() {
        #expect(ExitSentinel.fileName(instance: InstanceConfig(arguments: [])) == "running.sentinel")
        #expect(ExitSentinel.fileName(instance: InstanceConfig(arguments: ["--instance", "mini"])) == "running-mini.sentinel")
    }
}
