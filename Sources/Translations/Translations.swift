import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// The public entry point for the Translations SDK.
///
/// Typical setup:
///
/// ```swift
/// Translations.configure(
///     baseURL: URL(string: "https://your-dashboard.example.com/api")!,
///     projectId: "<project-id>",
///     token: "tsk_..."
/// )
/// Translations.enableShakeToTranslate()
/// ```
public enum Translations {
    private static var client: APIClient?
    private static var configuration: TranslationsConfiguration?
    private static var cache: XcstringsCache?
    private static var lastRefreshAt: Date?
    private static var didRefreshThisLaunch: Bool = false

    #if canImport(UIKit)
    private static var overlay: OverlayWindow?
    private static var presentationWindow: UIWindow?
    private static var availableLocales: [String] = []
    private static var matchCache: [String: MatchResult] = [:]
    private static var presenter: UIViewController?
    private static var shakeToTranslateInstalled = false
    private static var activationTask: Task<Void, Never>?
    #endif

    /// Configure the SDK. Must be called once before any other API.
    public static func configure(
        baseURL: URL,
        projectId: String,
        token: String,
        defaultLocale: String? = nil,
        enabledInRelease: Bool = false,
        matchThreshold: Double = 0.4
    ) {
        let cfg = TranslationsConfiguration(
            baseURL: baseURL,
            projectId: projectId,
            token: token,
            defaultLocale: defaultLocale,
            enabledInRelease: enabledInRelease,
            matchThreshold: matchThreshold
        )
        configure(with: cfg)
    }

    /// Configure with a fully-built configuration object.
    public static func configure(with configuration: TranslationsConfiguration) {
        self.configuration = configuration
        let client = APIClient(configuration: configuration)
        self.client = client
        if configuration.useOfflineCache {
            let cache = XcstringsCache(projectId: configuration.projectId, client: client)
            self.cache = cache
            Task { await cache.loadFromDiskIfNeeded() }
        } else {
            self.cache = nil
        }
        self.lastRefreshAt = nil
        self.didRefreshThisLaunch = false
    }

    /// Force a refresh of the offline `.xcstrings` cache. Useful when the
    /// configured `cacheRefreshPolicy` is `.manual`.
    @discardableResult
    public static func refreshCache() async -> Bool {
        guard let cache = cache else { return false }
        do {
            try await cache.refresh()
            lastRefreshAt = Date()
            didRefreshThisLaunch = true
            return true
        } catch {
            return false
        }
    }

    /// Returns true if the configured policy says we should refresh now.
    private static func shouldRefreshNow() -> Bool {
        guard let cfg = configuration else { return false }
        switch cfg.cacheRefreshPolicy {
        case .always:
            return true
        case .oncePerLaunch:
            return !didRefreshThisLaunch
        case .every(let interval):
            if let last = lastRefreshAt {
                return Date().timeIntervalSince(last) >= interval
            }
            return true
        case .manual:
            return false
        }
    }

    /// Kicks off a refresh in a detached task so activation never has to wait
    /// on the network when a cached copy already exists. The flags that gate
    /// the policy are flipped immediately so concurrent activations don't
    /// schedule duplicate refreshes.
    private static func refreshCacheInBackground() {
        guard let cache = cache, shouldRefreshNow() else { return }
        didRefreshThisLaunch = true
        let scheduledAt = Date()
        lastRefreshAt = scheduledAt
        Task.detached {
            do {
                try await cache.refresh()
            } catch {
                // Network failures are silent: the cached copy (if any) is
                // still used. Roll back the scheduling timestamp so the next
                // activation can retry per policy.
                await MainActor.run {
                    if Translations.lastRefreshAt == scheduledAt {
                        Translations.lastRefreshAt = nil
                        if case .oncePerLaunch = Translations.configuration?.cacheRefreshPolicy {
                            Translations.didRefreshThisLaunch = false
                        }
                    }
                }
            }
        }
    }

