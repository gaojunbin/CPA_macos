import Foundation

/// A server-reported retry restriction, independent of account health and quota usage.
public struct AccountCooldown: Decodable, Equatable, Sendable {
    public let scope: String
    public let modelKey: String?
    public let reason: String
    public let retryAt: Date?

    enum CodingKeys: String, CodingKey {
        case scope, reason
        case modelKey = "model_key"
        case retryAt = "retry_at"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        scope = try container.decode(String.self, forKey: .scope)
        modelKey = try container.decodeIfPresent(String.self, forKey: .modelKey)
        reason = try container.decodeIfPresent(String.self, forKey: .reason) ?? "unknown"
        let rawDate = try container.decodeIfPresent(String.self, forKey: .retryAt)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let fractional = rawDate.flatMap(formatter.date(from:))
        formatter.formatOptions = [.withInternetDateTime]
        retryAt = fractional ?? rawDate.flatMap(formatter.date(from:))
    }

    public var isActive: Bool { retryAt.map { $0 > Date() } ?? false }

    public var reasonDescription: String {
        switch reason {
        case "credential_quota": return "账号额度冷却"
        case "quota": return "模型额度冷却"
        case "cloudflare_challenge": return "Cloudflare 验证限制"
        case "unauthorized", "invalid_grant": return "授权失效"
        case "payment_required": return "计费限制"
        case "model_not_supported": return "模型不受支持"
        case "not_found": return "上游资源不存在"
        case "transient_error": return "上游暂时异常"
        default: return "暂时受限"
        }
    }
}
