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
import org.json.JSONArray
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
    val maxImpressions: Int,
    val groups: JSONArray = JSONArray(),
    val dismissAfter: Int = 0,
    val frequencyTimes: Int = 0,
    val frequencyGapMs: Long = 0L
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
    private val sessionMessages = mutableListOf<InAppMessage>()
    private val triggerValues = mutableMapOf<String, String>()
    private val sessionStarted = System.currentTimeMillis()
    private var sessionLoaded = false

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
        if (!eventName.isNullOrBlank()) {
            synchronized(triggerValues) { triggerValues[eventName] = "true" }
            considerSession(app, cfg)
        }
        if (trigger == "app_open") ensureSession(app, cfg)
        scope.launch {
            runCatching { fetchAndShow(app, cfg, trigger, eventName) }
                .onFailure { Log.w(PushFyre.TAG, "in-app messaging failed: ${it.message}") }
        }
    }

    fun addTrigger(context: Context, key: String, value: String) {
        val name = key.trim()
        if (name.isEmpty() || !enabled) return
        val cfg = PushFyre.config ?: return
        synchronized(triggerValues) { triggerValues[name] = value }
        considerSession(context.applicationContext, cfg)
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
                maxImpressions = if (json.isNull("maxImpressions")) 0 else json.optInt("maxImpressions", 0),
                groups = json.optJSONArray("groups") ?: JSONArray(),
                dismissAfter = if (json.isNull("dismissAfter")) 0 else json.optInt("dismissAfter", 0),
                frequencyTimes = frequency?.optInt("times", 0) ?: 0,
                frequencyGapMs = gapMillis(frequency)
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

                    override fun onNamedClick(actionId: String) {
                        PushFyre.tapHandler?.onNotificationTapped(activity, null, actionId)
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
            "multiple" -> count < message.frequencyTimes.coerceAtLeast(1) &&
                (lastAt == 0L || System.currentTimeMillis() - lastAt >= message.frequencyGapMs.coerceAtLeast(1L))
            else -> true
        }
    }

    private fun gapMillis(frequency: JSONObject?): Long {
        if (frequency == null) return 86_400_000L
        val gap = frequency.optInt("gap", frequency.optInt("days", 1)).coerceAtLeast(1)
        return when (frequency.optString("gapUnit")) {
            "minutes" -> gap * 60_000L
            "hours" -> gap * 3_600_000L
            "weeks" -> gap * 7L * 86_400_000L
            else -> gap * 86_400_000L
        }
    }

    private fun ensureSession(app: Context, cfg: PushFyreConfig) {
        if (sessionLoaded) return
        sessionLoaded = true
        scope.launch {
            runCatching {
                val loaded = fetch(app, cfg, "session", null)
                synchronized(sessionMessages) {
                    sessionMessages.clear()
                    sessionMessages.addAll(loaded)
                }
                main.post(sessionTick)
            }.onFailure { Log.w(PushFyre.TAG, "in-app session triggers failed: ${it.message}") }
        }
    }

    private val sessionTick = object : Runnable {
        override fun run() {
            val cfg = PushFyre.config
            val app = tracker?.current?.get()?.applicationContext
            if (cfg != null && app != null) considerSession(app, cfg)
            main.postDelayed(this, 1000L)
        }
    }

    private fun considerSession(app: Context, cfg: PushFyreConfig) {
        if (showing) return
        val messages = synchronized(sessionMessages) { sessionMessages.toList() }
        val message = messages.firstOrNull { groupsMatch(it) && allowed(app, it) } ?: return
        present(app, cfg, message)
    }

    private fun groupsMatch(message: InAppMessage): Boolean {
        val groups = message.groups
        if (groups.length() == 0) return false
        for (index in 0 until groups.length()) {
            val group = groups.optJSONArray(index) ?: continue
            if (group.length() == 0) continue
            if ((0 until group.length()).all { ruleMatches(group.optJSONObject(it)) }) return true
        }
        return false
    }

    private fun ruleMatches(rule: JSONObject?): Boolean {
        if (rule == null) return false
        return when (rule.optString("kind")) {
            "trigger" -> {
                val key = rule.optString("key").trim()
                if (key.isEmpty()) return false
                val actual = synchronized(triggerValues) { triggerValues[key] }.orEmpty()
                if (rule.optString("operator") == "is_not") actual != rule.optString("value") else actual == rule.optString("value")
            }
            "session_duration", "since_last" -> {
                val seconds = rule.optInt("seconds", 0)
                if (seconds < 1) return false
                val elapsed = if (rule.optString("kind") == "since_last") {
                    val last = prefsLast()
                    if (last == 0L) 1_000_000_000.0 else (System.currentTimeMillis() - last) / 1000.0
                } else {
                    (System.currentTimeMillis() - sessionStarted) / 1000.0
                }
                if (rule.optString("operator") == "less") elapsed < seconds else elapsed > seconds
            }
            else -> false
        }
    }

    private fun prefsLast(): Long {
        val app = tracker?.current?.get()?.applicationContext ?: return 0L
        return prefs(app).getLong("pushfyre.inapp.last", 0L)
    }

    private fun fetch(app: Context, cfg: PushFyreConfig, trigger: String, eventName: String?): List<InAppMessage> {
        val query = buildString {
            append("/in-app/sdk/messages?appId=").append(enc(cfg.appId))
            append("&platform=android&trigger=").append(enc(trigger))
            append("&widgets=1")
            if (!eventName.isNullOrBlank()) append("&eventName=").append(enc(eventName))
            PushFyreApi.deviceId(app)?.let { append("&deviceId=").append(enc(it)) }
        }
        val (code, body) = PushFyreApi.authorizedRequest(app, cfg, "GET", query)
        if (code !in 200..299) return emptyList()
        val array = JSONObject(body).optJSONArray("messages") ?: return emptyList()
        return buildList {
            for (index in 0 until array.length()) {
                val json = array.optJSONObject(index) ?: continue
                add(parseMessage(json))
            }
        }
    }

    private fun parseMessage(json: JSONObject): InAppMessage {
        val frequency = json.optJSONObject("frequency")
        return InAppMessage(
            id = json.optString("id"),
            name = json.optString("name"),
            format = json.optString("format"),
            content = json.optJSONObject("content") ?: JSONObject(),
            frequencyType = frequency?.optString("type").orEmpty().ifBlank { "every_session" },
            frequencyDays = frequency?.optInt("days", 1) ?: 1,
            maxImpressions = if (json.isNull("maxImpressions")) 0 else json.optInt("maxImpressions", 0),
            groups = json.optJSONArray("groups") ?: JSONArray(),
            dismissAfter = if (json.isNull("dismissAfter")) 0 else json.optInt("dismissAfter", 0),
            frequencyTimes = frequency?.optInt("times", 0) ?: 0,
            frequencyGapMs = gapMillis(frequency)
        )
    }

    private fun recordShown(context: Context, message: InAppMessage) {
        val prefs = prefs(context)
        prefs.edit()
            .putInt("${message.id}.count", prefs.getInt("${message.id}.count", 0) + 1)
            .putLong("${message.id}.last", System.currentTimeMillis())
            .putLong("pushfyre.inapp.last", System.currentTimeMillis())
            .apply()
        synchronized(shownThisSession) { shownThisSession.add(message.id) }
    }

    // MARK: - Reporting

    private fun known(format: String) = format in setOf(
        "banner", "modal", "bottom_sheet", "full_screen", "image", "carousel", "dynamic",
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
