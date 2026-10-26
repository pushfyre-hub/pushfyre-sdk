import UIKit

/// Draws one in-app message over the foreground window with plain UIKit views, so the SDK
/// needs no storyboard, asset catalog or image library from the host app.
final class PushFyreInAppRenderer {

    var onShown: (() -> Void)?
    var onDismissed: (() -> Void)?
    var onAction: ((String?) -> Void)?
    var onRespond: (([String: Any]) -> Void)?

    private let window: UIWindow
    private let message: InAppMessage
    private let content: [String: Any]

    private let background: UIColor
    private let textColor: UIColor
    private let buttonColor: UIColor
    private let buttonTextColor: UIColor
    private let actionUrl: String?

    private var container: UIView?
    private weak var cardView: UIView?
    private var finished = false

    private static let images = NSCache<NSString, UIImage>()

    init(window: UIWindow, message: InAppMessage) {
        self.window = window
        self.message = message
        self.content = message.content
        self.background = Self.color(message.content["backgroundColor"] as? String, fallback: .white)
        self.textColor = Self.color(message.content["textColor"] as? String, fallback: UIColor(red: 0.07, green: 0.09, blue: 0.15, alpha: 1))
        self.buttonColor = Self.color(message.content["buttonColor"] as? String, fallback: UIColor(red: 0.91, green: 0.2, blue: 0.1, alpha: 1))
        self.buttonTextColor = Self.color(message.content["buttonTextColor"] as? String, fallback: .white)
        self.actionUrl = (message.content["action"] as? [String: Any])?["value"] as? String
    }

    /// The icon is optional, but a banner or full-screen message with no button must stay dismissable.
    private var showClose: Bool {
        let wanted = (content["showClose"] as? Bool) ?? true
        let hasButton = !((content["buttonText"] as? String) ?? "").isEmpty
        return wanted || ((message.format == "full_screen" || message.format == "banner") && !hasButton)
    }

    func show() {
        if PushFyreInAppWidgets.handles(message.format) {
            PushFyreInAppWidgets.present(window: window, message: message, onShown: { [weak self] in
                self?.onShown?()
            }, onDismissed: { [weak self] in
                self?.onDismissed?()
            }, onRespond: { [weak self] answer in
                self?.onRespond?(answer)
            })
            return
        }
        message.format == "banner" ? showBanner() : showOverlay()
        onShown?()
    }

    // MARK: - Banner

