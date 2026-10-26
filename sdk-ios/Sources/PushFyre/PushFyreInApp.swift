import Foundation
import UIKit

/// One message returned by the server, already filtered to this device.
struct InAppMessage {
    let id: String
    let name: String
    let format: String
    let content: [String: Any]
    let frequencyType: String
    let frequencyDays: Int
    let maxImpressions: Int
}

/// In-app messaging: fetches the messages that apply to this install, shows at most one at a
/// time on the foreground window, and reports impressions, clicks and dismissals.
///
/// Everything here is best effort. A failure to fetch or draw a message is logged and dropped
/// so it can never affect the host app.
enum PushFyreInApp {

    private static let defaults = UserDefaults.standard
    private static let stateQueue = DispatchQueue(label: "com.wonindia.pushfyre.inapp")

    /// Ids already shown since the process started, for the "once per session" rule.
    private static var shownThisSession = Set<String>()
    private static var showing = false
    private static var activeRenderer: PushFyreInAppRenderer?

    static var enabled = true

    // MARK: - Triggers

    static func trigger(trigger: String, eventName: String?) {
        guard enabled, let config = PushFyre.config else { return }

        var path = "/in-app/sdk/messages?appId=\(escape(config.appId))&platform=ios&trigger=\(escape(trigger))"
        if let eventName = eventName, !eventName.isEmpty { path += "&eventName=\(escape(eventName))" }
        if let deviceId = PushFyreApi.deviceId { path += "&deviceId=\(escape(deviceId))" }

        PushFyreApi.authorizedRequest(config, method: "GET", path: path) { status, data in
            guard (200...299).contains(status),
                  let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let items = json["messages"] as? [[String: Any]] else { return }

            for item in items {
                let frequency = item["frequency"] as? [String: Any]
                let message = InAppMessage(
                    id: item["id"] as? String ?? "",
                    name: item["name"] as? String ?? "",
                    format: item["format"] as? String ?? "modal",
                    content: item["content"] as? [String: Any] ?? [:],
                    frequencyType: (frequency?["type"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "every_session",
                    frequencyDays: frequency?["days"] as? Int ?? 1,
                    maxImpressions: item["maxImpressions"] as? Int ?? 0
                )
                if !message.id.isEmpty, allowed(message) {
                    DispatchQueue.main.async { present(message, config: config) }
                    return
                }
            }
        }
    }

    // MARK: - Presenting

    private static func present(_ message: InAppMessage, config: PushFyreConfig, attempt: Int = 0) {
        guard !showing else { return }
        guard let window = foregroundWindow() else {
            // The app may still be launching; try again briefly rather than losing the message.
            if attempt < 10 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    present(message, config: config, attempt: attempt + 1)
                }
            }
            return
        }

        showing = true
        let renderer = PushFyreInAppRenderer(window: window, message: message)
        activeRenderer = renderer
        renderer.onShown = {
            recordShown(message)
            report(message, config: config, event: "impression")
        }
        renderer.onDismissed = {
            finished()
            report(message, config: config, event: "dismiss")
        }
        renderer.onAction = { url in
            finished()
            report(message, config: config, event: "button_click")
            open(message: message, url: url)
        }
        renderer.show()
    }

    private static func finished() {
        showing = false
        activeRenderer = nil
    }

    private static func open(message: InAppMessage, url: String?) {
        let action = message.content["action"] as? [String: Any]
        let type = action?["type"] as? String ?? ""
        guard type != "dismiss", let target = url, !target.isEmpty else { return }

        // Let the app route it first, exactly like a tapped push notification.
        if PushFyre.tapHandler?(target, "in_app") == true { return }
        guard let destination = URL(string: target) else { return }
        UIApplication.shared.open(destination)
    }

    private static func foregroundWindow() -> UIWindow? {
        guard UIApplication.shared.applicationState == .active else { return nil }
        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .filter { $0.activationState == .foregroundActive }
            .flatMap { $0.windows }
        return windows.first(where: { $0.isKeyWindow }) ?? windows.first
    }

    // MARK: - Frequency

    private static func allowed(_ message: InAppMessage) -> Bool {
        let count = defaults.integer(forKey: "pushfyre.inapp.\(message.id).count")
        let last = defaults.double(forKey: "pushfyre.inapp.\(message.id).last")
        if message.maxImpressions > 0, count >= message.maxImpressions { return false }

        switch message.frequencyType {
        case "once":
            return count == 0
        case "every_n_days":
            guard last > 0 else { return true }
            return Date().timeIntervalSince1970 - last >= Double(max(1, message.frequencyDays)) * 86_400
        case "every_session":
            return stateQueue.sync { !shownThisSession.contains(message.id) }
        default:
            return true
        }
    }

    private static func recordShown(_ message: InAppMessage) {
        let key = "pushfyre.inapp.\(message.id)"
        defaults.set(defaults.integer(forKey: "\(key).count") + 1, forKey: "\(key).count")
        defaults.set(Date().timeIntervalSince1970, forKey: "\(key).last")
        stateQueue.sync { _ = shownThisSession.insert(message.id) }
    }

    // MARK: - Reporting

    private static func report(_ message: InAppMessage, config: PushFyreConfig, event: String) {
        var body: [String: Any] = [
            "appId": config.appId,
            "messageId": message.id,
            "platform": "ios",
            "event": event
        ]
        if let deviceId = PushFyreApi.deviceId { body["deviceId"] = deviceId }
        PushFyreApi.authorizedRequest(config, method: "POST", path: "/in-app/sdk/events", body: body) { status, _ in
            if !(200...299).contains(status) { PushFyre.log("in-app \(event) report returned HTTP \(status)") }
        }
    }

    private static func escape(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}
