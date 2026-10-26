package com.wonindia.push

import android.app.Activity
import android.app.Dialog
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.ColorDrawable
import android.graphics.drawable.GradientDrawable
import android.os.Build
import android.util.LruCache
import android.util.TypedValue
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.view.ViewGroup.LayoutParams.MATCH_PARENT
import android.view.ViewGroup.LayoutParams.WRAP_CONTENT
import android.view.Window
import android.view.WindowManager
import android.widget.FrameLayout
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL
import kotlin.concurrent.thread

/**
 * Draws one in-app message on top of an Activity using plain Views, so the SDK needs no
 * layout resources, theme or image library from the host app.
 */
internal class PushFyreInAppRenderer(
    private val activity: Activity,
    private val message: InAppMessage,
    private val listener: Listener
) {
    interface Listener {
        fun onShown()
        fun onDismissed()
        fun onAction(url: String?)
        fun onRespond(answer: JSONObject) {}
    }

    private val content = message.content

    /** The icon is optional, but a banner or full-screen message with no button must stay dismissable. */
    private fun showClose(format: String) =
        content.optBoolean("showClose", true) ||
            ((format == "full_screen" || format == "banner") && content.optString("buttonText").isBlank())
    private val bgColor = color(content.optString("backgroundColor"), Color.WHITE)
    private val textColor = color(content.optString("textColor"), Color.parseColor("#111827"))
    private val buttonColor = color(content.optString("buttonColor"), Color.parseColor("#E8321A"))
    private val buttonTextColor = color(content.optString("buttonTextColor"), Color.WHITE)
    private val actionUrl: String? = content.optJSONObject("action")
        ?.optString("value")?.takeIf { it.isNotBlank() }

    private var dialog: Dialog? = null
    private var banner: View? = null
    private var finished = false

    fun show() {
        if (PushFyreInAppWidgets.handles(message.format)) {
            PushFyreInAppWidgets.show(activity, message, listener)
            return
        }
        if (message.format == "banner") showBanner() else showDialog()
        listener.onShown()
    }

    // MARK: - Containers

    private fun showBanner() {
        val root = activity.findViewById<ViewGroup>(android.R.id.content)
        val bar = LinearLayout(activity).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(dp(14), statusBarHeight() + dp(12), dp(if (showClose("banner")) 40 else 14), dp(12))
            this.background = rounded(bgColor, bottomOnly = true, radius = 16f)
            elevation = dp(8).toFloat()
        }
        addImage(bar, content.optString("imageUrl"), dp(44), dp(44), 8f)
        val texts = LinearLayout(activity).apply { orientation = LinearLayout.VERTICAL }
        title(texts, content.optString("title"), 15f, Gravity.START)
        body(texts, content.optString("message"), 13f, Gravity.START)
        bar.addView(texts, LinearLayout.LayoutParams(0, WRAP_CONTENT, 1f).apply { leftMargin = dp(10) })
        content.optString("buttonText").takeIf { it.isNotBlank() }?.let { label ->
            bar.addView(actionButton(label, compact = true), LinearLayout.LayoutParams(WRAP_CONTENT, WRAP_CONTENT).apply {
                leftMargin = dp(10)
            })
        }

        val holder = FrameLayout(activity)
        holder.addView(bar, FrameLayout.LayoutParams(MATCH_PARENT, WRAP_CONTENT))
        if (showClose("banner")) {
            holder.addView(closeButton(), FrameLayout.LayoutParams(dp(30), dp(30), Gravity.END or Gravity.CENTER_VERTICAL).apply {
                rightMargin = dp(8)
                topMargin = statusBarHeight() / 2
            })
        }
        root.addView(holder, FrameLayout.LayoutParams(MATCH_PARENT, WRAP_CONTENT, Gravity.TOP))
        banner = holder
        holder.translationY = -dp(220).toFloat()
        holder.animate().translationY(0f).setDuration(260).start()
    }

    private fun showDialog() {
        val format = message.format
        val shell = Dialog(activity)
        shell.requestWindowFeature(Window.FEATURE_NO_TITLE)
        shell.setCancelable(true)
        shell.setOnCancelListener { finish(dismissed = true) }

        val card = buildCard(format)
        val frame = FrameLayout(activity)
        frame.setOnClickListener { finish(dismissed = true) }
        card.setOnClickListener { /* swallow taps on the card */ }

        val width = (activity.resources.displayMetrics.widthPixels - dp(40)).coerceAtMost(dp(if (format == "image") 460 else 420))
        val params = when (format) {
            "full_screen" -> FrameLayout.LayoutParams(MATCH_PARENT, MATCH_PARENT)
            "bottom_sheet" -> FrameLayout.LayoutParams(MATCH_PARENT, WRAP_CONTENT, Gravity.BOTTOM)
            else -> FrameLayout.LayoutParams(width, WRAP_CONTENT, Gravity.CENTER)
        }
        frame.addView(card, params)
        shell.setContentView(frame)
        shell.window?.apply {
            setBackgroundDrawable(ColorDrawable(Color.TRANSPARENT))
            setLayout(MATCH_PARENT, MATCH_PARENT)
            addFlags(WindowManager.LayoutParams.FLAG_DIM_BEHIND)
            setDimAmount(if (format == "full_screen") 0f else 0.55f)
        }
        // A light full-screen background would hide the white status-bar icons.
        if (format == "full_screen" && Build.VERSION.SDK_INT >= Build.VERSION_CODES.M && isLight(bgColor)) {
            @Suppress("DEPRECATION")
            shell.window?.decorView?.systemUiVisibility = View.SYSTEM_UI_FLAG_LIGHT_STATUS_BAR
        }
        dialog = shell
        shell.show()
    }

    // MARK: - Cards

    private fun buildCard(format: String): View {
        val wrapper = FrameLayout(activity)
        val column = LinearLayout(activity).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER_HORIZONTAL
        }

        when (format) {
            "image" -> {
                wrapper.background = rounded(bgColor, radius = 18f)
                wrapper.clipToOutline = true
                val picture = ImageView(activity).apply {
                    adjustViewBounds = true
                    scaleType = ImageView.ScaleType.FIT_CENTER
                    setOnClickListener { act() }
                }
                loadInto(picture, content.optString("imageUrl"))
                column.addView(picture, LinearLayout.LayoutParams(MATCH_PARENT, WRAP_CONTENT))
            }
            "carousel" -> {
                wrapper.background = rounded(bgColor, radius = 18f)
                wrapper.clipToOutline = true
                drawCarousel(column)
            }
            "full_screen" -> {
                wrapper.setBackgroundColor(bgColor)
                column.gravity = Gravity.CENTER
                column.setPadding(dp(28), dp(48), dp(28), dp(28))
                addImage(column, content.optString("imageUrl"), MATCH_PARENT, dp(220), 14f)
                title(column, content.optString("title"), 22f, Gravity.CENTER, topMargin = dp(20))
                body(column, content.optString("message"), 15f, Gravity.CENTER)
                content.optString("buttonText").takeIf { it.isNotBlank() }?.let { column.addView(actionButton(it), buttonParams()) }
            }
            "bottom_sheet" -> {
                wrapper.background = rounded(bgColor, topOnly = true, radius = 22f)
                column.setPadding(dp(22), dp(26), dp(22), dp(28))
                addImage(column, content.optString("imageUrl"), MATCH_PARENT, dp(110), 14f)
                title(column, content.optString("title"), 20f, Gravity.CENTER)
                body(column, content.optString("message"), 15f, Gravity.CENTER)
                content.optString("buttonText").takeIf { it.isNotBlank() }?.let { column.addView(actionButton(it), buttonParams()) }
            }
            else -> { // modal
                wrapper.background = rounded(bgColor, radius = 18f)
                wrapper.clipToOutline = true
                addImage(column, content.optString("imageUrl"), MATCH_PARENT, dp(180), 0f)
                val hasImage = isHttp(content.optString("imageUrl"))
                val padded = LinearLayout(activity).apply {
                    orientation = LinearLayout.VERTICAL
                    gravity = Gravity.CENTER_HORIZONTAL
                    // Leave room for the close button when there is no picture above the text.
                    setPadding(dp(22), dp(if (hasImage) 20 else 40), dp(22), dp(24))
                }
                title(padded, content.optString("title"), 20f, Gravity.CENTER)
                body(padded, content.optString("message"), 15f, Gravity.CENTER)
                content.optString("buttonText").takeIf { it.isNotBlank() }?.let { padded.addView(actionButton(it), buttonParams()) }
                column.addView(padded, LinearLayout.LayoutParams(MATCH_PARENT, WRAP_CONTENT))
            }
        }

        if (format == "full_screen") {
            val scroll = ScrollView(activity).apply { isFillViewport = true }
            scroll.addView(column, FrameLayout.LayoutParams(MATCH_PARENT, WRAP_CONTENT))
            wrapper.addView(scroll, FrameLayout.LayoutParams(MATCH_PARENT, MATCH_PARENT))
        } else {
            wrapper.addView(column, FrameLayout.LayoutParams(MATCH_PARENT, WRAP_CONTENT))
        }
        if (showClose(format)) {
            wrapper.addView(closeButton(), FrameLayout.LayoutParams(dp(30), dp(30), Gravity.END or Gravity.TOP).apply {
                topMargin = dp(if (format == "full_screen") 40 else 10)
                rightMargin = dp(10)
            })
        }
        return wrapper
    }

    private fun drawCarousel(column: LinearLayout) {
        val slides = content.optJSONArray("slides")
        val count = slides?.length() ?: 0
        val slideList = if (count > 0) (0 until count).map { slides!!.optJSONObject(it) ?: JSONObject() } else listOf(content)
        var index = 0

        fun draw() {
            column.removeAllViews()
            val slide = slideList[index]
            addImage(column, slide.optString("imageUrl"), MATCH_PARENT, dp(190), 0f)
            val text = LinearLayout(activity).apply {
                orientation = LinearLayout.VERTICAL
                gravity = Gravity.CENTER_HORIZONTAL
                setPadding(dp(22), dp(if (isHttp(slide.optString("imageUrl"))) 18 else 40), dp(22), dp(20))
            }
            title(text, slide.optString("title"), 20f, Gravity.CENTER)
            body(text, slide.optString("message"), 15f, Gravity.CENTER)

            val dots = LinearLayout(activity).apply { gravity = Gravity.CENTER }
            for (position in slideList.indices) {
                val dot = View(activity).apply { this.background = rounded(if (position == index) buttonColor else Color.parseColor("#33000000"), radius = 4f) }
                dots.addView(dot, LinearLayout.LayoutParams(dp(8), dp(8)).apply { leftMargin = dp(3); rightMargin = dp(3) })
            }
            text.addView(dots, LinearLayout.LayoutParams(WRAP_CONTENT, WRAP_CONTENT).apply { topMargin = dp(16) })

            val controls = LinearLayout(activity).apply { gravity = Gravity.CENTER }
            if (index > 0) {
                controls.addView(
                    pill("Back", Color.TRANSPARENT, textColor, outline = true).apply { setOnClickListener { index -= 1; draw() } },
                    LinearLayout.LayoutParams(WRAP_CONTENT, WRAP_CONTENT).apply { rightMargin = dp(10) }
                )
            }
            if (index < slideList.size - 1) {
                controls.addView(pill("Next", buttonColor, buttonTextColor).apply { setOnClickListener { index += 1; draw() } })
            } else {
                controls.addView(actionButton(content.optString("buttonText").ifBlank { "Done" }))
            }
            text.addView(controls, LinearLayout.LayoutParams(WRAP_CONTENT, WRAP_CONTENT).apply { topMargin = dp(14) })
            column.addView(text, LinearLayout.LayoutParams(MATCH_PARENT, WRAP_CONTENT))
        }
        draw()
    }

    // MARK: - Pieces

    private fun title(parent: LinearLayout, text: String, size: Float, gravity: Int, topMargin: Int = 0) {
        if (text.isBlank()) return
        parent.addView(TextView(activity).apply {
            this.text = text
            setTextSize(TypedValue.COMPLEX_UNIT_SP, size)
            setTypeface(typeface, Typeface.BOLD)
            setTextColor(textColor)
            this.gravity = gravity
        }, LinearLayout.LayoutParams(if (gravity == Gravity.START) WRAP_CONTENT else MATCH_PARENT, WRAP_CONTENT).apply {
            this.topMargin = topMargin
        })
    }

    private fun body(parent: LinearLayout, text: String, size: Float, gravity: Int) {
        if (text.isBlank()) return
        parent.addView(TextView(activity).apply {
            this.text = text
            setTextSize(TypedValue.COMPLEX_UNIT_SP, size)
            setTextColor(textColor)
            alpha = 0.85f
            setLineSpacing(0f, 1.15f)
            this.gravity = gravity
        }, LinearLayout.LayoutParams(if (gravity == Gravity.START) WRAP_CONTENT else MATCH_PARENT, WRAP_CONTENT).apply {
            topMargin = dp(6)
        })
    }

    private fun addImage(parent: LinearLayout, url: String, width: Int, height: Int, radius: Float) {
        if (!isHttp(url)) return
        val view = ImageView(activity).apply {
            scaleType = ImageView.ScaleType.CENTER_CROP
            if (radius > 0f) {
                this.background = rounded(Color.parseColor("#14000000"), radius = radius)
                clipToOutline = true
            } else {
                setBackgroundColor(Color.parseColor("#14000000"))
            }
        }
        parent.addView(view, LinearLayout.LayoutParams(width, height))
        loadInto(view, url)
    }

    private fun actionButton(label: String, compact: Boolean = false): TextView =
        pill(label, buttonColor, buttonTextColor, compact).apply { setOnClickListener { act() } }

    private fun pill(label: String, fill: Int, text: Int, compact: Boolean = false, outline: Boolean = false) = TextView(activity).apply {
        this.text = label
        setTextSize(TypedValue.COMPLEX_UNIT_SP, if (compact) 13f else 15f)
        setTypeface(typeface, Typeface.BOLD)
        setTextColor(text)
        gravity = Gravity.CENTER
        setPadding(dp(if (compact) 14 else 22), dp(if (compact) 8 else 12), dp(if (compact) 14 else 22), dp(if (compact) 8 else 12))
        this.background = GradientDrawable().apply {
            cornerRadius = dp(10).toFloat()
            setColor(fill)
            if (outline) setStroke(dp(1), Color.parseColor("#33000000"))
        }
        isClickable = true
    }

    private fun buttonParams() = LinearLayout.LayoutParams(WRAP_CONTENT, WRAP_CONTENT).apply { topMargin = dp(16) }

    private fun closeButton() = TextView(activity).apply {
        text = "×"
        setTextColor(Color.WHITE)
        setTextSize(TypedValue.COMPLEX_UNIT_SP, 18f)
        gravity = Gravity.CENTER
        this.background = rounded(Color.parseColor("#59000000"), radius = 15f)
        contentDescription = "Close"
        setOnClickListener { finish(dismissed = true) }
    }

    // MARK: - Actions

    private fun act() {
        if (finished) return
        finished = true
        tearDown()
        listener.onAction(actionUrl)
    }

    private fun finish(dismissed: Boolean) {
        if (finished) return
        finished = true
        tearDown()
        if (dismissed) listener.onDismissed()
    }

    private fun tearDown() {
        dialog?.let { runCatching { it.dismiss() } }
        dialog = null
        banner?.let { view ->
            view.animate().translationY(-dp(220).toFloat()).setDuration(200).withEndAction {
                (view.parent as? ViewGroup)?.removeView(view)
            }.start()
        }
        banner = null
    }

    // MARK: - Helpers

    private fun dp(value: Int) = (value * activity.resources.displayMetrics.density).toInt()

    private fun statusBarHeight(): Int {
        val id = activity.resources.getIdentifier("status_bar_height", "dimen", "android")
        return if (id > 0) activity.resources.getDimensionPixelSize(id) else dp(24)
    }

    private fun rounded(fill: Int, radius: Float = 0f, topOnly: Boolean = false, bottomOnly: Boolean = false) =
        GradientDrawable().apply {
            setColor(fill)
            val r = dp(radius.toInt()).toFloat()
            cornerRadii = when {
                topOnly -> floatArrayOf(r, r, r, r, 0f, 0f, 0f, 0f)
                bottomOnly -> floatArrayOf(0f, 0f, 0f, 0f, r, r, r, r)
                else -> floatArrayOf(r, r, r, r, r, r, r, r)
            }
        }

    private fun isLight(color: Int) =
        (0.299 * Color.red(color) + 0.587 * Color.green(color) + 0.114 * Color.blue(color)) > 160

    private fun color(value: String, fallback: Int) = runCatching { Color.parseColor(value) }.getOrDefault(fallback)

    private fun isHttp(url: String) = url.startsWith("https://") || url.startsWith("http://")

    private fun loadInto(view: ImageView, url: String) {
        if (!isHttp(url)) return
        images.get(url)?.let { view.setImageBitmap(it); return }
        thread(name = "pushfyre-inapp-image", isDaemon = true) {
            val bitmap = runCatching {
                val conn = (URL(url).openConnection() as HttpURLConnection).apply {
                    connectTimeout = 10_000
                    readTimeout = 10_000
                }
                try {
                    conn.inputStream.use { BitmapFactory.decodeStream(it) }
                } finally {
                    conn.disconnect()
                }
            }.getOrNull() ?: return@thread
            images.put(url, bitmap)
            view.post { view.setImageBitmap(bitmap) }
        }
    }

    private companion object {
        val images = object : LruCache<String, Bitmap>(24 * 1024 * 1024) {
            override fun sizeOf(key: String, value: Bitmap) = value.byteCount
        }
    }
}
