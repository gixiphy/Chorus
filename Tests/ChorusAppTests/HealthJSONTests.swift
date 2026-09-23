import Foundation
import Testing
@testable import Chorus

@Suite("/v1/health JSON")
struct HealthJSONTests {
    @Test("含 lastExit 與 crashReports 欄位，count 是整數、recent 是陣列")
    func crashFields() throws {
        let text = AutomationHTTPTransport.healthJSON()
        let object = try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        let lastExit = try #require(object["lastExit"] as? String)
        #expect(["clean", "crash", "firstLaunch", "unknown"].contains(lastExit))
        let crashReports = try #require(object["crashReports"] as? [String: Any])
        #expect(crashReports["count"] is Int)
        #expect(crashReports["recent"] is [[String: Any]])
    }
}
