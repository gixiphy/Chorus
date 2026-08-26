import Foundation

/// 線上格式的最外層：協定版本 + 訊息。
public struct Envelope: Codable, Sendable {
    public let v: Int
    public let msg: SyncMessage

    public init(msg: SyncMessage) {
        v = ChorusProtocol.version
        self.msg = msg
    }
}

public enum EnvelopeDecodeError: Error, Equatable {
    /// 對方協定版本較新且訊息無法解析 —— 忽略即可，不應斷線。
    case unsupportedVersion(Int)
    /// 資料毀損或非本協定。
    case malformed
}

public enum EnvelopeCoding {
    /// 只帶版本欄位的探測結構：訊息解不開時仍能讀出版本。
    private struct VersionProbe: Codable {
        let v: Int
    }

    public static func encode(_ envelope: Envelope) throws -> Data {
        try JSONEncoder().encode(envelope)
    }

    public static func decode(_ data: Data) -> Result<Envelope, EnvelopeDecodeError> {
        let decoder = JSONDecoder()
        if let envelope = try? decoder.decode(Envelope.self, from: data) {
            return .success(envelope)
        }
        // 訊息解不開：分辨「較新版本」與「壞資料」
        if let probe = try? decoder.decode(VersionProbe.self, from: data) {
            if probe.v > ChorusProtocol.version {
                return .failure(.unsupportedVersion(probe.v))
            }
        }
        return .failure(.malformed)
    }
}
