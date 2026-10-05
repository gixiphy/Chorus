import Foundation
import Testing
@testable import ChorusCore

@Suite("Doctor")
struct DoctorTests {
    private func healthy(peers: [DoctorInputs.Peer] = []) -> DoctorInputs {
        DoctorInputs(
            browserState: "ready",
            listenerState: "ready",
            accessibilityTrusted: true,
            tapState: .active,
            tapError: nil,
            mainLoopResponsive: true,
            lastExitWasCrash: false,
            peers: peers
        )
    }

    private func peer(
        phase: DoctorInputs.Peer.Phase,
        isDialer: Bool = true,
        key: DoctorInputs.Peer.KeyState = .present,
        candidates: [String] = ["Studio._chorus._tcp.local."],
        failures: Int = 0,
        permissions: PeerPermissionPolicy = .full
    ) -> DoctorInputs.Peer {
        DoctorInputs.Peer(
            peerID: "a1b2c3d4e5f6",
            deviceName: "Studio",
            phase: phase,
            isDialer: isDialer,
            key: key,
            candidates: candidates,
            nextCandidate: candidates.first,
            consecutiveFailures: failures,
            permissions: permissions,
            lastHeardSecondsAgo: phase == .connected ? 3 : nil
        )
    }

    private func check(_ id: String, in checks: [DoctorCheck]) -> DoctorCheck? {
        checks.first { $0.id == id }
    }

    @Test("Healthy machine has no warnings or errors")
    func healthyMachine() {
        let checks = DoctorRules.evaluate(healthy(peers: [peer(phase: .connected)]))
        #expect(checks.allSatisfy { $0.status == .ok || $0.status == .info })
        #expect(check("peer.a1b2c3d4.connection", in: checks)?.status == .ok)
    }

    @Test("No peers is informational, not an error")
    func noPeers() {
        let checks = DoctorRules.evaluate(healthy())
        #expect(check("sync.peers", in: checks)?.status == .info)
        #expect(!DoctorReport(generatedAt: .now, checks: checks).hasErrors)
    }

    @Test("Listener not started without peers is expected, not a fault")
    func listenerIdleWithoutPeers() {
        var inputs = healthy()
        inputs.listenerState = ""
        let result = check("sync.listener", in: DoctorRules.evaluate(inputs))
        #expect(result?.status == .ok)
        #expect(result?.detail?.contains("配對") == true)
        #expect(result?.remedy == nil)
    }

    @Test("Local network denial is an error with a remedy")
    func discoveryDenied() {
        var inputs = healthy()
        inputs.browserState = "waiting(-65555: NoAuth)"
        let result = check("sync.discovery", in: DoctorRules.evaluate(inputs))
        #expect(result?.status == .error)
        #expect(result?.remedy?.contains("區域網路") == true)
        #expect(DoctorRules.isDiscoveryProblem("waiting(-65555: NoAuth)"))
        #expect(!DoctorRules.isDiscoveryProblem("ready"))
    }

    @Test("Missing PSK is an error that asks to re-pair")
    func missingPSK() {
        let checks = DoctorRules.evaluate(healthy(peers: [peer(phase: .idle, key: .missing)]))
        let result = check("peer.a1b2c3d4.connection", in: checks)
        #expect(result?.status == .error)
        #expect(result?.remedy?.contains("重新配對") == true)
    }

    @Test("Unreadable Keychain item is not reported as missing")
    func unreadableKeyDoesNotSuggestRepair() {
        let checks = DoctorRules.evaluate(healthy(peers: [peer(phase: .idle, key: .unreadable(status: -25293))]))
        let result = check("peer.a1b2c3d4.connection", in: checks)
        #expect(result?.status == .error)
        #expect(result?.detail?.contains("-25293") == true)
        #expect(result?.remedy?.contains("重新配對") == false)
        #expect(result?.remedy?.contains("鑰匙圈") == true)
    }

    @Test("Dialer with failures reports the next candidate")
    func dialerFailures() {
        let candidates = ["Studio._chorus._tcp.local.", "192.168.1.20:55781"]
        var target = peer(phase: .backoff(secondsRemaining: 4), candidates: candidates, failures: 3)
        target.nextCandidate = candidates[1]
        let result = check("peer.a1b2c3d4.connection", in: DoctorRules.evaluate(healthy(peers: [target])))
        #expect(result?.status == .warning)
        #expect(result?.detail?.contains("3") == true)
        #expect(result?.detail?.contains("192.168.1.20:55781") == true)
    }

