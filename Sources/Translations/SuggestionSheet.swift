#if canImport(UIKit)
import UIKit

final class SuggestionSheetController: UIViewController {
    private let sourceText: String
    private let matchedKey: String
    private let currentTranslation: String?
    private let availableLocales: [String]
    private let initialLocale: String
    private let onSubmit: (_ locale: String, _ value: String) async -> Result<Void, Error>

    private let scroll = UIScrollView()
    private let stack = UIStackView()
    private let sourceLabel = UILabel()
    private let currentLabel = UILabel()
    private let localePicker = UISegmentedControl()
    private let editor = UITextView()
    private let submit = UIButton(type: .system)
    private let status = UILabel()
    private let activity = UIActivityIndicatorView(style: .medium)

    init(sourceText: String,
         matchedKey: String,
         currentTranslation: String?,
         availableLocales: [String],
         initialLocale: String,
         onSubmit: @escaping (_ locale: String, _ value: String) async -> Result<Void, Error>) {
        self.sourceText = sourceText
        self.matchedKey = matchedKey
        self.currentTranslation = currentTranslation
        self.availableLocales = availableLocales.isEmpty ? [initialLocale] : availableLocales
        self.initialLocale = initialLocale
        self.onSubmit = onSubmit
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .pageSheet
        if let sheet = sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.prefersGrabberVisible = true
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        title = "Suggest Translation"
        navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .close, target: self, action: #selector(dismissSelf))

        scroll.translatesAutoresizingMaskIntoConstraints = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.spacing = 14

        let titleRow = makeSectionTitle("Source string")
        sourceLabel.numberOfLines = 0
        sourceLabel.text = sourceText
        sourceLabel.font = .systemFont(ofSize: 17, weight: .medium)

        let keyRow = makeSectionTitle("Key")
        let keyLabel = UILabel()
        keyLabel.text = matchedKey
        keyLabel.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        keyLabel.textColor = .secondaryLabel
        keyLabel.numberOfLines = 0

        let currentRow = makeSectionTitle("Current translation")
        currentLabel.numberOfLines = 0
        currentLabel.text = (currentTranslation?.isEmpty == false) ? currentTranslation : "— none —"
        currentLabel.textColor = currentTranslation == nil ? .tertiaryLabel : .label

        let localeRow = makeSectionTitle("Locale")
        for (i, code) in availableLocales.enumerated() {
            localePicker.insertSegment(withTitle: code, at: i, animated: false)
        }
        let initialIndex = availableLocales.firstIndex(of: initialLocale) ?? 0
        localePicker.selectedSegmentIndex = initialIndex
        localePicker.apportionsSegmentWidthsByContent = true

        let editorRow = makeSectionTitle("Your suggestion")
        editor.font = .systemFont(ofSize: 17)
        editor.layer.borderColor = UIColor.separator.cgColor
        editor.layer.borderWidth = 1
        editor.layer.cornerRadius = 8
        editor.heightAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true
        editor.text = currentTranslation ?? ""

        var sub = UIButton.Configuration.filled()
        sub.title = "Submit suggestion"
        submit.configuration = sub
        submit.addTarget(self, action: #selector(submitTapped), for: .touchUpInside)

        status.font = .systemFont(ofSize: 13)
        status.textColor = .secondaryLabel
        status.numberOfLines = 0

        activity.hidesWhenStopped = true

        let submitRow = UIStackView(arrangedSubviews: [submit, activity])
        submitRow.axis = .horizontal
        submitRow.spacing = 10
        submitRow.alignment = .center

        [titleRow, sourceLabel, keyRow, keyLabel, currentRow, currentLabel,
         localeRow, localePicker, editorRow, editor, submitRow, status]
            .forEach { stack.addArrangedSubview($0) }

        scroll.addSubview(stack)
        view.addSubview(scroll)

        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            stack.topAnchor.constraint(equalTo: scroll.topAnchor, constant: 16),
            stack.leadingAnchor.constraint(equalTo: scroll.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: scroll.trailingAnchor, constant: -20),
            stack.bottomAnchor.constraint(equalTo: scroll.bottomAnchor, constant: -16),
            stack.widthAnchor.constraint(equalTo: scroll.widthAnchor, constant: -40),
        ])
    }

    private func makeSectionTitle(_ s: String) -> UILabel {
        let l = UILabel()
        l.text = s.uppercased()
        l.font = .systemFont(ofSize: 11, weight: .semibold)
        l.textColor = .secondaryLabel
        return l
    }

    @objc private func dismissSelf() { dismiss(animated: true) }

    @objc private func submitTapped() {
        let value = editor.text ?? ""
        let idx = max(0, localePicker.selectedSegmentIndex)
        let locale = availableLocales[idx]
        guard !value.isEmpty else {
            status.text = "Translation cannot be empty."
            status.textColor = .systemRed
            return
        }
        submit.isEnabled = false
        activity.startAnimating()
        status.text = ""
        Task {
            let result = await onSubmit(locale, value)
            await MainActor.run {
                self.activity.stopAnimating()
                self.submit.isEnabled = true
                switch result {
                case .success:
                    self.status.text = "Suggestion submitted. Thanks!"
                    self.status.textColor = .systemGreen
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { self.dismiss(animated: true) }
                case .failure(let err):
                    self.status.text = err.localizedDescription
                    self.status.textColor = .systemRed
                }
            }
        }
    }
}
#endif
