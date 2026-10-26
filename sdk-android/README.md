# PushFyre Android SDK

In-house push notification client, replacing OneSignal. Wraps FCM registration, tagging, and notification display behind a small API.

## Integration

The SDK is on Maven Central, so there is no repository or token to set up. Add one line to your app module:

```kotlin
// app/build.gradle.kts
dependencies {
    implementation("io.github.pushfyre-hub:sdk-android:1.0.0")
}
```

Make sure `mavenCentral()` is in your repositories (it is by default in new Android projects):

```kotlin
// settings.gradle.kts
dependencyResolutionManagement {
    repositories {
        google()
        mavenCentral()
    }
}
```

Minimum requirements: `minSdk 24`, the Google Services plugin, and `google-services.json` in the app module - the same Firebase setup FCM itself needs.

## Usage

```kotlin
// Application.onCreate()
PushFyre.initialize(
    this,
    PushFyreConfig(
        appId = "app_e6ae6e50",
        apiBaseUrl = "https://push.example.com/api/v1",
        environment = if (BuildConfig.DEBUG) PushFyreEnvironment.TEST else PushFyreEnvironment.PROD
    )
)

// Activity - prompts for POST_NOTIFICATIONS on Android 13+, no-op below it
PushFyre.requestNotificationPermission(this)

// Once you know who the user is
PushFyre.login(this, externalUserId)
PushFyre.sendTag(this, "isPremium", "true")
```

See `PushFyreConfig.kt` for every option and what each one does.

## In-app messages

Campaigns created under **In-App Messages** in the portal (banner, modal, bottom sheet, full screen, image and carousel) show inside your app with no extra code. The SDK fetches the messages that apply to the device when the app starts, and shows at most one at a time on the foreground screen.

Fire your own event to show a message that listens for it:

```kotlin
PushFyre.trigger(context, "checkout_started")
```

Turn them off for a while, for example during onboarding:

```kotlin
PushFyre.setInAppMessagesEnabled(false)
```

A button that opens a link goes to `PushFyre.setTapHandler` first (with `actionId = "in_app"`), so your app can route deep links itself; otherwise the link opens externally.

## Releasing a new version

```bash
git tag 1.0.1
git push origin 1.0.1
```

CI publishes that tag to Maven Central. The one-time account, namespace and signing setup is in [RELEASING.md](RELEASING.md). Locally, `./gradlew :sdk-android:publishToMavenLocal` publishes `1.0.0-SNAPSHOT` for same-machine testing.

Apps bump the version string in their own `build.gradle.kts` to pick up a release - nothing else changes.
