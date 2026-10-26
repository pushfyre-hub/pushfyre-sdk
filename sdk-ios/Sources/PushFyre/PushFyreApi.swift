import Foundation
import UIKit

/// Network layer. Deliberately dependency-free so the package adds no HTTP client.
enum PushFyreApi {

    private static let credentialKey = "com.wonindia.pushfyre.credential"
    private static let tokenKey = "com.wonindia.pushfyre.apnsToken"
    private static let tagsKey = "com.wonindia.pushfyre.tags"
    private static let deviceIdKey = "com.wonindia.pushfyre.deviceId"
    private static let reportedKey = "com.wonindia.pushfyre.reportedEvents"

    private static var reportedEvents: [String] {
        UserDefaults.standard.stringArray(forKey: reportedKey) ?? []
    }

    /// Keeps the most recent reports only, so the list cannot grow without bound.
    private static func markReported(_ key: String) {
        UserDefaults.standard.set(Array((reportedEvents + [key]).suffix(200)), forKey: reportedKey)
    }
    private static let environmentTag = "environment"

    // MARK: - Device metadata

    /// Marketing names for the identifiers `hw.machine` reports, so the portal's
    /// subscription list reads "iPhone 15 Pro" rather than "iPhone16,1".
    ///
    /// Only a lookup - an identifier missing from it falls through to the raw value, so a
    /// device released after this SDK still reports something usable.
    private static let modelNames: [String: String] = [
        "iPhone12,1": "iPhone 11", "iPhone12,3": "iPhone 11 Pro", "iPhone12,5": "iPhone 11 Pro Max",
        "iPhone12,8": "iPhone SE (2nd gen)",
        "iPhone13,1": "iPhone 12 mini", "iPhone13,2": "iPhone 12", "iPhone13,3": "iPhone 12 Pro",
        "iPhone13,4": "iPhone 12 Pro Max",
        "iPhone14,2": "iPhone 13 Pro", "iPhone14,3": "iPhone 13 Pro Max", "iPhone14,4": "iPhone 13 mini",
        "iPhone14,5": "iPhone 13", "iPhone14,6": "iPhone SE (3rd gen)",
        "iPhone14,7": "iPhone 14", "iPhone14,8": "iPhone 14 Plus",
        "iPhone15,2": "iPhone 14 Pro", "iPhone15,3": "iPhone 14 Pro Max",
        "iPhone15,4": "iPhone 15", "iPhone15,5": "iPhone 15 Plus",
        "iPhone16,1": "iPhone 15 Pro", "iPhone16,2": "iPhone 15 Pro Max",
        "iPhone17,1": "iPhone 16 Pro", "iPhone17,2": "iPhone 16 Pro Max",
        "iPhone17,3": "iPhone 16", "iPhone17,4": "iPhone 16 Plus", "iPhone17,5": "iPhone 16e",
        "iPad13,1": "iPad Air (4th gen)", "iPad13,2": "iPad Air (4th gen)",
        "iPad13,16": "iPad Air (5th gen)", "iPad13,17": "iPad Air (5th gen)",
        "iPad14,1": "iPad mini (6th gen)", "iPad14,2": "iPad mini (6th gen)",
        "iPad13,4": "iPad Pro 11-inch (3rd gen)", "iPad13,8": "iPad Pro 12.9-inch (5th gen)",
        "iPad14,3": "iPad Pro 11-inch (4th gen)", "iPad14,5": "iPad Pro 12.9-inch (6th gen)"
    ]

