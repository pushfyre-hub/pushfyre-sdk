package com.wonindia.push

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build
import androidx.core.app.NotificationCompat
import org.json.JSONObject

/**
 * One ongoing notification per activity. The next update replaces it.
 * Android does not have a Dynamic Island, and this does not use the status-bar live-update chip.
 */
internal object PushFyreLiveUpdate {
    private const val CHANNEL_ID = "pushfyre_live"
    private const val PREFS = "pushfyre_live"

    fun show(context: Context, data: Map<String, String>) {
        val key = data["activityKey"].orEmpty()
        if (key.isEmpty()) return
        val version = data["version"]?.toIntOrNull() ?: 0
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val previous = prefs.getInt(key, 0)
        if (previous > version && version > 0) return

        val manager = context.getSystemService(NotificationManager::class.java)
        val notificationId = notificationId(key)
        if (data["event"] == "end") {
            manager.cancel(notificationId)
            prefs.edit().remove(key).apply()
            return
        }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            manager.createNotificationChannel(
                NotificationChannel(CHANNEL_ID, "Live updates", NotificationManager.IMPORTANCE_DEFAULT)
            )
        }

        val state = runCatching { JSONObject(data["state"].orEmpty()) }.getOrNull()
        val layout = data["layout"] ?: state?.optString("layout").orEmpty()
        val title = data["title"].orEmpty().ifBlank { "Update" }
        val body = data["message"].orEmpty()
        val icon = context.applicationInfo.icon
        val builder = NotificationCompat.Builder(context, CHANNEL_ID)
            .setSmallIcon(icon)
            .setContentTitle(title)
            .setContentText(body)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setAutoCancel(false)
            .setContentIntent(openApp(context, key))

        when (layout) {
            "delivery", "steps" -> {
                val progress = state?.optInt("progress") ?: 0
                val total = if (layout == "steps") (state?.optInt("total") ?: 0) else 100
                val current = if (layout == "steps") (state?.optInt("current") ?: 0) else progress
                if (total > 0) builder.setProgress(total, current.coerceIn(0, total), false)
            }
            "countdown" -> {
                val ends = state?.optString("endsAt").orEmpty()
                val millis = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    runCatching { java.time.Instant.parse(ends).toEpochMilli() }.getOrNull()
                } else {
                    null
                }
                if (millis != null && Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                    builder.setWhen(millis)
                        .setShowWhen(true)
                        .setUsesChronometer(true)
                        .setChronometerCountDown(true)
                }
            }
        }

        manager.notify(notificationId, builder.build())
        prefs.edit().putInt(key, version).apply()
    }

    private fun openApp(context: Context, key: String): PendingIntent {
        val launch = context.packageManager.getLaunchIntentForPackage(context.packageName)
            ?: Intent()
        launch.putExtra("pushfyre_activity_key", key)
        launch.flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
        val flags = PendingIntent.FLAG_UPDATE_CURRENT or
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) PendingIntent.FLAG_IMMUTABLE else 0
        return PendingIntent.getActivity(context, notificationId(key), launch, flags)
    }

    private fun notificationId(key: String): Int {
        var hash = 17
        for (char in key) hash = 31 * hash + char.code
        return hash and 0x7fffffff
    }
}
