import UIKit

enum PushFyreDynamic {
    private static let pattern = try? NSRegularExpression(pattern: "\\{\\{\\s*([A-Za-z0-9_.-]{1,64})\\s*\\}\\}")

    static func fill(_ value: String, tags: [String: String]) -> String {
        guard value.contains("{{"), let pattern else { return value }
        let range = NSRange(value.startIndex..., in: value)
        var result = value
        let matches = pattern.matches(in: value, range: range).reversed()
        for match in matches {
            guard let nameRange = Range(match.range(at: 1), in: value), let full = Range(match.range, in: result) else { continue }
            let name = String(value[nameRange])
            result.replaceSubrange(full, with: tags[name] ?? "")
        }
        return result
    }

    static func fill(_ content: [String: Any], tags: [String: String]) -> [String: Any] {
        var next = content
        for (key, value) in content {
            if let text = value as? String {
                next[key] = fill(text, tags: tags)
            }
        }
        if var action = content["action"] as? [String: Any] {
            if let value = action["value"] as? String { action["value"] = fill(value, tags: tags) }
            next["action"] = action
        }
        if var dynamic = content["dynamic"] as? [String: Any], let blocks = dynamic["blocks"] as? [[String: Any]] {
            dynamic["blocks"] = blocks.map { block -> [String: Any] in
                var copy = block
                for key in ["text", "src", "label"] {
                    if let text = copy[key] as? String { copy[key] = fill(text, tags: tags) }
                }
                if var action = copy["action"] as? [String: Any], let value = action["value"] as? String {
                    action["value"] = fill(value, tags: tags)
                    copy["action"] = action
                }
                return copy
            }
            next["dynamic"] = dynamic
        }
        return next
    }

    static func views(from content: [String: Any], textColor: UIColor, buttonColor: UIColor, onOpen: @escaping (String) -> Void) -> [UIView] {
        guard let dynamic = content["dynamic"] as? [String: Any], let blocks = dynamic["blocks"] as? [[String: Any]] else { return [] }
        return blocks.compactMap { block in
            let type = block["type"] as? String ?? ""
            if type == "text", let text = block["text"] as? String, !text.isEmpty {
                let label = UILabel()
                label.text = text
                label.textColor = textColor
                label.font = .systemFont(ofSize: 14)
                label.numberOfLines = 0
                return label
            }
            if type == "image", let src = block["src"] as? String, src.hasPrefix("https://") {
                let label = UILabel()
                label.text = "Image"
                label.textColor = textColor
                label.font = .systemFont(ofSize: 12)
                label.isUserInteractionEnabled = true
                label.addGestureRecognizer(TapAction(action: { onOpen(src) }))
                return label
            }
            if type == "button", let text = block["label"] as? String, !text.isEmpty {
                let button = UIButton(type: .system)
                button.setTitle(text, for: .normal)
                button.setTitleColor(.white, for: .normal)
                button.backgroundColor = buttonColor
                button.layer.cornerRadius = 10
                button.contentEdgeInsets = UIEdgeInsets(top: 10, left: 16, bottom: 10, right: 16)
                let action = block["action"] as? [String: Any]
                let kind = action?["type"] as? String ?? ""
                let value = action?["value"] as? String ?? ""
                let opener = TapTarget {
                    if kind == "dismiss" { onOpen("") }
                    else { onOpen(value) }
                }
                button.addTarget(opener, action: #selector(TapTarget.run), for: .touchUpInside)
                objc_setAssociatedObject(button, Unmanaged.passUnretained(opener).toOpaque(), opener, .OBJC_ASSOCIATION_RETAIN)
                return button
            }
            return nil
        }
    }

    static func place(_ views: [UIView], on stack: UIStackView, content: [String: Any]) {
        guard !views.isEmpty else { return }
        let above = (content["dynamic"] as? [String: Any])?["placement"] as? String == "above"
        if above {
            for (index, view) in views.enumerated() { stack.insertArrangedSubview(view, at: index) }
        } else {
            views.forEach { stack.addArrangedSubview($0) }
        }
    }
}

private final class TapTarget: NSObject {
    private let handler: () -> Void
    init(_ handler: @escaping () -> Void) { self.handler = handler }
    @objc func run() { handler() }
}

private final class TapAction: UITapGestureRecognizer {
    private let handler: () -> Void
    init(action: @escaping () -> Void) {
        handler = action
        super.init(target: nil, action: nil)
        addTarget(self, action: #selector(run))
    }
    @objc private func run() { handler() }
}