    /// Hardware identifier, e.g. `iPhone15,3`. `UIDevice.model` is not usable here: it
    /// returns only "iPhone", and `UIDevice.name` has been redacted to the model name since
    /// iOS 16 unless the app holds a special entitlement.
    private static var machineIdentifier: String {
        var info = utsname()
        uname(&info)
        return withUnsafePointer(to: &info.machine) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
        }
    }

    static var deviceName: String {
        let identifier = machineIdentifier
        // The simulator reports the host's architecture, so read the device it simulates.
        let resolved = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] ?? identifier
        let model = modelNames[resolved] ?? resolved
        let version = UIDevice.current.systemVersion
        return String("\(model) (iOS \(version))".prefix(160))
    }

    static var appVersion: String? {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    }

    // MARK: - Tags

    /// Tags persist locally so every re-registration re-sends the full accumulated set,
    /// surviving relaunches and token refreshes.
    static var storedTags: [String: String] {
        UserDefaults.standard.dictionary(forKey: tagsKey) as? [String: String] ?? [:]
    }

    @discardableResult
    static func putTags(_ tags: [String: String]) -> [String: String] {
        var merged = storedTags
        for (key, value) in tags { merged[key] = value }
        UserDefaults.standard.set(merged, forKey: tagsKey)
        return merged
    }

    @discardableResult
    static func removeTags(_ keys: [String]) -> [String: String] {
        var merged = storedTags
        for key in keys { merged.removeValue(forKey: key) }
        UserDefaults.standard.set(merged, forKey: tagsKey)
        return merged
    }

    static func uploadLiveActivityToken(
        _ config: PushFyreConfig,
        kind: String,
        token: String,
        activityKey: String?
    ) {
        guard let deviceId = deviceId, !token.isEmpty else { return }
        var body: [String: Any] = ["deviceId": deviceId, "kind": kind, "token": token]
        if let activityKey, !activityKey.isEmpty {
            body["activityKey"] = activityKey
        }
        authorizedRequest(config, method: "POST", path: "/live-activities/sdk/tokens", body: body) { _, _ in }
    }

    /// The server-issued id of this install, once it has registered at least once.
    static var deviceId: String? {
        UserDefaults.standard.string(forKey: deviceIdKey)
    }

    /// Runs `block` after every registration queued so far has finished. In-app messaging uses
    /// it so the server already knows this device when it picks messages for a segment.
    static func afterRegistration(_ block: @escaping () -> Void) {
        registrationQueue.async(execute: block)
    }

    /// Authenticated call used by in-app messaging. Drops the cached credential on 401/403 so
    /// the next call fetches a fresh one.
    static func authorizedRequest(
        _ config: PushFyreConfig,
        method: String,
        path: String,
        body: [String: Any]? = nil,
        completion: @escaping (Int, Data?) -> Void
    ) {
        guard let url = URL(string: "\(config.apiBaseUrl)\(path)") else {
            completion(0, nil)
            return
        }
        credential(config) { result in
            guard let result = result else {
                completion(0, nil)
                return
            }
            var request = URLRequest(url: url)
            request.httpMethod = method
            request.timeoutInterval = 15
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer \(result.authToken)", forHTTPHeaderField: "Authorization")
            request.setValue(result.tenantId, forHTTPHeaderField: "x-tenant-id")
            if let body = body {
                request.httpBody = try? JSONSerialization.data(withJSONObject: body)
            }
            URLSession.shared.dataTask(with: request) { data, response, _ in
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                if status == 401 || status == 403 { clearCredential() }
                completion(status, data)
            }.resume()
        }
    }

    static var cachedApnsToken: String? {
        get { UserDefaults.standard.string(forKey: tokenKey) }
        set { UserDefaults.standard.set(newValue, forKey: tokenKey) }
    }

    static func clearCredential() {
        UserDefaults.standard.removeObject(forKey: credentialKey)
    }

    /// Fetches the device credential from the public runtime endpoint and caches it. The
    /// credential is app-scoped rather than user-scoped, so caching it is safe and avoids a
    /// round trip on every launch.
    private static func credential(
        _ config: PushFyreConfig,
        completion: @escaping ((authToken: String, tenantId: String)?) -> Void
    ) {
        if let cached = UserDefaults.standard.dictionary(forKey: credentialKey) as? [String: String],
           let authToken = cached["authToken"], let tenantId = cached["tenantId"] {
            completion((authToken, tenantId))
            return
        }

        guard let url = URL(string: "\(config.apiBaseUrl)/sdk/\(config.appId)/mobile-runtime") else {
            PushFyre.log("apiBaseUrl is not a valid URL: \(config.apiBaseUrl)")
            completion(nil)
            return
        }

        URLSession.shared.dataTask(with: url) { data, response, error in
            if let error = error {
                PushFyre.log("runtime fetch failed: \(error.localizedDescription)")
                completion(nil)
                return
            }

            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let authToken = json["authToken"] as? String,
                  let tenantId = json["tenantId"] as? String else {
                PushFyre.log("runtime returned HTTP \(status) without a credential")
                completion(nil)
                return
            }

            UserDefaults.standard.set(
                ["authToken": authToken, "tenantId": tenantId], forKey: credentialKey
            )
            completion((authToken, tenantId))
        }.resume()
    }

    /// `initialize`, `register(deviceToken:)`, `login` and `sendTags`/`removeTags` each
    /// trigger their own registration call, and a fast succession of them (typical at
    /// launch, when a session is already signed in) used to race: whichever HTTP request's
    /// delete-then-replace landed on the server last won, even if it read `storedTags`
    /// before an earlier-launched call had finished writing a fuller tag set. Running every
    /// registration through this serial queue makes them run in call order instead - each
    /// waits for the previous one's full round trip (not just its dispatch) to finish before
    /// starting, so the last one queued, which read the most current local tags, is always
    /// the one that actually lands last.
    private static let registrationQueue = DispatchQueue(label: "com.wonindia.pushfyre.registration")

    static func registerDevice(
        _ config: PushFyreConfig,
        apnsToken: String,
        externalUserId: String? = nil
    ) {
        registrationQueue.async {
            let semaphore = DispatchSemaphore(value: 0)
            credential(config) { result in
                guard let result = result else {
                    PushFyre.log("no device credential; registration skipped")
                    semaphore.signal()
                    return
                }
                postDevice(config, apnsToken: apnsToken, credential: result, externalUserId: externalUserId) {
                    semaphore.signal()
                }
            }
            // Blocks this queue's background thread - never the caller's - until the whole
            // round trip (credential fetch, then the register POST) finishes exactly once.
            semaphore.wait()
        }
    }

    private static func postDevice(
        _ config: PushFyreConfig,
        apnsToken: String,
        credential: (authToken: String, tenantId: String),
        externalUserId: String?,
        completion: @escaping () -> Void
    ) {
        guard let url = URL(string: "\(config.apiBaseUrl)/devices/register") else {
            completion()
            return
        }

        // The reserved environment tag is written last so a consumer cannot overwrite it
        // with sendTag() and accidentally make a debug install look like production.
        var tags = storedTags
        tags[environmentTag] = config.environment.rawValue

        var body: [String: Any] = [
            "appId": config.appId,
            "platform": "ios",
            "token": apnsToken,
            "deviceName": deviceName,
            "language": Locale.preferredLanguages.first.map { String($0.prefix(2)) } ?? "en",
            "timezone": TimeZone.current.identifier,
            "tags": tags
        ]
        if let appVersion = appVersion {
            body["appVersion"] = appVersion
        }
        if let externalUserId = externalUserId {
            body["externalUserId"] = externalUserId
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(credential.authToken)", forHTTPHeaderField: "Authorization")
        request.setValue(credential.tenantId, forHTTPHeaderField: "x-tenant-id")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        URLSession.shared.dataTask(with: request) { data, response, error in
            defer { completion() }

            if let error = error {
                PushFyre.log("register failed: \(error.localizedDescription)")
                return
            }

            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if (200...299).contains(status) {
                // The server's device id is what later click events are attributed to.
                if let data = data,
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let deviceId = json["id"] as? String, !deviceId.isEmpty {
                    UserDefaults.standard.set(deviceId, forKey: deviceIdKey)
                }
                cachedApnsToken = apnsToken
                PushFyre.log("device registered (HTTP \(status))")
            } else if status == 401 || status == 403 {
                // A cached credential outlives its expiry; drop it so the next attempt refetches.
                clearCredential()
                PushFyre.log("credential rejected (HTTP \(status)); cleared cache for retry")
            } else {
                let text = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                PushFyre.log("register returned HTTP \(status) \(text.prefix(200))")
            }
        }.resume()
    }

    /// Reports an engagement event ("clicked") for a received notification.
    static func trackEvent(_ config: PushFyreConfig, notificationId: String, eventType: String) {
        // A notification can be both presented and tapped; count each event once.
        let eventKey = "\(notificationId)|\(eventType)"
        guard !reportedEvents.contains(eventKey) else { return }
        guard let deviceId = UserDefaults.standard.string(forKey: deviceIdKey), !deviceId.isEmpty else {
            PushFyre.log("no device id yet - \(eventType) event for \(notificationId) not sent")
            return
        }
        guard let url = URL(string: "\(config.apiBaseUrl)/notifications/events") else { return }

        credential(config) { result in
            guard let result = result else {
                PushFyre.log("no device credential; \(eventType) event not sent")
                return
            }

            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer \(result.authToken)", forHTTPHeaderField: "Authorization")
            request.setValue(result.tenantId, forHTTPHeaderField: "x-tenant-id")
            request.httpBody = try? JSONSerialization.data(withJSONObject: [
                "notificationId": notificationId,
                "deviceId": deviceId,
                "eventType": eventType
            ])

            URLSession.shared.dataTask(with: request) { data, response, error in
                if let error = error {
                    PushFyre.log("\(eventType) event failed: \(error.localizedDescription)")
                    return
                }
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                if status == 401 || status == 403 { clearCredential() }
                if (200...299).contains(status) {
                    markReported(eventKey)
                    // Authoritative badge after open/read — corrects any local race with multiple taps.
                    if eventType == "clicked" || eventType == "opened",
                       let data = data,
                       let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let badgeNumber = json["badgeCount"] as? NSNumber {
                        let badgeCount = badgeNumber.intValue
                        DispatchQueue.main.async {
                            UIApplication.shared.applicationIconBadgeNumber = max(0, badgeCount)
                        }
                    }
                }
                PushFyre.log("\(eventType) event sent (HTTP \(status))")
            }.resume()
        }
    }
}
