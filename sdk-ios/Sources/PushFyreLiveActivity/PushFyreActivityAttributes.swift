import ActivityKit
import Foundation

@available(iOS 16.2, *)
public struct PushFyreActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        public var layout: String
        public var title: String
        public var status: String
        public var progress: Double
        public var step: String
        public var current: Int
        public var total: Int
        public var home: String
        public var away: String
        public var homeScore: Int
        public var awayScore: Int
        public var name: String
        public var value: String
        public var change: String
        public var changePercent: String
        public var endsAt: String
        public var code: String
        public var detail: String
        public var version: Int

        public init(
            layout: String,
            title: String = "",
            status: String = "",
            progress: Double = 0,
            step: String = "",
            current: Int = 0,
            total: Int = 0,
            home: String = "",
            away: String = "",
            homeScore: Int = 0,
            awayScore: Int = 0,
            name: String = "",
            value: String = "",
            change: String = "",
            changePercent: String = "",
            endsAt: String = "",
            code: String = "",
            detail: String = "",
            version: Int = 0
        ) {
            self.layout = layout
            self.title = title
            self.status = status
            self.progress = progress
            self.step = step
            self.current = current
            self.total = total
            self.home = home
            self.away = away
            self.homeScore = homeScore
            self.awayScore = awayScore
            self.name = name
            self.value = value
            self.change = change
            self.changePercent = changePercent
            self.endsAt = endsAt
            self.code = code
            self.detail = detail
            self.version = version
        }
    }

    public var activityKey: String
    public var layout: String

    public init(activityKey: String, layout: String) {
        self.activityKey = activityKey
        self.layout = layout
    }
}
