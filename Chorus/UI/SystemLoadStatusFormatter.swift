import ChorusCore
import Foundation

enum SystemLoadStatusFormatter {
    static func caption(
        evaluation: SystemLoadEvaluation,
        sample: SystemLoadSample?,
        isHolding: Bool,
        alsoPreventSystemSleep: Bool
    ) -> String {
        switch evaluation.phase {
        case .waiting:
            return String(localized: "監測中，等待持續負載")
        case .qualifying:
            let signal = evaluation.qualifiedSignals.first.map(Self.name)
                ?? primaryQualifyingName(sample: sample)
            return String(localized: "\(signal) 達門檻 · 確認中")
        case .active:
            let detail = activeDetail(evaluation: evaluation, sample: sample)
            if alsoPreventSystemSleep {
                return String(localized: "\(detail) · 螢幕與系統保持喚醒")
            }
            return String(localized: "\(detail) · 螢幕常亮")
        case .coolingDown:
            let seconds = Int((evaluation.cooldownRemaining ?? 0).rounded(.up))
            if sample == nil || allUnavailable(sample) {
                return String(localized: "監測資料中斷 · 約 \(seconds) 秒後解除")
            }
            return String(localized: "負載降低 · 約 \(seconds) 秒後解除")
        case .unavailable:
            if sample?.gpu == .unsupported,
               sample?.cpu == .unavailable || sample?.cpu == .unsupported,
               sample?.network == .unavailable || sample?.network == .unsupported {
                return String(localized: "無可用監測資料")
            }
            if sample?.gpu == .unsupported {
                return String(localized: "CPU／網路監測中 · GPU 不支援")
            }
            return String(localized: "無可用監測資料")
        }
    }

    private static func activeDetail(
        evaluation: SystemLoadEvaluation,
        sample: SystemLoadSample?
    ) -> String {
        if let signal = evaluation.qualifiedSignals.sorted(by: { $0.rawValue < $1.rawValue }).first,
           let sample,
           case .value(let value) = sample.reading(for: signal) {
            if signal == .network {
                let mib = value / 1_048_576
                return String(format: String(localized: "網路 %.2f MiB/s"), mib)
            }
            return String(format: String(localized: "%@ %.0f%%"), name(signal), value)
        }
        return String(localized: "高負載")
    }

    private static func primaryQualifyingName(sample: SystemLoadSample?) -> String {
        guard let sample else { return String(localized: "負載") }
        if case .value(let v) = sample.cpu, v >= 50 { return name(.cpu) }
        if case .value(let v) = sample.gpu, v >= 50 { return name(.gpu) }
        if case .value(let v) = sample.network, v >= 1_048_576 { return name(.network) }
        return String(localized: "負載")
    }

    private static func name(_ signal: SystemLoadSignal) -> String {
        switch signal {
        case .cpu: String(localized: "CPU")
        case .gpu: String(localized: "GPU")
        case .network: String(localized: "網路")
        }
    }

    private static func allUnavailable(_ sample: SystemLoadSample?) -> Bool {
        guard let sample else { return true }
        func dead(_ reading: SystemLoadReading) -> Bool {
            switch reading {
            case .unavailable, .unsupported: true
            case .value: false
            }
        }
        return dead(sample.cpu) && dead(sample.gpu) && dead(sample.network)
    }
}
