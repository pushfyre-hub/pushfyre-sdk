# PushFyre SDK

Push notifications, in-app messages and user tagging for mobile apps, backed by [PushFyre](https://github.com/pushfyre-hub).

| Platform | Package | Folder |
|---|---|---|
| Android | `io.github.pushfyre-hub:sdk-android` on Maven Central | [`sdk-android`](sdk-android) |
| iOS | Swift source | [`sdk-ios`](sdk-ios) |

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

## Releasing

Maintainers: see [`sdk-android/RELEASING.md`](sdk-android/RELEASING.md).

## License

Apache License 2.0. See [LICENSE](LICENSE).
