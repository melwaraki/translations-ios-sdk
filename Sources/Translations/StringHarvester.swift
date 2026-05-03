#if canImport(UIKit)
import UIKit

/// A reference to a piece of rendered text on screen, with the view that displays it
/// and a frame in window coordinates.
struct HarvestedString {
    let text: String
    weak var view: UIView?
    let frame: CGRect
}

enum StringHarvester {
    /// Walk the visible UIKit view hierarchy of the given window and return a
    /// deduplicated list of rendered strings with their on-screen frames.
    static func harvest(in window: UIWindow) -> [HarvestedString] {
        var seen: [String: HarvestedString] = [:]
        walk(window, root: window, into: &seen)
        return Array(seen.values)
    }

    private static func walk(_ view: UIView, root: UIWindow, into seen: inout [String: HarvestedString]) {
        if view.isHidden || view.alpha == 0 {
            return
        }
        if let text = extractText(from: view), !text.isEmpty {
            let frame = view.convert(view.bounds, to: root)
            // Drop strings clipped completely off-screen.
            if frame.intersects(root.bounds) {
                let key = "\(text)|\(Int(frame.minX)),\(Int(frame.minY))"
                if seen[key] == nil {
                    seen[key] = HarvestedString(text: text, view: view, frame: frame)
                }
            }
        }
        for sub in view.subviews {
            walk(sub, root: root, into: &seen)
        }
    }

    private static func extractText(from view: UIView) -> String? {
        if let label = view as? UILabel { return label.text }
        if let button = view as? UIButton {
            return button.titleLabel?.text ?? button.title(for: .normal)
        }
        if let field = view as? UITextField {
            return field.text?.isEmpty == false ? field.text : field.placeholder
        }
        if let textView = view as? UITextView {
            return textView.text
        }
        // SwiftUI hosting views expose strings via accessibility labels.
        if String(describing: type(of: view)).contains("Text"),
           let label = view.accessibilityLabel, !label.isEmpty {
            return label
        }
        return nil
    }
}
#endif
