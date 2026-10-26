import Foundation
import UserNotifications

/// Integration settings, supplied once via `PushFyre.initialize(_:)`.
public struct PushFyreConfig {

    /// Application id issued by the push portal, e.g. `app_49e692ad`.
    public let appId: String

    /// Base URL of the push API including the version prefix, for example
    /// `https://push.example.com/api/v1`. Self-hosted deployments differ per environment,
    /// so it cannot be baked into the SDK.
    public let apiBaseUrl: String

    /// How a notification is presented while the app is in the foreground. iOS shows
    /// nothing in that state unless the delegate opts in, so the default opts in.
    public let foregroundPresentation: UNNotificationPresentationOptions

    /// Whether the SDK becomes the `UNUserNotificationCenter` delegate during
    /// initialisation. Leave `true` unless the app already owns that delegate and wants to
    /// forward the callbacks itself.
    public let managesNotificationCenterDelegate: Bool

    /// Which audience this install belongs to. Wire it to your build configuration - a
    /// `DEBUG` build as `.test` - so the portal can send a campaign to test installs only
    /// without reaching real users.
    public let environment: PushFyreEnvironment

    public init(
        appId: String,
        apiBaseUrl: String,
        foregroundPresentation: UNNotificationPresentationOptions? = nil,
        managesNotificationCenterDelegate: Bool = true,
        environment: PushFyreEnvironment = .prod
    ) {
        self.appId = appId
        self.apiBaseUrl = apiBaseUrl
        self.foregroundPresentation = foregroundPresentation ?? Self.defaultForegroundPresentation
        self.managesNotificationCenterDelegate = managesNotificationCenterDelegate
        self.environment = environment
    }

    /// `.banner` only exists from iOS 14; `.alert` is its pre-14 equivalent. Resolved at
    /// runtime so the package keeps an iOS 13 deployment target.
    public static var defaultForegroundPresentation: UNNotificationPresentationOptions {
        if #available(iOS 14.0, *) {
            return [.banner, .sound, .badge]
        } else {
            return [.alert, .sound, .badge]
        }
    }
}

/// Audience an install belongs to, reported as the reserved `environment` tag.
///
/// The portal's audience selector targets this directly, so a debug build can be pushed to
/// in isolation. Devices that never report it are treated as ``prod``.
public enum PushFyreEnvironment: String {

    /// Development and QA installs. Reachable only by "Test devices" campaigns.
    case test

    /// App Store and TestFlight builds. The default, so forgetting to set this cannot hide
    /// real users from their campaigns.
    case prod
}

/// Decides where a tapped notification goes.
///
/// - Parameters:
///   - targetUrl: link carried by the campaign or the tapped button, `nil` when neither
///     carried one.
///   - actionId: the tapped action button's identifier, `nil` when the notification body
///     itself was tapped.
/// - Returns: `true` if the app handled it, `false` to let the SDK open the link in Safari.
public typealias PushFyreTapHandler = (_ targetUrl: String?, _ actionId: String?) -> Bool
