import ActivityKit
import SwiftUI
import WidgetKit

@available(iOS 16.2, *)
public struct PushFyreActivityWidget: Widget {
    public init() {}

    public var body: some WidgetConfiguration {
        ActivityConfiguration(for: PushFyreActivityAttributes.self) { context in
            PushFyreActivityLockView(state: context.state)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.center) {
                    VStack {
                        Text(PushFyreActivityText.title(context.state))
                        Text(PushFyreActivityText.detail(context.state))
                    }
                }
            } compactLeading: {
                Text(PushFyreActivityText.title(context.state))
                    .lineLimit(1)
            } compactTrailing: {
                Text(PushFyreActivityText.detail(context.state))
                    .lineLimit(1)
            } minimal: {
                Text(String(PushFyreActivityText.title(context.state).prefix(1)))
            }
        }
    }
}
