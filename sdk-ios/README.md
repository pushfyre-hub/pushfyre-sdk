# PushFyre iOS SDK

Push notifications, tags and in-app messages for iOS, as a Swift package (`PushFyre`). The package manifest is `Package.swift` at the repository root; the sources are in `sdk-ios/Sources/PushFyre`.

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
