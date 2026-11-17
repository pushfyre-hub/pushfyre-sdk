package com.wonindia.push

import android.content.Intent
import android.graphics.Color
import android.graphics.Typeface
import android.net.Uri
import android.util.TypedValue
import android.view.Gravity
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
                blocks.optJSONObject(index)?.let { fillBlock(it, tags) }
            }
        }
    }

    private fun fillBlock(block: JSONObject, tags: Map<String, String>) {
        listOf("text", "src", "label").forEach { key ->
            if (block.has(key)) block.put(key, fill(block.optString(key), tags))
        }
        block.optJSONObject("action")?.let { action ->
            action.put("value", fill(action.optString("value"), tags))
        }
        block.optJSONArray("children")?.let { children ->
            for (index in 0 until children.length()) {
                children.optJSONObject(index)?.let { fillBlock(it, tags) }
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
            "row", "column" -> {
                val children = block.optJSONArray("children") ?: return null
                LinearLayout(context).apply {
                    orientation = if (block.optString("type") == "row") LinearLayout.HORIZONTAL else LinearLayout.VERTICAL
                    gravity = gravity(block.optString("align"))
                    paint(block.optString("background"))?.let { setBackgroundColor(it) }
                    val pad = if (block.optString("background").isBlank()) 0 else dp(parent, 6)
                    setPadding(pad, pad, pad, pad)
                    for (index in 0 until children.length()) {
                        val child = children.optJSONObject(index) ?: continue
                        viewFor(this, child, textColor, buttonColor, onOpen, onImage)?.let { view ->
                            val params = LinearLayout.LayoutParams(
                                if (orientation == LinearLayout.HORIZONTAL) 0 else MATCH_PARENT,
                                WRAP_CONTENT,
                                if (orientation == LinearLayout.HORIZONTAL) 1f else 0f
                            )
                            addView(view, params)
                        }
                    }
                }.takeIf { it.childCount > 0 }
            }
            "text" -> {
                val value = block.optString("text")
                if (value.isBlank()) null
                else TextView(context).apply {
                    text = value
                    setTextColor(paint(block.optString("color")) ?: textColor)
                    setTextSize(TypedValue.COMPLEX_UNIT_SP, textSize(block.optString("size")))
                    gravity = gravity(block.optString("align"))
                    paint(block.optString("background"))?.let { setBackgroundColor(it) }
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
                    setTextColor(paint(block.optString("color")) ?: Color.WHITE)
                    setTypeface(typeface, Typeface.BOLD)
                    setTextSize(TypedValue.COMPLEX_UNIT_SP, textSize(block.optString("size")))
                    gravity = gravity(block.optString("align"))
                    setPadding(dp(parent, 16), dp(parent, 10), dp(parent, 16), dp(parent, 10))
                    background = android.graphics.drawable.GradientDrawable().apply {
                        cornerRadius = dp(parent, 10).toFloat()
                        setColor(paint(block.optString("background")) ?: buttonColor)
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
        return (0 until blocks.length()).flatMap { index ->
            val block = blocks.optJSONObject(index) ?: return@flatMap emptyList()
            when (block.optString("type")) {
                "row", "column" -> lines(block.optJSONArray("children")).split("\n").filter { it.isNotBlank() }
                "text" -> listOfNotNull(block.optString("text").takeIf { it.isNotBlank() })
                "image" -> listOfNotNull("Image".takeIf { block.optString("src").startsWith("https://") })
                "button" -> listOfNotNull(block.optString("label").takeIf { it.isNotBlank() })
                else -> emptyList()
            }
        }.joinToString("\n")
    }

    fun open(context: android.content.Context, url: String) {
        if (url.isBlank()) return
        val intent = Intent(Intent.ACTION_VIEW, Uri.parse(url)).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        runCatching { context.startActivity(intent) }
    }

    private fun paint(value: String): Int? {
        if (!Regex("#[0-9a-fA-F]{6}").matches(value)) return null
        return runCatching { Color.parseColor(value) }.getOrNull()
    }

    private fun gravity(align: String): Int {
        return when (align) {
            "center" -> Gravity.CENTER_HORIZONTAL
            "right" -> Gravity.END
            else -> Gravity.START
        }
    }

    private fun textSize(size: String): Float {
        return when (size) {
            "lg" -> 18f
            "sm" -> 12f
            else -> 14f
        }
    }

    private fun dp(parent: LinearLayout, value: Int): Int {
        return TypedValue.applyDimension(
            TypedValue.COMPLEX_UNIT_DIP,
            value.toFloat(),
            parent.resources.displayMetrics
        ).toInt()
    }
}
