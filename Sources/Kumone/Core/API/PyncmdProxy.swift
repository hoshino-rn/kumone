import Foundation
import os.log

enum PyncmdProxyError: LocalizedError {
    case notConfigured
    case invalidResponse
    case http(Int)
    case needsLogin
    case sessionRejected
    case allEndpointsFailed(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return String(localized: "未配置 pyncmd 服务器，请在 设置 ▸ 音源 中填写地址")
        case .invalidResponse:
            return String(localized: "pyncmd 服务器返回了无法识别的响应")
        case .http(let status):
            if status == 401 || status == 403 {
                return String(localized: "pyncmd 访问令牌无效（HTTP \(status)）")
            }
            return String(localized: "pyncmd 服务器返回 HTTP \(status)")
        case .needsLogin:
            return String(localized: "pyncmd 服务未登录，请先在 pyncmd 控制台登录")
        case .sessionRejected:
            return String(localized: "pyncmd 未能接受 Kumone 的登录态，请重试")
        case .allEndpointsFailed(let detail):
            return detail.isEmpty
                ? String(localized: "无法连接 pyncmd 服务器，请确认服务已启动")
                : String(localized: "无法连接 pyncmd 服务器：\(detail)")
        }
    }
}

/// Hands this app's own API calls to the user's pyncmd service.
///
/// The service keeps its own NetEase session (logged in on the computer that
/// runs it), so requests made through it carry that session's device and
/// cookies instead of this app's. That is the split used to keep playback off
/// the account's direct session while the app itself still signs in for its
/// playlists.
enum PyncmdProxy {
    private static let log = Logger(subsystem: "sb.moe.kumone", category: "pyncmd")

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 20
        return URLSession(configuration: configuration)
    }()

    /// Paths that must stay on the app's own session.
    ///
    /// Signing in has to run here to obtain this app's cookies, and the
    /// account identity plus the playlist reads are what its library needs
    /// before pyncmd is involved. Everything else — catalog, playback URLs,
    /// lyrics, search and account writes — is served by pyncmd.
    private static let directPrefixes = [
        "/login",
        "/logout",
        "/w/login",
        "/sms",
        "/nuser/account",
        "/user/playlist",
        "/v6/playlist/detail",
        "/song/like/get",
    ]

    static func keepsDirectSession(path: String) -> Bool {
        directPrefixes.contains { path.hasPrefix($0) }
    }

    /// What `/api/session` reports: the account and the cookies Kumone needs
    /// to adopt the service's login without a second scan.
    struct Session: Decodable {
        let loggedIn: Bool
        let nickname: String?
        let uid: Int?
        let cookies: [String: String]?

        private enum CodingKeys: String, CodingKey {
            case loggedIn = "logged_in"
            case nickname, uid, cookies
        }
    }

    /// POSTs the encoded envelope to `api/netease`, trying each configured
    /// endpoint in order. `body` is `{ path, mode, payload, cookies }`.
    static func send(body: Data, path: String) async throws -> Data {
        let endpoints = PyncmdConfiguration.endpoints()
        guard !endpoints.isEmpty else { throw PyncmdProxyError.notConfigured }
        var lastError: Error = PyncmdProxyError.notConfigured

        for endpoint in endpoints {
            do {
                let data = try await perform(
                    endpoint: endpoint, path: "api/netease", method: "POST", body: body
                )
                // 301 is pyncmd's own session saying it needs a login on the
                // computer. Surface that instead of the app's "需要登录".
                if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   object["code"] as? Int == 301 {
                    throw PyncmdProxyError.needsLogin
                }
                PyncmdConfiguration.remember(endpoint)
                return data
            } catch {
                if Task.isCancelled || error is CancellationError {
                    throw CancellationError()
                }
                if let proxyError = error as? PyncmdProxyError,
                   case .needsLogin = proxyError {
                    throw proxyError
                }
                lastError = error
                log.error(
                    "endpoint=\(endpoint.baseURL.host ?? "", privacy: .public) path=\(path, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
                )
            }
        }

        throw failure(lastError)
    }

    /// Reads the service's current login so the app can adopt it.
    static func fetchSession(timeout: TimeInterval = 20) async throws -> Session {
        let endpoints = PyncmdConfiguration.endpoints()
        guard !endpoints.isEmpty else { throw PyncmdProxyError.notConfigured }
        var lastError: Error = PyncmdProxyError.notConfigured

        for endpoint in endpoints {
            do {
                let data = try await perform(
                    endpoint: endpoint, path: "api/session", method: "GET", body: nil,
                    timeout: timeout
                )
                let session = try JSONDecoder().decode(Session.self, from: data)
                PyncmdConfiguration.remember(endpoint)
                return session
            } catch {
                if Task.isCancelled || error is CancellationError {
                    throw CancellationError()
                }
                lastError = error
                log.error(
                    "endpoint=\(endpoint.baseURL.host ?? "", privacy: .public) session error=\(error.localizedDescription, privacy: .public)"
                )
            }
        }

        throw failure(lastError)
    }

    /// Writes the app's current login into pyncmd, so both sides use one
    /// account without signing in twice.
    static func pushSession(cookies: [String: String]) async throws {
        guard let token = cookies["MUSIC_U"], !token.isEmpty else {
            throw MusicAPIError.needLogin
        }
        let body = try JSONSerialization.data(withJSONObject: [
            "MUSIC_U": token,
            "__csrf": cookies["__csrf"] ?? "",
        ])
        let endpoints = PyncmdConfiguration.endpoints()
        guard !endpoints.isEmpty else { throw PyncmdProxyError.notConfigured }
        var lastError: Error = PyncmdProxyError.notConfigured

        for endpoint in endpoints {
            do {
                let data = try await perform(
                    endpoint: endpoint, path: "api/login/cookie", method: "POST", body: body
                )
                guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    throw PyncmdProxyError.invalidResponse
                }
                guard object["logged_in"] as? Bool == true else {
                    throw PyncmdProxyError.sessionRejected
                }
                PyncmdConfiguration.remember(endpoint)
                return
            } catch {
                if Task.isCancelled || error is CancellationError {
                    throw CancellationError()
                }
                if let proxyError = error as? PyncmdProxyError,
                   case .sessionRejected = proxyError {
                    throw proxyError
                }
                lastError = error
                log.error(
                    "endpoint=\(endpoint.baseURL.host ?? "", privacy: .public) push error=\(error.localizedDescription, privacy: .public)"
                )
            }
        }

        throw failure(lastError)
    }

    private static func perform(
        endpoint: PyncmdEndpoint, path: String, method: String, body: Data?,
        timeout: TimeInterval = 20
    ) async throws -> Data {
        guard let url = endpoint.url(path: path, query: []) else {
            throw PyncmdProxyError.invalidResponse
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.timeoutInterval = timeout
        if body != nil {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if let token = PyncmdConfiguration.effectiveToken, !token.isEmpty {
            request.setValue(token, forHTTPHeaderField: "X-Pyncmd-Token")
        }
        let (data, response) = try await session.data(for: request)
        if Task.isCancelled { throw CancellationError() }
        guard let http = response as? HTTPURLResponse else {
            throw PyncmdProxyError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw PyncmdProxyError.http(http.statusCode)
        }
        return data
    }

    /// An authentication refusal is about the token, not the address, so keep
    /// that answer instead of wrapping it as an unreachable server.
    private static func failure(_ lastError: Error) -> Error {
        if let proxyError = lastError as? PyncmdProxyError,
           case .http(let status) = proxyError,
           status == 401 || status == 403 {
            return proxyError
        }
        return PyncmdProxyError.allEndpointsFailed(lastError.localizedDescription)
    }
}
