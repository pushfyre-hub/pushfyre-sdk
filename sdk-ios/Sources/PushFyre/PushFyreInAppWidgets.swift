import UIKit

/// Draws interactive widgets. Classic banners and popups stay in PushFyreInAppRenderer.
enum PushFyreInAppWidgets {

    private static let formats: Set<String> = [
        "poll", "slider", "scratch", "flash", "feedback", "yes_no",
        "checklist", "quiz", "image_choice", "countdown", "copy_code"
    ]

    static func handles(_ format: String) -> Bool {
        formats.contains(format)
    }

    static func present(window: UIWindow, message: InAppMessage, onShown: @escaping () -> Void, onDismissed: @escaping () -> Void, onRespond: @escaping ([String: Any]) -> Void) {
        let content = message.content
        let dim = UIView(frame: window.bounds)
        dim.backgroundColor = UIColor.black.withAlphaComponent(0.55)
        dim.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        let card = UIStackView()
        card.axis = .vertical
        card.spacing = 8
        card.translatesAutoresizingMaskIntoConstraints = false
        card.layoutMargins = UIEdgeInsets(top: 20, left: 16, bottom: 20, right: 16)
        card.isLayoutMarginsRelativeArrangement = true
        let backdrop = UIView()
        backdrop.translatesAutoresizingMaskIntoConstraints = false
        backdrop.backgroundColor = uiColor(content["backgroundColor"] as? String, fallback: .white)
        backdrop.layer.cornerRadius = 16
        dim.addSubview(backdrop)
        let textColor = uiColor(content["textColor"] as? String, fallback: .black)
        let buttonColor = uiColor(content["buttonColor"] as? String, fallback: UIColor(red: 0.91, green: 0.20, blue: 0.10, alpha: 1))
        var closed = false
        func finish(_ answer: [String: Any]?) {
            if closed { return }
            closed = true
            dim.removeFromSuperview()
            if let answer = answer { onRespond(answer) } else { onDismissed() }
        }
        addContent(content, to: card, textColor: textColor, buttonColor: buttonColor)
        switch message.format {
        case "poll":
            for choice in strings(content["choices"]) {
                card.addArrangedSubview(button(choice, color: buttonColor) { finish(["choice": choice]) })
            }
        case "yes_no":
            card.addArrangedSubview(button("Yes", color: buttonColor) { finish(["value": "yes"]) })
            card.addArrangedSubview(button("No", color: buttonColor) { finish(["value": "no"]) })
        case "slider":
            let min = content["min"] as? Double ?? Double(content["min"] as? Int ?? 0)
            let max = content["max"] as? Double ?? Double(content["max"] as? Int ?? 10)
            let slider = UISlider()
            slider.minimumValue = Float(min)
            slider.maximumValue = Float(max)
            slider.value = Float(min)
            let readout = UILabel()
            readout.textColor = textColor
            readout.text = "\(Int(min))"
            slider.addTarget(readout, action: #selector(UILabel.sliderChanged(_:)), for: .valueChanged)
            card.addArrangedSubview(slider)
            card.addArrangedSubview(readout)
            card.addArrangedSubview(button("Submit", color: buttonColor) { finish(["value": Int(slider.value)]) })
        case "scratch":
            card.addArrangedSubview(button("Scratch to reveal", color: buttonColor) { finish(["revealed": true]) })
        case "flash":
            card.addArrangedSubview(button(text(content["front"]).isEmpty ? "Front" : text(content["front"]), color: buttonColor) { finish(["flipped": true]) })
        case "feedback":
            var score = 0
            let stars = UIStackView()
            stars.axis = .horizontal
            stars.spacing = 4
            for star in 1...5 {
                stars.addArrangedSubview(button("★", color: buttonColor) { score = star })
            }
            card.addArrangedSubview(stars)
            let comment = UITextField()
            comment.placeholder = "Comment"
            comment.borderStyle = .roundedRect
            card.addArrangedSubview(comment)
            card.addArrangedSubview(button("Send", color: buttonColor) {
                guard score >= 1 else { return }
                finish(["score": score, "comment": String((comment.text ?? "").prefix(280))])
            })
        case "checklist":
            var boxes: [UISwitch: String] = [:]
            for item in strings(content["items"]) {
                let row = UIStackView()
                row.axis = .horizontal
                row.spacing = 8
                let toggle = UISwitch()
                boxes[toggle] = item
                let label = UILabel()
                label.text = item
                label.textColor = textColor
                row.addArrangedSubview(toggle)
                row.addArrangedSubview(label)
                card.addArrangedSubview(row)
            }
            card.addArrangedSubview(button("Done", color: buttonColor) {
                let checked = boxes.compactMap { $0.key.isOn ? $0.value : nil }
                finish(["checked": checked])
            })
        case "quiz":
            addQuiz(content, to: card, buttonColor: buttonColor, finish: finish)
        case "image_choice":
            let choices = content["imageChoices"] as? [[String: Any]] ?? []
            for item in choices {
                let label = text(item["label"])
                card.addArrangedSubview(button(label.isEmpty ? "Picture" : label, color: buttonColor) { finish(["label": label]) })
            }
        case "countdown":
            let label = UILabel()
            label.textAlignment = .center
            label.font = .boldSystemFont(ofSize: 22)
            label.textColor = textColor
            label.text = remaining(text(content["endsAt"]))
            card.addArrangedSubview(label)
        case "copy_code":
            let code = text(content["code"])
            card.addArrangedSubview(button(code.isEmpty ? "Copy" : code, color: buttonColor) {
                UIPasteboard.general.string = code
                finish(["copied": true])
            })
        default:
            break
        }
        card.addArrangedSubview(button("Close", color: .systemGray5) { finish(nil) })
        dim.addSubview(card)
        NSLayoutConstraint.activate([
            card.leadingAnchor.constraint(equalTo: dim.leadingAnchor, constant: 16),
            card.trailingAnchor.constraint(equalTo: dim.trailingAnchor, constant: -16),
            card.bottomAnchor.constraint(equalTo: dim.safeAreaLayoutGuide.bottomAnchor, constant: -16),
            backdrop.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            backdrop.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            backdrop.topAnchor.constraint(equalTo: card.topAnchor),
            backdrop.bottomAnchor.constraint(equalTo: card.bottomAnchor)
        ])
        window.addSubview(dim)
        onShown()
    }

    private static func addContent(_ content: [String: Any], to card: UIStackView, textColor: UIColor, buttonColor: UIColor) {
        switch text(content["contentKind"]).isEmpty ? "text" : text(content["contentKind"]) {
        case "gift":
            let label = UILabel()
            label.textColor = textColor
            label.text = text(content["giftLabel"]) + " · " + text(content["code"])
            card.addArrangedSubview(label)
        case "youtube":
            let id = youtubeId(text(content["youtubeUrl"]))
            card.addArrangedSubview(button(id.isEmpty ? "YouTube link" : "Play on YouTube", color: .black) {
                if let url = URL(string: "https://www.youtube.com/watch?v=\(id)"), !id.isEmpty {
                    UIApplication.shared.open(url)
                }
            })
        default:
            if !text(content["title"]).isEmpty {
                let title = UILabel()
                title.font = .boldSystemFont(ofSize: 18)
                title.textColor = textColor
                title.numberOfLines = 0
                title.text = text(content["title"])
                card.addArrangedSubview(title)
            }
            if !text(content["message"]).isEmpty {
                let message = UILabel()
                message.textColor = textColor
                message.numberOfLines = 0
                message.text = text(content["message"])
                card.addArrangedSubview(message)
            }
        }
    }

    private static func addQuiz(_ content: [String: Any], to card: UIStackView, buttonColor: UIColor, finish: @escaping ([String: Any]?) -> Void) {
        let questions = content["questions"] as? [[String: Any]] ?? []
        let stage = UIStackView()
        stage.axis = .vertical
        stage.spacing = 8
        var index = 0
        var answers: [Int] = []
        func draw() {
            stage.arrangedSubviews.forEach { view in
                stage.removeArrangedSubview(view)
                view.removeFromSuperview()
            }
            guard index < questions.count else { return }
            let item = questions[index]
            let prompt = UILabel()
            prompt.numberOfLines = 0
            prompt.text = text(item["prompt"])
            stage.addArrangedSubview(prompt)
            let choices = item["choices"] as? [String] ?? []
            for (choiceIndex, choice) in choices.enumerated() {
                stage.addArrangedSubview(button(choice, color: buttonColor) {
                    answers.append(choiceIndex)
                    index += 1
                    if index >= questions.count {
                        var score = 0
                        for (position, picked) in answers.enumerated() {
                            let correct = questions[position]["correct"] as? Int ?? 0
                            if picked == correct { score += 1 }
                        }
                        finish(["score": score, "answers": answers])
                    } else {
                        draw()
                    }
                })
            }
        }
        draw()
        card.addArrangedSubview(stage)
    }

    private static func button(_ title: String, color: UIColor, action: @escaping () -> Void) -> UIButton {
        let button = TapButton(type: .system)
        button.setTitle(title, for: .normal)
        button.backgroundColor = color
        button.setTitleColor(color == .systemGray5 ? .darkGray : .white, for: .normal)
        button.layer.cornerRadius = 10
        button.contentEdgeInsets = UIEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        button.onTap = action
        button.addTarget(button, action: #selector(TapButton.tapped), for: .touchUpInside)
        return button
    }

    private static func strings(_ value: Any?) -> [String] {
        (value as? [String] ?? []).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    private static func text(_ value: Any?) -> String {
        (value as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func youtubeId(_ url: String) -> String {
        guard let match = url.range(of: #"(?:youtube\.com/watch\?v=|youtu\.be/|youtube\.com/embed/)([\w-]{6,})"#, options: .regularExpression) else { return "" }
        let found = String(url[match])
        return found.split(whereSeparator: { $0 == "/" || $0 == "=" }).last.map(String.init) ?? ""
    }

    private static func remaining(_ value: String) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm"
        let end = formatter.date(from: value)?.timeIntervalSince1970 ?? 0
        let left = max(0, end - Date().timeIntervalSince1970)
        return "\(Int(left) / 3600)h \((Int(left) % 3600) / 60)m left"
    }

    private static func uiColor(_ value: String?, fallback: UIColor) -> UIColor {
        guard var hex = value?.trimmingCharacters(in: .whitespaces), hex.hasPrefix("#"), hex.count == 7 else { return fallback }
        hex.removeFirst()
        var number: UInt64 = 0
        guard Scanner(string: hex).scanHexInt64(&number) else { return fallback }
        return UIColor(red: CGFloat((number >> 16) & 0xff) / 255, green: CGFloat((number >> 8) & 0xff) / 255, blue: CGFloat(number & 0xff) / 255, alpha: 1)
    }
}

private final class TapButton: UIButton {
    var onTap: (() -> Void)?
    @objc func tapped() { onTap?() }
}

private extension UILabel {
    @objc func sliderChanged(_ slider: UISlider) {
        text = "\(Int(slider.value))"
    }
}
