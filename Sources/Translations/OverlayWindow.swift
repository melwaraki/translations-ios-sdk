#if canImport(UIKit)
import UIKit

/// A transparent UIWindow that floats above the host app, draws tappable
/// rectangles over harvested strings, and forwards taps to the suggestion sheet.
final class OverlayWindow: UIWindow {
    private var highlights: [HighlightView] = []
    var onTap: ((HarvestedString) -> Void)?

    override init(windowScene: UIWindowScene) {
        super.init(windowScene: windowScene)
        windowLevel = .alert + 1
        backgroundColor = .clear
        isHidden = true
        rootViewController = OverlayRootController()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    func show(items: [HarvestedString]) {
        clearHighlights()
        for item in items {
            let h = HighlightView(item: item)
            h.frame = item.frame
            h.onTap = { [weak self] item in self?.onTap?(item) }
            rootViewController?.view.addSubview(h)
            highlights.append(h)
        }
        isHidden = false
    }

    func hide() {
        clearHighlights()
        isHidden = true
    }

    private func clearHighlights() {
        for h in highlights { h.removeFromSuperview() }
        highlights.removeAll()
    }

    /// Forward touches to the host app unless they hit a highlight rectangle.
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        for h in highlights where h.frame.contains(point) {
            return h
        }
        return nil
    }
}

private final class OverlayRootController: UIViewController {
    override func loadView() {
        let v = UIView()
        v.backgroundColor = .clear
        view = v
    }
    override var prefersStatusBarHidden: Bool { false }
}

private final class HighlightView: UIView {
    let item: HarvestedString
    var onTap: ((HarvestedString) -> Void)?

    init(item: HarvestedString) {
        self.item = item
        super.init(frame: .zero)
        backgroundColor = UIColor.systemBlue.withAlphaComponent(0.18)
        layer.borderColor = UIColor.systemBlue.cgColor
        layer.borderWidth = 1
        layer.cornerRadius = 4
        isUserInteractionEnabled = true
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped))
        addGestureRecognizer(tap)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    @objc private func tapped() {
        onTap?(item)
    }
}
#endif
