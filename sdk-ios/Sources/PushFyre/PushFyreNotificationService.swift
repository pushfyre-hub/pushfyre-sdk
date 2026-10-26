import Foundation
import UserNotifications

/// Base class for your app's Notification Service Extension.
///
/// iOS cannot show a campaign image or action buttons from the payload alone: media has to
/// be downloaded and attached before the notification is presented, and buttons only appear
/// if a category carrying them is registered. Both are the job of a service extension, which
/// has to be a separate target in your app - a Swift package cannot add one for you.
///
/// Create the target (File -> New -> Target -> Notification Service Extension), add
/// PushFyre to it, and replace the generated class with:
///
/// ```swift
/// import PushFyre
///
/// class NotificationService: PushFyreNotificationService {}
/// ```
///
/// Nothing else is needed; override `didReceive` only if you want to add your own handling.
open class PushFyreNotificationService: UNNotificationServiceExtension {

    /// Must match the category id the worker sets on notifications that carry buttons.
    public static let dynamicCategory = "pushfyre_dynamic"

    private static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "gif"]
    private static let audioExtensions: Set<String> = ["mp3", "wav", "aiff", "aif", "m4a", "caf"]
    private static let videoExtensions: Set<String> = ["mp4", "m4v", "mov"]
    private static var mediaExtensions: Set<String> {
        imageExtensions.union(audioExtensions).union(videoExtensions)
    }

    private var contentHandler: ((UNNotificationContent) -> Void)?
    private var bestAttempt: UNMutableNotificationContent?

    open override func didReceive(
        _ request: UNNotificationRequest,
        withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
    ) {
        self.contentHandler = contentHandler
        guard let content = request.content.mutableCopy() as? UNMutableNotificationContent else {
            contentHandler(request.content)
            return
        }
        bestAttempt = content

        let userInfo = content.userInfo
        registerActions(from: userInfo, on: content)

        guard let url = Self.mediaURL(from: userInfo) else {
            contentHandler(content)
            return
        }

        attach(url) { attachment in
            if let attachment = attachment {
                content.attachments = [attachment]
            }
            contentHandler(content)
        }
    }

    /// iOS kills the extension after ~30s; deliver whatever is ready rather than nothing.
    open override func serviceExtensionTimeWillExpire() {
        if let contentHandler = contentHandler, let bestAttempt = bestAttempt {
            contentHandler(bestAttempt)
        }
    }

    // MARK: - Internals

    /// Categories are normally static, but campaign buttons change per notification, so the
    /// category is re-registered here with the actions this payload carries.
    private func registerActions(from userInfo: [AnyHashable: Any], on content: UNMutableNotificationContent) {
        let raw = Self.actionButtons(from: userInfo)
        guard !raw.isEmpty else { return }

        let actions: [UNNotificationAction] = raw.compactMap { button in
            let title = ((button["title"] as? String) ?? (button["label"] as? String) ?? (button["actionId"] as? String) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { return nil }
            let identifier = (button["actionId"] as? String)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .flatMap { $0.isEmpty ? nil : $0 } ?? title
            return UNNotificationAction(identifier: identifier, title: title, options: [.foreground])
        }
        guard !actions.isEmpty else { return }

        let category = UNNotificationCategory(
            identifier: Self.dynamicCategory,
            actions: actions,
            intentIdentifiers: [],
            options: []
        )
        UNUserNotificationCenter.current().setNotificationCategories([category])
        content.categoryIdentifier = Self.dynamicCategory
    }

    static func actionButtons(from userInfo: [AnyHashable: Any]) -> [[String: Any]] {
        if let json = userInfo["actionButtons"] as? String,
           let data = json.data(using: .utf8),
           let raw = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            return raw
        }
        if let raw = userInfo["actionButtons"] as? [[String: Any]] {
            return raw
        }
        return []
    }

    /// Portal campaigns put the URL in `imageUrl`; some payloads nest it under `ios.media`
    /// or `data`. Any http(s) value is accepted so a redirecting host like picsum still runs.
    private static func mediaURL(from userInfo: [AnyHashable: Any]) -> URL? {
        let nested: [[AnyHashable: Any]] = [
            userInfo,
            userInfo["data"] as? [AnyHashable: Any] ?? [:],
            userInfo["ios"] as? [AnyHashable: Any] ?? [:]
        ]
        let keys = ["imageUrl", "image", "media"]
        for bag in nested {
            for key in keys {
                guard let raw = bag[key] as? String else { continue }
                let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard let url = URL(string: trimmed),
                      let scheme = url.scheme?.lowercased(),
                      scheme == "http" || scheme == "https" else {
                    continue
                }
                return url
            }
        }
        return nil
    }

    private func attach(_ url: URL, completion: @escaping (UNNotificationAttachment?) -> Void) {
        var request = URLRequest(url: url)
        // Prefer formats iOS can attach. Without this, some CDNs return WebP, which
        // UNNotificationAttachment rejects, so the expanded banner stays empty.
        request.setValue(
            "image/jpeg,image/png,image/gif,audio/mpeg,audio/mp3,audio/wav,audio/x-wav,audio/mp4,video/mp4",
            forHTTPHeaderField: "Accept"
        )
        request.timeoutInterval = 15

        URLSession.shared.downloadTask(with: request) { location, response, error in
            guard let location = location else {
                NSLog("PushFyre NSE: image download failed: \(error?.localizedDescription ?? "no file")")
                completion(nil)
                return
            }

            let http = response as? HTTPURLResponse
            let finalURL = http?.url ?? url
            let suggested = http?.suggestedFilename ?? finalURL.lastPathComponent
            let ext = Self.attachmentExtension(
                filename: suggested,
                mimeType: http?.mimeType,
                url: finalURL
            )
            let destination = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension(ext)

            do {
                if FileManager.default.fileExists(atPath: destination.path) {
                    try FileManager.default.removeItem(at: destination)
                }
                try FileManager.default.moveItem(at: location, to: destination)
                completion(try UNNotificationAttachment(
                    identifier: "media",
                    url: destination,
                    options: [UNNotificationAttachmentOptionsTypeHintKey: Self.uti(for: ext)]
                ))
            } catch {
                NSLog("PushFyre NSE: attachment failed: \(error.localizedDescription)")
                completion(nil)
            }
        }.resume()
    }

    private static func attachmentExtension(filename: String, mimeType: String?, url: URL) -> String {
        if let mimeExt = fileExtension(for: mimeType), mediaExtensions.contains(mimeExt) {
            return mimeExt == "jpeg" ? "jpg" : mimeExt
        }
        let fromFile = (filename as NSString).pathExtension.lowercased()
        if mediaExtensions.contains(fromFile) {
            return fromFile == "jpeg" ? "jpg" : fromFile
        }
        let fromURL = url.pathExtension.lowercased()
        if mediaExtensions.contains(fromURL) {
            return fromURL == "jpeg" ? "jpg" : fromURL
        }
        return "jpg"
    }

    private static func fileExtension(for mimeType: String?) -> String? {
        switch mimeType?.lowercased() {
        case "image/png": return "png"
        case "image/gif": return "gif"
        case "image/jpeg", "image/jpg": return "jpg"
        case "audio/mpeg", "audio/mp3": return "mp3"
        case "audio/wav", "audio/x-wav", "audio/wave": return "wav"
        case "audio/aiff", "audio/x-aiff": return "aiff"
        case "audio/mp4", "audio/x-m4a": return "m4a"
        case "video/mp4": return "mp4"
        default: return nil
        }
    }

    private static func uti(for ext: String) -> String {
        switch ext.lowercased() {
        case "png": return "public.png"
        case "gif": return "com.compuserve.gif"
        case "mp3": return "public.mp3"
        case "wav": return "com.microsoft.waveform-audio"
        case "aiff", "aif": return "public.aiff-audio"
        case "m4a": return "public.mpeg-4-audio"
        case "mp4", "m4v": return "public.mpeg-4"
        case "mov": return "com.apple.quicktime-movie"
        case "caf": return "com.apple.coreaudio-format"
        default: return "public.jpeg"
        }
    }
}
