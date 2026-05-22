#if canImport(UIKit)
import ObjectiveC
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
        if let observer = observer {
            NotificationCenter.default.removeObserver(observer)
        }
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
    private static let lock = NSLock()
    private static var installed = false
    static func installOnce() {
        lock.lock()
        defer { lock.unlock() }
        guard !installed else { return }
        installed = true
        // Swizzle only on UIWindow. `motionEnded` is inherited from UIResponder,
        // so we first install an override on UIWindow to avoid mutating
        // UIResponder's implementation (which would affect SwiftUI hosting views).
        let originalSelector = #selector(UIResponder.motionEnded(_:with:))
        let swizzledSelector = #selector(UIWindow.translations_motionEnded(_:with:))
        guard let original = class_getInstanceMethod(UIWindow.self, originalSelector),
              let swizzled = class_getInstanceMethod(UIWindow.self, swizzledSelector) else {
            return
        }
        let didAdd = class_addMethod(
            UIWindow.self,
            originalSelector,
            method_getImplementation(swizzled),
            method_getTypeEncoding(swizzled)
        )

        if didAdd {
            class_replaceMethod(
                UIWindow.self,
                swizzledSelector,
                method_getImplementation(original),
                method_getTypeEncoding(original)
            )
        } else {
            method_exchangeImplementations(original, swizzled)
        }
    }
}

private extension UIWindow {
    @objc func translations_motionEnded(_ motion: UIEvent.EventSubtype, with event: UIEvent?) {
        // Calling the original IMP through the alias selector changes `_cmd` to
        // `translations_motionEnded`, which can be forwarded to next responders
        // and crash (e.g. UIWindowScene unrecognized selector). Forward using the
        // canonical selector instead.
        next?.motionEnded(motion, with: event)
        if motion == .motionShake {
            NotificationCenter.default.post(name: .translationsShake, object: self)
        }
    }
}
#endif
