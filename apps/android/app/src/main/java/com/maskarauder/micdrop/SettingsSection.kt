package com.maskarauder.micdrop

import android.content.Context
import android.view.View
import android.widget.Button
import android.widget.LinearLayout
import android.widget.TextView

internal class SettingsSection(context: Context, private val title: String, expanded: Boolean) : LinearLayout(context) {
    private val header = Button(context).apply {
        isAllCaps = false
        gravity = android.view.Gravity.START or android.view.Gravity.CENTER_VERTICAL
        textSize = 17f
        minHeight = dp(48)
        isAccessibilityHeading = true
        backgroundTintList = android.content.res.ColorStateList.valueOf(context.getColor(R.color.surface))
        setTextColor(context.getColor(R.color.text_primary))
    }
    private val summary = TextView(context).apply {
        textSize = 14f
        setTextColor(context.getColor(R.color.text_secondary))
        setPadding(dp(12), 0, dp(12), dp(8))
    }
    val body = LinearLayout(context).apply {
        orientation = VERTICAL
        setPadding(dp(12), dp(4), dp(12), dp(12))
    }
    val expanded get() = body.visibility == View.VISIBLE

    init {
        orientation = VERTICAL
        background = context.getDrawable(R.drawable.settings_card)
        layoutParams = LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.WRAP_CONTENT).apply { bottomMargin = dp(12) }
        addView(header, LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.WRAP_CONTENT))
        addView(summary)
        addView(body)
        header.setOnClickListener { expand(!this.expanded) }
        expand(expanded)
    }

    fun expand(value: Boolean) {
        body.visibility = if (value) View.VISIBLE else View.GONE
        header.text = "$title  ${if (value) "▾" else "▸"}"
        header.setTextColor(context.getColor(if (value) R.color.accent else R.color.text_primary))
        header.contentDescription = title
        header.stateDescription = context.getString(if (value) R.string.section_expanded else R.string.section_collapsed)
    }

    fun summarize(text: String) {
        summary.text = text
        summary.visibility = if (text.isBlank()) View.GONE else View.VISIBLE
    }
    private fun dp(value: Int) = (value * resources.displayMetrics.density).toInt()
}
