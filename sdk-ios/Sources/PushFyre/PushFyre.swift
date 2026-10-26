import Foundation
import UIKit
import UserNotifications

/// Entry point for the WON push platform on iOS.
///
/// Integration is a package dependency plus two calls:
///
/// ```swift
/// // AppDelegate.application(_:didFinishLaunchingWithOptions:)
/// PushFyre.initialize(PushFyreConfig(
///     appId: "app_49e692ad",
///     apiBaseUrl: "https://push.example.com/api/v1",
///     environment: isDebugBuild ? .test : .prod
/// ))
/// PushFyre.requestAuthorization()
///
/// // APNs hands the token to the app delegate, so this one line has to be forwarded.
/// func application(_ app: UIApplication,
///                  didRegisterForRemoteNotificationsWithDeviceToken token: Data) {
///     PushFyre.register(deviceToken: token)
/// }
/// ```
///
/// The forwarding line is unavoidable without swizzling `UIApplicationDelegate`, which this
/// package deliberately does not do.
///
/// Attach tags once you know something about the user, and target them from the portal:
///
/// ```swift
/// PushFyre.sendTag(key: "deviceId", value: cfuuid)
/// PushFyre.sendTag(key: "isPremium", value: "true")
/// ```
public enum PushFyre {

    /// Campaign link fields, most specific first. `targetUrl` is what existing OneSignal
    /// campaigns put in additional data, `launchUrl` is the portal's own field.
    static let linkKeys = ["targetUrl", "deepLink", "launchUrl", "u"]

    private(set) static var config: PushFyreConfig?
    private(set) static var tapHandler: PushFyreTapHandler?

    private static let notificationCenterDelegate = PushFyreNotificationDelegate()

    /// Set `false` to silence the SDK's console output.
    public static var loggingEnabled = true

    // MARK: - Setup

    /// Idempotent: safe to call on every launch.
    public static func initialize(_ config: PushFyreConfig) {
        precondition(!config.appId.isEmpty, "PushFyreConfig.appId must not be empty")
        precondition(!config.apiBaseUrl.isEmpty, "PushFyreConfig.apiBaseUrl must not be empty")

        self.config = config

        if config.managesNotificationCenterDelegate {
            UNUserNotificationCenter.current().delegate = notificationCenterDelegate
        }

        // A token issued on a previous launch is re-registered so a reinstalled or restored
        // device does not silently stop being deliverable.
        if let token = PushFyreApi.cachedApnsToken {
            PushFyreApi.registerDevice(config, apnsToken: token)
        }

        // Queued behind the registration above, so the device is already known to the server.
        PushFyreApi.afterRegistration {
            PushFyreInApp.trigger(trigger: "app_open", eventName: nil)
        }
    }

    // MARK: - In-app messages

    /// Fires a named event that in-app messages can listen for, for example
    /// `PushFyre.trigger("checkout_started")`. Does nothing when no live campaign is waiting
    /// on that event.
    public static func trigger(_ eventName: String) {
        let name = eventName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        PushFyreInApp.trigger(trigger: "event", eventName: name)
    }

    /// Turns in-app messages off or on for this process, for example while onboarding.
    public static func setInAppMessagesEnabled(_ enabled: Bool) {
        PushFyreInApp.enabled = enabled
    }

    /// Decide where a tapped notification goes. Without a handler, links open in Safari.
    public static func setTapHandler(_ handler: PushFyreTapHandler?) {
        tapHandler = handler
    }

    /// Prompts for notification permission and, once granted, registers with APNs.
    ///
    /// iOS allows only one system prompt: after a decline the user must re-enable
    /// notifications in Settings, so call this at a point that makes sense to them.
    public static func requestAuthorization(
        options: UNAuthorizationOptions = [.alert, .sound, .badge],
        completion: ((Bool) -> Void)? = nil
    ) {
        UNUserNotificationCenter.current().requestAuthorization(options: options) { granted, error in
            if let error = error {
                log("authorization failed: \(error.localizedDescription)")
            }
            log("notification permission granted=\(granted)")

            if granted {
                DispatchQueue.main.async {
                    // No device token is issued until this runs - and the simulator never
                    // issues one at all, so APNs testing needs a physical device.
                    UIApplication.shared.registerForRemoteNotifications()
                }
            }
            completion?(granted)
        }
    }

    // MARK: - Registration

    /// Forward from `application(_:didRegisterForRemoteNotificationsWithDeviceToken:)`.
    public static func register(deviceToken: Data) {
        guard let config = config else {
            log("register(deviceToken:) called before initialize - ignored")
            return
        }

        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        log("APNs token \(token.prefix(16))…")
        PushFyreApi.registerDevice(config, apnsToken: token)
    }

    /// Forward from `application(_:didFailToRegisterForRemoteNotificationsWithError:)`.
    public static func registrationFailed(with error: Error) {
        // Usually a missing aps-environment entitlement, or a simulator build.
        log("APNs registration failed: \(error.localizedDescription)")
    }

