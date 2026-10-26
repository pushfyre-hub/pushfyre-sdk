package com.wonindia.push

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import com.google.firebase.messaging.FirebaseMessagingService
import com.google.firebase.messaging.RemoteMessage
import kotlin.random.Random

/**
 * Arrives with the dependency via manifest merging - integrators never declare it.
 *
 * Android auto-displays an FCM `notification` block only while the app is backgrounded.
 * In the foreground, and for data-only campaigns, the message lands here instead and
 * nothing appears unless we post it ourselves.
 */
class PushFyreMessagingService : FirebaseMessagingService() {

    override fun onNewToken(token: String) {
        Log.d(PushFyre.TAG, "onNewToken ${token.take(16)}...")
        PushFyre.onTokenRefreshed(this, token)
    }

    override fun onMessageReceived(message: RemoteMessage) {
        val title = message.notification?.title ?: message.data["title"] ?: return
        val body = message.notification?.body ?: message.data["message"].orEmpty()
        val target = LINK_KEYS.firstNotNullOfOrNull { key ->
            message.data[key]?.takeIf { it.isNotBlank() }
        }

        val imageUrl = IMAGE_KEYS.firstNotNullOfOrNull { key ->
            message.data[key]?.takeIf { it.isNotBlank() }
        }

        Log.d(PushFyre.TAG, "message received title=$title target=$target image=$imageUrl")
        show(title, body, target, imageUrl, message.data["largeIcon"], message.data["actionButtons"])
    }

    private fun show(
        title: String,
        body: String,
        target: String?,
        imageUrl: String?,
        largeIconUrl: String?,
        actionButtonsJson: String?
    ) {
        val config = PushFyre.config ?: run {
            Log.w(PushFyre.TAG, "message received before initialize - not displaying")
            return
        }

        if (!NotificationManagerCompat.from(this).areNotificationsEnabled()) {
            Log.w(PushFyre.TAG, "notifications disabled for this app - not displaying")
            return
        }

        val manager = getSystemService(NotificationManager::class.java)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            // Android 8+ silently drops notifications posted to an unknown channel.
            manager.createNotificationChannel(
                NotificationChannel(
                    config.channelId, config.channelName, NotificationManager.IMPORTANCE_HIGH
                )
            )
        }

        // Same convention OneSignal uses: a drawable named ic_stat_pushfyre_default
        // wins, then an explicitly configured res id, then the launcher icon. The launcher
        // icon is the last resort because Android silhouettes the small icon, which turns
        // most full-colour app icons into a white square.
        val icon = resources.getIdentifier("ic_stat_pushfyre_default", "drawable", packageName)
            .takeIf { it != 0 }
            ?: config.smallIconRes.takeIf { it != 0 }
            ?: applicationInfo.icon

        val builder = NotificationCompat.Builder(this, config.channelId)
            .setSmallIcon(icon)
            .setContentTitle(title)
            .setContentText(body)
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setAutoCancel(true)
            .setContentIntent(tapIntent(target))

        // A campaign image becomes the expanded big picture; without one, long text
        // expands instead so the body is never truncated.
        // A campaign large icon shows beside the text; the big picture replaces it when
        // expanded, which is the same arrangement OneSignal produces.
        largeIconUrl?.takeIf { it.isNotBlank() }?.let(::downloadBitmap)?.let(builder::setLargeIcon)

        parseButtons(actionButtonsJson).forEachIndexed { index, button ->
            builder.addAction(
                0,
                button.title,
                tapIntent(button.url.ifBlank { target }, index + 1, button.actionId)
            )
        }

        val picture = imageUrl?.let(::downloadBitmap)
        if (picture != null) {
            builder.setLargeIcon(picture)
                .setStyle(
                    NotificationCompat.BigPictureStyle()
                        .bigPicture(picture)
                        .bigLargeIcon(null as android.graphics.Bitmap?)
                        .setSummaryText(body)
                )
        } else {
            builder.setStyle(NotificationCompat.BigTextStyle().bigText(body))
        }

