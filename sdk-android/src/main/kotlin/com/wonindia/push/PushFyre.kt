package com.wonindia.push

import android.Manifest
import android.app.Application
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.util.Log
import androidx.activity.ComponentActivity
import androidx.activity.result.ActivityResultLauncher
import androidx.activity.result.contract.ActivityResultContracts
import androidx.core.content.ContextCompat
import com.google.firebase.messaging.FirebaseMessaging
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

/**
 * Entry point for the WON push platform.
 *
 * Integration is a dependency plus one call - no manifest edits, no copied files:
 *
 * ```
 * class MyApp : Application() {
 *     override fun onCreate() {
 *         super.onCreate()
 *         PushFyre.initialize(this, PushFyreConfig(
 *             appId = "app_49e692ad",
 *             apiBaseUrl = "https://push.example.com/api/v1",
 *             environment = if (BuildConfig.DEBUG) PushFyreEnvironment.TEST
 *                           else PushFyreEnvironment.PROD
 *         ))
 *     }
 * }
 * ```
 *
 * Attach tags once you know something about the user, and target them from the portal:
 *
 * ```
 * PushFyre.sendTag(context, "deviceId", cfuuid)
 * PushFyre.sendTag(context, "isPremium", "true")
 * ```
 *
 * On Android 13+ call [requestNotificationPermission] from an Activity; registration
 * itself does not need it, so a device stays reachable even before the user decides.
 */
object PushFyre {

    internal const val TAG = "PushFyre"

    @Volatile internal var config: PushFyreConfig? = null
        private set

    @Volatile internal var tapHandler: PushFyreTapHandler? = null
        private set

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    /**
     * `initialize`, `login` and `sendTags`/`removeTags` each trigger their own registration
     * call, and a fast succession of them (typical at launch, when a session is already
     * signed in) used to race: whichever HTTP request's delete-then-replace landed on the
     * server last won, even if it read `storedTags()` before an earlier-launched call had
     * finished writing a fuller tag set. Serializing every registration through this mutex
     * makes them run in launch order instead, so the last one queued - which by definition
     * read the most current local tags - is always the one that actually lands last.
     */
    private val registrationMutex = Mutex()

    private suspend fun register(app: Context, config: PushFyreConfig, externalUserId: String? = null) {
        registrationMutex.withLock {
            val token = FirebaseMessaging.getInstance().awaitToken()
            PushFyreApi.registerDevice(app, config, token, externalUserId)
        }
    }

    /** Idempotent: safe to call on every process start. */
    @JvmStatic
    fun initialize(context: Context, config: PushFyreConfig) {
        require(config.appId.isNotBlank()) { "PushFyreConfig.appId must not be blank" }
        require(config.apiBaseUrl.isNotBlank()) { "PushFyreConfig.apiBaseUrl must not be blank" }

        this.config = config
        val app = context.applicationContext
        (app as? Application)?.let { PushFyreInApp.attach(it) }

        scope.launch {
            runCatching { register(app, config) }
                .onFailure { Log.e(TAG, "initialize failed", it) }
            // After registration, so the server already knows this device when it picks
            // messages for a segment or a per-device frequency cap.
            PushFyreInApp.trigger(app, "app_open")
        }
    }

    /**
     * Fires a named event that in-app messages can listen for, for example
     * `PushFyre.trigger(context, "checkout_started")`. Does nothing when no live campaign
     * is waiting on that event.
     */
    @JvmStatic
    fun trigger(context: Context, eventName: String) {
        if (eventName.isBlank()) return
        PushFyreInApp.trigger(context.applicationContext, "event", eventName.trim())
    }

    /** Turns in-app messages off or on for this process, for example while onboarding. */
    @JvmStatic
    fun setInAppMessagesEnabled(enabled: Boolean) {
        PushFyreInApp.enabled = enabled
    }

    /** Decide where a tapped notification goes. Without one, links open externally. */
    @JvmStatic
    fun setTapHandler(handler: PushFyreTapHandler?) {
        tapHandler = handler
    }

    /**
     * Android 13+ display permission. No-op below 33 or once granted. Registration is
     * deliberately independent of this, so declining does not make the device unreachable.
     */
    @JvmStatic
    fun requestNotificationPermission(activity: ComponentActivity) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return

        val granted = ContextCompat.checkSelfPermission(
            activity, Manifest.permission.POST_NOTIFICATIONS
        ) == PackageManager.PERMISSION_GRANTED
        if (granted) return

