import ActivityKit
import SwiftUI

@available(iOS 16.2, *)
struct PushFyreActivityText {
    static func blockLines(_ state: PushFyreActivityAttributes.ContentState) -> [String] {
        (state.dynamic?.blocks ?? []).flatMap { block -> [String] in
            if block.type == "row" || block.type == "column" {
                return (block.children ?? []).flatMap { item -> [String] in
                    if item.type == "row" || item.type == "column" {
                        return (item.children ?? []).compactMap { leafLine($0.type, text: $0.text, src: $0.src, label: $0.label) }
                    }
                    if let line = leafLine(item.type, text: item.text, src: item.src, label: item.label) { return [line] }
                    return []
                }
            }
            if block.type == "text", let text = block.text, !text.isEmpty { return [text] }
            if block.type == "image", let src = block.src, src.hasPrefix("https://") { return ["Image"] }
            if block.type == "button", let label = block.label, !label.isEmpty { return [label] }
            return []
        }
    }

    static func leafLine(_ type: String, text: String?, src: String?, label: String?) -> String? {
        if type == "text", let text, !text.isEmpty { return text }
        if type == "image", let src, src.hasPrefix("https://") { return "Image" }
        if type == "button", let label, !label.isEmpty { return label }
        return nil
    }

    static func title(_ state: PushFyreActivityAttributes.ContentState) -> String {
        switch state.layout {
        case "dynamic": return blockLines(state).first ?? "Update"
        case "score": return "\(state.home) \(state.homeScore) – \(state.awayScore) \(state.away)"
        case "price": return state.name
        case "pass": return state.title
        default: return state.title
        }
    }

    static func detail(_ state: PushFyreActivityAttributes.ContentState) -> String {
        switch state.layout {
        case "dynamic": return blockLines(state).dropFirst().joined(separator: "\n")
        case "delivery": return state.progress > 0 ? "\(state.status) · \(Int(state.progress))%" : state.status
        case "steps": return "\(state.step) (\(state.current) of \(state.total))"
        case "price": return [state.value, state.change, state.changePercent].filter { !$0.isEmpty }.joined(separator: " ")
        case "countdown": return state.endsAt
        case "pass": return [state.code, state.detail].filter { !$0.isEmpty }.joined(separator: " · ")
        default: return state.status
        }
    }
}

@available(iOS 16.2, *)
struct PushFyreActivityLockView: View {
    let state: PushFyreActivityAttributes.ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if state.layout == "dynamic" {
                PushFyreActivityBlocks(blocks: state.dynamic?.blocks ?? [])
            } else {
                Text(PushFyreActivityText.title(state))
                    .font(.headline)
                Text(PushFyreActivityText.detail(state))
                    .font(.subheadline)
                if state.layout == "delivery" || state.layout == "steps" {
                    ProgressView(value: state.layout == "steps" && state.total > 0 ? Double(state.current) / Double(state.total) : state.progress / 100)
                }
            }
        }
        .padding()
    }
}

@available(iOS 16.2, *)
struct PushFyreActivityBlocks: View {
    let blocks: [PushFyreActivityAttributes.ContentState.Block]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                if block.type == "row" || block.type == "column" {
                    PushFyreActivityGroup(block: block)
                } else {
                    PushFyreActivityLeaf(
                        type: block.type,
                        text: block.text,
                        src: block.src,
                        label: block.label,
                        actionValue: block.action?.value,
                        align: block.align,
                        size: block.size,
                        color: block.color,
                        background: block.background
                    )
                }
            }
        }
    }
}

@available(iOS 16.2, *)
struct PushFyreActivityGroup: View {
    let block: PushFyreActivityAttributes.ContentState.Block

    var body: some View {
        let items = block.children ?? []
        Group {
            if block.type == "row" {
                HStack(alignment: .center, spacing: 6) {
                    ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                        itemView(item)
                    }
                }
            } else {
                VStack(alignment: frame(block.align), spacing: 4) {
                    ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                        itemView(item)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: Alignment(horizontal: frame(block.align), vertical: .center))
        .padding(block.background == nil ? 0 : 6)
        .background(paint(block.background))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private func itemView(_ item: PushFyreActivityAttributes.ContentState.Item) -> some View {
        if item.type == "row" || item.type == "column" {
            let leaves = item.children ?? []
            Group {
                if item.type == "row" {
                    HStack(alignment: .center, spacing: 6) {
                        ForEach(Array(leaves.enumerated()), id: \.offset) { _, leaf in
                            leafView(leaf)
                        }
                    }
                } else {
                    VStack(alignment: frame(item.align), spacing: 4) {
                        ForEach(Array(leaves.enumerated()), id: \.offset) { _, leaf in
                            leafView(leaf)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: Alignment(horizontal: frame(item.align), vertical: .center))
            .padding(item.background == nil ? 0 : 6)
            .background(paint(item.background))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        } else {
            leafView(item)
        }
    }

    private func leafView(_ item: PushFyreActivityAttributes.ContentState.Item) -> some View {
        drawn(type: item.type, text: item.text, src: item.src, label: item.label, actionValue: item.action?.value, align: item.align, size: item.size, color: item.color, background: item.background)
    }

    private func leafView(_ leaf: PushFyreActivityAttributes.ContentState.Leaf) -> some View {
        drawn(type: leaf.type, text: leaf.text, src: leaf.src, label: leaf.label, actionValue: leaf.action?.value, align: leaf.align, size: leaf.size, color: leaf.color, background: leaf.background)
    }

    private func drawn(type: String, text: String?, src: String?, label: String?, actionValue: String?, align: String?, size: String?, color: String?, background: String?) -> some View {
        PushFyreActivityLeaf(type: type, text: text, src: src, label: label, actionValue: actionValue, align: align, size: size, color: color, background: background)
    }
}

@available(iOS 16.2, *)
struct PushFyreActivityLeaf: View {
    let type: String
    let text: String?
    let src: String?
    let label: String?
    let actionValue: String?
    let align: String?
    let size: String?
    let color: String?
    let background: String?

    var body: some View {
        Group {
            if type == "text", let text, !text.isEmpty {
                Text(text).font(font).foregroundStyle(paint(color) ?? .primary)
            } else if type == "image", let src, src.hasPrefix("https://") {
                Text("Image").font(font).foregroundStyle(paint(color) ?? .secondary)
            } else if type == "button", let label, !label.isEmpty {
                if let actionValue, let url = URL(string: actionValue), actionValue.hasPrefix("https://") {
                    Link(label, destination: url).font(font.weight(.semibold))
                } else {
                    Text(label).font(font.weight(.semibold)).foregroundStyle(paint(color) ?? .primary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: Alignment(horizontal: frame(align), vertical: .center))
        .padding(background == nil ? 0 : 4)
        .background(paint(background))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var font: Font {
        switch size {
        case "lg": return .headline
        case "sm": return .caption2
        default: return .caption
        }
    }
}

@available(iOS 16.2, *)
private func frame(_ align: String?) -> HorizontalAlignment {
    switch align {
    case "center": return .center
    case "right": return .trailing
    default: return .leading
    }
}

@available(iOS 16.2, *)
private func paint(_ value: String?) -> Color? {
    guard let value, value.count == 7, value.hasPrefix("#") else { return nil }
    let digits = value.dropFirst()
    guard let number = Int(digits, radix: 16) else { return nil }
    return Color(
        red: Double((number >> 16) & 0xff) / 255,
        green: Double((number >> 8) & 0xff) / 255,
        blue: Double(number & 0xff) / 255
    )
}
