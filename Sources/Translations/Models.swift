import Foundation

/// Controls how the on-device xcstrings cache is refreshed against the server.
public enum CacheRefreshPolicy: Sendable, Equatable {
    /// Refresh at most once per app launch (the first time translation mode is opened).
    case oncePerLaunch
    /// Refresh whenever the cache is older than the given interval (seconds).
    case every(TimeInterval)
    /// Always revalidate on every activation. Cheap when the ETag matches (304).
    case always
    /// Never refresh automatically. The host app is responsible for calling
    /// `Translations.refreshCache()` itself.
    case manual
}

public struct TranslationsConfiguration: Sendable {
    public let baseURL: URL
    public let projectId: String
    public let token: String
    public let defaultLocale: String?
    public let enabledInRelease: Bool
    public let matchThreshold: Double
    /// When true, match + lookup are served from the cached `.xcstrings` file
    /// in the app's caches directory and the network is only used to refresh
    /// that cache and to submit suggestions.
    public let useOfflineCache: Bool
    /// Policy controlling how often the cached `.xcstrings` is refreshed.
    public let cacheRefreshPolicy: CacheRefreshPolicy

    public init(
        baseURL: URL,
        projectId: String,
        token: String,
        defaultLocale: String? = nil,
        enabledInRelease: Bool = false,
        matchThreshold: Double = 0.4,
        useOfflineCache: Bool = true,
        cacheRefreshPolicy: CacheRefreshPolicy = .oncePerLaunch
    ) {
        self.baseURL = baseURL
        self.projectId = projectId
        self.token = token
        self.defaultLocale = defaultLocale
        self.enabledInRelease = enabledInRelease
        self.matchThreshold = matchThreshold
        self.useOfflineCache = useOfflineCache
        self.cacheRefreshPolicy = cacheRefreshPolicy
    }
}

struct ProjectInfo: Decodable {
    let id: String
    let name: String
    let sourceLocale: String
}

struct LocaleInfo: Decodable {
    let localeCode: String
}

struct LookupTranslation: Decodable {
    let localeCode: String
    let value: String?
    let state: String?
}

struct LookupResponse: Decodable {
    let id: String
    let key: String
    let sourceValue: String
    let comment: String?
    let translations: [LookupTranslation]
}

struct MatchInput: Encodable {
    let strings: [String]
    let locale: String?
    let threshold: Double
}

struct MatchResult: Decodable {
    let input: String
    let matched: Bool
    let key: String?
    let stringId: String?
    let sourceValue: String?
    let translation: String?
    let similarity: Double?
}

struct MatchResponse: Decodable {
    let matches: [MatchResult]
}

struct SuggestionInput: Encodable {
    let key: String
    let localeCode: String
    let value: String
}

struct SuggestionResponse: Decodable {
    let id: String
}

// MARK: - .xcstrings document model
//
// We decode only the fields we need; unknown keys are ignored. The on-disk
// cache stores the JSON bytes verbatim so future fields round-trip if we add
// more decoded properties later.

struct XcstringsStringUnit: Decodable {
    let state: String?
    let value: String?
}

struct XcstringsLocalization: Decodable {
    let stringUnit: XcstringsStringUnit?
}

struct XcstringsEntry: Decodable {
    let comment: String?
    let extractionState: String?
    let localizations: [String: XcstringsLocalization]?
}

struct XcstringsDoc: Decodable {
    let sourceLanguage: String?
    let version: String?
    let strings: [String: XcstringsEntry]
}
