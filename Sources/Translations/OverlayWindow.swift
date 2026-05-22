#if canImport(UIKit)
import UIKit

/// A transparent UIWindow that floats above the host app, draws tappable
/// rectangles over harvested strings, and forwards taps to the suggestion sheet.
final class OverlayWindow: UIWindow {
    private var highlights: [HighlightView] = []
    private let listPanel = MatchedListPanel()
    var onTap: ((HarvestedString) -> Void)?

    override init(windowScene: UIWindowScene) {
        super.init(windowScene: windowScene)
        windowLevel = .alert + 1
        backgroundColor = .clear
        isHidden = true
        rootViewController = OverlayRootController()
        if let root = rootViewController?.view {
            listPanel.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(listPanel)
            NSLayoutConstraint.activate([
                listPanel.leadingAnchor.constraint(equalTo: root.leadingAnchor),
                listPanel.trailingAnchor.constraint(equalTo: root.trailingAnchor),
                listPanel.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            ])
            listPanel.onSelect = { [weak self] item in
                self?.flashHighlight(for: item)
                self?.onTap?(item)
            }
        }
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
        listPanel.update(items: items)
        if let root = rootViewController?.view {
            root.bringSubviewToFront(listPanel)
        }
        isHidden = false
    }

    func hide() {
        clearHighlights()
        listPanel.update(items: [])
        isHidden = true
    }

    private func clearHighlights() {
        for h in highlights { h.removeFromSuperview() }
        highlights.removeAll()
    }

    private func flashHighlight(for item: HarvestedString) {
        guard let highlight = highlights.first(where: { $0.item.text == item.text && $0.frame == item.frame }) else { return }
        highlight.pulse()
    }

    /// Forward touches to the host app unless they hit a highlight rectangle
    /// or the bottom matched-list panel.
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let panelPoint = convert(point, to: listPanel)
        if listPanel.bounds.contains(panelPoint),
           let hit = listPanel.hitTest(panelPoint, with: event) {
            return hit
        }
        return highlights
            .filter { $0.frame.contains(point) }
            .min { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
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
    private var isPressed = false

    init(item: HarvestedString) {
        self.item = item
        super.init(frame: .zero)
        backgroundColor = UIColor.systemYellow.withAlphaComponent(0.18)
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.18
        layer.shadowRadius = 2
        layer.shadowOffset = CGSize(width: 0, height: 1)
        layer.borderColor = UIColor.systemBlue.cgColor
        layer.borderWidth = 1
        layer.cornerRadius = 4
        isUserInteractionEnabled = true
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped))
        addGestureRecognizer(tap)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        isPressed = true
        updateAppearance()
        super.touchesBegan(touches, with: event)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        isPressed = false
        updateAppearance()
        super.touchesEnded(touches, with: event)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        isPressed = false
        updateAppearance()
        super.touchesCancelled(touches, with: event)
    }

    func pulse() {
        let original = backgroundColor
        UIView.animate(withDuration: 0.18, animations: {
            self.backgroundColor = UIColor.systemBlue.withAlphaComponent(0.55)
            self.transform = CGAffineTransform(scaleX: 1.05, y: 1.05)
        }, completion: { _ in
            UIView.animate(withDuration: 0.3) {
                self.backgroundColor = original
                self.transform = .identity
            }
        })
    }

    private func updateAppearance() {
        if isPressed {
            backgroundColor = UIColor.systemBlue.withAlphaComponent(0.28)
            layer.borderWidth = 2
        } else {
            backgroundColor = UIColor.systemYellow.withAlphaComponent(0.18)
            layer.borderWidth = 1
        }
    }

    @objc private func tapped() {
        onTap?(item)
    }
}

// MARK: - Matched list panel

/// Bottom drawer listing every matched on-screen string. Tapping a row
/// fires `onSelect` so the same suggestion flow runs as a direct highlight tap.
private final class MatchedListPanel: UIView {
    var onSelect: ((HarvestedString) -> Void)?

