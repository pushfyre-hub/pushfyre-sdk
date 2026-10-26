# PushFyre SDK

Push notifications, in-app messages and user tagging for mobile apps, backed by [PushFyre](https://github.com/pushfyre-hub).

| Platform | Package | Folder |
|---|---|---|
| Android | `io.github.pushfyre-hub:sdk-android` on Maven Central | [`sdk-android`](sdk-android) |
| iOS | Swift package `PushFyre` (Swift Package Manager, from this repository) | [`sdk-ios`](sdk-ios) |

## Android in five minutes

1. **Create the app in the PushFyre portal.** Choose **Google Android (FCM)** and upload your Firebase service account JSON. The channel shows **Active** only once that file is saved. Copy the **App ID**.
2. **Add Firebase.** Put `google-services.json` in your `app/` folder and apply the Google Services plugin.
3. **Add the dependency.** One line, no repository and no token:

   ```kotlin
   // app/build.gradle.kts
   dependencies {
       implementation("io.github.pushfyre-hub:sdk-android:1.0.0")
   }
   ```

4. **Initialize once**, in `Application.onCreate`:

   ```kotlin
   PushFyre.initialize(
       this,
       PushFyreConfig(
           appId = "app_xxxxxxxx",
           apiBaseUrl = "https://your-push-api/api/v1",
           environment = if (BuildConfig.DEBUG) PushFyreEnvironment.TEST else PushFyreEnvironment.PROD
       )
   )
   ```

5. **Ask for permission** from an Activity (Android 13 and later):

   ```kotlin
   PushFyre.requestNotificationPermission(this)
   ```

Run the app. The device appears under **Audience** in the portal, and you can send yourself a push from **Test Subscription**.

Requirements: `minSdk 24`, the Google Services plugin and `google-services.json`. Full guide, tags, tap handling and in-app messages: [`sdk-android/README.md`](sdk-android/README.md).

## iOS in five minutes

1. **Create the app in the PushFyre portal.** Choose **Apple iOS (APNs)** and upload your APNs key (`.p8`) or certificate (`.p12`). The channel shows **Active** only once that file is saved. Copy the **App ID**.
2. **Add the package.** In Xcode choose **File → Add Package Dependencies** and enter the URL of this repository, `https://github.com/pushfyre-hub/pushfyre-sdk`. No account or token is needed. Or in your own `Package.swift`:

   ```swift
   dependencies: [
       .package(url: "https://github.com/pushfyre-hub/pushfyre-sdk.git", from: "1.0.1")
   ],
   targets: [
       .target(name: "YourApp", dependencies: ["PushFyre"])
   ]
   ```

3. **Enable capabilities:** Push Notifications and Background Modes → Remote notifications.
4. **Initialize at launch**, and forward the APNs device token:

   ```swift
   PushFyre.initialize(PushFyreConfig(
       appId: "app_xxxxxxxx",
       apiBaseUrl: "https://your-push-api/api/v1",
       environment: isDebugBuild ? .test : .prod
   ))
   PushFyre.requestAuthorization()

   func application(_ app: UIApplication,
                    didRegisterForRemoteNotificationsWithDeviceToken token: Data) {
       PushFyre.register(deviceToken: token)
   }
   ```

Test on a physical device, because the iOS Simulator never receives an APNs token. The device appears under **Audience** in the portal, and you can send yourself a push from **Test Subscription**. Requires iOS 13 or later. More in [`sdk-ios/README.md`](sdk-ios/README.md).

## Releasing

Maintainers: one tag releases both SDKs. Pushing a version tag such as `1.0.1` publishes the Android SDK to Maven Central, and the same tag is what Swift Package Manager installs for iOS. See [`sdk-android/RELEASING.md`](sdk-android/RELEASING.md).

## License

Apache License 2.0. See [LICENSE](LICENSE).