    /// Associates this device with your own user id so campaigns can target it.
    public static func login(externalUserId: String) {
        guard let config = config else {
            log("login called before initialize - ignored")
            return
        }
        guard let token = PushFyreApi.cachedApnsToken else {
            log("login called before a device token was issued - ignored")
            return
        }
        PushFyreApi.registerDevice(config, apnsToken: token, externalUserId: externalUserId)
    }

    // MARK: - Tags

    /// Attaches a single tag to this device for targeting, the equivalent of OneSignal's
    /// `User.addTag`. Tags are stored locally and re-sent on every registration, so they
    /// survive relaunches and token refreshes.
    ///
    /// ```swift
    /// PushFyre.sendTag(key: "isPremium", value: "true")
    /// PushFyre.sendTag(key: "segmentId", value: "\(segmentId)")
    /// ```
    ///
    /// `environment` is reserved by the SDK and cannot be set here.
    public static func sendTag(key: String, value: String) {
        sendTags([key: value])
    }

    /// Attaches several tags in one round trip. See ``sendTag(key:value:)``.
    public static func sendTags(_ tags: [String: String]) {
        let accepted = tags.filter { !$0.key.isEmpty }
        guard !accepted.isEmpty else { return }

        PushFyreApi.putTags(accepted)
        syncTags()
    }

    /// Drops tags from this device so they no longer match a segment.
    public static func removeTags(_ keys: [String]) {
        guard !keys.isEmpty else { return }

        PushFyreApi.removeTags(keys)
        syncTags()
    }

    /// Drops a single tag. See ``removeTags(_:)``.
    public static func removeTag(_ key: String) {
        removeTags([key])
    }

    /// Tags currently attached to this device, as last stored locally.
    public static var tags: [String: String] {
        PushFyreApi.storedTags
    }

    /// Re-registers so the server sees the current tag set. Tags are already persisted by
    /// the time this runs, so a failed sync is repaired by the next launch rather than lost.
    private static func syncTags() {
        guard let config = config else {
            log("sendTags before initialize - stored locally, will sync on next launch")
            return
        }
        guard let token = PushFyreApi.cachedApnsToken else {
            log("sendTags before a device token was issued - will sync once APNs responds")
            return
        }
        PushFyreApi.registerDevice(config, apnsToken: token)
    }

    // MARK: - Tap handling

    /// Forward from `userNotificationCenter(_:didReceive:withCompletionHandler:)` when the
    /// app owns the notification-centre delegate itself.
    public static func handleNotificationResponse(_ response: UNNotificationResponse) {
        let userInfo = response.notification.request.content.userInfo
        let link = linkKeys
            .compactMap { userInfo[$0] as? String }
            .first { !$0.isEmpty }

        // The default identifier means the body was tapped rather than an action button.
        let actionId = response.actionIdentifier == UNNotificationDefaultActionIdentifier
            ? nil
            : response.actionIdentifier

        log("notification tapped target=\(link ?? "nil") actionId=\(actionId ?? "nil")")

        // Drop the icon badge immediately; the clicked event also decrements Devices.BadgeCount
        // so the next "Increase by" APNs send stays aligned with what the user sees.
        DispatchQueue.main.async {
            let current = UIApplication.shared.applicationIconBadgeNumber
            if current > 0 {
                UIApplication.shared.applicationIconBadgeNumber = current - 1
            }
        }

        // Tapping proves the notification arrived; the dedupe skips it if the foreground
        // callback already reported it.
        trackEvents(userInfo, ["delivered", "clicked"])

        if tapHandler?(link, actionId) == true { return }

        guard let link = link, let url = URL(string: link) else { return }
        DispatchQueue.main.async {
            UIApplication.shared.open(url)
        }
    }

    static func trackEvents(_ userInfo: [AnyHashable: Any], _ eventTypes: [String]) {
        guard let config = config,
              let notificationId = userInfo["notificationId"] as? String,
              !notificationId.isEmpty else { return }
        for eventType in eventTypes {
            PushFyreApi.trackEvent(config, notificationId: notificationId, eventType: eventType)
        }
    }

    /// Sends an ActivityKit token to PushFyre. Called by PushFyreLiveActivity.
    public static func uploadLiveActivityToken(kind: String, token: String, activityKey: String?) {
        guard let config else { return }
        PushFyreApi.uploadLiveActivityToken(config, kind: kind, token: token, activityKey: activityKey)
    }

    static func log(_ message: String) {
        guard loggingEnabled else { return }
        print("[PushFyre] \(message)")
    }
}

/// Owns the notification-centre callbacks so consumers do not have to implement them.
final class PushFyreNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        PushFyre.trackEvents(notification.request.content.userInfo, ["delivered"])
        completionHandler(PushFyre.config?.foregroundPresentation ?? PushFyreConfig.defaultForegroundPresentation)
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        PushFyre.handleNotificationResponse(response)
        completionHandler()
    }
}