    /// True when translation mode is allowed in the current build.
    public static var isEnabled: Bool {
        guard let cfg = configuration else { return false }
        #if DEBUG
        return true
        #else
        return cfg.enabledInRelease
        #endif
    }

    #if canImport(UIKit)

    /// Install the shake-to-translate gesture. Call once at app launch.
    @MainActor
    public static func enableShakeToTranslate() {
        guard isEnabled else { return }
        UIWindow.enableTranslationsShakeForwarding()
        ShakeNotifier.shared.onShake = { Task { @MainActor in toggleTranslationMode() } }
        guard !shakeToTranslateInstalled else { return }
        shakeToTranslateInstalled = true
        ShakeNotifier.shared.start()
    }

    /// Manually open translation mode (for a button-driven entry point).
    @MainActor
    public static func openTranslationMode() {
        guard isEnabled else { return }
        guard activationTask == nil else { return }
        activationTask = Task { @MainActor in
            await activate()
            if !Task.isCancelled {
                activationTask = nil
            }
        }
    }

    /// Manually close translation mode.
    @MainActor
    public static func closeTranslationMode() {
        activationTask?.cancel()
        activationTask = nil
        overlay?.hide()
    }

    @MainActor
    private static func toggleTranslationMode() {
        if let overlay = overlay, !overlay.isHidden {
            activationTask?.cancel()
            activationTask = nil
            overlay.hide()
            return
        }
        guard activationTask == nil else { return }
        activationTask = Task { @MainActor in
            await activate()
            if !Task.isCancelled {
                activationTask = nil
            }
        }
    }

    @MainActor
    private static func activate() async {
        guard !Task.isCancelled else { return }
        guard let client = client, let cfg = configuration else { return }
        guard let scene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .first(where: { $0.activationState == .foregroundActive })
                ?? UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first,
              let keyWindow = scene.windows.first(where: { $0.isKeyWindow }) ?? scene.windows.first
        else { return }

        if overlay == nil {
            overlay = OverlayWindow(windowScene: scene)
            overlay?.onTap = { harvested in
                Task { @MainActor in await presentSuggestion(for: harvested) }
            }
        }
        overlay?.frame = keyWindow.frame

        guard !Task.isCancelled else { return }

        let harvested = await StringHarvester.harvest(in: keyWindow)
        let unique = Array(Set(harvested.map { $0.text }))
        let locale = cfg.defaultLocale ?? deviceLocaleCode()

        // Offline-first: if we already have a cached document on disk, use it
        // immediately and refresh in the background. Activation never waits on
        // the network in this path, so translation mode is instant and works
        // when the device is offline.
        if let cache = cache {
            await cache.loadFromDiskIfNeeded()
            if await cache.hasDocument {
                if availableLocales.isEmpty {
                    availableLocales = await cache.availableLocales()
                }
                let matches = await cache.match(
                    strings: unique, locale: locale, threshold: cfg.matchThreshold
                )
                for m in matches where m.matched { matchCache[m.input] = m }
                refreshCacheInBackground()
                let displayItems = harvested.filter { matchCache[$0.text]?.matched == true }
                overlay?.show(items: displayItems)
                return
            }
            // Cold start: no cached doc yet. Try a one-shot refresh before
            // falling back to the network match path so the very first launch
            // still gets a usable result.
            if shouldRefreshNow() {
                didRefreshThisLaunch = true
                lastRefreshAt = Date()
                do {
                    try await cache.refresh()
                } catch {
                    lastRefreshAt = nil
                    if case .oncePerLaunch = cfg.cacheRefreshPolicy { didRefreshThisLaunch = false }
                }
                if await cache.hasDocument {
                    if availableLocales.isEmpty {
                        availableLocales = await cache.availableLocales()
                    }
                    let matches = await cache.match(
                        strings: unique, locale: locale, threshold: cfg.matchThreshold
                    )
                    for m in matches where m.matched { matchCache[m.input] = m }
                    let displayItems = harvested.filter { matchCache[$0.text]?.matched == true }
                    overlay?.show(items: displayItems)
                    return
                }
            }
        }

        // Final fallback: cache disabled or cold-start refresh failed. Use the
        // original network endpoints so the SDK keeps working in degraded
        // configurations.
        if availableLocales.isEmpty {
            do {
                let locales = try await client.locales()
                availableLocales = locales.map { $0.localeCode }
            } catch {
            }
        }
        let matches: [MatchResult]
        do {
            matches = try await client.match(strings: unique, locale: locale)
        } catch {
            matches = []
        }
        for m in matches where m.matched { matchCache[m.input] = m }
        let displayItems = harvested.filter { matchCache[$0.text]?.matched == true }
        overlay?.show(items: displayItems)
    }

