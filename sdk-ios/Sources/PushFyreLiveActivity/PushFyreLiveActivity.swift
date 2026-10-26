import ActivityKit
import Foundation
import PushFyre

@available(iOS 16.2, *)
public enum PushFyreLiveActivity {
    /// Starts an activity from inside the app and keeps its update token registered.
    @discardableResult
    public static func start(
        key: String,
        layout: String,
        state: PushFyreActivityAttributes.ContentState
    ) async throws -> String {
        let attributes = PushFyreActivityAttributes(activityKey: key, layout: layout)
        let activity = try Activity.request(
            attributes: attributes,
            content: ActivityContent(state: state, staleDate: nil),
            pushType: .token
        )
        observe(activity)
        return activity.id
    }

    /// Listens for push-to-start tokens on iOS 17.2 and later, and for update tokens on activities already running.
    public static func enable() {
        if #available(iOS 17.2, *) {
            Task {
                for await token in Activity<PushFyreActivityAttributes>.pushToStartTokenUpdates {
                    PushFyre.uploadLiveActivityToken(kind: "ios_push_to_start", token: hex(token), activityKey: nil)
                }
            }
        }
        Task {
            for await activity in Activity<PushFyreActivityAttributes>.activityUpdates {
                observe(activity)
            }
        }
    }

    private static func observe(_ activity: Activity<PushFyreActivityAttributes>) {
        Task {
            for await token in activity.pushTokenUpdates {
                PushFyre.uploadLiveActivityToken(
                    kind: "ios_update",
                    token: hex(token),
                    activityKey: activity.attributes.activityKey
                )
            }
        }
    }

    private static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }
}
