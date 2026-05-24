#if canImport(UIKit)
import UIKit
import Vision

/// A reference to a piece of rendered text on screen, with the view that displays it
/// and a frame in window coordinates.
struct HarvestedString {
    let text: String
    weak var view: UIView?
    let frame: CGRect
}

enum StringHarvester {
    /// Detect visible strings on a rendered screenshot of the active window.
    ///
    /// This mirrors LocaleReporter's OCR-driven selection UX so SwiftUI and
    /// custom-rendered text are consistently discoverable.
    static func harvest(in window: UIWindow, locale: String? = nil) async -> [HarvestedString] {
        if let ocr = await harvestWithOCR(in: window, locale: locale), !ocr.isEmpty {
            return ocr
        }
        // Fallback for environments where OCR fails unexpectedly.
        var seen: [String: HarvestedString] = [:]
        walk(window, root: window, into: &seen)
        return Array(seen.values)
    }

    private static func harvestWithOCR(in window: UIWindow, locale: String?) async -> [HarvestedString]? {
        // Capture any UIKit-derived values on the main actor to avoid main-thread violations
        let captured: (screenshot: UIImage?, imageSize: CGSize, windowBounds: CGRect) = await MainActor.run {
            let shot = captureScreenshot(from: window)
            let size = shot?.size ?? .zero
            let bounds = window.bounds
            return (shot, size, bounds)
        }

        guard let screenshot = captured.screenshot, let cgImage = screenshot.cgImage else {
            return nil
        }

        return await withCheckedContinuation { continuation in
            let request = VNRecognizeTextRequest { request, _ in
                let observations = (request.results as? [VNRecognizedTextObservation]) ?? []
                var seen: [String: HarvestedString] = [:]

                for observation in observations {
                    guard let candidate = observation.topCandidates(1).first else { continue }
                    let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { continue }

                    let frame = normalizedVisionRectToWindowRect(
                        observation.boundingBox,
                        imageSize: captured.imageSize,
                        windowBounds: captured.windowBounds
                    ).integral

                    guard frame.width > 2, frame.height > 2,
                          frame.intersects(captured.windowBounds) else { continue }

                    let key = "\(text)|\(Int(frame.minX)),\(Int(frame.minY))"
                    if seen[key] == nil {
                        seen[key] = HarvestedString(text: text, view: nil, frame: frame)
                    }
                }
                continuation.resume(returning: Array(seen.values))
            }

            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.minimumTextHeight = 0.012
            request.recognitionLanguages = recognitionLanguages(for: locale)

            DispatchQueue.global(qos: .userInitiated).async {
                let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
                do {
                    try handler.perform([request])
                } catch {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    @MainActor
    private static func captureScreenshot(from window: UIWindow) -> UIImage? {
        let rendererFormat = UIGraphicsImageRendererFormat.default()
        rendererFormat.scale = UIScreen.main.scale
        let renderer = UIGraphicsImageRenderer(size: window.bounds.size, format: rendererFormat)
        return renderer.image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: false)
        }
    }

    private static func normalizedVisionRectToWindowRect(
        _ normalized: CGRect,
        imageSize: CGSize,
        windowBounds: CGRect
    ) -> CGRect {
        // Vision rects are normalized with an origin at bottom-left.
        let imageRect = CGRect(
            x: normalized.minX * imageSize.width,
            y: (1 - normalized.maxY) * imageSize.height,
            width: normalized.width * imageSize.width,
            height: normalized.height * imageSize.height
        )

        // Our screenshot is captured at window size; convert with explicit scale
        // to avoid orientation/size drift.
        let sx = windowBounds.width / max(imageSize.width, 1)
        let sy = windowBounds.height / max(imageSize.height, 1)
        return CGRect(
            x: imageRect.minX * sx,
            y: imageRect.minY * sy,
            width: imageRect.width * sx,
            height: imageRect.height * sy
        )
    }

    private static func recognitionLanguages(for locale: String?) -> [String] {
        var languages: [String] = []
        if let locale = locale, !locale.isEmpty {
            languages.append(locale.replacingOccurrences(of: "_", with: "-"))
            if let language = languages[0].split(separator: "-").first {
                languages.append(String(language))
            }
        }
        languages.append(contentsOf: Locale.preferredLanguages)
        languages.append("en-US")

        var seen = Set<String>()
        return languages.filter { code in
            let normalized = code.replacingOccurrences(of: "_", with: "-").lowercased()
            guard !normalized.isEmpty, !seen.contains(normalized) else { return false }
            seen.insert(normalized)
            return true
        }
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
