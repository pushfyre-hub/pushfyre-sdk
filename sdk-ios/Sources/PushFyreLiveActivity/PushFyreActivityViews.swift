import ActivityKit
import SwiftUI

@available(iOS 16.2, *)
struct PushFyreActivityText {
    static func blockLines(_ state: PushFyreActivityAttributes.ContentState) -> [String] {
        (state.dynamic?.blocks ?? []).compactMap { block in
            if block.type == "text", let text = block.text, !text.isEmpty { return text }
            if block.type == "image", let src = block.src, src.hasPrefix("https://") { return "Image" }
            if block.type == "button", let label = block.label, !label.isEmpty { return label }
            return nil
        }
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
                if block.type == "text", let text = block.text, !text.isEmpty {
                    Text(text).font(.caption)
                } else if block.type == "image", let src = block.src, src.hasPrefix("https://") {
                    Text("Image").font(.caption)
                } else if block.type == "button", let label = block.label, !label.isEmpty {
                    if let value = block.action?.value, let url = URL(string: value), value.hasPrefix("https://") {
                        Link(label, destination: url).font(.caption.weight(.semibold))
                    } else {
                        Text(label).font(.caption.weight(.semibold))
                    }
                }
            }
        }
    }
}
