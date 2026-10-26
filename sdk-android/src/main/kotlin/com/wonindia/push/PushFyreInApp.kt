package com.wonindia.push

import android.app.Activity
import android.app.Application
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.util.Log
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import org.json.JSONObject
import java.lang.ref.WeakReference
import java.net.URLEncoder

/** One message returned by the server, already filtered to this device. */
internal class InAppMessage(
    val id: String,
    val name: String,
    val format: String,
    val content: JSONObject,
    val frequencyType: String,
    val frequencyDays: Int,
    val maxImpressions: Int
)

/**
 * In-app messaging: fetches the messages that apply to this install, shows at most one at a
 * time on the foreground Activity, and reports impressions, clicks and dismissals.
 *
 * Everything here is best effort. A failure to fetch or draw a message is logged and dropped
 * so it can never affect the host app.
 */
internal object PushFyreInApp {

    private const val PREFS = "pushfyre_inapp"
    private const val SESSION_PENDING_MS = 15_000L

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val main = Handler(Looper.getMainLooper())

    /** Ids already shown since the process started, for the "once per session" rule. */
    private val shownThisSession = mutableSetOf<String>()

    @Volatile private var showing = false
    @Volatile private var tracker: ActivityTracker? = null
    @Volatile var enabled = true

    // MARK: - Foreground Activity

    private class ActivityTracker : Application.ActivityLifecycleCallbacks {
        @Volatile var current: WeakReference<Activity>? = null
        private var waiting: Pair<Long, (Activity) -> Unit>? = null

        fun whenAvailable(block: (Activity) -> Unit) {
            val activity = current?.get()
            if (activity != null && !activity.isFinishing) {
                activity.runOnUiThread { block(activity) }
            } else {
                waiting = System.currentTimeMillis() to block
            }
        }

        override fun onActivityResumed(activity: Activity) {
            current = WeakReference(activity)
            val pending = waiting ?: return
            waiting = null
            if (System.currentTimeMillis() - pending.first <= SESSION_PENDING_MS) {
                activity.runOnUiThread { pending.second(activity) }
            }
        }

        override fun onActivityPaused(activity: Activity) {
            if (current?.get() === activity) current = null
        }

        override fun onActivityCreated(activity: Activity, savedInstanceState: Bundle?) = Unit
        override fun onActivityStarted(activity: Activity) = Unit
        override fun onActivityStopped(activity: Activity) = Unit
        override fun onActivitySaveInstanceState(activity: Activity, outState: Bundle) = Unit
        override fun onActivityDestroyed(activity: Activity) = Unit
    }

    @Synchronized
    fun attach(app: Application) {
        if (tracker != null) return
        val created = ActivityTracker()
        tracker = created
        app.registerActivityLifecycleCallbacks(created)
    }

    // MARK: - Triggers

    fun trigger(context: Context, trigger: String, eventName: String? = null) {
        val cfg = PushFyre.config ?: run { Log.w(PushFyre.TAG, "in-app trigger before initialize - ignored"); return }
        if (!enabled) return
        val app = context.applicationContext
        scope.launch {
            runCatching { fetchAndShow(app, cfg, trigger, eventName) }
                .onFailure { Log.w(PushFyre.TAG, "in-app messaging failed: ${it.message}") }
        }
    }

    private fun fetchAndShow(app: Context, cfg: PushFyreConfig, trigger: String, eventName: String?) {
        if (showing) return
        val query = buildString {
            append("/in-app/sdk/messages?appId=").append(enc(cfg.appId))
            append("&platform=android&trigger=").append(enc(trigger))
            append("&widgets=1")
            if (!eventName.isNullOrBlank()) append("&eventName=").append(enc(eventName))
            PushFyreApi.deviceId(app)?.let { append("&deviceId=").append(enc(it)) }
        }
        val (code, body) = PushFyreApi.authorizedRequest(app, cfg, "GET", query)
        if (code !in 200..299) return

        val array = JSONObject(body).optJSONArray("messages") ?: return
        for (index in 0 until array.length()) {
            val json = array.optJSONObject(index) ?: continue
            val frequency = json.optJSONObject("frequency")
            val message = InAppMessage(
                id = json.optString("id"),
                name = json.optString("name"),
                format = json.optString("format"),
                content = json.optJSONObject("content") ?: JSONObject(),
                frequencyType = frequency?.optString("type").orEmpty().ifBlank { "every_session" },
                frequencyDays = frequency?.optInt("days", 1) ?: 1,
                maxImpressions = if (json.isNull("maxImpressions")) 0 else json.optInt("maxImpressions", 0)
            )
            if (message.id.isBlank() || !known(message.format) || !allowed(app, message)) continue
            present(app, cfg, message)
            return
        }
    }

