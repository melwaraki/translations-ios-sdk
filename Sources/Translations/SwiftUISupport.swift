#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import UIKit

public extension View {
    /// Opt-in modifier for SwiftUI apps. Attach to your root view to enable
    /// shake-to-translate without touching UIKit.
    func translationsShakeToTranslate() -> some View {
        background(ShakeInstallerRepresentable())
    }
}

private struct ShakeInstallerRepresentable: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        let v = UIView(frame: .zero)
        DispatchQueue.main.async {
            Translations.enableShakeToTranslate()
        }
        return v
    }
    func updateUIView(_ uiView: UIView, context: Context) {}
}
#endif