    @MainActor
    private static func presentSuggestion(for item: HarvestedString) async {
        guard let cfg = configuration, let client = client else { return }
        guard let match = lookupMatch(for: item.text), match.matched, let key = match.key else { return }
        guard let scene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .first(where: { $0.activationState == .foregroundActive })
                ?? UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first
        else { return }

        let locale = cfg.defaultLocale ?? deviceLocaleCode()

        // Build the sheet immediately so the user gets instant feedback. The
        // sheet itself fetches the current translation per-locale via the
        // closure below, so changing the locale segment always shows the
        // matching value (or an empty editor when none exists).
        let sheet = SuggestionSheetController(
            sourceText: item.text,
            matchedKey: key,
            availableLocales: availableLocales,
            initialLocale: locale,
            translationLookup: { localeCode in
                await fetchCurrentTranslation(key: key, locale: localeCode)
            },
            onSubmit: { locale, value in
                do {
                    _ = try await client.submitSuggestion(key: key, localeCode: locale, value: value)
                    return .success(())
                } catch {
                    return .failure(error)
                }
            },
            onDismiss: { [weak overlay = overlay] in
                tearDownPresentationWindow()
                overlay?.isHidden = false
            }
        )

        // Always present on a dedicated window above our overlay so the sheet
        // is interactive and never intercepted by lingering highlight views.
        let nav = UINavigationController(rootViewController: sheet)
        let host = PresentationRootController()
        host.modalPresentationStyle = .overFullScreen
        let window = UIWindow(windowScene: scene)
        window.windowLevel = .alert + 2
        window.backgroundColor = .clear
        window.rootViewController = host
        window.makeKeyAndVisible()
        presentationWindow = window

        // Hide the overlay highlights while the sheet is up so it always reads
        // as the front-most surface.
        overlay?.isHidden = true

        host.present(nav, animated: true)
    }

    @MainActor
    private static func tearDownPresentationWindow() {
        presentationWindow?.isHidden = true
        presentationWindow?.rootViewController = nil
        presentationWindow = nil
    }

    /// Tolerant lookup so OCR-induced whitespace doesn't break matching.
    private static func lookupMatch(for text: String) -> MatchResult? {
        if let exact = matchCache[text] { return exact }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let m = matchCache[trimmed] { return m }
        let collapsed = trimmed
            .replacingOccurrences(of: "\u{00A0}", with: " ")
        if let m = matchCache[collapsed] { return m }
        let lowered = collapsed.lowercased()
        return matchCache.first(where: { $0.key.lowercased() == lowered })?.value
    }

    @MainActor
    private static func fetchCurrentTranslation(key: String, locale: String) async -> String? {
        if let cache = cache, await cache.hasDocument,
           let lookup = await cache.lookup(key: key, locale: locale),
           let t = lookup.translations.first {
            return t.value
        }
        if let client = client,
           let lookup = try? await client.lookup(key: key, locale: locale),
           let t = lookup.translations.first {
            return t.value
        }
        return nil
    }

    private final class PresentationRootController: UIViewController {
        override func loadView() {
            let v = UIView()
            v.backgroundColor = .clear
            view = v
        }
    }

    private static func deviceLocaleCode() -> String {
        if #available(iOS 16, *) {
            return Locale.current.identifier(.bcp47)
        }
        return Locale.current.identifier
    }
    #endif
}
