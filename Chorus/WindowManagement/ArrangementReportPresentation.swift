import ChorusCore
import Foundation

extension ArrangementReport {
    var summaryText: String {
        if hasPermissionIssue {
            if !didMoveAnyWindow {
                return String(localized: "沒有視窗被移動：需要輔助使用權限")
            }
            return String(localized: "已排列 \(appliedCount)/\(items.count) 個視窗，需要輔助使用權限")
        }

        if arrangement == nil {
            if isComplete {
                return String(localized: "已還原 \(appliedCount) 個視窗")
            }
            return String(localized: "整組還原未完成：\(failedItems.count) 個視窗失敗")
        }

        if isComplete {
            var summary = String(localized: "已排列 \(appliedCount) 個視窗")
            if constrainedCount > 0 {
                summary += String(localized: "，\(constrainedCount) 個受最小尺寸限制")
            }
            if emptySlots > 0 {
                summary += String(localized: "，其餘 \(emptySlots) 個位置留空")
            }
            return summary
        }

        guard didMoveAnyWindow else {
            return String(localized: "沒有視窗被移動：排列未完成")
        }
        var summary = String(localized: "已排列 \(appliedCount)/\(items.count) 個視窗")
        if constrainedCount > 0 {
            summary += String(localized: "，\(constrainedCount) 個受最小尺寸限制")
        }
        if emptySlots > 0 {
            summary += String(localized: "，另有 \(emptySlots) 個位置留空")
        }
        return summary
    }

    var issueLines: [String] {
        items.compactMap { item -> String? in
            guard item.status != .applied else { return nil }
            return String(localized: "\(item.appName)：\(item.status.shortDescription)")
        }
        .prefix(3)
        .map(\.self)
    }

    var outcome: WindowManager.Outcome {
        if hasPermissionIssue {
            return .permissionRequired
        }
        if arrangement == nil {
            return isComplete ? .restored : .partial
        }
        if isComplete {
            return constrainedCount > 0 ? .constrained : .applied
        }
        return didMoveAnyWindow ? .partial : .failed(String(localized: "排列未完成"))
    }

    private var hasPermissionIssue: Bool {
        items.contains { item in
            if case .skipped(.permissionRevoked) = item.status {
                return true
            }
            return false
        }
    }
}

extension ArrangementReport.Status {
    var shortDescription: String {
        switch self {
        case .applied:
            return String(localized: "已套用")
        case .constrained:
            return String(localized: "最小尺寸超過區域")
        case .reverted(let reason):
            return String(localized: "\(localizedReportReason(reason))，已回復原位")
        case .revertFailed(let reason):
            return String(localized: "\(localizedReportReason(reason))，且無法回復原位")
        case .failed(let reason):
            return localizedReportReason(reason)
        case .skipped(.timeBudget):
            return String(localized: "超過批次時間限制")
        case .skipped(.topologyChanged):
            return String(localized: "螢幕配置已改變")
        case .skipped(.permissionRevoked):
            return String(localized: "需要輔助使用權限")
        }
    }
}

private func localizedReportReason(_ reason: String) -> String {
    switch reason {
    case ArrangementReport.timeoutReason:
        return String(localized: "操作逾時")
    case "目標視窗已關閉":
        return String(localized: "目標視窗已關閉")
    case "已被移動，略過":
        return String(localized: "已被移動，略過")
    case "unsupported":
        return String(localized: "此視窗不支援排列")
    case "noTarget":
        return String(localized: "沒有可排列的視窗")
    case "permissionRequired":
        return String(localized: "需要輔助使用權限")
    default:
        return reason
    }
}