    private func showBanner() {
        let host = BannerHostView()
        host.translatesAutoresizingMaskIntoConstraints = false
        window.addSubview(host)
        NSLayoutConstraint.activate([
            host.topAnchor.constraint(equalTo: window.topAnchor),
            host.leadingAnchor.constraint(equalTo: window.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: window.trailingAnchor)
        ])

        let bar = UIView()
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.backgroundColor = background
        bar.layer.cornerRadius = 16
        bar.layer.maskedCorners = [.layerMinXMaxYCorner, .layerMaxXMaxYCorner]
        bar.layer.shadowColor = UIColor.black.cgColor
        bar.layer.shadowOpacity = 0.18
        bar.layer.shadowRadius = 10
        bar.layer.shadowOffset = CGSize(width: 0, height: 4)
        host.addSubview(bar)
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: host.topAnchor),
            bar.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            bar.bottomAnchor.constraint(equalTo: host.bottomAnchor)
        ])

        let row = UIStackView()
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 10
        row.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: window.safeAreaLayoutGuide.topAnchor, constant: 10),
            row.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 14),
            row.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: showClose ? -44 : -14),
            row.bottomAnchor.constraint(equalTo: bar.bottomAnchor, constant: -12)
        ])

        if let imageUrl = content["imageUrl"] as? String, let picture = makeImage(imageUrl, height: 44, corner: 8) {
            picture.widthAnchor.constraint(equalToConstant: 44).isActive = true
            row.addArrangedSubview(picture)
        }
        let texts = UIStackView()
        texts.axis = .vertical
        texts.spacing = 2
        addLabels(to: texts, title: content["title"] as? String, body: content["message"] as? String, size: 15, alignment: .left)
        row.addArrangedSubview(texts)
        if let label = content["buttonText"] as? String, !label.isEmpty {
            let button = makeButton(label, compact: true)
            button.setContentHuggingPriority(.required, for: .horizontal)
            button.setContentCompressionResistancePriority(.required, for: .horizontal)
            row.addArrangedSubview(button)
        }

        if showClose {
            let close = makeCloseButton()
            bar.addSubview(close)
            NSLayoutConstraint.activate([
                close.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -8),
                close.centerYAnchor.constraint(equalTo: row.centerYAnchor)
            ])
        }

        container = host
        host.layoutIfNeeded()
        host.transform = CGAffineTransform(translationX: 0, y: -(host.bounds.height + 40))
        UIView.animate(withDuration: 0.28, delay: 0, options: .curveEaseOut) { host.transform = .identity }
    }

    // MARK: - Overlay formats

    private func showOverlay() {
        let format = message.format
        let overlay = UIView(frame: window.bounds)
        overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        overlay.backgroundColor = format == "full_screen" ? background : UIColor.black.withAlphaComponent(0.55)
        window.addSubview(overlay)
        container = overlay

        if format != "full_screen" {
            let dismissTap = UITapGestureRecognizer(target: self, action: #selector(backgroundTapped))
            overlay.addGestureRecognizer(dismissTap)
        }

        let card = UIView()
        card.translatesAutoresizingMaskIntoConstraints = false
        card.backgroundColor = background
        card.clipsToBounds = true
        cardView = card
        overlay.addSubview(card)

        let stack = UIStackView()
        stack.axis = .vertical
        stack.alignment = .fill
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)

        switch format {
        case "full_screen":
            NSLayoutConstraint.activate([
                card.topAnchor.constraint(equalTo: overlay.topAnchor),
                card.bottomAnchor.constraint(equalTo: overlay.bottomAnchor),
                card.leadingAnchor.constraint(equalTo: overlay.leadingAnchor),
                card.trailingAnchor.constraint(equalTo: overlay.trailingAnchor),
                stack.centerYAnchor.constraint(equalTo: card.centerYAnchor),
                stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 28),
                stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -28)
            ])
            stack.spacing = 14
            stack.alignment = .center
            if let url = content["imageUrl"] as? String, let picture = makeImage(url, height: 220, corner: 14) {
                stack.addArrangedSubview(picture)
                picture.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            }
            addLabels(to: stack, title: content["title"] as? String, body: content["message"] as? String, size: 22, alignment: .center)
            addButtonIfNeeded(to: stack)
        case "bottom_sheet":
            card.layer.cornerRadius = 22
            card.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
            NSLayoutConstraint.activate([
                card.leadingAnchor.constraint(equalTo: overlay.leadingAnchor),
                card.trailingAnchor.constraint(equalTo: overlay.trailingAnchor),
                card.bottomAnchor.constraint(equalTo: overlay.bottomAnchor),
                stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 26),
                stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 22),
                stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -22),
                stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -28)
            ])
            stack.spacing = 12
            stack.alignment = .center
            if let url = content["imageUrl"] as? String, let picture = makeImage(url, height: 110, corner: 14) {
                stack.addArrangedSubview(picture)
                picture.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            }
            addLabels(to: stack, title: content["title"] as? String, body: content["message"] as? String, size: 20, alignment: .center)
            addButtonIfNeeded(to: stack)
        default:
            card.layer.cornerRadius = 18
            NSLayoutConstraint.activate([
                card.centerXAnchor.constraint(equalTo: overlay.centerXAnchor),
                card.centerYAnchor.constraint(equalTo: overlay.centerYAnchor),
                card.widthAnchor.constraint(lessThanOrEqualToConstant: format == "image" ? 460 : 420),
                card.leadingAnchor.constraint(greaterThanOrEqualTo: overlay.leadingAnchor, constant: 20),
                card.trailingAnchor.constraint(lessThanOrEqualTo: overlay.trailingAnchor, constant: -20),
                stack.topAnchor.constraint(equalTo: card.topAnchor),
                stack.leadingAnchor.constraint(equalTo: card.leadingAnchor),
                stack.trailingAnchor.constraint(equalTo: card.trailingAnchor),
                stack.bottomAnchor.constraint(equalTo: card.bottomAnchor)
            ])
            let preferred = card.widthAnchor.constraint(equalToConstant: 420)
            preferred.priority = .defaultHigh
            preferred.isActive = true

            if format == "image" {
                if let url = content["imageUrl"] as? String, let picture = makeImage(url, height: 260, corner: 0, fitWidth: min(460, window.bounds.width - 40)) {
                    picture.isUserInteractionEnabled = true
                    picture.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(actionTapped)))
                    stack.addArrangedSubview(picture)
                } else {
                    stack.addArrangedSubview(paddedLabels(title: content["title"] as? String, body: content["message"] as? String, hasImage: false))
                }
            } else if format == "carousel" {
                drawCarousel(in: stack)
            } else { // modal
                if let url = content["imageUrl"] as? String, let picture = makeImage(url, height: 180, corner: 0) {
                    stack.addArrangedSubview(picture)
                }
                let hasImage = (content["imageUrl"] as? String).map { $0.hasPrefix("http") } ?? false
                let padded = paddedLabels(title: content["title"] as? String, body: content["message"] as? String, hasImage: hasImage)
                stack.addArrangedSubview(padded)
                addButtonIfNeeded(to: padded.arrangedSubviews.first as? UIStackView ?? padded, bottomSpace: true)
            }
        }

        if showClose {
            let close = makeCloseButton()
            overlay.addSubview(close)
            NSLayoutConstraint.activate([
                close.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -10),
                close.topAnchor.constraint(equalTo: format == "full_screen" ? overlay.safeAreaLayoutGuide.topAnchor : card.topAnchor, constant: 10)
            ])
        }

        overlay.alpha = 0
        UIView.animate(withDuration: 0.22) { overlay.alpha = 1 }
    }

    private func drawCarousel(in stack: UIStackView) {
        let raw = content["slides"] as? [[String: Any]] ?? []
        let slides = raw.isEmpty ? [content] : raw
        var index = 0

        func draw() {
            stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
            let slide = slides[index]
            if let url = slide["imageUrl"] as? String, let picture = makeImage(url, height: 190, corner: 0) {
                stack.addArrangedSubview(picture)
            }
            let slideHasImage = (slide["imageUrl"] as? String).map { $0.hasPrefix("http") } ?? false
            let text = paddedLabels(title: slide["title"] as? String, body: slide["message"] as? String, hasImage: slideHasImage)
            stack.addArrangedSubview(text)
            let inner = (text.arrangedSubviews.first as? UIStackView) ?? text

            let dots = UIStackView()
            dots.spacing = 6
            dots.alignment = .center
            for position in slides.indices {
                let dot = UIView()
                dot.layer.cornerRadius = 4
                dot.backgroundColor = position == index ? buttonColor : UIColor.black.withAlphaComponent(0.2)
                dot.widthAnchor.constraint(equalToConstant: 8).isActive = true
                dot.heightAnchor.constraint(equalToConstant: 8).isActive = true
                dots.addArrangedSubview(dot)
            }
            inner.addArrangedSubview(dots)

            let controls = UIStackView()
            controls.spacing = 10
            if index > 0 {
                let back = makeButton("Back", compact: false, outline: true, triggersAction: false)
                back.addAction { index -= 1; draw() }
                controls.addArrangedSubview(back)
            }
            if index < slides.count - 1 {
                let next = makeButton("Next", compact: false, triggersAction: false)
                next.addAction { index += 1; draw() }
                controls.addArrangedSubview(next)
            } else {
                let label = (content["buttonText"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Done"
                let done = makeButton(label, compact: false)
                done.addTarget(self, action: #selector(actionTapped), for: .touchUpInside)
                controls.addArrangedSubview(done)
            }
            inner.addArrangedSubview(controls)
        }
        draw()
    }

    // MARK: - Pieces

    private func addLabels(to stack: UIStackView, title: String?, body: String?, size: CGFloat, alignment: NSTextAlignment) {
        if let title = title, !title.isEmpty {
            let label = UILabel()
            label.text = title
            label.font = .systemFont(ofSize: size, weight: .bold)
            label.textColor = textColor
            label.numberOfLines = 0
            label.textAlignment = alignment
            stack.addArrangedSubview(label)
        }
        if let body = body, !body.isEmpty {
            let label = UILabel()
            label.text = body
            label.font = .systemFont(ofSize: max(13, size - 5))
            label.textColor = textColor.withAlphaComponent(0.85)
            label.numberOfLines = 0
            label.textAlignment = alignment
            stack.addArrangedSubview(label)
        }
    }

    /// Text block with card padding, returned as a stack so callers can append a button.
    private func paddedLabels(title: String?, body: String?, hasImage: Bool = true) -> UIStackView {
        let inner = UIStackView()
        inner.axis = .vertical
        inner.alignment = .center
        inner.spacing = 8
        addLabels(to: inner, title: title, body: body, size: 20, alignment: .center)

        let outer = UIStackView(arrangedSubviews: [inner])
        outer.axis = .vertical
        outer.isLayoutMarginsRelativeArrangement = true
        // Leave room for the close button when there is no picture above the text.
        outer.layoutMargins = UIEdgeInsets(top: hasImage ? 22 : 40, left: 22, bottom: 22, right: 22)
        return outer
    }

    private func addButtonIfNeeded(to stack: UIStackView, bottomSpace: Bool = false) {
        guard let label = content["buttonText"] as? String, !label.isEmpty else { return }
        let button = makeButton(label, compact: false)
        stack.addArrangedSubview(button)
        _ = bottomSpace
    }

    private func makeButton(_ title: String, compact: Bool, outline: Bool = false, triggersAction: Bool = true) -> UIButton {
        let button = UIButton(type: .custom)
        button.setTitle(title, for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: compact ? 13 : 15, weight: .semibold)
        button.setTitleColor(outline ? textColor : buttonTextColor, for: .normal)
        button.backgroundColor = outline ? .clear : buttonColor
        button.layer.cornerRadius = 10
        if outline {
            button.layer.borderWidth = 1
            button.layer.borderColor = UIColor.black.withAlphaComponent(0.2).cgColor
        }
        let vertical: CGFloat = compact ? 8 : 12
        let horizontal: CGFloat = compact ? 14 : 22
        button.contentEdgeInsets = UIEdgeInsets(top: vertical, left: horizontal, bottom: vertical, right: horizontal)
        if triggersAction {
            button.addTarget(self, action: #selector(actionTapped), for: .touchUpInside)
        }
        return button
    }

    private func makeCloseButton() -> UIButton {
        let button = UIButton(type: .custom)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setTitle("\u{00D7}", for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: 20)
        button.setTitleColor(.white, for: .normal)
        button.backgroundColor = UIColor.black.withAlphaComponent(0.35)
        button.layer.cornerRadius = 15
        button.accessibilityLabel = "Close"
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 30),
            button.heightAnchor.constraint(equalToConstant: 30)
        ])
        button.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        return button
    }

    /// - Parameter fitWidth: when set, the view is sized to the image's own aspect ratio at that
    ///   width once it loads (used by the image-only format so nothing is cropped), instead of
    ///   cropping to a fixed `height`.
    private func makeImage(_ urlString: String, height: CGFloat, corner: CGFloat, fitWidth: CGFloat? = nil) -> UIImageView? {
        guard urlString.hasPrefix("https://") || urlString.hasPrefix("http://"), let url = URL(string: urlString) else { return nil }
        let view = UIImageView()
        view.contentMode = fitWidth == nil ? .scaleAspectFill : .scaleAspectFit
        view.clipsToBounds = true
        view.layer.cornerRadius = corner
        view.backgroundColor = UIColor.black.withAlphaComponent(0.08)
        let heightConstraint = view.heightAnchor.constraint(equalToConstant: height)
        heightConstraint.isActive = true

        func apply(_ image: UIImage) {
            view.image = image
            if let width = fitWidth, image.size.width > 0 {
                heightConstraint.constant = (width * image.size.height / image.size.width).rounded()
            }
        }

        if let cached = Self.images.object(forKey: urlString as NSString) {
            apply(cached)
        } else {
            URLSession.shared.dataTask(with: url) { data, _, _ in
                guard let data = data, let image = UIImage(data: data) else { return }
                Self.images.setObject(image, forKey: urlString as NSString)
                DispatchQueue.main.async { apply(image) }
            }.resume()
        }
        return view
    }

    // MARK: - Actions

    @objc private func actionTapped() {
        guard !finished else { return }
        finished = true
        tearDown { [weak self] in self?.onAction?(self?.actionUrl) }
    }

    @objc private func closeTapped() { dismiss() }
    @objc private func backgroundTapped(_ gesture: UITapGestureRecognizer) {
        // Taps on the card itself belong to its buttons, not to the dimmed background.
        if let card = cardView, let overlay = container, card.frame.contains(gesture.location(in: overlay)) { return }
        dismiss()
    }

    private func dismiss() {
        guard !finished else { return }
        finished = true
        tearDown { [weak self] in self?.onDismissed?() }
    }

    private func tearDown(_ completion: @escaping () -> Void) {
        guard let view = container else { completion(); return }
        UIView.animate(withDuration: 0.2, animations: {
            view.alpha = 0
            if self.message.format == "banner" {
                view.transform = CGAffineTransform(translationX: 0, y: -(view.bounds.height + 40))
            }
        }, completion: { _ in
            view.removeFromSuperview()
            completion()
        })
        container = nil
    }

    // MARK: - Helpers

    private static func color(_ hex: String?, fallback: UIColor) -> UIColor {
        guard var value = hex?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return fallback }
        if value.hasPrefix("#") { value.removeFirst() }
        guard value.count == 6, let number = UInt32(value, radix: 16) else { return fallback }
        return UIColor(
            red: CGFloat((number >> 16) & 0xFF) / 255,
            green: CGFloat((number >> 8) & 0xFF) / 255,
            blue: CGFloat(number & 0xFF) / 255,
            alpha: 1
        )
    }
}

/// Lets touches fall through to the app everywhere except the banner itself.
private final class BannerHostView: UIView {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        return hit === self ? nil : hit
    }
}

private final class ClosureSleeve {
    let closure: () -> Void
    init(_ closure: @escaping () -> Void) { self.closure = closure }
    @objc func invoke() { closure() }
}

private extension UIControl {
    /// Attaches a closure as a touch-up handler, keeping it alive for the control's lifetime.
    func addAction(_ closure: @escaping () -> Void) {
        let sleeve = ClosureSleeve(closure)
        addTarget(sleeve, action: #selector(ClosureSleeve.invoke), for: .touchUpInside)
        objc_setAssociatedObject(self, Unmanaged.passUnretained(sleeve).toOpaque(), sleeve, .OBJC_ASSOCIATION_RETAIN)
    }
}
