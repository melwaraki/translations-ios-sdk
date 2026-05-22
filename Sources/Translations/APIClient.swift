import Foundation

public enum TranslationsError: Error, LocalizedError {
    case notConfigured
    case httpError(status: Int, message: String?)
    case transport(Error)
    case decoding(Error)

    public var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Translations.configure(...) was not called."
        case .httpError(let status, let message):
            return "HTTP \(status): \(message ?? "request failed")"
        case .transport(let err):
            return err.localizedDescription
        case .decoding(let err):
            return "Decoding error: \(err.localizedDescription)"
        }
    }
}

final class APIClient: @unchecked Sendable {
    private let configuration: TranslationsConfiguration
    private let session: URLSession

    init(configuration: TranslationsConfiguration, session: URLSession = .shared) {
        self.configuration = configuration
        self.session = session
    }

    private func makeRequest(path: String, method: String, body: Data? = nil, query: [URLQueryItem] = []) -> URLRequest {
        var url = configuration.baseURL.appendingPathComponent(path)
        if !query.isEmpty {
            var comps = URLComponents(url: url, resolvingAgainstBaseURL: false)!
            comps.queryItems = query
            url = comps.url!
        }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("Bearer \(configuration.token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if body != nil {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = body
        }
        return req
    }

    private func send<T: Decodable>(_ request: URLRequest, as type: T.Type) async throws -> T {
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw TranslationsError.transport(error)
        }
        guard let http = response as? HTTPURLResponse else {
            throw TranslationsError.httpError(status: -1, message: "no response")
        }
        if !(200..<300).contains(http.statusCode) {
            let msg = String(data: data, encoding: .utf8)
            throw TranslationsError.httpError(status: http.statusCode, message: msg)
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw TranslationsError.decoding(error)
        }
    }

    func match(strings: [String], locale: String?) async throws -> [MatchResult] {
        let path = "v1/projects/\(configuration.projectId)/match"
        let body = MatchInput(strings: strings, locale: locale, threshold: configuration.matchThreshold)
        let data = try JSONEncoder().encode(body)
        let req = makeRequest(path: path, method: "POST", body: data)
        let resp: MatchResponse = try await send(req, as: MatchResponse.self)
        return resp.matches
    }

    func lookup(key: String, locale: String?) async throws -> LookupResponse {
        let path = "v1/projects/\(configuration.projectId)/lookup"
        var query = [URLQueryItem(name: "key", value: key)]
        if let locale = locale { query.append(URLQueryItem(name: "locale", value: locale)) }
        let req = makeRequest(path: path, method: "GET", query: query)
        return try await send(req, as: LookupResponse.self)
    }

    func submitSuggestion(key: String, localeCode: String, value: String) async throws -> SuggestionResponse {
        let path = "v1/projects/\(configuration.projectId)/suggestions"
        let body = SuggestionInput(key: key, localeCode: localeCode, value: value)
        let data = try JSONEncoder().encode(body)
        let req = makeRequest(path: path, method: "POST", body: data)
        return try await send(req, as: SuggestionResponse.self)
    }

    func locales() async throws -> [LocaleInfo] {
        let path = "v1/projects/\(configuration.projectId)/locales"
        let req = makeRequest(path: path, method: "GET")
        return try await send(req, as: [LocaleInfo].self)
    }

    /// Result of an export.xcstrings fetch.
    enum XcstringsFetchResult {
        /// Server returned 304 Not Modified — the caller's existing cache is still fresh.
        case notModified
        /// Server returned a fresh document. The raw JSON bytes are included so
        /// callers can persist them verbatim alongside the etag.
        case modified(data: Data, etag: String?)
    }

    /// Fetches the project's exported `.xcstrings` document, optionally with an
    /// `If-None-Match` header so the server can return 304.
    func fetchXcstrings(ifNoneMatch: String?) async throws -> XcstringsFetchResult {
        let path = "v1/projects/\(configuration.projectId)/export.xcstrings"
        var req = makeRequest(path: path, method: "GET")
        if let etag = ifNoneMatch {
            req.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            throw TranslationsError.transport(error)
        }
        guard let http = response as? HTTPURLResponse else {
            throw TranslationsError.httpError(status: -1, message: "no response")
        }
        if http.statusCode == 304 {
            return .notModified
        }
        if !(200..<300).contains(http.statusCode) {
            let msg = String(data: data, encoding: .utf8)
            throw TranslationsError.httpError(status: http.statusCode, message: msg)
        }
        let etag = http.value(forHTTPHeaderField: "Etag")
            ?? http.value(forHTTPHeaderField: "ETag")
        return .modified(data: data, etag: etag)
    }
}