    private let background = UIView()
    private let headerButton = UIButton(type: .system)
    private let iconView = UIImageView(image: UIImage(systemName: "text.viewfinder"))
    private let titleLabel = UILabel()
    private let countBadge = PaddingLabel()
    private let chevron = UIImageView(image: UIImage(systemName: "chevron.up"))
    private let separator = UIView()
    private let table = UITableView(frame: .zero, style: .plain)
    private var tableHeightConstraint: NSLayoutConstraint!
    private let headerHeight: CGFloat = 56
    private let expandedTableHeight: CGFloat = 240
    private var items: [HarvestedString] = []
    private var isExpanded = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isHidden = true

        background.translatesAutoresizingMaskIntoConstraints = false
        background.backgroundColor = UIColor { trait in
            trait.userInterfaceStyle == .dark
                ? UIColor(white: 0.10, alpha: 0.96)
                : UIColor(white: 1.0, alpha: 0.96)
        }
        background.layer.cornerRadius = 18
        background.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        background.layer.borderWidth = 0.5
        background.layer.borderColor = UIColor.separator.cgColor
        background.layer.shadowColor = UIColor.black.cgColor
        background.layer.shadowOpacity = 0.18
        background.layer.shadowRadius = 12
        background.layer.shadowOffset = CGSize(width: 0, height: -2)
        addSubview(background)

        NSLayoutConstraint.activate([
            background.topAnchor.constraint(equalTo: topAnchor),
            background.leadingAnchor.constraint(equalTo: leadingAnchor),
            background.trailingAnchor.constraint(equalTo: trailingAnchor),
            background.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.tintColor = .systemBlue
        iconView.contentMode = .scaleAspectFit
        iconView.isUserInteractionEnabled = false

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.text = "Matched strings"
        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        titleLabel.textColor = .label
        titleLabel.isUserInteractionEnabled = false

        countBadge.translatesAutoresizingMaskIntoConstraints = false
        countBadge.font = .systemFont(ofSize: 12, weight: .semibold)
        countBadge.textColor = .white
        countBadge.backgroundColor = .systemBlue
        countBadge.layer.cornerRadius = 10
        countBadge.layer.masksToBounds = true
        countBadge.textAlignment = .center
        countBadge.textInsets = UIEdgeInsets(top: 2, left: 8, bottom: 2, right: 8)
        countBadge.text = "0"
        countBadge.isUserInteractionEnabled = false

        chevron.translatesAutoresizingMaskIntoConstraints = false
        chevron.tintColor = .secondaryLabel
        chevron.contentMode = .scaleAspectFit
        chevron.isUserInteractionEnabled = false

        headerButton.translatesAutoresizingMaskIntoConstraints = false
        headerButton.backgroundColor = .clear
        headerButton.addTarget(self, action: #selector(toggle), for: .touchUpInside)

        background.addSubview(headerButton)
        background.addSubview(iconView)
        background.addSubview(titleLabel)
        background.addSubview(countBadge)
        background.addSubview(chevron)

        separator.translatesAutoresizingMaskIntoConstraints = false
        separator.backgroundColor = .separator
        background.addSubview(separator)

        table.translatesAutoresizingMaskIntoConstraints = false
        table.backgroundColor = .clear
        table.separatorInset = UIEdgeInsets(top: 0, left: 16, bottom: 0, right: 16)
        table.dataSource = self
        table.delegate = self
        table.rowHeight = 48
        table.alwaysBounceVertical = false
        table.register(MatchedListCell.self, forCellReuseIdentifier: "cell")
        background.addSubview(table)

        NSLayoutConstraint.activate([
            headerButton.topAnchor.constraint(equalTo: background.topAnchor),
            headerButton.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            headerButton.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            headerButton.heightAnchor.constraint(equalToConstant: headerHeight),

            iconView.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 18),
            iconView.centerYAnchor.constraint(equalTo: headerButton.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 22),
            iconView.heightAnchor.constraint(equalToConstant: 22),

            titleLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 12),
            titleLabel.centerYAnchor.constraint(equalTo: headerButton.centerYAnchor),

            countBadge.leadingAnchor.constraint(equalTo: titleLabel.trailingAnchor, constant: 8),
            countBadge.centerYAnchor.constraint(equalTo: headerButton.centerYAnchor),
            countBadge.heightAnchor.constraint(equalToConstant: 20),

            chevron.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -18),
            chevron.centerYAnchor.constraint(equalTo: headerButton.centerYAnchor),
            chevron.widthAnchor.constraint(equalToConstant: 16),
            chevron.heightAnchor.constraint(equalToConstant: 16),

            separator.topAnchor.constraint(equalTo: headerButton.bottomAnchor),
            separator.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            separator.heightAnchor.constraint(equalToConstant: 0.5),

            table.topAnchor.constraint(equalTo: separator.bottomAnchor),
            table.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            table.trailingAnchor.constraint(equalTo: background.trailingAnchor),
        ])

