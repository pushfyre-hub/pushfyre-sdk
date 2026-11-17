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
        if (message.data["pushfyre_type"] == "live_activity") {
            PushFyreLiveUpdate.show(this, message.data)
            return
        }
        val title = message.notification?.title ?: message.data["title"] ?: return
        val body = message.notification?.body ?: message.data["message"].orEmpty()
        val target = LINK_KEYS.firstNotNullOfOrNull { key ->
            message.data[key]?.takeIf { it.isNotBlank() }
        }

        val imageUrl = IMAGE_KEYS.firstNotNullOfOrNull { key ->
            message.data[key]?.takeIf { it.isNotBlank() }
        }

        val notificationId = message.data["notificationId"].orEmpty()
        Log.d(PushFyre.TAG, "message received title=$title target=$target image=$imageUrl")
        val shown = show(
            title,
            body,
            target,
            imageUrl,
            message.data["largeIcon"],
            message.data["actionButtons"],
            notificationId,
            DisplayOptions.from(message.data)
        )
        if (shown && notificationId.isNotBlank()) {
            PushFyre.reportDeliveryEvent(this, notificationId, "delivered")
        }
    }

    private fun show(
        title: String,
        body: String,
        target: String?,
        imageUrl: String?,
        largeIconUrl: String?,
        actionButtonsJson: String?,
        notificationId: String,
        options: DisplayOptions
    ): Boolean {
        val config = PushFyre.config ?: run {
            Log.w(PushFyre.TAG, "message received before initialize - not displaying")
            return false
        }

        if (!NotificationManagerCompat.from(this).areNotificationsEnabled()) {
            Log.w(PushFyre.TAG, "notifications disabled for this app - not displaying")
            return false
        }

        val manager = getSystemService(NotificationManager::class.java)
        val sound = options.sound?.let(::rawSound)
        val ledColor = options.ledColor?.let(::parseColor)
        // Android 8+ fixes sound and LED on the channel, so a campaign that picks either
        // posts to its own channel. Without them it keeps the default channel.
        val channelId = if (sound == null && ledColor == null) config.channelId
        else listOfNotNull(config.channelId, sound?.let { options.sound?.let(::resourceName) }, ledColor?.let { "led%08x".format(it) })
            .joinToString("_")
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            // Android 8+ silently drops notifications posted to an unknown channel.
            manager.createNotificationChannel(
                NotificationChannel(channelId, config.channelName, NotificationManager.IMPORTANCE_HIGH).apply {
                    sound?.let {
                        setSound(it, android.media.AudioAttributes.Builder()
                            .setUsage(android.media.AudioAttributes.USAGE_NOTIFICATION)
                            .build())
                    }
                    ledColor?.let {
                        enableLights(true)
                        lightColor = it
                    }
                }
            )
        }

        // A drawable named in the campaign wins. Then the same convention OneSignal uses:
        // ic_stat_pushfyre_default, then an explicitly configured res id, then the launcher
        // icon. The launcher icon is the last resort because Android silhouettes the small
        // icon, which turns most full-colour app icons into a white square.
        val icon = options.smallIcon?.let(::drawableId)
            ?: resources.getIdentifier("ic_stat_pushfyre_default", "drawable", packageName)
                .takeIf { it != 0 }
            ?: config.smallIconRes.takeIf { it != 0 }
            ?: applicationInfo.icon

        val builder = NotificationCompat.Builder(this, channelId)
            .setSmallIcon(icon)
            .setContentTitle(title)
            .setContentText(body)
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setAutoCancel(true)
            .setContentIntent(tapIntent(target, notificationId = notificationId))

        options.subtitle?.let(builder::setSubText)
        options.category?.let(builder::setCategory)
        builder.setVisibility(options.visibility)
        options.accentColor?.let(::parseColor)?.let(builder::setColor)
        options.groupKey?.let(builder::setGroup)
        sound?.let(builder::setSound)
        ledColor?.let { builder.setLights(it, 1000, 1000) }

        // A campaign image becomes the expanded big picture; without one, long text
        // expands instead so the body is never truncated.
        // A campaign large icon shows beside the text; the big picture replaces it when
        // expanded, which is the same arrangement OneSignal produces.
        largeIconUrl?.takeIf { it.isNotBlank() }?.let(::downloadBitmap)?.let(builder::setLargeIcon)

        parseButtons(actionButtonsJson).forEachIndexed { index, button ->
            builder.addAction(
                0,
                button.title,
                tapIntent(button.url.ifBlank { target }, index + 1, button.actionId, notificationId)
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

        // A Collapse ID replaces the notification already showing under that id.
        val collapseId = options.collapseId
        if (collapseId != null) manager.notify(collapseId, 0, builder.build())
        else manager.notify(Random.nextInt(), builder.build())
        return true
    }

    private fun resourceName(value: String) =
        value.substringAfterLast('/').substringBeforeLast('.').lowercase().replace(Regex("[^a-z0-9_]"), "_")

    private fun drawableId(name: String): Int? {
        val resource = resourceName(name)
        return resources.getIdentifier(resource, "drawable", packageName).takeIf { it != 0 }
            ?: resources.getIdentifier(resource, "mipmap", packageName).takeIf { it != 0 }
    }

    /** Campaign sounds are files in the app's res/raw, named without the extension. */
    private fun rawSound(name: String): Uri? {
        val resource = resourceName(name)
        if (resource.isBlank() || resource == "default") return null
        val id = resources.getIdentifier(resource, "raw", packageName)
        if (id == 0) {
            Log.w(PushFyre.TAG, "sound $name is not in res/raw - using the default sound")
            return null
        }
        return Uri.parse("android.resource://$packageName/$id")
    }

    /** Portal colours are RRGGBB or AARRGGBB, with or without a leading #. */
    private fun parseColor(value: String): Int? = runCatching {
        android.graphics.Color.parseColor("#" + value.trim().removePrefix("#"))
    }.getOrNull()

    /** The composer's Android settings, as the worker puts them in the data map. */
    internal data class DisplayOptions(
        val subtitle: String?,
        val smallIcon: String?,
        val sound: String?,
        val category: String?,
        val visibility: Int,
        val ledColor: String?,
        val accentColor: String?,
        val groupKey: String?,
        val collapseId: String?
    ) {
        companion object {
            private val CATEGORIES = mapOf(
                "alarm" to NotificationCompat.CATEGORY_ALARM,
                "call" to NotificationCompat.CATEGORY_CALL,
                "event" to NotificationCompat.CATEGORY_EVENT,
                "message" to NotificationCompat.CATEGORY_MESSAGE,
                "promo" to NotificationCompat.CATEGORY_PROMO,
                "reminder" to NotificationCompat.CATEGORY_REMINDER,
                "social" to NotificationCompat.CATEGORY_SOCIAL
            )

            fun from(data: Map<String, String>): DisplayOptions {
                fun value(key: String) = data[key]?.trim()?.takeIf { it.isNotEmpty() }
                return DisplayOptions(
                    subtitle = value("subtitle"),
                    smallIcon = value("smallIcon"),
                    sound = value("sound"),
                    category = value("category")?.let { CATEGORIES[it.lowercase()] },
                    visibility = when (value("visibility")?.lowercase()) {
                        "private" -> NotificationCompat.VISIBILITY_PRIVATE
                        "secret" -> NotificationCompat.VISIBILITY_SECRET
                        else -> NotificationCompat.VISIBILITY_PUBLIC
                    },
                    ledColor = value("ledColor"),
                    accentColor = value("accentColor"),
                    groupKey = value("groupKey"),
                    collapseId = value("collapseId")
                )
            }
        }
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
    private fun tapIntent(
        target: String?,
        requestOffset: Int = 0,
        actionId: String? = null,
        notificationId: String? = null
    ): PendingIntent {
        val intent = Intent(this, PushFyreTapActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            .apply {
                target?.takeIf { it.isNotBlank() }?.let { putExtra(EXTRA_TARGET_URL, it) }
                actionId?.takeIf { it.isNotBlank() }?.let { putExtra(EXTRA_ACTION_ID, it) }
                notificationId?.takeIf { it.isNotBlank() }?.let { putExtra(EXTRA_NOTIFICATION_ID, it) }
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
        const val EXTRA_NOTIFICATION_ID = "com.wonindia.push.NOTIFICATION_ID"
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
        val notificationId = intent?.getStringExtra(PushFyreMessagingService.EXTRA_NOTIFICATION_ID)
        Log.d(PushFyre.TAG, "notification tapped target=$target actionId=$actionId")
        if (!notificationId.isNullOrBlank()) {
            PushFyre.reportDeliveryEvent(this, notificationId, "clicked", actionId, target)
        }

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
