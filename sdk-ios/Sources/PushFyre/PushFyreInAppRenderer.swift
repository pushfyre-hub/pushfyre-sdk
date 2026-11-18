import UIKit

/// Draws one in-app message over the foreground window with plain UIKit views, so the SDK
/// needs no storyboard, asset catalog or image library from the host app.
final class PushFyreInAppRenderer {

    var onShown: (() -> Void)?
    var onDismissed: (() -> Void)?
    var onAction: ((String?) -> Void)?
    var onRespond: (([String: Any]) -> Void)?
    /// A custom action id from a click, with no link for the SDK to open.
    var onNamedClick: ((String) -> Void)?

    private let window: UIWindow
    private let message: InAppMessage
    private let content: [String: Any]

    private let background: UIColor
    private let textColor: UIColor
    private let buttonColor: UIColor
    private let buttonTextColor: UIColor
    private let actionUrl: String?

    private let tapGate = BackgroundTapGate()
    private var container: UIView?
    private weak var cardView: UIView?
    private var finished = false

    private static let images = NSCache<NSString, UIImage>()

    init(window: UIWindow, message: InAppMessage) {
        self.window = window
        self.message = message
        let filled = PushFyreDynamic.fill(message.content, tags: PushFyreApi.storedTags)
        self.content = filled
        self.background = Self.color(message.content["backgroundColor"] as? String, fallback: .white)
        self.textColor = Self.color(message.content["textColor"] as? String, fallback: UIColor(red: 0.07, green: 0.09, blue: 0.15, alpha: 1))
        self.buttonColor = Self.color(message.content["buttonColor"] as? String, fallback: UIColor(red: 0.91, green: 0.2, blue: 0.1, alpha: 1))
        self.buttonTextColor = Self.color(message.content["buttonTextColor"] as? String, fallback: .white)
        self.actionUrl = (filled["action"] as? [String: Any])?["value"] as? String
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
        let top = message.format == "banner" || (message.format == "dynamic" && dynamicPlace() == "top")
        if top && hasDesigned {
            showDesignedTop()
        } else if message.format == "dynamic" && dynamicPlace() == "top" {
            showDynamicTop()
        } else if message.format == "banner" {
            showBanner()
        } else {
            showOverlay()
        }
        onShown?()
        if message.dismissAfter > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(message.dismissAfter)) { [weak self] in
                self?.dismiss()
            }
        }
    }

    private func dynamicPlace() -> String {
        let value = content["position"] as? String ?? "center"
        return ["top", "bottom", "full"].contains(value) ? value : "center"
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
        placeDynamic(on: texts)
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

    private func showDynamicTop() {
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
        host.addSubview(bar)
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: host.topAnchor),
            bar.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            bar.bottomAnchor.constraint(equalTo: host.bottomAnchor)
        ])

        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: window.safeAreaLayoutGuide.topAnchor, constant: 10),
            stack.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: showClose ? -44 : -16),
            stack.bottomAnchor.constraint(equalTo: bar.bottomAnchor, constant: -12)
        ])
        placeDynamic(on: stack)

        if showClose {
            let close = makeCloseButton()
            bar.addSubview(close)
            NSLayoutConstraint.activate([
                close.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -8),
                close.topAnchor.constraint(equalTo: stack.topAnchor)
            ])
        }

        container = host
        host.layoutIfNeeded()
        host.transform = CGAffineTransform(translationX: 0, y: -(host.bounds.height + 40))
        UIView.animate(withDuration: 0.28, delay: 0, options: .curveEaseOut) { host.transform = .identity }
    }

    private var hasDesigned: Bool {
        guard message.format != "carousel", let blocks = content["blocks"] as? [[String: Any]] else { return false }
        return !blocks.isEmpty
    }

    private func showDesignedTop() {
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
        bar.clipsToBounds = true
        host.addSubview(bar)
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: host.topAnchor),
            bar.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            bar.bottomAnchor.constraint(equalTo: host.bottomAnchor)
        ])
        paintBackground(on: bar)

        let pad = CGFloat(min(48, max(0, intValue(content["padding"], fallback: 16))))
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: window.safeAreaLayoutGuide.topAnchor, constant: pad),
            stack.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: pad),
            stack.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -pad),
            stack.bottomAnchor.constraint(equalTo: bar.bottomAnchor, constant: -pad)
        ])
        addDesigned(to: stack)
        let backgroundTap = UITapGestureRecognizer(target: self, action: #selector(designedBackgroundTapped(_:)))
        backgroundTap.delegate = tapGate
        bar.addGestureRecognizer(backgroundTap)

        if showClose {
            let close = makeCloseButton()
            bar.addSubview(close)
            NSLayoutConstraint.activate([
                close.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -8),
                close.topAnchor.constraint(equalTo: stack.topAnchor)
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
        let full = format == "full_screen" || (format == "dynamic" && dynamicPlace() == "full")
        let overlay = UIView(frame: window.bounds)
        overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        overlay.backgroundColor = full ? background : UIColor.black.withAlphaComponent(0.55)
        window.addSubview(overlay)
        container = overlay

        if !full {
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

        if hasDesigned {
            pinDesigned(card: card, stack: stack, overlay: overlay, format: format)
            addDesigned(to: stack)
        } else {
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
        case "dynamic":
            let place = dynamicPlace()
            if place == "full" {
                NSLayoutConstraint.activate([
                    card.topAnchor.constraint(equalTo: overlay.topAnchor),
                    card.bottomAnchor.constraint(equalTo: overlay.bottomAnchor),
                    card.leadingAnchor.constraint(equalTo: overlay.leadingAnchor),
                    card.trailingAnchor.constraint(equalTo: overlay.trailingAnchor),
                    stack.centerYAnchor.constraint(equalTo: card.centerYAnchor),
                    stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 28),
                    stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -28)
                ])
            } else if place == "bottom" {
                card.layer.cornerRadius = 22
                card.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
                NSLayoutConstraint.activate([
                    card.leadingAnchor.constraint(equalTo: overlay.leadingAnchor),
                    card.trailingAnchor.constraint(equalTo: overlay.trailingAnchor),
                    card.bottomAnchor.constraint(equalTo: overlay.bottomAnchor),
                    stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 36),
                    stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 22),
                    stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -22),
                    stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -28)
                ])
            } else {
                card.layer.cornerRadius = 18
                NSLayoutConstraint.activate([
                    card.centerXAnchor.constraint(equalTo: overlay.centerXAnchor),
                    card.centerYAnchor.constraint(equalTo: overlay.centerYAnchor),
                    card.widthAnchor.constraint(lessThanOrEqualToConstant: 420),
                    card.leadingAnchor.constraint(greaterThanOrEqualTo: overlay.leadingAnchor, constant: 20),
                    card.trailingAnchor.constraint(lessThanOrEqualTo: overlay.trailingAnchor, constant: -20),
                    stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 36),
                    stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 22),
                    stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -22),
                    stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -22)
                ])
                let preferredDynamic = card.widthAnchor.constraint(equalToConstant: 420)
                preferredDynamic.priority = .defaultHigh
                preferredDynamic.isActive = true
            }
            stack.spacing = 8
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
        }

        if !hasDesigned {
            placeDynamic(on: stack)
        }
        if showClose {
            let close = makeCloseButton()
            overlay.addSubview(close)
            NSLayoutConstraint.activate([
                close.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -10),
                close.topAnchor.constraint(equalTo: format == "full_screen" || (format == "dynamic" && dynamicPlace() == "full") ? overlay.safeAreaLayoutGuide.topAnchor : card.topAnchor, constant: 10)
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
        let size = CGFloat(min(48, max(16, intValue(content["closeWidth"], fallback: intValue(content["closeHeight"], fallback: 30)))))
        let button = UIButton(type: .custom)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setTitle("\u{00D7}", for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: max(14, size * 0.6))
        button.setTitleColor(.white, for: .normal)
        button.backgroundColor = UIColor.black.withAlphaComponent(0.35)
        button.layer.cornerRadius = size / 2
        button.accessibilityLabel = "Close"
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: size),
            button.heightAnchor.constraint(equalToConstant: size)
        ])
        if let url = content["closeIconUrl"] as? String, let picture = makeImage(url, height: size, corner: size / 2) {
            button.setTitle(nil, for: .normal)
            button.backgroundColor = .clear
            picture.isUserInteractionEnabled = false
            picture.translatesAutoresizingMaskIntoConstraints = false
            button.addSubview(picture)
            NSLayoutConstraint.activate([
                picture.topAnchor.constraint(equalTo: button.topAnchor),
                picture.bottomAnchor.constraint(equalTo: button.bottomAnchor),
                picture.leadingAnchor.constraint(equalTo: button.leadingAnchor),
                picture.trailingAnchor.constraint(equalTo: button.trailingAnchor)
            ])
        }
        button.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        button.accessibilityIdentifier = "inapp-close"
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

    // MARK: - Designed blocks

    private func pinDesigned(card: UIView, stack: UIStackView, overlay: UIView, format: String) {
        let full = format == "full_screen" || (format == "dynamic" && dynamicPlace() == "full")
        let bottom = format == "bottom_sheet" || (format == "dynamic" && dynamicPlace() == "bottom")
        let pad = CGFloat(min(48, max(0, intValue(content["padding"], fallback: 16))))
        paintBackground(on: card)
        stack.spacing = 8
        if full {
            NSLayoutConstraint.activate([
                card.topAnchor.constraint(equalTo: overlay.topAnchor),
                card.bottomAnchor.constraint(equalTo: overlay.bottomAnchor),
                card.leadingAnchor.constraint(equalTo: overlay.leadingAnchor),
                card.trailingAnchor.constraint(equalTo: overlay.trailingAnchor),
                stack.topAnchor.constraint(equalTo: overlay.safeAreaLayoutGuide.topAnchor, constant: pad),
                stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: pad),
                stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -pad),
                stack.bottomAnchor.constraint(lessThanOrEqualTo: overlay.safeAreaLayoutGuide.bottomAnchor, constant: -pad)
            ])
        } else if bottom {
            card.layer.cornerRadius = 22
            card.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
            NSLayoutConstraint.activate([
                card.leadingAnchor.constraint(equalTo: overlay.leadingAnchor),
                card.trailingAnchor.constraint(equalTo: overlay.trailingAnchor),
                card.bottomAnchor.constraint(equalTo: overlay.bottomAnchor),
                stack.topAnchor.constraint(equalTo: card.topAnchor, constant: pad),
                stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: pad),
                stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -pad),
                stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -pad)
            ])
        } else {
            card.layer.cornerRadius = 18
            NSLayoutConstraint.activate([
                card.centerXAnchor.constraint(equalTo: overlay.centerXAnchor),
                card.centerYAnchor.constraint(equalTo: overlay.centerYAnchor),
                card.widthAnchor.constraint(lessThanOrEqualToConstant: format == "image" ? 460 : 420),
                card.leadingAnchor.constraint(greaterThanOrEqualTo: overlay.leadingAnchor, constant: 20),
                card.trailingAnchor.constraint(lessThanOrEqualTo: overlay.trailingAnchor, constant: -20),
                stack.topAnchor.constraint(equalTo: card.topAnchor, constant: pad),
                stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: pad),
                stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -pad),
                stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -pad)
            ])
            let preferred = card.widthAnchor.constraint(equalToConstant: 420)
            preferred.priority = .defaultHigh
            preferred.isActive = true
        }
    }

    private func paintBackground(on card: UIView) {
        guard let urlString = content["backgroundImage"] as? String,
              urlString.hasPrefix("https://") || urlString.hasPrefix("http://"),
              let url = URL(string: urlString) else { return }
        let view = UIImageView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.contentMode = .scaleAspectFill
        view.clipsToBounds = true
        card.insertSubview(view, at: 0)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: card.topAnchor),
            view.bottomAnchor.constraint(equalTo: card.bottomAnchor),
            view.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: card.trailingAnchor)
        ])
        func apply(_ image: UIImage) { view.image = image }
        if let cached = Self.images.object(forKey: urlString as NSString) {
            apply(cached)
        } else {
            URLSession.shared.dataTask(with: url) { data, _, _ in
                guard let data, let image = UIImage(data: data) else { return }
                Self.images.setObject(image, forKey: urlString as NSString)
                DispatchQueue.main.async { apply(image) }
            }.resume()
        }
    }

    private func addDesigned(to stack: UIStackView) {
        let blocks = content["blocks"] as? [[String: Any]] ?? []
        for block in blocks {
            if let enabled = block["enabled"] as? Bool, !enabled { continue }
            let type = block["type"] as? String ?? "text"
            let style = block["style"] as? [String: Any] ?? [:]
            if type == "image" {
                guard let src = block["src"] as? String, let picture = makeImage(src, height: 160, corner: 10) else { continue }
                picture.isUserInteractionEnabled = true
                picture.accessibilityIdentifier = "inapp-block"
                let tap = UITapGestureRecognizer(target: self, action: #selector(designedImageTapped(_:)))
                picture.addGestureRecognizer(tap)
                objc_setAssociatedObject(picture, &Self.blockKey, BlockBox(block), .OBJC_ASSOCIATION_RETAIN)
                stack.addArrangedSubview(marginBox(picture, style: style))
            } else if type == "button" {
                let title = ((block["text"] as? String)?.isEmpty == false ? block["text"] as? String : nil) ?? (block["label"] as? String ?? "")
                guard !title.isEmpty else { continue }
                let button = UIButton(type: .custom)
                let font = designedFont(style)
                let titleColor = Self.color(style["color"] as? String, fallback: buttonTextColor)
                button.setAttributedTitle(underlined(title, font: font, color: titleColor, underline: (style["underline"] as? Bool) == true), for: .normal)
                button.backgroundColor = Self.color(style["background"] as? String, fallback: buttonColor)
                button.layer.cornerRadius = CGFloat(min(40, max(0, intValue(style["radius"], fallback: 12))))
                button.clipsToBounds = true
                button.contentEdgeInsets = UIEdgeInsets(top: 10, left: 18, bottom: 10, right: 18)
                let border = min(8, max(0, intValue(style["borderWidth"], fallback: 0)))
                if border > 0 {
                    button.layer.borderWidth = CGFloat(border)
                    button.layer.borderColor = Self.color(style["borderColor"] as? String, fallback: buttonColor).cgColor
                }
                button.addAction { [weak self] in self?.openBlock(block, alwaysClose: true) }
                let blur = min(40, max(0, intValue(style["shadowBlur"], fallback: 0)))
                let host = UIView()
                button.translatesAutoresizingMaskIntoConstraints = false
                host.addSubview(button)
                NSLayoutConstraint.activate([
                    button.topAnchor.constraint(equalTo: host.topAnchor),
                    button.bottomAnchor.constraint(equalTo: host.bottomAnchor),
                    button.leadingAnchor.constraint(equalTo: host.leadingAnchor),
                    button.trailingAnchor.constraint(equalTo: host.trailingAnchor)
                ])
                if blur > 0 {
                    host.layer.shadowColor = Self.color(style["shadowColor"] as? String, fallback: .black).cgColor
                    host.layer.shadowOpacity = 0.35
                    host.layer.shadowRadius = CGFloat(blur) / 2
                    host.layer.shadowOffset = CGSize(width: intValue(style["shadowX"], fallback: 0), height: intValue(style["shadowY"], fallback: 0))
                }
                let row = UIStackView()
                row.axis = .horizontal
                let align = style["align"] as? String
                let lead = UIView()
                let trail = UIView()
                lead.setContentHuggingPriority(.defaultLow, for: .horizontal)
                trail.setContentHuggingPriority(.defaultLow, for: .horizontal)
                if align == "left" || align == "start" {
                    row.addArrangedSubview(host)
                    row.addArrangedSubview(trail)
                } else if align == "right" || align == "end" {
                    row.addArrangedSubview(lead)
                    row.addArrangedSubview(host)
                } else {
                    row.addArrangedSubview(lead)
                    row.addArrangedSubview(host)
                    row.addArrangedSubview(trail)
                    lead.widthAnchor.constraint(equalTo: trail.widthAnchor).isActive = true
                }
                stack.addArrangedSubview(marginBox(row, style: style))
            } else {
                guard let text = block["text"] as? String, !text.isEmpty else { continue }
                let label = UILabel()
                label.numberOfLines = 0
                let color = Self.color(style["color"] as? String, fallback: textColor)
                let font = designedFont(style)
                if (style["underline"] as? Bool) == true {
                    label.attributedText = underlined(text, font: font, color: color, underline: true)
                } else {
                    label.text = text
                    label.textColor = color
                    label.font = font
                }
                label.textAlignment = textAlign(style["align"])
                stack.addArrangedSubview(marginBox(label, style: style))
            }
        }
    }

    private func marginBox(_ view: UIView, style: [String: Any]) -> UIView {
        let box = UIStackView(arrangedSubviews: [view])
        box.axis = .vertical
        box.isLayoutMarginsRelativeArrangement = true
        box.layoutMargins = UIEdgeInsets(
            top: CGFloat(min(80, max(0, intValue(style["marginTop"], fallback: 0)))),
            left: CGFloat(min(80, max(0, intValue(style["marginLeft"], fallback: 0)))),
            bottom: CGFloat(min(80, max(0, intValue(style["marginBottom"], fallback: 0)))),
            right: CGFloat(min(80, max(0, intValue(style["marginRight"], fallback: 0))))
        )
        return box
    }

    private func designedFont(_ style: [String: Any]) -> UIFont {
        let size = CGFloat(min(48, max(10, intValue(style["fontSize"], fallback: 16))))
        let bold = (style["bold"] as? Bool) == true
        let italic = (style["italic"] as? Bool) == true
        let family = style["fontFamily"] as? String
        let named: String?
        switch family {
        case "courier":
            if bold && italic { named = "Courier-BoldOblique" }
            else if bold { named = "Courier-Bold" }
            else if italic { named = "Courier-Oblique" }
            else { named = "Courier" }
        case "georgia", "lora":
            if bold && italic { named = "Georgia-BoldItalic" }
            else if bold { named = "Georgia-Bold" }
            else if italic { named = "Georgia-Italic" }
            else { named = "Georgia" }
        default:
            named = nil
        }
        if let named, let font = UIFont(name: named, size: size) { return font }
        var traits: UIFontDescriptor.SymbolicTraits = []
        if bold { traits.insert(.traitBold) }
        if italic { traits.insert(.traitItalic) }
        let base = UIFont.systemFont(ofSize: size, weight: bold ? .bold : .medium)
        if let descriptor = base.fontDescriptor.withSymbolicTraits(traits) {
            return UIFont(descriptor: descriptor, size: size)
        }
        return base
    }

    private func underlined(_ text: String, font: UIFont, color: UIColor, underline: Bool) -> NSAttributedString {
        var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        if underline { attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        return NSAttributedString(string: text, attributes: attributes)
    }

    private func textAlign(_ value: Any?) -> NSTextAlignment {
        switch value as? String {
        case "center": return .center
        case "right", "end": return .right
        default: return .left
        }
    }

    private func intValue(_ value: Any?, fallback: Int) -> Int {
        if let number = value as? Int { return number }
        if let number = value as? Double { return Int(number) }
        if let number = value as? NSNumber { return number.intValue }
        return fallback
    }

    private func openBlock(_ block: [String: Any], alwaysClose: Bool) {
        guard !finished else { return }
        let action = block["action"] as? [String: Any]
        let type = action?["type"] as? String ?? ""
        let value = action?["value"] as? String ?? ""
        let link = value.hasPrefix("http://") || value.hasPrefix("https://") || (type == "deeplink" && value.contains("://"))
        applyClicks(block["clicks"])
        if link {
            finished = true
            tearDown { [weak self] in self?.onAction?(value) }
        } else if alwaysClose || type == "dismiss" || (block["dismissOnClick"] as? Bool) == true {
            dismiss()
        }
    }

    private func applyClicks(_ raw: Any?) {
        let clicks = raw as? [[String: Any]] ?? []
        for item in clicks {
            let kind = item["kind"] as? String ?? ""
            if kind == "tag", let key = item["key"] as? String, !key.trimmingCharacters(in: .whitespaces).isEmpty {
                PushFyre.sendTag(key: key, value: item["value"] as? String ?? "")
            } else if kind == "outcome", let name = item["name"] as? String {
                sendOutcome(name)
            } else if kind == "action", let name = item["name"] as? String, !name.trimmingCharacters(in: .whitespaces).isEmpty {
                onNamedClick?(name)
            }
        }
    }

    private func sendOutcome(_ name: String) {
        let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty, cleaned.range(of: "^[A-Za-z0-9_.: -]{1,80}$", options: .regularExpression) != nil,
              let config = PushFyre.config, let deviceId = PushFyreApi.deviceId else { return }
        PushFyreApi.authorizedRequest(config, method: "POST", path: "/devices/\(deviceId)/session", body: [
            "phase": "outcome",
            "outcomeName": cleaned,
            "outcomeWeight": 1,
            "attribution": "unattributed"
        ]) { _, _ in }
    }

    @objc private func designedImageTapped(_ gesture: UITapGestureRecognizer) {
        guard let box = objc_getAssociatedObject(gesture.view as Any, &Self.blockKey) as? BlockBox else { return }
        openBlock(box.block, alwaysClose: false)
    }

    private static var blockKey: UInt8 = 0

    // MARK: - Actions

    private func placeDynamic(on stack: UIStackView) {
        let views = PushFyreDynamic.views(from: content, textColor: textColor, buttonColor: buttonColor) { [weak self] url in
            guard let self, !self.finished else { return }
            self.finished = true
            if url.isEmpty {
                self.tearDown { [weak self] in self?.onDismissed?() }
            } else {
                self.tearDown { [weak self] in self?.onAction?(url) }
            }
        }
        PushFyreDynamic.place(views, on: stack, content: content)
    }

    @objc private func actionTapped() {
        guard !finished else { return }
        // A dismiss action is a dismissal, not a click. Reporting both would count it in the click-through rate.
        let type = (content["action"] as? [String: Any])?["type"] as? String ?? ""
        if type == "dismiss" {
            dismiss()
            return
        }
        finished = true
        tearDown { [weak self] in self?.onAction?(self?.actionUrl) }
    }

    @objc private func designedBackgroundTapped(_ gesture: UITapGestureRecognizer) {
        guard let bar = gesture.view else { return }
        let hit = bar.hitTest(gesture.location(in: bar), with: nil)
        if hit is UIControl { return }
        if (hit as? UIImageView)?.accessibilityIdentifier == "inapp-block" { return }
        applyClicks(content["backgroundClicks"])
        if (content["backgroundDismissOnClick"] as? Bool) == true { dismiss() }
    }

    @objc private func closeTapped() {
        applyClicks(content["closeClicks"])
        dismiss()
    }
    @objc private func backgroundTapped(_ gesture: UITapGestureRecognizer) {
        // Taps on the card itself belong to its buttons, not to the dimmed background.
        if let card = cardView, let overlay = container, card.frame.contains(gesture.location(in: overlay)) {
            let hit = card.hitTest(gesture.location(in: card), with: nil)
            if hit is UIControl { return }
            if (hit as? UIImageView)?.accessibilityIdentifier == "inapp-block" { return }
            applyClicks(content["backgroundClicks"])
            if (content["backgroundDismissOnClick"] as? Bool) == true { dismiss() }
            return
        }
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
private final class BackgroundTapGate: NSObject, UIGestureRecognizerDelegate {
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        var view = touch.view
        while let current = view {
            if current is UIControl { return false }
            if (current as? UIImageView)?.accessibilityIdentifier == "inapp-block" { return false }
            view = current.superview
        }
        return true
    }
}

private final class BannerHostView: UIView {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        return hit === self ? nil : hit
    }
}

private final class BlockBox: NSObject {
    let block: [String: Any]
    init(_ block: [String: Any]) { self.block = block }
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
