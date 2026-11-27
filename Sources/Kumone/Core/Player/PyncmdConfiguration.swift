import Foundation

/// A base address of a pyncmd-compatible server, e.g. `http://10.126.126.1:8090`.
struct PyncmdEndpoint: Hashable {
    let baseURL: URL

    init?(_ raw: String) {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        if !value.contains("://") {
            value = "http://" + value
        }
        while value.hasSuffix("/") {
            value.removeLast()
        }
        guard let url = URL(string: value), url.scheme != nil, url.host != nil else {
            return nil
        }
        baseURL = url
    }

    var displayName: String { baseURL.absoluteString }

    /// Builds `{base}/{path}?{query}`; the base may itself carry a path prefix.
    func url(path: String, query: [URLQueryItem]) -> URL? {
        let target = path
            .split(separator: "/", omittingEmptySubsequences: true)
            .reduce(baseURL) { partial, component in
                partial.appendingPathComponent(String(component))
            }
        var components = URLComponents(url: target, resolvingAgainstBaseURL: false)
        components?.queryItems = query
        return components?.url
    }
}

/// Where the app finds the user's self-hosted pyncmd service.
///
/// The endpoint list is read from `UserDefaults` (editable in Settings ▸ 音源),
/// falling back to the value baked into Info.plist at build time. Several
/// addresses may be supplied (LAN first, EasyTier second, for example): they are
/// tried in order, and the last one that answered is tried first next time.
enum PyncmdConfiguration {
    static let endpointsKey = "settings.pyncmdEndpoints"
    static let tokenKey = "settings.pyncmdToken"
    static let lastWorkingEndpointKey = "settings.pyncmdLastWorkingEndpoint"
    static let dataProxyKey = "settings.pyncmdDataProxy"

    /// The macOS app can talk to a server running on the same machine. On iOS
    /// this is the phone itself, so builds for a device should inject a LAN or
    /// EasyTier address (Settings also accepts one at runtime).
    static let defaultEndpointText = "http://127.0.0.1:8090"

    private static let infoBaseURLKey = "KumonePyncmdBaseURL"
    private static let infoTokenKey = "KumonePyncmdToken"

    static var builtInEndpointText: String {
        (Bundle.main.object(forInfoDictionaryKey: infoBaseURLKey) as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The endpoint text in effect before parsing: the user's setting when set,
    /// otherwise the build-time value, otherwise the loopback default.
    static var effectiveEndpointText: String {
        let stored = UserDefaults.standard.string(forKey: endpointsKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !stored.isEmpty {
            return stored
        }
        let builtIn = builtInEndpointText
        return builtIn.isEmpty ? defaultEndpointText : builtIn
    }

    /// Parses a comma/semicolon/whitespace separated list. An empty `text`
    /// means "use the effective setting", which keeps the test button useful
    /// when the field is blank but a build-time address is configured.
    static func endpoints(from text: String? = nil) -> [PyncmdEndpoint] {
        var raw = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if raw.isEmpty {
            raw = effectiveEndpointText
        }

        var result: [PyncmdEndpoint] = []
        var seen = Set<String>()
        for piece in raw.split(whereSeparator: { $0 == "," || $0 == ";" || $0.isWhitespace }) {
            guard let endpoint = PyncmdEndpoint(String(piece)) else { continue }
            if seen.insert(endpoint.baseURL.absoluteString).inserted {
                result.append(endpoint)
            }
        }

        let lastWorking = UserDefaults.standard.string(forKey: lastWorkingEndpointKey)
        if let lastWorking,
           let index = result.firstIndex(where: { $0.baseURL.absoluteString == lastWorking }),
           index > 0 {
            result.insert(result.remove(at: index), at: 0)
        }
        return result
    }

    static var effectiveToken: String? {
        let stored = UserDefaults.standard.string(forKey: tokenKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let value = stored.isEmpty ? builtInToken : stored
        return value.isEmpty ? nil : value
    }

    /// Whether catalog and playback requests are handed to the pyncmd
    /// service instead of this app's own upstream session.
    ///
    /// An explicit choice always wins. Before one exists, the proxy follows
    /// the address: a build-time or user-entered endpoint means the app was
    /// set up around pyncmd, while no address at all keeps it off (unit tests
    /// and plain SwiftPM runs have no Info.plist entry).
    static var isDataProxyEnabled: Bool {
        if let stored = UserDefaults.standard.object(forKey: dataProxyKey) as? Bool {
            return stored
        }
        return hasConfiguredEndpoint
    }

    static func setDataProxyEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: dataProxyKey)
    }

    static var hasConfiguredEndpoint: Bool {
        if !builtInEndpointText.isEmpty { return true }
        let stored = UserDefaults.standard.string(forKey: endpointsKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return !stored.isEmpty
    }

    static func remember(_ endpoint: PyncmdEndpoint) {
        UserDefaults.standard.set(
            endpoint.baseURL.absoluteString,
            forKey: lastWorkingEndpointKey
        )
    }

    private static var builtInToken: String {
        (Bundle.main.object(forInfoDictionaryKey: infoTokenKey) as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