        // Register on the registry directly, not with activity.registerForActivityResult: that one only works
        // before the screen starts, so it crashed when called from a button tap, the usual place to ask.
        var launcher: ActivityResultLauncher<String>? = null
        launcher = activity.activityResultRegistry.register(
            "pushfyre.notification-permission",
            ActivityResultContracts.RequestPermission()
        ) { ok ->
            Log.d(TAG, "POST_NOTIFICATIONS granted=$ok")
            launcher?.unregister()
        }
        launcher.launch(Manifest.permission.POST_NOTIFICATIONS)
    }

    /**
     * Saves a phone number for WhatsApp and marks this device as opted in.
     *
     * Call this only after the person has agreed, in your own UI, to receive WhatsApp
     * messages at this number. The SDK does not show a consent dialog. The number must be
     * international, for example `+14155552671`. An invalid number is ignored.
     */
    @JvmStatic
    fun setWhatsAppPhone(context: Context, phone: String) {
        val normalized = normalizeWhatsAppPhone(phone)
        if (normalized == null) {
            Log.w(TAG, "setWhatsAppPhone ignored: use international format, for example +14155552671")
            return
        }
        val cfg = config ?: run { Log.w(TAG, "setWhatsAppPhone before initialize - ignored"); return }
        val app = context.applicationContext
        PushFyreApi.saveWhatsAppConsent(app, normalized, true)
        scope.launch {
            runCatching { register(app, cfg) }
                .onFailure { Log.e(TAG, "WhatsApp phone registration failed", it) }
        }
    }

    /** Stops WhatsApp messages for this device. The stored number is no longer used for sends. */
    @JvmStatic
    fun clearWhatsAppPhone(context: Context) {
        val cfg = config ?: run { Log.w(TAG, "clearWhatsAppPhone before initialize - ignored"); return }
        val app = context.applicationContext
        PushFyreApi.saveWhatsAppConsent(app, null, false)
        scope.launch {
            runCatching { register(app, cfg) }
                .onFailure { Log.e(TAG, "WhatsApp opt-out registration failed", it) }
        }
    }

    /** Associates this device with your own user id, for targeting by external id. */
    @JvmStatic
    fun login(context: Context, externalUserId: String) {
        val cfg = config ?: run { Log.w(TAG, "login before initialize - ignored"); return }
        val app = context.applicationContext
        scope.launch {
            runCatching { register(app, cfg, externalUserId) }
                .onFailure { Log.e(TAG, "login failed", it) }
        }
    }

    // MARK: - Tags

    /**
     * Attaches a single tag to this device for targeting, the equivalent of OneSignal's
     * `sendTag`. Tags are stored locally and re-sent on every registration, so they survive
     * restarts and token refreshes.
     *
     * ```
     * PushFyre.sendTag(context, "isPremium", "true")
     * PushFyre.sendTag(context, "segmentId", segmentId.toString())
     * ```
     *
     * `environment` is reserved by the SDK and cannot be set here.
     */
    @JvmStatic
    fun sendTag(context: Context, key: String, value: String) =
        sendTags(context, mapOf(key to value))

    /** Attaches several tags in one round trip. See [sendTag]. */
    @JvmStatic
    fun sendTags(context: Context, tags: Map<String, String>) {
        val cfg = config ?: run { Log.w(TAG, "sendTags before initialize - ignored"); return }
        val app = context.applicationContext
        val accepted = tags.filterKeys { it.isNotBlank() }
        if (accepted.isEmpty()) return

        PushFyreApi.putTags(app, accepted)
        syncTags(app, cfg)
    }

    /** Drops tags from this device so they no longer match a segment. */
    @JvmStatic
    fun removeTags(context: Context, keys: Collection<String>) {
        val cfg = config ?: run { Log.w(TAG, "removeTags before initialize - ignored"); return }
        val app = context.applicationContext
        if (keys.isEmpty()) return

        PushFyreApi.removeTags(app, keys)
        syncTags(app, cfg)
    }

    /** Drops a single tag. See [removeTags]. */
    @JvmStatic
    fun removeTag(context: Context, key: String) = removeTags(context, listOf(key))

    /**
     * Joins the Firebase topic for a broadcast Live Activity. The notification itself
     * is an ongoing notification that later updates replace. This is not a Dynamic Island.
     */
    @JvmStatic
    fun subscribeLiveActivity(context: Context, activityKey: String) {
        val cfg = config ?: return
        val key = activityKey.trim()
        if (key.isEmpty()) return
        val topic = "pfyla-$key"
        val app = context.applicationContext
        FirebaseMessaging.getInstance().subscribeToTopic(topic)
        scope.launch {
            val deviceId = PushFyreApi.deviceId(app) ?: return@launch
            runCatching {
                PushFyreApi.authorizedRequest(
                    app,
                    cfg,
                    "POST",
                    "/live-activities/sdk/$key/subscribe?platform=android",
                    """{"deviceId":"$deviceId"}"""
                )
            }
        }
    }

    /** Leaves the Firebase topic for a broadcast Live Activity. */
    @JvmStatic
    fun unsubscribeLiveActivity(context: Context, activityKey: String) {
        val cfg = config ?: return
        val key = activityKey.trim()
        if (key.isEmpty()) return
        val app = context.applicationContext
        FirebaseMessaging.getInstance().unsubscribeFromTopic("pfyla-$key")
        scope.launch {
            val deviceId = PushFyreApi.deviceId(app) ?: return@launch
            runCatching {
                PushFyreApi.authorizedRequest(
                    app,
                    cfg,
                    "POST",
                    "/live-activities/sdk/$key/unsubscribe",
                    """{"deviceId":"$deviceId"}"""
                )
            }
        }
    }

    /** Tags currently attached to this device, as last stored locally. */
    @JvmStatic
    fun tags(context: Context): Map<String, String> =
        PushFyreApi.storedTags(context.applicationContext)

    /**
     * Re-registers so the server sees the current tag set. Tags are already persisted by
     * the time this runs, so a failed sync is repaired by the next launch rather than lost.
     */
    private fun syncTags(app: Context, cfg: PushFyreConfig) {
        scope.launch {
            runCatching { register(app, cfg) }
                .onFailure { Log.e(TAG, "tag sync failed", it) }
        }
    }

    private fun normalizeWhatsAppPhone(raw: String): String? {
        val compact = raw.replace(Regex("[\\s()-]"), "")
        if (compact.isEmpty()) return null
        val withPlus = if (compact.startsWith("+")) compact else "+$compact"
        return if (Regex("^\\+[1-9][0-9]{7,14}$").matches(withPlus)) withPlus else null
    }

    internal fun onTokenRefreshed(context: Context, token: String) {
        val cfg = config ?: return
        val app = context.applicationContext
        scope.launch {
            runCatching {
                registrationMutex.withLock { PushFyreApi.registerDevice(app, cfg, token) }
            }.onFailure { Log.e(TAG, "token refresh registration failed", it) }
        }
    }
}
