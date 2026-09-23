import ChorusCore
import Foundation
import Testing

/// 縮短版的真實 .ips：第一行 header、第二行起 body。frame 0 是 crash 點。
private let sampleIPS = """
{"app_name":"Chorus","timestamp":"2026-09-23 11:27:44.00 +0800","app_version":"1.11.0","build_version":"116","bug_type":"309","os_version":"macOS 26.0 (25A123)","name":"Chorus"}
{
  "procName" : "Chorus",
  "exception" : {"codes":"0x0000000000000001, 0x00000001c16c415c","rawCodes":[1,7540064604],"type":"EXC_BREAKPOINT","signal":"SIGTRAP"},
  "faultingThread" : 1,
  "threads" : [
    {"id":1,"frames":[{"imageOffset":100,"imageIndex":0}]},
    {"id":2,"triggered":true,"frames":[
      {"imageOffset":1053020,"symbol":"_assertionFailure(_:_:file:line:flags:)","symbolLocation":208,"imageIndex":1},
      {"imageOffset":4096,"imageIndex":0},
      {"imageOffset":8192,"imageIndex":0}
    ]}
  ],
  "usedImages" : [
    {"name":"Chorus","uuid":"11111111-2222-3333-4444-555555555555","base":4294967296,"path":"/Applications/Chorus.app/Contents/MacOS/Chorus"},
    {"name":"libswiftCore.dylib","uuid":"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee","base":8000000000,"path":"/usr/lib/swift/libswiftCore.dylib"}
  ]
}
"""

@Suite("CrashReportSummary：.ips 解析")
struct CrashReportSummaryIPSTests {
    @Test("header 的時間與 build、body 的 exception 與 faultingThread 前幾格")
    func parsesIPS() throws {
        let summary = try #require(CrashReportSummary.parseIPS(sampleIPS))
        #expect(summary.kind == .ips)
        #expect(summary.appVersion == "116")
        #expect(summary.exception == "EXC_BREAKPOINT (SIGTRAP)")
        #expect(summary.topFrames == [
            "libswiftCore.dylib _assertionFailure(_:_:file:line:flags:) + 208",
            "Chorus + 4096",
            "Chorus + 8192",
        ])
        let components = Calendar(identifier: .gregorian).dateComponents(
            in: TimeZone(secondsFromGMT: 8 * 3600)!, from: summary.occurredAt
        )
        #expect(components.year == 2026 && components.month == 9 && components.day == 23)
        #expect(components.hour == 11 && components.minute == 27 && components.second == 44)
        #expect(summary.fileName == "")
    }

    @Test("最多留 maxFrames 格")
    func capsFrames() throws {
        let manyFrames = (0..<12).map { #"{"imageOffset":\#($0),"imageIndex":0}"# }.joined(separator: ",")
        let text = sampleIPS.replacingOccurrences(
            of: #"{"imageOffset":1053020,"symbol":"_assertionFailure(_:_:file:line:flags:)","symbolLocation":208,"imageIndex":1},"#,
            with: manyFrames + ","
        )
        let summary = try #require(CrashReportSummary.parseIPS(text))
        #expect(summary.topFrames.count == CrashReportSummary.maxFrames)
        #expect(summary.topFrames.first == "Chorus + 0")
    }

    @Test("缺 exception 或 faultingThread 仍回摘要；不是兩行 JSON 就回 nil")
    func tolerant() throws {
        let noException = sampleIPS
            .replacingOccurrences(of: #""exception" : {"codes":"0x0000000000000001, 0x00000001c16c415c","rawCodes":[1,7540064604],"type":"EXC_BREAKPOINT","signal":"SIGTRAP"},"#, with: "")
            .replacingOccurrences(of: #""faultingThread" : 1,"#, with: "")
        let summary = try #require(CrashReportSummary.parseIPS(noException))
        #expect(summary.exception == nil)
        #expect(summary.topFrames == ["Chorus + 100"])   // 沒 faultingThread 就拿第 0 條
        #expect(CrashReportSummary.parseIPS("not json") == nil)
        #expect(CrashReportSummary.parseIPS("{}") == nil)
        #expect(CrashReportSummary.parseIPS("{}\n[1,2]") == nil)
    }
}

private let sampleMetricKit = """
{"version":"1.0.0",
 "diagnosticMetaData":{"appBuildVersion":"116","appVersion":"1.11.0","exceptionType":1,"signal":11,"exceptionCode":0,"terminationReason":"Namespace SIGNAL, Code 11","osVersion":"macOS 26.0 (25A123)","platformArchitecture":"arm64"},
 "callStackTree":{"callStackPerThread":true,"callStacks":[
   {"threadAttributed":false,"callStackRootFrames":[{"binaryUUID":"X","offsetIntoBinaryTextSegment":1,"binaryName":"other","address":1}]},
   {"threadAttributed":true,"callStackRootFrames":[
     {"binaryUUID":"11111111-2222-3333-4444-555555555555","offsetIntoBinaryTextSegment":10,"sampleCount":1,"binaryName":"dyld","address":10,
      "subFrames":[{"binaryUUID":"11111111-2222-3333-4444-555555555555","offsetIntoBinaryTextSegment":20,"binaryName":"Chorus","address":20,
        "subFrames":[{"binaryUUID":"11111111-2222-3333-4444-555555555555","offsetIntoBinaryTextSegment":30,"binaryName":"Chorus","address":30}]}]}
   ]}
 ]}}
"""

@Suite("CrashReportSummary：MetricKit 解析")
struct CrashReportSummaryMetricKitTests {
    @Test("取 threadAttributed 的那條，鏈尾（crash 點）在前")
    func parsesMetricKit() throws {
        let at = Date(timeIntervalSince1970: 1_800_000_000)
        let summary = try #require(CrashReportSummary.parseMetricKit(Data(sampleMetricKit.utf8), kind: .crash, occurredAt: at))
        #expect(summary.kind == .crash)
        #expect(summary.occurredAt == at)
        #expect(summary.appVersion == "116")
        #expect(summary.exception == "exceptionType=1 signal=11 Namespace SIGNAL, Code 11")
        #expect(summary.topFrames == ["Chorus + 30", "Chorus + 20", "dyld + 10"])
    }

    @Test("沒有 callStackTree 也回摘要；非 JSON 回 nil")
    func tolerant() throws {
        let summary = try #require(CrashReportSummary.parseMetricKit(
            Data(#"{"diagnosticMetaData":{"appBuildVersion":"7"}}"#.utf8), kind: .hang, occurredAt: Date()
        ))
        #expect(summary.appVersion == "7")
        #expect(summary.exception == nil)
        #expect(summary.topFrames.isEmpty)
        #expect(CrashReportSummary.parseMetricKit(Data("nope".utf8), kind: .crash, occurredAt: Date()) == nil)
    }
}
