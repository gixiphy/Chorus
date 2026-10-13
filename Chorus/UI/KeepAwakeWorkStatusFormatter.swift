import ChorusCore
import Foundation

/// 合併模式（有 agent 工作或高負載）選單副標。純函式，方便單元測試。
enum KeepAwakeWorkStatusFormatter {
    static func caption(
        agentBusy: Bool,
        agentNames: [String],
        load: SystemLoadEvaluation,
        sample: SystemLoadSample?,
        isHolding: Bool,
        idleBlanked: Bool
    ) -> String {
        let loadBusy = load.shouldHold
        let suffix = String(localized: "螢幕與系統不待機")

        if isHolding, idleBlanked {
            return String(localized: "工作中 — 閒置熄屏")
        }

        if agentBusy, loadBusy, load.phase == .active {
            let agent = primaryAgentLabel(agentNames)
            let detail = SystemLoadStatusFormatter.activeDetail(evaluation: load, sample: sample)
            return String(localized: "\(agent) 工作中＋\(detail) — \(suffix)")
        }

        if agentBusy {
            let agent = agentNamesLabel(agentNames)
            return String(localized: "\(agent) 工作中 — \(suffix)")
        }

        if loadBusy {
            switch load.phase {
            case .coolingDown:
                let seconds = Int((load.cooldownRemaining ?? 0).rounded(.up))
                if sample == nil || SystemLoadStatusFormatter.allUnavailable(sample) {
                    return String(localized: "監測資料中斷 · 約 \(seconds) 秒後解除")
                }
                return String(localized: "負載降低 · 約 \(seconds) 秒後解除")
            case .active:
                let detail = SystemLoadStatusFormatter.activeDetail(evaluation: load, sample: sample)
                return String(localized: "\(detail) 高負載 — \(suffix)")
            default:
                break
            }
        }

        switch load.phase {
        case .qualifying:
            let signal = load.qualifiedSignals.first.map(SystemLoadStatusFormatter.name)
                ?? SystemLoadStatusFormatter.primaryQualifyingName(sample: sample)
            return String(localized: "\(signal) 達門檻 · 確認中")
        case .unavailable:
            if sample?.gpu == .unsupported,
               sample?.cpu == .unavailable || sample?.cpu == .unsupported,
               sample?.network == .unavailable || sample?.network == .unsupported {
                return String(localized: "監測中：沒有 agent 工作（負載監測無資料）")
            }
            if sample?.gpu == .unsupported {
                return String(localized: "監測中：沒有 agent 工作（GPU 不支援，CPU／網路監測中）")
            }
            return String(localized: "監測中：沒有 agent 工作（負載監測無資料）")
        case .waiting, .coolingDown, .active:
            return String(localized: "監測中：沒有 agent 工作、負載未達門檻")
        }
    }

    private static func agentNamesLabel(_ names: [String]) -> String {
        let trimmed = names.filter { !$0.isEmpty }
        guard !trimmed.isEmpty else { return String(localized: "Agent") }
        if trimmed.count <= 2 {
            return trimmed.joined(separator: "、")
        }
        let head = trimmed.prefix(2).joined(separator: "、")
        let rest = trimmed.count - 2
        return String(localized: "\(head) 等 \(rest) 個")
    }

    private static func primaryAgentLabel(_ names: [String]) -> String {
        names.first(where: { !$0.isEmpty }) ?? String(localized: "Agent")
    }
}
