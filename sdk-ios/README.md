# PushFyre iOS SDK

Push notifications, tags and in-app messages for iOS, as a Swift package (`PushFyre`). The package manifest is `Package.swift` at the repository root; the sources are in `sdk-ios/Sources/PushFyre`.

## Quick start

1. **Create the app in the PushFyre portal.** Choose **Apple iOS (APNs)** and upload your APNs key (`.p8`) or certificate (`.p12`). The channel shows **Active** only once that file is saved. Copy the **App ID**.
2. **Add the package.** In Xcode: **File → Add Package Dependencies**, then enter `https://github.com/pushfyre-hub/pushfyre-sdk`. No account or token is needed, the repository is public.
3. **Enable capabilities:** Push Notifications and Background Modes → Remote notifications.
4. **Initialize at launch** and forward the device token (see Setup below).
5. **Check it works** on a physical device (the Simulator never receives an APNs token). The device appears under **Audience** in the portal, and you can send a push from **Test Subscription**.

Or in your own `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/pushfyre-hub/pushfyre-sdk.git", from: "1.0.1")
],
targets: [
    .target(name: "YourApp", dependencies: ["PushFyre"])
]
```

## Setup

```swift
// AppDelegate.application(_:didFinishLaunchingWithOptions:)
PushFyre.initialize(PushFyreConfig(
    appId: "app_49e692ad",
    apiBaseUrl: "https://push.example.com/api/v1",
    environment: isDebugBuild ? .test : .prod
))
PushFyre.requestAuthorization()

// APNs hands the token to the app delegate, so forward it.
func application(_ app: UIApplication,
                 didRegisterForRemoteNotificationsWithDeviceToken token: Data) {
    PushFyre.register(deviceToken: token)
}
```

Once you know who the user is:

```swift
PushFyre.login(externalUserId: "user-1001")
PushFyre.sendTag(key: "isPremium", value: "true")
```

See `PushFyreConfig.swift` for every option.

## In-app messages

Campaigns created under **In-App Messages** in the portal (banner, modal, bottom sheet, full screen, image and carousel) show inside your app with no extra code. After `initialize`, the SDK fetches the messages that apply to the device and shows at most one at a time on the foreground window.

Fire your own event to show a message that listens for it:

```swift
PushFyre.trigger("checkout_started")
```

Turn them off for a while, for example during onboarding:

```swift
PushFyre.setInAppMessagesEnabled(false)
```

A button that opens a link goes to your `PushFyre.setTapHandler` first (with `actionId == "in_app"`), so your app can route deep links itself; otherwise the link opens in Safari.

Messages are fetched over HTTPS when the app opens or an event fires. There is no persistent connection, so a newly launched campaign appears the next time one of those happens.

## Live Activities

The main `PushFyre` library stays on iOS 13. Live Activities are the second library, `PushFyreLiveActivity`, and need iOS 16.2.

1. Add the `PushFyreLiveActivity` product to the app target.
2. Add a Widget Extension target and add `PushFyreActivityWidget()` to its widget bundle.
3. Set `NSSupportsLiveActivities` to `YES` in the app Info.plist.
4. Call `PushFyreLiveActivity.enable()` at launch so update tokens, and on iOS 17.2 the push-to-start token, are uploaded.

Until that extension has registered a token, PushFyre cannot update the lock screen or the Dynamic Island.