        manager.notify(Random.nextInt(), builder.build())

    }

    /**
     * Runs on the FCM background thread, so a blocking fetch here is safe.
     *
     * The bytes are read fully before decoding: BitmapFactory.decodeStream returns null
     * more often than not on a raw network stream, because it needs to seek and a socket
     * stream cannot. Redirects are followed explicitly - many image URLs (CDN-backed ones
     * especially) answer with a 302, and HttpURLConnection will not follow one that
     * crosses between http and https.
     */
    private fun downloadBitmap(url: String): android.graphics.Bitmap? = runCatching {
        var current = url
        var bytes: ByteArray? = null

        for (hop in 0 until 5) {
            val connection = (java.net.URL(current).openConnection() as java.net.HttpURLConnection).apply {
                connectTimeout = 15_000
                readTimeout = 15_000
                instanceFollowRedirects = true
                setRequestProperty("Accept", "image/*")
            }
            try {
                val code = connection.responseCode
                if (code in 300..399) {
                    val location = connection.getHeaderField("Location")
                    if (location.isNullOrBlank()) {
                        Log.w(PushFyre.TAG, "image redirect with no Location header")
                        return@runCatching null
                    }
                    current = java.net.URL(java.net.URL(current), location).toString()
                    continue
                }
                if (code !in 200..299) {
                    Log.w(PushFyre.TAG, "image fetch returned HTTP $code for $current")
                    return@runCatching null
                }
                bytes = connection.inputStream.use { it.readBytes() }
                break
            } finally {
                connection.disconnect()
            }
        }

        val data = bytes ?: run {
            Log.w(PushFyre.TAG, "image fetch failed for $url")
            return@runCatching null
        }

        android.graphics.BitmapFactory.decodeByteArray(data, 0, data.size).also {
            Log.d(PushFyre.TAG, "image ${data.size} bytes -> bitmap=${it != null}")
        }
    }.getOrElse {
        Log.e(PushFyre.TAG, "image download failed", it)
        null
    }

    /**
     * Routes through [PushFyreTapActivity] rather than straight to a browser, so the
     * host app's tap handler decides where the link opens.
     */
    private fun tapIntent(target: String?, requestOffset: Int = 0, actionId: String? = null): PendingIntent {
        val intent = Intent(this, PushFyreTapActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            .apply {
                target?.takeIf { it.isNotBlank() }?.let { putExtra(EXTRA_TARGET_URL, it) }
                actionId?.takeIf { it.isNotBlank() }?.let { putExtra(EXTRA_ACTION_ID, it) }
            }

        return PendingIntent.getActivity(
            this,
            // Distinct request codes, or every action would reuse the first intent.
            Random.nextInt(Int.MAX_VALUE - 16) + requestOffset,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
    }

    private data class ActionButton(val title: String, val url: String, val actionId: String)

    /** The worker sends actionButtons as a JSON array string inside the data map. */
    private fun parseButtons(json: String?): List<ActionButton> {
        if (json.isNullOrBlank()) return emptyList()
        return runCatching {
            val array = org.json.JSONArray(json)
            (0 until array.length()).mapNotNull { index ->
                val item = array.optJSONObject(index) ?: return@mapNotNull null
                val title = item.optString("title").ifBlank { item.optString("label") }
                if (title.isBlank()) null
                else ActionButton(
                    title = title,
                    url = item.optString("url").ifBlank { item.optString("launchUrl") },
                    actionId = item.optString("actionId").ifBlank { title }
                )
            // Android shows at most three actions; extras are silently dropped.
            }.take(3)
        }.getOrElse {
            Log.w(PushFyre.TAG, "could not parse actionButtons", it)
            emptyList()
        }
    }

    internal companion object {
        /**
         * Campaign link field names, most specific first. `targetUrl` is what existing
         * OneSignal campaigns put in additionalData; `launchUrl` is the portal's own
         * field; `u` is a legacy alias.
         */
        val LINK_KEYS = listOf("targetUrl", "deepLink", "launchUrl", "u")

        /** Campaign image fields, matching what the worker puts in the data map. */
        val IMAGE_KEYS = listOf("imageUrl", "bigPicture", "gifUrl", "bannerUrl")
        const val EXTRA_TARGET_URL = "com.wonindia.push.TARGET_URL"
        const val EXTRA_ACTION_ID = "com.wonindia.push.ACTION_ID"
    }
}

/**
 * Invisible activity that receives the notification tap and hands it to the app's
 * [PushFyreTapHandler], falling back to opening the link externally.
 *
 * It exists because Android 12 blocks "notification trampolines": a tap may not reach an
 * Activity indirectly through a receiver or service, so the PendingIntent has to target an
 * Activity, which may then start another one.
 */
class PushFyreTapActivity : android.app.Activity() {

    override fun onCreate(savedInstanceState: android.os.Bundle?) {
        super.onCreate(savedInstanceState)

        val target = intent?.getStringExtra(PushFyreMessagingService.EXTRA_TARGET_URL)
        val actionId = intent?.getStringExtra(PushFyreMessagingService.EXTRA_ACTION_ID)
        Log.d(PushFyre.TAG, "notification tapped target=$target actionId=$actionId")

        try {
            if (PushFyre.tapHandler?.onNotificationTapped(this, target, actionId) != true) {
                openFallback(target)
            }
        } catch (error: Exception) {
            Log.e(PushFyre.TAG, "tap handler failed", error)
            openFallback(target)
        } finally {
            // Nothing is ever drawn; the real destination is whatever was just started.
            finish()
        }
    }

    private fun openFallback(target: String?) {
        val intent = if (target.isNullOrBlank()) {
            packageManager.getLaunchIntentForPackage(packageName)
        } else {
            Intent(Intent.ACTION_VIEW, android.net.Uri.parse(target))
        }?.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK) ?: return

        runCatching { startActivity(intent) }
            .onFailure { Log.e(PushFyre.TAG, "could not open $target", it) }
    }
}
