import Foundation

/// An OAuth-capable account provider exposed by the CLIProxyAPI management API.
///
/// The management server drives the whole OAuth exchange (PKCE, token swap, persistence)
/// server-side. A client requests an auth URL and polls for completion. Redirect-based
/// providers additionally relay the callback URL; device-flow providers need no callback.
///
/// The flow here is fully manual: the app shows the authorization link to copy (the user may
/// open it in any browser), and for redirect-based providers the user pastes the redirected
/// `http://localhost:<port>/…` URL back into the app, which forwards it to the (possibly remote)
/// management server. Kimi and current xAI/Grok use device flows with no redirect, so they only need polling.
/// `callbackPort` is kept to hint the expected localhost address in the paste field.
public enum OAuthProvider: String, CaseIterable, Sendable {
    case codex
    case claude
    case antigravity
    case xai
    case kimi
    case devin
    case meta
    case kimiAI = "kimi-ai"

    public var displayName: String {
        switch self {
        case .codex: return "Codex"
        case .claude: return "Claude"
        case .antigravity: return "Antigravity"
        case .xai: return "Grok"
        case .kimi: return "Kimi"
        case .devin: return "Devin"
        case .meta: return "Meta"
        case .kimiAI: return "Kimi.ai"
        }
    }

    /// Management endpoint that mints the authorization URL + session state.
    public var authPath: String {
        switch self {
        case .codex: return "/v0/management/codex-auth-url"
        case .claude: return "/v0/management/anthropic-auth-url"
        case .antigravity: return "/v0/management/antigravity-auth-url"
        case .xai: return "/v0/management/xai-auth-url"
        case .kimi: return "/v0/management/kimi-auth-url"
        case .devin: return "/v0/management/devin-auth-url"
        case .meta: return "/v0/management/meta-auth-url"
        case .kimiAI: return "/v0/management/kimi-ai-auth-url"
        }
    }

    /// Canonical provider identifier expected by `/v0/management/oauth-callback`.
    public var callbackProvider: String {
        switch self {
        case .codex: return "codex"
        case .claude: return "anthropic"
        case .antigravity: return "antigravity"
        case .xai: return "xai"
        case .kimi: return "kimi"
        case .devin: return "devin"
        case .meta: return "meta"
        case .kimiAI: return "kimi-ai"
        }
    }

    /// Loopback port the upstream OAuth app redirects to, matching the hardcoded redirect URIs
    /// in CLIProxyAPI's auth packages. Devin uses the server-configured port instead.
    public var callbackPort: UInt16? {
        switch self {
        case .codex: return 1455          // http://localhost:1455/auth/callback
        case .claude: return 54545        // http://localhost:54545/callback
        case .antigravity: return 51121   // http://localhost:51121/oauth-callback
        case .xai: return nil             // RFC 8628 device flow in current CLIProxyAPI
        case .kimi, .kimiAI, .meta: return nil
        case .devin: return nil           // Dynamic server port; still an authorization-code flow.
        }
    }

    /// Device-flow providers only need the user to authorize in a browser; the server polls
    /// the upstream token endpoint, so the client never captures a redirect.
    public var usesDeviceFlow: Bool {
        switch self {
        case .xai, .kimi, .kimiAI, .meta: return true
        default: return false
        }
    }

    /// Key into `ProviderCatalog` so the OAuth UI can reuse the same icon/accent as the dashboard.
    public var catalogKey: String { rawValue }

    public var hint: String {
        usesDeviceFlow ? "在浏览器中授权后自动完成" : "浏览器登录后粘贴回调链接"
    }
}

/// Result of polling `/v0/management/get-auth-status`.
public enum OAuthStatus: Equatable, Sendable {
    case ok
    case wait
    case error(String)
}

/// The authorization URL and opaque session state returned by an `*-auth-url` endpoint.
public struct OAuthAuthURL: Sendable {
    public let url: String
    public let state: String
    public let flow: String?
    public let userCode: String?
    public let expiresIn: Int?

    public init(
        url: String,
        state: String,
        flow: String? = nil,
        userCode: String? = nil,
        expiresIn: Int? = nil
    ) {
        self.url = url
        self.state = state
        self.flow = flow
        self.userCode = userCode
        self.expiresIn = expiresIn
    }

    public var isDeviceFlow: Bool {
        flow?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "device"
    }
}

public enum OAuthError: LocalizedError, Sendable {
    case timeout
    case invalidCallback
    case providerError(String)

    public var errorDescription: String? {
        switch self {
        case .timeout:
            return "等待授权超时，请重试。"
        case .invalidCallback:
            return "回调链接无效，请确认已复制完整的地址（应包含 code= 参数）。"
        case let .providerError(message):
            return message
        }
    }
}

/// Reject another attempt's callback before the server can associate it with this session.
public func validateOAuthCallback(_ redirectURL: String, state: String) throws {
    guard !state.isEmpty,
          let url = URLComponents(string: redirectURL.trimmingCharacters(in: .whitespacesAndNewlines)),
          url.scheme == "http", ["localhost", "127.0.0.1", "::1"].contains(url.host ?? ""),
          url.queryItems?.filter({ $0.name == "state" }).count == 1,
          url.queryItems?.first(where: { $0.name == "state" })?.value == state,
          url.queryItems?.contains(where: { ($0.name == "code" || $0.name == "error") && !($0.value ?? "").isEmpty }) == true
    else { throw OAuthError.invalidCallback }
}
