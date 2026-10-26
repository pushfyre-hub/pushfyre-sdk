package com.wonindia.push

import android.app.Dialog
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.graphics.Color
import android.graphics.drawable.GradientDrawable
import android.net.Uri
import android.view.Gravity
import android.view.ViewGroup
import android.widget.Button
import android.widget.CheckBox
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.SeekBar
import android.widget.TextView
import org.json.JSONArray
import org.json.JSONObject
import java.util.regex.Pattern

/** Draws interactive widgets. Classic banners and popups stay in PushFyreInAppRenderer. */
internal object PushFyreInAppWidgets {

    private val formats = setOf(
        "poll", "slider", "scratch", "flash", "feedback", "yes_no",
        "checklist", "quiz", "image_choice", "countdown", "copy_code"
    )

    fun handles(format: String) = format in formats

    fun show(activity: android.app.Activity, message: InAppMessage, listener: PushFyreInAppRenderer.Listener) {
        val content = message.content
        val textColor = color(content.optString("textColor"), Color.parseColor("#111827"))
        val buttonColor = color(content.optString("buttonColor"), Color.parseColor("#e8321a"))
        val background = color(content.optString("backgroundColor"), Color.WHITE)
        val dialog = Dialog(activity)
        dialog.requestWindowFeature(android.view.Window.FEATURE_NO_TITLE)
        val scroll = ScrollView(activity)
        val column = LinearLayout(activity).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(48, 48, 48, 48)
            setBackgroundColor(background)
        }
        addContent(activity, column, content, textColor)
        var closed = false
        fun finish(answer: JSONObject?) {
            if (closed) return
            closed = true
            dialog.dismiss()
            if (answer != null) listener.onRespond(answer) else listener.onDismissed()
        }
        when (message.format) {
            "poll" -> strings(content.optJSONArray("choices")).forEach { choice ->
                column.addView(button(activity, choice, buttonColor) { finish(JSONObject().put("choice", choice)) })
            }
            "yes_no" -> listOf("yes" to "Yes", "no" to "No").forEach { (value, label) ->
                column.addView(button(activity, label, buttonColor) { finish(JSONObject().put("value", value)) })
            }
            "slider" -> {
                val min = content.optDouble("min", 0.0)
                val max = content.optDouble("max", 10.0)
                val label = TextView(activity).apply { setTextColor(textColor); text = min.toInt().toString() }
                val bar = SeekBar(activity).apply {
                    this.max = (max - min).toInt().coerceAtLeast(1)
                    setOnSeekBarChangeListener(object : SeekBar.OnSeekBarChangeListener {
                        override fun onProgressChanged(seekBar: SeekBar?, progress: Int, fromUser: Boolean) {
                            label.text = (min + progress).toInt().toString()
                        }
                        override fun onStartTrackingTouch(seekBar: SeekBar?) {}
                        override fun onStopTrackingTouch(seekBar: SeekBar?) {}
                    })
                }
                column.addView(bar)
                column.addView(label)
                column.addView(button(activity, "Submit", buttonColor) {
                    finish(JSONObject().put("value", min + bar.progress))
                })
            }
            "scratch" -> column.addView(button(activity, "Scratch to reveal", buttonColor) {
                finish(JSONObject().put("revealed", true))
            })
            "flash" -> {
                val face = button(activity, content.optString("front").ifBlank { "Front" }, buttonColor) {}
                face.setOnClickListener {
                    face.text = content.optString("back").ifBlank { "Back" }
                    finish(JSONObject().put("flipped", true))
                }
                column.addView(face)
            }
            "feedback" -> {
                var score = 0
                val stars = LinearLayout(activity)
                repeat(5) { index ->
                    stars.addView(button(activity, "★", buttonColor) { score = index + 1 })
                }
                column.addView(stars)
                val comment = EditText(activity).apply { hint = "Comment"; maxLines = 4 }
                column.addView(comment)
                column.addView(button(activity, "Send", buttonColor) {
                    if (score < 1) return@button
                    finish(JSONObject().put("score", score).put("comment", comment.text.toString().take(280)))
                })
            }
            "checklist" -> {
                val boxes = strings(content.optJSONArray("items")).map { item ->
                    CheckBox(activity).apply { text = item; setTextColor(textColor) }.also { column.addView(it) }
                }
                column.addView(button(activity, "Done", buttonColor) {
                    val checked = JSONArray()
                    boxes.filter { it.isChecked }.forEach { checked.put(it.text.toString()) }
                    finish(JSONObject().put("checked", checked))
                })
            }
            "quiz" -> addQuiz(activity, column, content, buttonColor) { score, answers ->
                finish(JSONObject().put("score", score).put("answers", answers))
            }
            "image_choice" -> {
                val choices = content.optJSONArray("imageChoices")
                if (choices != null) {
                    for (index in 0 until choices.length()) {
                        val item = choices.optJSONObject(index) ?: continue
                        val label = item.optString("label")
                        column.addView(button(activity, label.ifBlank { "Picture" }, buttonColor) {
                            finish(JSONObject().put("label", label))
                        })
                    }
                }
            }
            "countdown" -> {
                val end = endMillis(content.optString("endsAt"))
                val left = (end - System.currentTimeMillis()).coerceAtLeast(0)
                column.addView(TextView(activity).apply {
                    gravity = Gravity.CENTER
                    setTextColor(textColor)
                    textSize = 22f
                    text = "${left / 3600000}h ${(left % 3600000) / 60000}m left"
                })
            }
            "copy_code" -> column.addView(button(activity, content.optString("code").ifBlank { "Copy" }, buttonColor) {
                val code = content.optString("code")
                val clipboard = activity.getSystemService(Context.CLIPBOARD_SERVICE) as? ClipboardManager
                clipboard?.setPrimaryClip(ClipData.newPlainText("code", code))
                finish(JSONObject().put("copied", true))
            })
        }
        column.addView(button(activity, "Close", Color.TRANSPARENT) { finish(null) })
        scroll.addView(column)
        dialog.setContentView(scroll)
        dialog.setOnCancelListener { finish(null) }
        dialog.window?.setLayout(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT)
        dialog.show()
        listener.onShown()
    }

    private fun addContent(activity: Context, column: LinearLayout, content: JSONObject, textColor: Int) {
        when (content.optString("contentKind").ifBlank { "text" }) {
            "image" -> column.addView(TextView(activity).apply { text = "Image"; setTextColor(textColor) })
            "gift" -> column.addView(TextView(activity).apply {
                setTextColor(textColor)
                text = content.optString("giftLabel") + " · " + content.optString("code")
            })
            "youtube" -> {
                val id = youtubeId(content.optString("youtubeUrl"))
                column.addView(button(activity, if (id.isEmpty()) "YouTube link" else "Play on YouTube", Color.BLACK) {
                    if (id.isNotEmpty()) activity.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse("https://www.youtube.com/watch?v=$id")))
                })
            }
            else -> {
                if (content.optString("title").isNotBlank()) {
                    column.addView(TextView(activity).apply { text = content.optString("title"); setTextColor(textColor); textSize = 18f })
                }
                if (content.optString("message").isNotBlank()) {
                    column.addView(TextView(activity).apply { text = content.optString("message"); setTextColor(textColor) })
                }
            }
        }
    }

    private fun addQuiz(activity: Context, column: LinearLayout, content: JSONObject, buttonColor: Int, done: (Int, JSONArray) -> Unit) {
        val questions = content.optJSONArray("questions") ?: JSONArray()
        val answers = JSONArray()
        var index = 0
        val stage = LinearLayout(activity).apply { orientation = LinearLayout.VERTICAL }
        fun draw() {
            stage.removeAllViews()
            val item = questions.optJSONObject(index) ?: return
            stage.addView(TextView(activity).apply { text = item.optString("prompt") })
            val choices = item.optJSONArray("choices") ?: JSONArray()
            for (choice in 0 until choices.length()) {
                val label = choices.optString(choice)
                stage.addView(button(activity, label, buttonColor) {
                    answers.put(choice)
                    index += 1
                    if (index >= questions.length()) {
                        var score = 0
                        for (position in 0 until answers.length()) {
                            val correct = questions.optJSONObject(position)?.optInt("correct", 0) ?: 0
                            if (answers.optInt(position) == correct) score += 1
                        }
                        done(score, answers)
                    } else {
                        draw()
                    }
                })
            }
        }
        draw()
        column.addView(stage)
    }

    private fun button(context: Context, label: String, color: Int, onClick: () -> Unit): Button {
        return Button(context).apply {
            text = label
            setTextColor(if (color == Color.TRANSPARENT) Color.DKGRAY else Color.WHITE)
            background = GradientDrawable().apply {
                cornerRadius = 24f
                setColor(if (color == Color.TRANSPARENT) Color.parseColor("#F3F4F6") else color)
            }
            setOnClickListener { onClick() }
            layoutParams = LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT).apply { topMargin = 16 }
        }
    }

    private fun strings(array: JSONArray?): List<String> {
        if (array == null) return emptyList()
        return (0 until array.length()).map { array.optString(it).trim() }.filter { it.isNotEmpty() }
    }

    private fun youtubeId(url: String): String {
        val matcher = Pattern.compile("(?:youtube\\.com/watch\\?v=|youtu\\.be/|youtube\\.com/embed/)([\\w-]{6,})").matcher(url)
        return if (matcher.find()) matcher.group(1) ?: "" else ""
    }

    private fun endMillis(value: String): Long {
        if (value.isBlank()) return 0L
        val format = java.text.SimpleDateFormat("yyyy-MM-dd'T'HH:mm", java.util.Locale.US)
        return runCatching { format.parse(value)?.time ?: 0L }.getOrDefault(0L)
    }

    private fun color(value: String, fallback: Int): Int {
        return runCatching { Color.parseColor(value) }.getOrDefault(fallback)
    }
}
