import SwiftUI
import Translations

@main
struct TranslationsExampleApp: App {
    init() {
        Translations.configure(
            baseURL: URL(string: ProcessInfo.processInfo.environment["TRANSLATIONS_BASE_URL"]
                         ?? "https://your-dashboard.example.com/api")!,
            projectId: ProcessInfo.processInfo.environment["TRANSLATIONS_PROJECT_ID"] ?? "demo-project",
            token: ProcessInfo.processInfo.environment["TRANSLATIONS_TOKEN"] ?? "tsk_demo",
            enabledInRelease: false
        )
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .translationsShakeToTranslate()
        }
    }
}