    @Test("Dialer without any address is an error")
    func noAddress() {
        let target = peer(phase: .idle, candidates: [])
        let result = check("peer.a1b2c3d4.connection", in: DoctorRules.evaluate(healthy(peers: [target])))
        #expect(result?.status == .error)
    }

    @Test("Non-dialer waits for the other side instead of reporting failures")
    func nonDialerWaits() {
        let target = peer(phase: .idle, isDialer: false)
        let result = check("peer.a1b2c3d4.connection", in: DoctorRules.evaluate(healthy(peers: [target])))
        #expect(result?.status == .warning)
        #expect(result?.detail?.contains("等待對方") == true)
        #expect(result?.remedy?.contains("chorus doctor") == true)
    }

    @Test("Restricted permissions are listed; full permissions are not")
    func permissionsListed() {
        let limited = PeerPermissionPolicy(acceptsSync: false, allowedControls: [.audio])
        let checks = DoctorRules.evaluate(healthy(peers: [peer(phase: .connected, permissions: limited)]))
        #expect(check("peer.a1b2c3d4.permissions", in: checks)?.detail?.contains("音量與靜音") == true)
        let full = DoctorRules.evaluate(healthy(peers: [peer(phase: .connected)]))
        #expect(check("peer.a1b2c3d4.permissions", in: full) == nil)
    }

    @Test("Audio tap states map to statuses")
    func tapStates() {
        var inputs = healthy()
        inputs.tapState = .denied
        #expect(check("audio.tap", in: DoctorRules.evaluate(inputs))?.status == .error)
        inputs.tapState = .probing
        #expect(check("audio.tap", in: DoctorRules.evaluate(inputs))?.status == .info)
        inputs.tapState = .failed
        inputs.tapError = "AudioHardwareCreateProcessTap -1"
        let failed = check("audio.tap", in: DoctorRules.evaluate(inputs))
        #expect(failed?.status == .error)
        #expect(failed?.detail?.contains("-1") == true)
        inputs.tapState = .off
        #expect(check("audio.tap", in: DoctorRules.evaluate(inputs))?.status == .info)
    }

    @Test("Accessibility and main loop problems surface")
    func mainLoopUnresponsive() {
        var inputs = healthy()
        inputs.accessibilityTrusted = false
        inputs.mainLoopResponsive = false
        inputs.lastExitWasCrash = true
        let checks = DoctorRules.evaluate(inputs)
        #expect(check("permissions.accessibility", in: checks)?.status == .warning)
        #expect(check("app.mainLoop", in: checks)?.status == .error)
        #expect(check("app.lastExit", in: checks)?.status == .warning)
    }

    @Test("Every non-ok check carries a remedy")
    func remediesPresent() {
        var inputs = healthy(peers: [peer(phase: .idle, key: .missing), peer(phase: .idle, isDialer: false)])
        inputs.browserState = "waiting(NoAuth)"
        inputs.listenerState = "failed(POSIX 48)"
        inputs.accessibilityTrusted = false
        inputs.tapState = .denied
        inputs.mainLoopResponsive = false
        inputs.lastExitWasCrash = true
        for check in DoctorRules.evaluate(inputs) where check.status == .warning || check.status == .error {
            #expect(check.remedy != nil, "\(check.id) 缺少修復說明")
        }
    }

    @Test("Unknown status from a newer app decodes and counts as warning")
    func unknownStatusDecodes() throws {
        let json = Data(#"{"generatedAt":0,"checks":[{"id":"x","status":"critical","title":"X"}]}"#.utf8)
        let report = try JSONDecoder().decode(DoctorReport.self, from: json)
        #expect(report.checks.first?.status.severity == DoctorCheck.Status.warning.severity)
        #expect(!report.hasErrors)
    }

    @Test("Formatter shows symbol, title, detail and remedy")
    func formatter() {
        let report = DoctorReport(generatedAt: .now, checks: [
            DoctorCheck(id: "a", status: .ok, title: "同步探索", detail: "正常"),
            DoctorCheck(id: "b", status: .error, title: "Studio", detail: "金鑰遺失", remedy: "移除後重新配對"),
        ])
        let text = DoctorFormatter.render(report)
        #expect(text.contains("✓ 同步探索 — 正常"))
        #expect(text.contains("✗ Studio — 金鑰遺失"))
        #expect(text.contains("→ 移除後重新配對"))
        #expect(text.contains("1 個錯誤"))
    }
}
