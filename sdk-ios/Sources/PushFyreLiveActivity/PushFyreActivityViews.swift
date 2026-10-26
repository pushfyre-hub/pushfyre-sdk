import ActivityKit
import SwiftUI

@available(iOS 16.2, *)
struct PushFyreActivityText {
    static func title(_ state: PushFyreActivityAttributes.ContentState) -> String {
        switch state.layout {
        case "score": return "\(state.home) \(state.homeScore) – \(state.awayScore) \(state.away)"
        case "price": return state.name
        case "pass": return state.title
        default: return state.title
        }
    }

    static func detail(_ state: PushFyreActivityAttributes.ContentState) -> String {
        switch state.layout {
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
            Text(PushFyreActivityText.title(state))
                .font(.headline)
            Text(PushFyreActivityText.detail(state))
                .font(.subheadline)
            if state.layout == "delivery" || state.layout == "steps" {
                ProgressView(value: state.layout == "steps" && state.total > 0 ? Double(state.current) / Double(state.total) : state.progress / 100)
            }
        }
        .padding()
    }
}
