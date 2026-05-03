import SwiftUI
import Translations

struct ContentView: View {
    @State private var liked = false

    var body: some View {
        NavigationStack {
            List {
                Section("Welcome") {
                    Text("Hello, traveler!")
                    Text("Tap a row to mark your favorite restaurant.")
                }
                Section("Actions") {
                    Button(liked ? "Saved as favorite" : "Save as favorite") {
                        liked.toggle()
                    }
                    Button("Open translation mode now") {
                        Translations.openTranslationMode()
                    }
                }
                Section("Tips") {
                    Text("Shake the device to enter translation mode.")
                    Text("Tap a highlighted string to suggest a better translation.")
                }
            }
            .navigationTitle("Translations Demo")
        }
    }
}

#Preview {
    ContentView()
}
