package com.wonindia.push

import android.content.Context
import android.os.Build
import android.util.Log
import com.google.android.gms.tasks.Task
import com.google.firebase.messaging.FirebaseMessaging
import kotlinx.coroutines.suspendCancellableCoroutine
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL
import java.util.Locale
import java.util.TimeZone
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

/** Network layer. Deliberately dependency-free so the SDK adds no HTTP client. */
internal object PushFyreApi {

    private const val PREFS = "pushfyre"
    private const val KEY_TOKEN = "auth_token"
    private const val KEY_TENANT = "tenant_id"
    private const val KEY_TAGS = "tags"
    private const val KEY_DEVICE_ID = "device_id"
    private const val ENVIRONMENT_TAG = "environment"

    /**
     * Human-readable hardware name, so the portal's subscription list distinguishes devices
     * instead of showing a column of "android".
     *
     * [Build.MODEL] on most vendors already carries the manufacturer ("Pixel 8"), but on
     * others it is a bare part number ("SM-S911B"), so the manufacturer is prepended only
     * when the model does not already start with it.
     */
    private fun deviceName(): String {
        val manufacturer = Build.MANUFACTURER.orEmpty().trim()
        val model = Build.MODEL.orEmpty().trim()
        val hardware = when {
            model.isEmpty() -> manufacturer
            manufacturer.isEmpty() -> model
            model.startsWith(manufacturer, ignoreCase = true) -> model
            else -> "${manufacturer.replaceFirstChar { it.uppercase() }} $model"
        }
        return "${hardware.ifEmpty { "Android device" }} (Android ${Build.VERSION.RELEASE})"
            .take(160)
    }

    /** Version name from the manifest, used by the portal's app-version segment filters. */
    private fun appVersion(context: Context): String? = runCatching {
        context.packageManager.getPackageInfo(context.packageName, 0).versionName
    }.getOrNull()

    // MARK: - Tags

    /** Tags persist locally so every re-registration re-sends the full accumulated set. */
    internal fun storedTags(context: Context): MutableMap<String, String> {
        val raw = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .getString(KEY_TAGS, null) ?: return mutableMapOf()
        val result = mutableMapOf<String, String>()
        runCatching {
            val json = JSONObject(raw)
            json.keys().forEach { key -> result[key] = json.optString(key) }
        }
        return result
    }

    internal fun putTags(context: Context, tags: Map<String, String>): Map<String, String> {
        val merged = storedTags(context).apply { putAll(tags) }
        writeTags(context, merged)
        return merged
    }

    internal fun removeTags(context: Context, keys: Collection<String>): Map<String, String> {
        val merged = storedTags(context).apply { keys.forEach { remove(it) } }
        writeTags(context, merged)
        return merged
    }

    private fun writeTags(context: Context, tags: Map<String, String>) {
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .edit()
            .putString(KEY_TAGS, JSONObject(tags as Map<*, *>).toString())
            .apply()
    }

    /**
     * Fetches the device credential from the public runtime endpoint and caches it. The
     * credential is app-scoped, not user-scoped, so it can safely live in app storage.
     */
    private fun runtime(context: Context, config: PushFyreConfig): Pair<String, String> {
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val cachedToken = prefs.getString(KEY_TOKEN, null)
        val cachedTenant = prefs.getString(KEY_TENANT, null)
        if (!cachedToken.isNullOrBlank() && !cachedTenant.isNullOrBlank()) {
            return cachedToken to cachedTenant
        }

        val body = get("${config.apiBaseUrl}/sdk/${config.appId}/mobile-runtime")
        val json = JSONObject(body)
        val token = json.getString("authToken")
        val tenant = json.getString("tenantId")
        prefs.edit().putString(KEY_TOKEN, token).putString(KEY_TENANT, tenant).apply()
        return token to tenant
    }