    private fun present(app: Context, cfg: PushFyreConfig, message: InAppMessage) {
        val activityTracker = tracker ?: return
        activityTracker.whenAvailable { activity ->
            if (showing) return@whenAvailable
            showing = true
            runCatching {
                PushFyreInAppRenderer(activity, message, object : PushFyreInAppRenderer.Listener {
                    override fun onShown() {
                        recordShown(app, message)
                        report(app, cfg, message, "impression")
                    }

                    override fun onDismissed() {
                        showing = false
                        report(app, cfg, message, "dismiss")
                    }

                    override fun onAction(url: String?) {
                        showing = false
                        report(app, cfg, message, "button_click")
                        openAction(activity, message, url)
                    }

                    override fun onRespond(answer: JSONObject) {
                        showing = false
                        report(app, cfg, message, "respond", answer)
                    }
                }).show()
            }.onFailure {
                showing = false
                Log.w(PushFyre.TAG, "in-app message could not be shown: ${it.message}")
            }
        }
    }

    private fun openAction(activity: Activity, message: InAppMessage, url: String?) {
        val action = message.content.optJSONObject("action")
        val type = action?.optString("type").orEmpty()
        val target = url?.takeIf { it.isNotBlank() }
        if (type == "dismiss" || target == null) return

        // Let the app route it first, exactly like a tapped push notification.
        val handled = PushFyre.tapHandler?.onNotificationTapped(activity, target, "in_app") == true
        if (handled) return
        runCatching {
            activity.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(target)).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        }.onFailure { Log.w(PushFyre.TAG, "in-app action could not open $target") }
    }

    // MARK: - Frequency

    private fun prefs(context: Context) = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    private fun allowed(context: Context, message: InAppMessage): Boolean {
        val prefs = prefs(context)
        val count = prefs.getInt("${message.id}.count", 0)
        val lastAt = prefs.getLong("${message.id}.last", 0L)
        if (message.maxImpressions > 0 && count >= message.maxImpressions) return false
        return when (message.frequencyType) {
            "once" -> count == 0
            "every_n_days" -> lastAt == 0L ||
                System.currentTimeMillis() - lastAt >= message.frequencyDays.coerceAtLeast(1) * 86_400_000L
            "every_session" -> synchronized(shownThisSession) { message.id !in shownThisSession }
            else -> true
        }
    }

    private fun recordShown(context: Context, message: InAppMessage) {
        val prefs = prefs(context)
        prefs.edit()
            .putInt("${message.id}.count", prefs.getInt("${message.id}.count", 0) + 1)
            .putLong("${message.id}.last", System.currentTimeMillis())
            .apply()
        synchronized(shownThisSession) { shownThisSession.add(message.id) }
    }

    // MARK: - Reporting

    private fun known(format: String) = format in setOf(
        "banner", "modal", "bottom_sheet", "full_screen", "image", "carousel",
        "poll", "slider", "scratch", "flash", "feedback", "yes_no",
        "checklist", "quiz", "image_choice", "countdown", "copy_code"
    )

    private fun report(app: Context, cfg: PushFyreConfig, message: InAppMessage, event: String, answer: JSONObject? = null) {
        scope.launch {
            runCatching {
                val payload = JSONObject()
                    .put("appId", cfg.appId)
                    .put("messageId", message.id)
                    .put("platform", "android")
                    .put("event", event)
                if (answer != null) payload.put("answer", answer)
                PushFyreApi.deviceId(app)?.let { payload.put("deviceId", it) }
                PushFyreApi.authorizedRequest(app, cfg, "POST", "/in-app/sdk/events", payload.toString())
            }.onFailure { Log.w(PushFyre.TAG, "in-app $event report failed: ${it.message}") }
        }
    }

    private fun enc(value: String) = URLEncoder.encode(value, "UTF-8")
}
