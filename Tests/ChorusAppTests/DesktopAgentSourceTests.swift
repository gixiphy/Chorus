import ChorusCore
import Foundation
import Testing
@testable import Chorus

@MainActor
@Suite("DesktopAgentSource")
struct DesktopAgentSourceTests {
    private let codexPath = "/Applications/Codex.app/Contents/Resources/codex"

    @Test("V-C07-3 process + signature + fresh mtime → contributing report")
    func workingWhenFresh() async {
        let now = Date(timeIntervalSince1970: 7_000_000)
        let process = DesktopAgentProcess(
            pid: 42,
            comm: "codex",
            executablePath: codexPath,
            arguments: [codexPath, "app-server"],
            startTime: 1
        )
        let source = DesktopAgentSource(
            lister: StaticDesktopLister([process]),
            verifier: FakeVerifier(ok: true),
            transcripts: StaticTranscriptScanner([
                (id: "/tmp/rollout-a.jsonl", mtime: now.addingTimeInterval(-10)),
            ]),
            now: { now }
        )
        source.start()
        await source.refresh()
        #expect(source.report.count == 1)
        #expect(source.report.first?.id == "desktop.codex")
        #expect(source.report.first?.isWorkingNow == false)
        #expect(source.report.first?.lastWorkingAt != nil)
        source.stop()
    }

    @Test("V-C07-3 stale mtime does not report")
    func staleMtime() async {
        let now = Date(timeIntervalSince1970: 7_100_000)
        let process = DesktopAgentProcess(
            pid: 42,
            comm: "codex",
            executablePath: codexPath,
            arguments: [codexPath, "app-server"],
            startTime: 1
        )
        let source = DesktopAgentSource(
            lister: StaticDesktopLister([process]),
            verifier: FakeVerifier(ok: true),
            transcripts: StaticTranscriptScanner([
                (id: "/tmp/rollout-old.jsonl", mtime: now.addingTimeInterval(-400)),
            ]),
            now: { now }
        )
        source.start()
        await source.refresh()
        #expect(source.report.isEmpty)
        source.stop()
    }

    @Test("V-C07-3 signature failure does not report")
    func signatureFails() async {
        let now = Date(timeIntervalSince1970: 7_200_000)
        let process = DesktopAgentProcess(
            pid: 42,
            comm: "codex",
            executablePath: codexPath,
            arguments: [codexPath, "app-server"],
            startTime: 1
        )
        let source = DesktopAgentSource(
            lister: StaticDesktopLister([process]),
            verifier: FakeVerifier(ok: false),
            transcripts: StaticTranscriptScanner([
                (id: "/tmp/rollout-a.jsonl", mtime: now.addingTimeInterval(-10)),
            ]),
            now: { now }
        )
        source.start()
        await source.refresh()
        #expect(source.report.isEmpty)
        source.stop()
    }

    @Test("V-C07-3 no process → no report")
    func noProcess() async {
        let source = DesktopAgentSource(
            lister: StaticDesktopLister([]),
            verifier: FakeVerifier(ok: true),
            transcripts: StaticTranscriptScanner([
                (id: "/tmp/rollout-a.jsonl", mtime: Date()),
            ])
        )
        source.start()
        await source.refresh()
        #expect(source.report.isEmpty)
        source.stop()
    }

    @Test("V-C07-6 future mtime stable clamp across ticks")
    func futureMtimeStableClamp() async {
        let now = Date(timeIntervalSince1970: 7_300_000)
        let future = now.addingTimeInterval(3_600)
        let process = DesktopAgentProcess(
            pid: 9,
            comm: "codex",
            executablePath: codexPath,
            arguments: [codexPath, "app-server"],
            startTime: 1
        )
        var clock = now
        let source = DesktopAgentSource(
            lister: StaticDesktopLister([process]),
            verifier: FakeVerifier(ok: true),
            transcripts: StaticTranscriptScanner([(id: "/tmp/rollout-future.jsonl", mtime: future)]),
            now: { clock }
        )
        source.start()
        await source.refresh()
        let first = source.report.first?.lastWorkingAt
        #expect(first == now)

        clock = now.addingTimeInterval(60)
        await source.refresh()
        #expect(source.report.first?.lastWorkingAt == first)
        source.stop()
    }

    @Test("Claude desktop source disabled even when path matches")
    func claudeDisabled() async {
        #expect(DesktopAgentMatcher.claudeDesktopSourceEnabled == false)
        let path = "/Users/test/Library/Application Support/Claude/claude-code/1.0.0/claude"
        let process = DesktopAgentProcess(
            pid: 7,
            comm: "claude",
            executablePath: path,
            arguments: [path],
            startTime: 1
        )
        let now = Date()
        let source = DesktopAgentSource(
            lister: StaticDesktopLister([process]),
            verifier: FakeVerifier(ok: true),
            transcripts: StaticTranscriptScanner([
                (id: "/tmp/claude.jsonl", mtime: now),
            ]),
            now: { now }
        )
        source.start()
        await source.refresh()
        #expect(source.report.isEmpty)
        source.stop()
    }
}
