import Foundation

/// On-device cache of a project's exported `.xcstrings` document.
///
/// The cache stores two files per project in the app's caches directory:
///   - `<projectId>.xcstrings` — the raw JSON document.
///   - `<projectId>.meta.json` — bookkeeping (etag, fetched-at).
///
/// Once loaded, match + lookup are served entirely from memory so translation
/// mode works offline.
actor XcstringsCache {
    struct Meta: Codable {
        let etag: String?
        let fetchedAt: Date
    }

    private let projectId: String
    private let client: APIClient
    private let directory: URL
    private let docURL: URL
    private let metaURL: URL

    private var doc: XcstringsDoc?
    private var bundledDoc: XcstringsDoc?
    private var meta: Meta?
    /// Source values keyed by lowercased text for fast exact match.
    private var sourceIndex: [String: (key: String, value: String)] = [:]

    private struct MatchCandidate {
        let key: String
        let sourceValue: String
        let matchValue: String
    }

    init(projectId: String, client: APIClient, fileManager: FileManager = .default) {
        self.projectId = projectId
        self.client = client
        let caches = (try? fileManager.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? URL(fileURLWithPath: NSTemporaryDirectory())
        self.directory = caches.appendingPathComponent("Translations", isDirectory: true)
        try? fileManager.createDirectory(at: self.directory, withIntermediateDirectories: true)
        self.docURL = self.directory.appendingPathComponent("\(projectId).xcstrings")
        self.metaURL = self.directory.appendingPathComponent("\(projectId).meta.json")
    }

    /// Loads any persisted document + meta into memory. Safe to call repeatedly.
    func loadFromDiskIfNeeded() {
        loadBundledDocumentIfNeeded()
        guard doc == nil else { return }
        if let data = try? Data(contentsOf: docURL),
           let parsed = try? JSONDecoder().decode(XcstringsDoc.self, from: data) {
            self.doc = mergedWithBundledDocument(parsed)
            self.rebuildIndex()
        } else if let bundledDoc = bundledDoc {
            self.doc = bundledDoc
            self.rebuildIndex()
        }
        if let metaData = try? Data(contentsOf: metaURL),
           let parsedMeta = try? JSONDecoder().decode(Meta.self, from: metaData) {
            self.meta = parsedMeta
        }
    }

    var hasDocument: Bool { doc != nil }
    var lastFetchedAt: Date? { meta?.fetchedAt }
    var currentEtag: String? { meta?.etag }

    func clear() {
        doc = nil
        meta = nil
        sourceIndex.removeAll()
        try? FileManager.default.removeItem(at: docURL)
        try? FileManager.default.removeItem(at: metaURL)
    }

    /// Refreshes the cache against the server. When the server replies 304 the
    /// existing document is kept and `fetchedAt` is bumped.
    func refresh() async throws {
        loadFromDiskIfNeeded()
        let result = try await client.fetchXcstrings(ifNoneMatch: meta?.etag)
        switch result {
        case .notModified:
            self.meta = Meta(etag: meta?.etag, fetchedAt: Date())
            persistMeta()
        case .modified(let data, let etag):
            let parsed = try JSONDecoder().decode(XcstringsDoc.self, from: data)
            self.doc = mergedWithBundledDocument(parsed)
            self.meta = Meta(etag: etag, fetchedAt: Date())
            self.rebuildIndex()
            try? data.write(to: docURL, options: .atomic)
            persistMeta()
        }
    }

    private func persistMeta() {
        guard let meta = meta else { return }
        if let data = try? JSONEncoder().encode(meta) {
            try? data.write(to: metaURL, options: .atomic)
        }
    }

    private func loadBundledDocumentIfNeeded() {
        guard bundledDoc == nil,
              let url = Bundle.main.url(forResource: "Localizable", withExtension: "xcstrings"),
              let data = try? Data(contentsOf: url),
              let parsed = try? JSONDecoder().decode(XcstringsDoc.self, from: data) else {
            return
        }
        bundledDoc = parsed
    }

    private func mergedWithBundledDocument(_ primary: XcstringsDoc) -> XcstringsDoc {
        guard let bundledDoc = bundledDoc else { return primary }
        var strings = bundledDoc.strings
        for (key, entry) in primary.strings {
            if let bundledEntry = strings[key] {
                var localizations = bundledEntry.localizations ?? [:]
                for (code, localization) in entry.localizations ?? [:] {
                    localizations[code] = localization
                }
                strings[key] = XcstringsEntry(
                    comment: entry.comment ?? bundledEntry.comment,
                    extractionState: entry.extractionState ?? bundledEntry.extractionState,
                    localizations: localizations
                )
            } else {
                strings[key] = entry
            }
        }
        return XcstringsDoc(
            sourceLanguage: primary.sourceLanguage ?? bundledDoc.sourceLanguage,
            version: primary.version ?? bundledDoc.version,
            strings: strings
        )
    }

    private func rebuildIndex() {
        sourceIndex.removeAll()
        guard let doc = doc else { return }
        let source = doc.sourceLanguage ?? "en"
        for (key, entry) in doc.strings {
            let sourceValue = entry.localizations?[source]?.stringUnit?.value ?? key
            sourceIndex[sourceValue.lowercased()] = (key, sourceValue)
        }
    }

    // MARK: - Local match + lookup

    /// Mirror of the server `/match` semantics, served from the cache. The
    /// implementation prefers exact case-insensitive matches and falls back to
    /// a token-set Jaccard similarity for fuzzy matches above `threshold`.
    func match(strings: [String], locale: String?, threshold: Double) -> [MatchResult] {
        guard let doc = doc else {
            return strings.map {
                MatchResult(input: $0, matched: false, key: nil, stringId: nil,
                            sourceValue: nil, translation: nil, similarity: nil)
            }
        }
        let source = doc.sourceLanguage ?? "en"
        let candidates = matchCandidates(locale: locale, source: source)
        return strings.map { input in
            // 1. Exact match against the lowercased source value index.
            if let hit = sourceIndex[input.lowercased()] {
                let entry = doc.strings[hit.key]
                let translation = translationValue(in: entry, locale: locale, source: source)
                return MatchResult(
                    input: input, matched: true, key: hit.key, stringId: nil,
                    sourceValue: hit.value, translation: translation, similarity: 1.0
                )
            }
            // 2. Exact match against the active locale. This is the path used
            //    when the app is currently rendering translated text.
            let normalizedInput = normalizeText(input)
            if let hit = candidates.first(where: { normalizeText($0.matchValue) == normalizedInput }) {
                let entry = doc.strings[hit.key]
                let translation = translationValue(in: entry, locale: locale, source: source)
                return MatchResult(
                    input: input, matched: true, key: hit.key, stringId: nil,
                    sourceValue: hit.sourceValue, translation: translation, similarity: 1.0
                )
            }
            // 3. Fuzzy fallback. Walks every source + active-locale candidate
            //    once; fine for typical project sizes (a few thousand strings).
            var best: (key: String, value: String, sim: Double)? = nil
            let inputTokens = tokenize(input)
            for candidate in candidates {
                let sim = jaccard(inputTokens, tokenize(candidate.matchValue))
                if sim >= threshold && (best == nil || sim > best!.sim) {
                    best = (candidate.key, candidate.sourceValue, sim)
                }
            }
            if let best = best {
                let entry = doc.strings[best.key]
                let translation = translationValue(in: entry, locale: locale, source: source)
                return MatchResult(
                    input: input, matched: true, key: best.key, stringId: nil,
                    sourceValue: best.value, translation: translation, similarity: best.sim
                )
            }
            return MatchResult(input: input, matched: false, key: nil, stringId: nil,
                               sourceValue: nil, translation: nil, similarity: nil)
        }
    }

    /// Mirror of the server `/lookup` semantics, served from the cache.
    func lookup(key: String, locale: String?) -> LookupResponse? {
        guard let doc = doc, let entry = doc.strings[key] else { return nil }
        let source = doc.sourceLanguage ?? "en"
        let sourceValue = entry.localizations?[source]?.stringUnit?.value ?? key
        var translations: [LookupTranslation] = []
        if let localizations = entry.localizations {
            for (code, loc) in localizations {
                translations.append(LookupTranslation(
                    localeCode: code,
                    value: loc.stringUnit?.value,
                    state: loc.stringUnit?.state
                ))
            }
        }
        // Filter to the requested locale when one is supplied. Use the
        // normalised matcher so `en-US`/`en_US`/`en-GB`/`en` interoperate.
        if let locale = locale {
            let normalized = normalizeLocale(locale)
            let language = languageCode(from: locale)
            var picked = translations.filter { normalizeLocale($0.localeCode) == normalized }
            if picked.isEmpty {
                picked = translations.filter { languageCode(from: $0.localeCode) == language }
            }
            if !picked.isEmpty {
                translations = picked
            }
        }
        return LookupResponse(
            id: key, key: key, sourceValue: sourceValue,
            comment: entry.comment, translations: translations
        )
    }

    /// All locale codes present in the cached document (excluding the source).
    func availableLocales() -> [String] {
        guard let doc = doc else { return [] }
        var set = Set<String>()
        for entry in doc.strings.values {
            if let locs = entry.localizations {
                for code in locs.keys { set.insert(code) }
            }
        }
        if let source = doc.sourceLanguage { set.remove(source) }
        return set.sorted()
    }

    // MARK: - Helpers

    private func translationValue(
        in entry: XcstringsEntry?,
        locale: String?,
        source: String
    ) -> String? {
        guard let entry = entry, let locale = locale else { return nil }
        let locs = entry.localizations ?? [:]
        if let exact = locs[locale]?.stringUnit?.value, !exact.isEmpty {
            return exact
        }
        // Normalise locale codes so `en-US` matches `en`, `en_US`, `en-GB`, etc.
        let normalized = normalizeLocale(locale)
        for (code, loc) in locs {
            if normalizeLocale(code) == normalized,
               let value = loc.stringUnit?.value, !value.isEmpty {
                return value
            }
        }
        // Fall back to any locale starting with the same language.
        let language = languageCode(from: locale)
        for (code, loc) in locs {
            if languageCode(from: code) == language,
               let value = loc.stringUnit?.value, !value.isEmpty {
                return value
            }
        }
        if locale == source || language == source {
            return locs[source]?.stringUnit?.value
        }
        return nil
    }

    private func matchCandidates(locale: String?, source: String) -> [MatchCandidate] {
        guard let doc = doc else { return [] }
        var candidates: [MatchCandidate] = []
        for (key, entry) in doc.strings {
            let sourceValue = entry.localizations?[source]?.stringUnit?.value ?? key
            candidates.append(MatchCandidate(
                key: key,
                sourceValue: sourceValue,
                matchValue: sourceValue
            ))

            guard let localizedValue = translationValue(in: entry, locale: locale, source: source),
                  normalizeText(localizedValue) != normalizeText(sourceValue) else {
                continue
            }
            candidates.append(MatchCandidate(
                key: key,
                sourceValue: sourceValue,
                matchValue: localizedValue
            ))
        }
        return candidates
    }

    private func normalizeLocale(_ s: String) -> String {
        s.replacingOccurrences(of: "_", with: "-").lowercased()
    }

    private func normalizeText(_ s: String) -> String {
        s
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    private func languageCode(from s: String) -> String {
        normalizeLocale(s).split(separator: "-").first.map(String.init) ?? normalizeLocale(s)
    }

    private func tokenize(_ s: String) -> Set<String> {
        let lowered = s.lowercased()
        let parts = lowered.split { !$0.isLetter && !$0.isNumber }
        return Set(parts.map(String.init))
    }

    private func jaccard(_ a: Set<String>, _ b: Set<String>) -> Double {
        if a.isEmpty && b.isEmpty { return 0 }
        let inter = a.intersection(b).count
        let union = a.union(b).count
        return union == 0 ? 0 : Double(inter) / Double(union)
    }
}
