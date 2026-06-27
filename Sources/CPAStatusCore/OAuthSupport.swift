import Foundation

/// An OAuth-capable account provider exposed by the CLIProxyAPI management API.
///
/// The management server drives the whole OAuth exchange (PKCE, token swap, persistence)
/// server-side. A client only has to: request an auth URL, let the user log in via a browser,
/// relay the `code`/`state` the provider redirects back with, and poll for completion.
///
/// The flow here is fully manual: the app shows the authorization link to copy (the user may
/// open it in any browser), and for redirect-based providers the user pastes the redirected
/// `http://localhost:<port>/…` URL back into the app, which forwards it to the (possibly remote)
/// management server. Kimi uses a device flow with no redirect, so it only needs polling.
/// `callbackPort` is kept to hint the expected localhost address in the paste field.
public enum OAuthProvider: String, CaseIterable, Sendable {
    case codex
    case claude
    case antigravity
    case xai
    case kimi

    public var displayName: String {
        switch self {
        case .codex: return "Codex"
        case .claude: return "Claude"
        case .antigravity: return "Antigravity"
        case .xai: return "Grok"
        case .kimi: return "Kimi"
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
        }
    }

    /// Loopback port the upstream OAuth app redirects to, matching the hardcoded redirect URIs
    /// in CLIProxyAPI's auth packages. `nil` means the provider uses a device flow (no redirect).
    public var callbackPort: UInt16? {
        switch self {
        case .codex: return 1455          // http://localhost:1455/auth/callback
        case .claude: return 54545        // http://localhost:54545/callback
        case .antigravity: return 51121   // http://localhost:51121/oauth-callback
        case .xai: return 56121           // http://127.0.0.1:56121/callback
        case .kimi: return nil            // device flow
        }
    }

    /// Device-flow providers only need the user to authorize in a browser; the server polls
    /// the upstream token endpoint, so the client never captures a redirect.
    public var usesDeviceFlow: Bool { callbackPort == nil }

    /// Key into `ProviderCatalog` so the OAuth UI can reuse the same icon/accent as the dashboard.
    public var catalogKey: String { rawValue }

    public var hint: String {
        usesDeviceFlow ? "在浏览器中授权后自动完成" : "浏览器登录后自动回填"
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

    public init(url: String, state: String) {
        self.url = url
        self.state = state
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
