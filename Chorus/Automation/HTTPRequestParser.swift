import Foundation

/// 極簡 HTTP/1.1 請求解析。只支援自動化介面實際會收到的形狀
/// （GET／POST、`Content-Length` body、無 chunked 編碼）。
///
/// 純函式、不碰網路——因此可以完整單元測試。這很重要：這是**唯一**一段
/// 直接處理外部輸入的程式碼，parser 的邊界條件出錯就是安全問題。
enum HTTPRequestParser {
    struct Request: Equatable {
        let method: String
        /// 已去掉 query string 的路徑。
        let path: String
        let query: String?
        /// 標頭鍵一律小寫（HTTP 標頭不分大小寫）。
        let headers: [String: String]
        let body: Data
    }

    enum Outcome: Equatable {
        /// 資料還沒收齊，繼續讀。
        case incomplete
        case malformed(String)
        case complete(Request)
    }

    private static let headerTerminator = Data("\r\n\r\n".utf8)
    private static let maxHeaderBytes = 16 * 1024
    private static let maxBodyBytes = 256 * 1024

    static func parse(_ data: Data) -> Outcome {
        guard let terminator = data.range(of: headerTerminator) else {
            // 還沒看到標頭結尾。超過上限就不可能是合法請求了，別無限累積。
            return data.count > maxHeaderBytes ? .malformed("標頭過長") : .incomplete
        }
        let headerData = data[data.startIndex..<terminator.lowerBound]
        guard headerData.count <= maxHeaderBytes else { return .malformed("標頭過長") }
        guard let headerText = String(data: headerData, encoding: .utf8) else {
            return .malformed("標頭不是合法的 UTF-8")
        }

        var lines = headerText.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { return .malformed("空請求") }
        let requestLine = lines.removeFirst().split(separator: " ", omittingEmptySubsequences: true)
        guard requestLine.count >= 3 else { return .malformed("請求行格式錯誤") }
        let method = String(requestLine[0]).uppercased()
        let rawTarget = String(requestLine[1])

        var headers: [String: String] = [:]
        for line in lines where !line.isEmpty {
            guard let separator = line.firstIndex(of: ":") else {
                return .malformed("標頭格式錯誤：\(line)")
            }
            let key = line[line.startIndex..<separator]
                .trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: separator)...]
                .trimmingCharacters(in: .whitespaces)
            // 重複標頭以第一個為準：後到的覆蓋是 request smuggling 的常見手法
            if headers[key] == nil {
                headers[key] = value
            }
        }

        let declaredLength = headers["content-length"].flatMap(Int.init) ?? 0
        guard declaredLength >= 0 else { return .malformed("Content-Length 為負數") }
        guard declaredLength <= maxBodyBytes else { return .malformed("body 過大") }

        let bodyStart = terminator.upperBound
        let available = data.distance(from: bodyStart, to: data.endIndex)
        guard available >= declaredLength else { return .incomplete }
        let bodyEnd = data.index(bodyStart, offsetBy: declaredLength)
        let body = Data(data[bodyStart..<bodyEnd])

        let (path, query) = splitTarget(rawTarget)
        return .complete(Request(
            method: method,
            path: path,
            query: query,
            headers: headers,
            body: body
        ))
    }

    private static func splitTarget(_ target: String) -> (path: String, query: String?) {
        guard let mark = target.firstIndex(of: "?") else { return (target, nil) }
        return (
            String(target[target.startIndex..<mark]),
            String(target[target.index(after: mark)...])
        )
    }
}
