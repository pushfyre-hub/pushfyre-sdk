package com.wonindia.push

import android.content.Intent
import android.graphics.Color
import android.graphics.Typeface
import android.net.Uri
import android.util.TypedValue
import android.view.View
import android.view.ViewGroup.LayoutParams.MATCH_PARENT
import android.view.ViewGroup.LayoutParams.WRAP_CONTENT
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.TextView
import org.json.JSONArray
import org.json.JSONObject

/** Fills {{name}} from device tags and draws the extra blocks under or over a message. */
internal object PushFyreDynamic {
    private val placeholder = Regex("\\{\\{\\s*([A-Za-z0-9_.-]{1,64})\\s*}}")

    fun fill(value: String, tags: Map<String, String>): String {
        if (!value.contains("{{")) return value
        return placeholder.replace(value) { match -> tags[match.groupValues[1]].orEmpty() }
    }

    fun fillObject(content: JSONObject, tags: Map<String, String>) {
        val names = content.keys().asSequence().toList()
        for (name in names) {
            val value = content.opt(name)
            if (value is String) content.put(name, fill(value, tags))
        }
        content.optJSONObject("action")?.let { action ->
            action.put("value", fill(action.optString("value"), tags))
        }
        content.optJSONObject("dynamic")?.optJSONArray("blocks")?.let { blocks ->
            for (index in 0 until blocks.length()) {
                val block = blocks.optJSONObject(index) ?: continue
                listOf("text", "src", "label").forEach { key ->
                    if (block.has(key)) block.put(key, fill(block.optString(key), tags))
                }
                block.optJSONObject("action")?.let { action ->
                    action.put("value", fill(action.optString("value"), tags))
                }
            }
        }
    }

    fun addBlocks(
        parent: LinearLayout,
        content: JSONObject,
        textColor: Int,
        buttonColor: Int,
        onOpen: (String) -> Unit,
        onImage: (ImageView, String) -> Unit = { _, _ -> }
    ) {
        val dynamic = content.optJSONObject("dynamic") ?: return
        val blocks = dynamic.optJSONArray("blocks") ?: return
        if (blocks.length() == 0) return
        val box = LinearLayout(parent.context).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(0, dp(parent, 8), 0, 0)
        }
        for (index in 0 until blocks.length()) {
            val block = blocks.optJSONObject(index) ?: continue
            viewFor(box, block, textColor, buttonColor, onOpen, onImage)?.let { box.addView(it) }
        }
        if (box.childCount == 0) return
        val above = dynamic.optString("placement") == "above"
        parent.addView(box, if (above) 0 else parent.childCount, LinearLayout.LayoutParams(MATCH_PARENT, WRAP_CONTENT))
    }

    private fun viewFor(
        parent: LinearLayout,
        block: JSONObject,
        textColor: Int,
        buttonColor: Int,
        onOpen: (String) -> Unit,
        onImage: (ImageView, String) -> Unit
    ): View? {
        val context = parent.context
        return when (block.optString("type")) {
            "text" -> {
                val value = block.optString("text")
                if (value.isBlank()) null
                else TextView(context).apply {
                    text = value
                    setTextColor(textColor)
                    setTextSize(TypedValue.COMPLEX_UNIT_SP, 14f)
                    setPadding(0, dp(parent, 4), 0, 0)
                }
            }
            "image" -> {
                val src = block.optString("src")
                if (!src.startsWith("https://")) null
                else ImageView(context).apply {
                    adjustViewBounds = true
                    scaleType = ImageView.ScaleType.CENTER_CROP
                    layoutParams = LinearLayout.LayoutParams(MATCH_PARENT, dp(parent, 140)).apply { topMargin = dp(parent, 6) }
                    // The host renderer loads images. A plain view keeps the space; the URL is opened on tap.
                    setBackgroundColor(Color.parseColor("#11000000"))
                    contentDescription = src
                    onImage(this, src)
                    setOnClickListener { onOpen(src) }
                }
            }
            "button" -> {
                val label = block.optString("label")
                if (label.isBlank()) null
                else TextView(context).apply {
                    text = label
                    setTextColor(Color.WHITE)
                    setTypeface(typeface, Typeface.BOLD)
                    setTextSize(TypedValue.COMPLEX_UNIT_SP, 14f)
                    setPadding(dp(parent, 16), dp(parent, 10), dp(parent, 16), dp(parent, 10))
                    background = android.graphics.drawable.GradientDrawable().apply {
                        cornerRadius = dp(parent, 10).toFloat()
                        setColor(buttonColor)
                    }
                    setOnClickListener {
                        val action = block.optJSONObject("action")
                        val type = action?.optString("type").orEmpty()
                        val value = action?.optString("value").orEmpty()
                        if (type == "dismiss") onOpen("")
                        else if (value.startsWith("https://") || value.contains("://")) onOpen(value)
                    }
                }
            }
            else -> null
        }
    }

    fun lines(blocks: JSONArray?): String {
        if (blocks == null) return ""
        return (0 until blocks.length()).mapNotNull { index ->
            val block = blocks.optJSONObject(index) ?: return@mapNotNull null
            when (block.optString("type")) {
                "text" -> block.optString("text").takeIf { it.isNotBlank() }
                "image" -> "Image".takeIf { block.optString("src").startsWith("https://") }
                "button" -> block.optString("label").takeIf { it.isNotBlank() }
                else -> null
            }
        }.joinToString("\n")
    }

    fun open(context: android.content.Context, url: String) {
        if (url.isBlank()) return
        val intent = Intent(Intent.ACTION_VIEW, Uri.parse(url)).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        runCatching { context.startActivity(intent) }
    }

    private fun dp(parent: LinearLayout, value: Int): Int {
        return TypedValue.applyDimension(
            TypedValue.COMPLEX_UNIT_DIP,
            value.toFloat(),
            parent.resources.displayMetrics
        ).toInt()
    }
}
