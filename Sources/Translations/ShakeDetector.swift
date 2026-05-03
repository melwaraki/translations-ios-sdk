#if canImport(UIKit)
import UIKit

/// A UIWindow subclass that detects motion-shake events and forwards them
/// to a callback. Installed by `Translations.enableShakeToTranslate()`.
final class ShakeListenerWindow: UIWindow {
    var onShake: (() -> Void)?

    override func motionEnded(_ motion: UIEvent.EventSubtype, with event: UIEvent?) {
        super.motionEnded(motion, with: event)
        if motion == .motionShake {
            onShake?()
        }
    }

    override var canBecomeFirstResponder: Bool { true }
}

/// Lightweight shake detector that swizzles the responder chain to listen for
/// shake events at the application's key window without forcing the host app
/// to use a particular UIWindow subclass.
final class ShakeNotifier: NSObject {
    static let shared = ShakeNotifier()
    private var observer: NSObjectProtocol?
    var onShake: (() -> Void)?

    func start() {
        // Use an UIApplication notification trick: post when the app receives a shake.
        // We rely on UIDevice's deviceOrientationDidChange + an internal CFNotification
        // is too brittle; instead, install a hidden first-responder window-level helper.
        observer = NotificationCenter.default.addObserver(
            forName: .translationsShake,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.onShake?()
        }
    }

    func stop() {
        if let observer = observer {
            NotificationCenter.default.removeObserver(observer)
        }
        observer = nil
    }
}

extension Notification.Name {
    static let translationsShake = Notification.Name("com.replit.translations.shake")
}

/// A UIWindow extension that, when installed via `UIWindow.enableTranslationsShake()`,
/// posts the `.translationsShake` notification on every shake. Call once at app launch.
public extension UIWindow {
    /// Re-routes shake events through swizzling-free posting. Call this from your
    /// AppDelegate / SceneDelegate after creating your key window. Safe to call
    /// multiple times.
    static func enableTranslationsShakeForwarding() {
        ShakeForwarderInstaller.installOnce()
    }
}

private enum ShakeForwarderInstaller {
    static var installed = false
    static func installOnce() {
        guard !installed else { return }
        installed = true
        // Replace UIWindow.motionEnded(_:with:) with a version that posts the notification.
        let originalSelector = #selector(UIResponder.motionEnded(_:with:))
        let swizzledSelector = #selector(UIWindow.translations_motionEnded(_:with:))
        guard let original = class_getInstanceMethod(UIWindow.self, originalSelector),
              let swizzled = class_getInstanceMethod(UIWindow.self, swizzledSelector) else {
            return
        }
        method_exchangeImplementations(original, swizzled)
    }
}

private extension UIWindow {
    @objc func translations_motionEnded(_ motion: UIEvent.EventSubtype, with event: UIEvent?) {
        // Call the original (now swapped) implementation first.
        self.translations_motionEnded(motion, with: event)
        if motion == .motionShake {
            NotificationCenter.default.post(name: .translationsShake, object: self)
        }
    }
}
#endif
