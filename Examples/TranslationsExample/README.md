# Translations Example App

A minimal SwiftUI app that demonstrates the Translations SDK end-to-end.

## Run it

1. Open `Examples/TranslationsExample` in Xcode 15 or newer (iOS 16+ deployment target).
2. Add the `Translations` Swift Package as a local package dependency (point Xcode at the repo root, which contains `Package.swift`).
3. Set the following environment variables on the run scheme:
   - `TRANSLATIONS_BASE_URL` — e.g. `https://your-dashboard.example.com/api`
   - `TRANSLATIONS_PROJECT_ID` — your project's UUID
   - `TRANSLATIONS_TOKEN` — a `tsk_…` token issued from the dashboard's **API Tokens** page (project-scoped recommended)
4. Run on a real device (the Simulator can simulate a shake via *Device → Shake*).
5. Shake the device — the SDK will highlight strings it recognizes from your project's `.xcstrings`. Tap one to suggest a better translation.
