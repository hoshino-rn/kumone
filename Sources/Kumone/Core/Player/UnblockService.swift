import Foundation
import os.log

/// Resolves gray tracks from the direct pyncmd source, then built-in search
/// providers when pyncmd cannot serve the original song ID.
enum UnblockService {
    private static let log = Logger(subsystem: "sb.moe.kumone", category: "audio-source")
    private static let httpClient = AudioSourceClient.shared
    private static let fallbackProviders: [any AudioSourceProvider] = [
        KugouAudioSourceProvider(),
        KuwoAudioSourceProvider(),
    ]

    struct Resolution {
        let source: ResolvedAudioSource?
        let attemptedSources: Set<AudioSourceID>
    }

    static func resolve(
        _ track: Track,
        enabledSources: Set<AudioSourceID>,
        excluding attemptedSources: Set<AudioSourceID>
    ) async -> Resolution {
        var newlyAttemptedSources = Set<AudioSourceID>()
        guard !Task.isCancelled else { return Resolution(source: nil, attemptedSources: []) }
        if enabledSources.contains(.pyncmd), !attemptedSources.contains(.pyncmd) {
            newlyAttemptedSources.insert(.pyncmd)
            do {
                return Resolution(
                    source: try await pyncmd(track),
                    attemptedSources: newlyAttemptedSources
                )
            } catch {
                if Task.isCancelled { return Resolution(source: nil, attemptedSources: newlyAttemptedSources) }
                logFailure(source: .pyncmd, operation: "resolve", error: error)
            }
        }

        for provider in fallbackProviders where enabledSources.contains(provider.id)
            && !attemptedSources.contains(provider.id) {
            guard !Task.isCancelled else { break }
            newlyAttemptedSources.insert(provider.id)
            do {
                if let resolved = try await provider.resolve(track: track) {
                    return Resolution(source: resolved, attemptedSources: newlyAttemptedSources)
                }
            } catch {
                if Task.isCancelled { break }
                logFailure(source: provider.id, operation: "resolve", error: error)
            }
        }
        return Resolution(source: nil, attemptedSources: newlyAttemptedSources)
    }

    /// Resolves through a self-hosted pyncmd-compatible server. The server is
    /// addressed directly (pyncmd protocol) instead of the old public
    /// gdstudio.xyz proxy, so the same account/login state kept by the local
    /// service supplies the URL. Several endpoints (LAN / EasyTier) are tried
    /// in order.
    private static func pyncmd(_ track: Track) async throws -> ResolvedAudioSource {
        let endpoints = PyncmdConfiguration.endpoints()
        guard !endpoints.isEmpty else {
            throw AudioSourceProviderError.missingEndpoint
        }
        let token = PyncmdConfiguration.effectiveToken
        var lastError: Error = AudioSourceProviderError.missingEndpoint

        for endpoint in endpoints {
            do {
                let resolved = try await pyncmd(track, endpoint: endpoint, token: token)
                PyncmdConfiguration.remember(endpoint)
                return resolved
            } catch {
                if Task.isCancelled { throw error }
                lastError = error
                log.error(
                    "source=pyncmd endpoint=\(endpoint.baseURL.host ?? "", privacy: .public) error=\(error.localizedDescription, privacy: .public)"
                )
            }
        }
        throw lastError
    }

    private static func pyncmd(
        _ track: Track,
        endpoint: PyncmdEndpoint,
        token: String?
    ) async throws -> ResolvedAudioSource {
        var headers: [String: String] = [:]
        if let token {
            headers["X-Pyncmd-Token"] = token
        }

        // exhigh (320 kbps) first; a logged-out or non-VIP account may only be
        // allowed the standard level. A network/auth failure is not fixed by
        // lowering the level, so it is rethrown immediately.
        for level in ["exhigh", "standard"] {
            guard let url = endpoint.url(
                path: "api/pyncm",
                query: [
                    URLQueryItem(name: "module", value: "track"),
                    URLQueryItem(name: "method", value: "GetTrackAudioV1"),
                    URLQueryItem(name: "song_ids", value: String(track.id)),
                    URLQueryItem(name: "level", value: level),
                ]
            ) else {
                throw AudioSourceProviderError.invalidURL
            }

            let data = try await httpClient.data(
                from: url,
                source: .pyncmd,
                operation: "resolve-\(level)",
                headers: headers,
                timeout: 5
            )
            if let resolved = try parsePyncmdAudio(data) {
                return resolved
            }
        }
        throw AudioSourceProviderError.missingStreamURL
    }

    private static func parsePyncmdAudio(_ data: Data) throws -> ResolvedAudioSource? {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AudioSourceProviderError.invalidResponse
        }
        if let code = object["code"] as? Int, code != 200 {
            let message = object["message"] as? String ?? "code \(code)"
            throw AudioSourceProviderError.serverRejected(message)
        }
        guard let songs = object["data"] as? [[String: Any]], let song = songs.first else {
            throw AudioSourceProviderError.invalidResponse
        }
        if let code = song["code"] as? Int, code != 200 {
            return nil
        }
        // A trial-only URL covers a short preview, not the track that was
        // requested; leave it for the other sources.
        if let trial = song["freeTrialInfo"], !(trial is NSNull) {
            return nil
        }
        guard let urlString = song["url"] as? String, !urlString.isEmpty,
              let url = URL(string: urlString) else {
            return nil
        }
        return ResolvedAudioSource(
            id: .pyncmd,
            displayName: AudioSourceID.pyncmd.displayName,
            url: url
        )
    }

    private static func logFailure(source: AudioSourceID, operation: String, error: Error) {
        log.error(
            "source=\(source.rawValue, privacy: .public) operation=\(operation, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
        )
    }
}
