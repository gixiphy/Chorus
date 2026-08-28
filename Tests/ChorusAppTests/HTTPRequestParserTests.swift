import Foundation
import Testing
@testable import Chorus

@Suite("HTTP request parser")
struct HTTPRequestParserTests {
    private func parse(_ text: String) -> HTTPRequestParser.Outcome {
        HTTPRequestParser.parse(Data(text.utf8))
    }

    @Test("最小 GET 請求")
    func minimalGET() {
        guard case let .complete(request) = parse("GET /v1/state HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n") else {
            Issue.record("未解析成功")
            return
        }
        #expect(request.method == "GET")
        #expect(request.path == "/v1/state")
        #expect(request.headers["host"] == "127.0.0.1")
        #expect(request.body.isEmpty)
    }

    @Test("標頭鍵一律小寫——HTTP 標頭不分大小寫")
    func headerCaseInsensitive() {
        guard case let .complete(request) = parse(
            "GET / HTTP/1.1\r\nHOST: localhost\r\nAuthorization: Bearer abc\r\n\r\n"
        ) else {
            Issue.record("未解析成功")
            return
        }
        #expect(request.headers["host"] == "localhost")
        #expect(request.headers["authorization"] == "Bearer abc")
    }

    @Test("POST 依 Content-Length 取 body")
    func postBody() {
        let body = #"{"verb":"get"}"#
        guard case let .complete(request) = parse(
            "POST /v1/command HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)"
        ) else {
            Issue.record("未解析成功")
            return
        }
        #expect(String(decoding: request.body, as: UTF8.self) == body)
    }

    @Test("body 還沒收齊時回 incomplete，不是解析失敗")
    func partialBody() {
        let outcome = parse("POST /x HTTP/1.1\r\nContent-Length: 20\r\n\r\nshort")
        #expect(outcome == .incomplete)
    }

    @Test("標頭還沒收完也是 incomplete")
    func partialHeaders() {
        #expect(parse("GET /x HTTP/1.1\r\nHost: 127.") == .incomplete)
    }

    @Test("body 比宣告的長：只取宣告的長度，多的不進 body")
    func extraBytesIgnored() {
        guard case let .complete(request) = parse(
            "POST /x HTTP/1.1\r\nContent-Length: 2\r\n\r\nABCDEF"
        ) else {
            Issue.record("未解析成功")
            return
        }
        #expect(String(decoding: request.body, as: UTF8.self) == "AB")
    }

    @Test("重複標頭以第一個為準——後到覆蓋是 request smuggling 的手法")
    func duplicateHeaders() {
        guard case let .complete(request) = parse(
            "GET / HTTP/1.1\r\nHost: 127.0.0.1\r\nHost: evil.example\r\n\r\n"
        ) else {
            Issue.record("未解析成功")
            return
        }
        #expect(request.headers["host"] == "127.0.0.1")
    }

    @Test("query string 與路徑分開")
    func queryString() {
        guard case let .complete(request) = parse("GET /v1/state?pretty=1 HTTP/1.1\r\nHost: x\r\n\r\n") else {
            Issue.record("未解析成功")
            return
        }
        #expect(request.path == "/v1/state")
        #expect(request.query == "pretty=1")
    }

    @Test("畸形輸入不當成合法請求")
    func malformed() {
        if case .complete = parse("GARBAGE\r\n\r\n") { Issue.record("請求行應被拒") }
        if case .complete = parse("GET / HTTP/1.1\r\nnocolon\r\n\r\n") { Issue.record("標頭應被拒") }
    }

    @Test("超大標頭在收齊前就拒絕，不無限累積")
    func oversizeHeaders() {
        let huge = "GET / HTTP/1.1\r\nX: " + String(repeating: "a", count: 20 * 1024)
        guard case let .malformed(reason) = parse(huge) else {
            Issue.record("應被拒絕")
            return
        }
        #expect(reason.contains("標頭"))
    }

    @Test("超大 body 拒絕")
    func oversizeBody() {
        guard case .malformed = parse("POST / HTTP/1.1\r\nContent-Length: 999999999\r\n\r\n") else {
            Issue.record("應被拒絕")
            return
        }
    }

    @Test("方法一律轉大寫")
    func methodUppercased() {
        guard case let .complete(request) = parse("post /x HTTP/1.1\r\nHost: y\r\nContent-Length: 0\r\n\r\n") else {
            Issue.record("未解析成功")
            return
        }
        #expect(request.method == "POST")
    }
}
