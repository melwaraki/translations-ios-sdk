# Translations iOS SDK

A drop-in Swift Package that lets translators contribute live, on-device, by **shaking the phone** to enter translation mode and tapping any visible string to submit a suggestion. Suggestions sync back to the [Translations dashboard](../artifacts/dashboard) for review.

- iOS 16+
- UIKit **and** SwiftUI
- Zero third-party dependencies (Foundation + UIKit/SwiftUI only)
- Disabled in Release builds by default

## Install

Add the package to your app in Xcode via **File → Add Package Dependencies…** and point it at this repository's URL, or pin to a tag once published.

```swift
// Package.swift
.package(url: "https://github.com/melwaraki/translations-ios-sdk", from: "0.1.0")
```

## Configure

```swift
import Translations

Translations.configure(
    baseURL: URL(string: "https://your-dashboard.example.com/api")!,
    projectId: "<project-id>",
    token: "tsk_<your_token>",
    defaultLocale: nil,           // falls back to device locale
    enabledInRelease: false       // gate prod builds explicitly
)
Translations.enableShakeToTranslate()
```

In SwiftUI:

```swift
@main
struct MyApp: App {
    init() {
        Translations.configure(
            baseURL: URL(string: "https://…/api")!,
            projectId: "…",
            token: "tsk_…"
        )
    }
    var body: some Scene {
        WindowGroup {
            ContentView().translationsShakeToTranslate()
        }
    }
}
```

In UIKit, call `Translations.enableShakeToTranslate()` from your `AppDelegate` / `SceneDelegate` after the key window is created.

## How it works

1. **Shake** — A swizzle on `UIWindow.motionEnded(_:with:)` posts a notification on every device shake.
2. **Harvest** — The SDK walks the visible UIKit view tree (`UILabel`, `UIButton`, `UITextField`, `UITextView`, plus SwiftUI hosting views via accessibility labels) and collects rendered strings with their on-screen frames.
3. **Match** — The strings are POSTed to `/v1/projects/:id/match`. The dashboard's API performs an exact + Postgres trigram fuzzy match against your `.xcstrings` source values and returns matched keys.
4. **Highlight** — Matched strings get a tappable blue rectangle in a transparent overlay window.
5. **Suggest** — Tapping a rectangle opens a sheet showing the source string, current translation (looked up via `/v1/projects/:id/lookup`), a locale picker, and a text editor. Submit posts to `/v1/projects/:id/suggestions`.

## API tokens

Generate a token from the dashboard's **API Tokens** page. Project-scoped tokens are recommended — they're invalidated automatically when the token owner is removed from the project. Translator tokens may be further restricted to specific locales; suggestions submitted for unauthorized locales return `403`.

## Release-build safety

Translation mode is enabled in `DEBUG` builds and disabled in Release builds unless you explicitly pass `enabledInRelease: true` to `configure(...)`. The shake handler and overlay window are no-ops when the SDK is disabled.

## Example app

See [`Examples/TranslationsExample`](Examples/TranslationsExample) for a minimal SwiftUI example.


## License

MIT.
