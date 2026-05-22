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

        let harvested = StringHarvester.harvest(in: keyWindow)
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
        guard let cfg = configuration, let client = client,
              let m = matchCache[item.text], m.matched, let key = m.key else { return }
        guard let scene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .first(where: { $0.activationState == .foregroundActive }),
              let host = scene.windows.first(where: { $0.isKeyWindow })?.rootViewController
        else { return }

        let locale = cfg.defaultLocale ?? deviceLocaleCode()
        var current: String? = nil
        // Prefer the on-device cache so opening the suggestion sheet works
        // offline. Fall back to the server lookup only when the cache is
        // unavailable.
        if let cache = cache, await cache.hasDocument {
            if let lookup = await cache.lookup(key: key, locale: locale),
               let t = lookup.translations.first(where: { $0.localeCode == locale }) {
                current = t.value
            }
        } else if let lookup = try? await client.lookup(key: key, locale: locale),
                  let t = lookup.translations.first(where: { $0.localeCode == locale }) {
            current = t.value
        }
        let sheet = SuggestionSheetController(
            sourceText: item.text,
            matchedKey: key,
            currentTranslation: current,
            availableLocales: availableLocales,
            initialLocale: locale
        ) { locale, value in
            do {
                _ = try await client.submitSuggestion(key: key, localeCode: locale, value: value)
                return .success(())
            } catch {
                return .failure(error)
            }
        }
        let nav = UINavigationController(rootViewController: sheet)
        var presenter = host
        while let presented = presenter.presentedViewController { presenter = presented }
        presenter.present(nav, animated: true)
    }

    private static func deviceLocaleCode() -> String {
        if #available(iOS 16, *) {
            return Locale.current.identifier(.bcp47)
        }
        return Locale.current.identifier
    }
    #endif
}
