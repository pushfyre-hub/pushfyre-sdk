package com.wonindia.push

import android.content.Context

/**
 * Integration settings, supplied once via [PushFyre.initialize].
 *
 * @param appId         the application id issued by the push portal, e.g. "app_49e692ad"
 * @param apiBaseUrl    base URL of the push API including the version prefix, e.g.
 *                      "https://push.example.com/api/v1". Self-hosted deployments differ
 *                      per environment, so it cannot be baked into the SDK.
 * @param smallIconRes  status-bar icon; defaults to the app icon, which Android renders
 *                      as a white square on some versions - pass a proper silhouette.
 * @param channelId     notification channel; created automatically on Android 8+.
 * @param channelName   user-visible channel name shown in system settings.
 * @param environment   which audience this install belongs to. Wire it to your build type
 *                      - `if (BuildConfig.DEBUG) TEST else PROD` - so the portal can send a
 *                      campaign to test installs only without reaching real users.
 */
data class PushFyreConfig(
    val appId: String,
    val apiBaseUrl: String,
    val smallIconRes: Int = 0,
    val channelId: String = "pushfyre_default",
    val channelName: String = "Notifications",
    val environment: PushFyreEnvironment = PushFyreEnvironment.PROD
)

/**
 * Audience an install belongs to, reported as the reserved `environment` tag.
 *
 * The portal's audience selector targets this directly, so a debug build can be pushed to
 * in isolation. Devices that never report it are treated as [PROD].
 */
enum class PushFyreEnvironment(internal val tagValue: String) {
    /** Development and QA installs. Reachable only by "Test devices" campaigns. */
    TEST("test"),

    /** Store builds. The default, so forgetting to set this cannot hide real users. */
    PROD("prod")
}

/** Where a notification tap should be delivered. */
fun interface PushFyreTapHandler {
    /**
     * @param targetUrl link carried by the campaign or the tapped button, null when neither
     *                  carried one.
     * @param actionId  the tapped action button's id, or null when the notification body
     *                  itself was tapped. Switch on this to route per button.
     * @return true if the app handled it; false to let the SDK open the link externally.
     */
    fun onNotificationTapped(context: Context, targetUrl: String?, actionId: String?): Boolean
}