    fun registerDevice(
        context: Context,
        config: PushFyreConfig,
        fcmToken: String,
        externalUserId: String? = null
    ) {
        val (authToken, tenantId) = runtime(context, config)

        // The reserved environment tag is written last so a consumer cannot overwrite it
        // with sendTag() and accidentally make a debug install look like production.
        val tags = storedTags(context).apply { put(ENVIRONMENT_TAG, config.environment.tagValue) }

        val payload = JSONObject()
            .put("appId", config.appId)
            .put("platform", "android")
            .put("token", fcmToken)
            .put("deviceName", deviceName())
            .put("language", Locale.getDefault().language)
            .put("timezone", TimeZone.getDefault().id)
            .put("tags", JSONObject(tags as Map<*, *>))
            .apply {
                appVersion(context)?.let { put("appVersion", it) }
                externalUserId?.let { put("externalUserId", it) }
            }

        val (code, responseBody) = postForBody(
            url = "${config.apiBaseUrl}/devices/register",
            body = payload.toString(),
            headers = mapOf(
                "Authorization" to "Bearer $authToken",
                "x-tenant-id" to tenantId
            )
        )

        // The device id lets in-app messaging target by segment and cap frequency per device.
        if (code in 200..299) {
            runCatching { JSONObject(responseBody).optString("id") }.getOrNull()
                ?.takeIf { it.isNotBlank() }
                ?.let { id ->
                    context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
                        .edit().putString(KEY_DEVICE_ID, id).apply()
                }
        }

        // A cached credential outlives its expiry; drop it so the next attempt refetches.
        if (code == 401 || code == 403) {
            context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().clear().apply()
            Log.w(PushFyre.TAG, "credential rejected ($code); cleared cache for retry")
            return
        }
        Log.d(PushFyre.TAG, "device registered (HTTP $code)")
    }

    /** The server-issued id of this install, once it has registered at least once. */
    internal fun deviceId(context: Context): String? =
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getString(KEY_DEVICE_ID, null)

    /**
     * Authenticated call used by in-app messaging. Returns the HTTP status and body, and
     * drops the cached credential on 401/403 so the next call fetches a fresh one.
     */
    internal fun authorizedRequest(
        context: Context,
        config: PushFyreConfig,
        method: String,
        path: String,
        body: String? = null
    ): Pair<Int, String> {
        val (authToken, tenantId) = runtime(context, config)
        val conn = (URL("${config.apiBaseUrl}$path").openConnection() as HttpURLConnection).apply {
            requestMethod = method
            connectTimeout = 15_000
            readTimeout = 15_000
            setRequestProperty("Content-Type", "application/json")
            setRequestProperty("Authorization", "Bearer $authToken")
            setRequestProperty("x-tenant-id", tenantId)
            if (body != null) doOutput = true
        }
        return conn.use {
            if (body != null) it.outputStream.use { out -> out.write(body.toByteArray()) }
            val code = it.responseCode
            val text = (if (code in 200..299) it.inputStream else it.errorStream)
                ?.bufferedReader()?.use { reader -> reader.readText() }.orEmpty()
            if (code == 401 || code == 403) {
                context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
                    .remove(KEY_TOKEN).remove(KEY_TENANT).apply()
            }
            code to text
        }
    }

    private fun get(url: String): String {
        val conn = (URL(url).openConnection() as HttpURLConnection).apply {
            requestMethod = "GET"
            connectTimeout = 15_000
            readTimeout = 15_000
        }
        return conn.use { it.inputStream.bufferedReader().readText() }
    }

    private fun post(url: String, body: String, headers: Map<String, String>): Int =
        postForBody(url, body, headers).first

    private fun postForBody(url: String, body: String, headers: Map<String, String>): Pair<Int, String> {
        val conn = (URL(url).openConnection() as HttpURLConnection).apply {
            requestMethod = "POST"
            connectTimeout = 15_000
            readTimeout = 15_000
            setRequestProperty("Content-Type", "application/json")
            headers.forEach { (k, v) -> setRequestProperty(k, v) }
            doOutput = true
        }
        return conn.use {
            it.outputStream.use { out -> out.write(body.toByteArray()) }
            val code = it.responseCode
            val text = (if (code in 200..299) it.inputStream else it.errorStream)
                ?.bufferedReader()?.use { reader -> reader.readText() }.orEmpty()
            code to text
        }
    }

    private inline fun <T> HttpURLConnection.use(block: (HttpURLConnection) -> T): T =
        try { block(this) } finally { disconnect() }
}

/** Bridges the FCM token Task into a coroutine without pulling in play-services-tasks-ktx. */
internal suspend fun FirebaseMessaging.awaitToken(): String =
    suspendCancellableCoroutine { cont ->
        token.addOnCompleteListener { task: Task<String> ->
            if (task.isSuccessful) {
                cont.resume(task.result)
            } else {
                cont.resumeWithException(task.exception ?: IllegalStateException("FCM token unavailable"))
            }
        }
    }