        tableHeightConstraint = table.heightAnchor.constraint(equalToConstant: 0)
        tableHeightConstraint.isActive = true

        // Bottom safe-area inset is added to the table content; the panel itself
        // extends to the screen bottom so the blur reaches the edge.
        table.contentInset = .zero
        NSLayoutConstraint.activate([
            table.bottomAnchor.constraint(equalTo: background.bottomAnchor),
        ])

        applyExpanded(false, animated: false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        table.contentInset.bottom = safeAreaInsets.bottom
        table.verticalScrollIndicatorInsets.bottom = safeAreaInsets.bottom
    }

    func update(items: [HarvestedString]) {
        self.items = items.sorted { $0.frame.minY < $1.frame.minY }
        countBadge.text = "\(items.count)"
        let shouldHide = items.isEmpty
        isHidden = shouldHide
        if shouldHide { applyExpanded(false, animated: false) }
        table.reloadData()
    }

    @objc private func toggle() {
        applyExpanded(!isExpanded, animated: true)
    }

    private func applyExpanded(_ expanded: Bool, animated: Bool) {
        isExpanded = expanded
        chevron.image = UIImage(systemName: expanded ? "chevron.down" : "chevron.up")
        separator.alpha = expanded ? 1 : 0
        let contentTableHeight = expanded ? expandedTableHeight + safeAreaInsets.bottom : 0
        tableHeightConstraint.constant = contentTableHeight
        guard animated, let parent = superview else {
            superview?.layoutIfNeeded()
            return
        }
        UIView.animate(withDuration: 0.22, delay: 0, options: [.curveEaseInOut]) {
            parent.layoutIfNeeded()
        }
    }
}

extension MatchedListPanel: UITableViewDataSource, UITableViewDelegate {
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        items.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "cell", for: indexPath) as! MatchedListCell
        cell.configure(with: items[indexPath.row])
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        onSelect?(items[indexPath.row])
    }
}

private final class MatchedListCell: UITableViewCell {
    private let textPreview = UILabel()
    private let dot = UIView()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear
        selectionStyle = .default
        let selected = UIView()
        selected.backgroundColor = UIColor.systemBlue.withAlphaComponent(0.10)
        selectedBackgroundView = selected

        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.backgroundColor = UIColor.systemYellow
        dot.layer.cornerRadius = 4

        textPreview.translatesAutoresizingMaskIntoConstraints = false
        textPreview.font = .systemFont(ofSize: 15)
        textPreview.numberOfLines = 1
        textPreview.lineBreakMode = .byTruncatingTail
        textPreview.textColor = .label

        contentView.addSubview(dot)
        contentView.addSubview(textPreview)

        NSLayoutConstraint.activate([
            dot.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 18),
            dot.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: 8),
            dot.heightAnchor.constraint(equalToConstant: 8),
            textPreview.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 12),
            textPreview.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            textPreview.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    func configure(with item: HarvestedString) {
        textPreview.text = item.text
    }
}

/// A simple padded UILabel used for the matched-count pill.
private final class PaddingLabel: UILabel {
    var textInsets: UIEdgeInsets = .zero {
        didSet { invalidateIntrinsicContentSize() }
    }

    override func drawText(in rect: CGRect) {
        super.drawText(in: rect.inset(by: textInsets))
    }

    override var intrinsicContentSize: CGSize {
        let base = super.intrinsicContentSize
        return CGSize(
            width: base.width + textInsets.left + textInsets.right,
            height: base.height + textInsets.top + textInsets.bottom
        )
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        let base = super.sizeThatFits(size)
        return CGSize(
            width: base.width + textInsets.left + textInsets.right,
            height: base.height + textInsets.top + textInsets.bottom
        )
    }
}
#endif
