import Foundation
import Security

/// 依 pid 驗證行程簽章 Team ID（spec §4.4）。
enum CodeSignatureVerifier {
    /// `SecCodeCopyGuestWithAttributes` + `SecCodeCheckValidity`，requirement 為
    /// `anchor apple generic and certificate leaf[subject.OU] = "<teamID>"`。
    static func teamIdentifierMatches(pid: Int32, teamID: String) -> Bool {
        guard pid > 0, !teamID.isEmpty else { return false }

        var code: SecCode?
        let attrs: NSDictionary = [kSecGuestAttributePid: NSNumber(value: pid)]
        let copyStatus = SecCodeCopyGuestWithAttributes(
            nil,
            attrs,
            SecCSFlags(rawValue: 0),
            &code
        )
        guard copyStatus == errSecSuccess, let code else { return false }

        let requirement = "anchor apple generic and certificate leaf[subject.OU] = \"\(teamID)\""
        var secRequirement: SecRequirement?
        let reqStatus = SecRequirementCreateWithString(
            requirement as CFString,
            SecCSFlags(rawValue: 0),
            &secRequirement
        )
        guard reqStatus == errSecSuccess, let secRequirement else { return false }

        let validity = SecCodeCheckValidity(code, SecCSFlags(rawValue: 0), secRequirement)
        return validity == errSecSuccess
    }
}

/// 可注入的驗簽介面（測試用假實作）。
protocol CodeSignatureVerifying: Sendable {
    func teamIdentifierMatches(pid: Int32, teamID: String) -> Bool
}

struct SystemCodeSignatureVerifier: CodeSignatureVerifying {
    func teamIdentifierMatches(pid: Int32, teamID: String) -> Bool {
        CodeSignatureVerifier.teamIdentifierMatches(pid: pid, teamID: teamID)
    }
}
