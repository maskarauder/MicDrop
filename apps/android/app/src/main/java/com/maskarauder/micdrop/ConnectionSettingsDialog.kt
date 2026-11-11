package com.maskarauder.micdrop

import android.app.AlertDialog
import android.content.Context
import android.text.InputType
import android.widget.ArrayAdapter
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.Spinner
import android.widget.TextView

internal object ConnectionSettingsDialog {
    fun show(context: Context, group: ConnectionSettingsGroup, saved: () -> Unit) {
        val current = AppConnectionSettings.load(context)
        val body = LinearLayout(context).apply {
            orientation = LinearLayout.VERTICAL
            val padding = (20 * resources.displayMetrics.density).toInt()
            setPadding(padding, padding, padding, padding)
        }
        fun label(text: String) = TextView(context).apply {
            this.text = text; textSize = 14f
            setPadding(0, (12 * resources.displayMetrics.density).toInt(), 0, 0)
            body.addView(this)
        }
        label("Saved for the next connection. Stop and Connect to apply. All times are in seconds; decimals are allowed.")
        if (group == ConnectionSettingsGroup.RECOVERY) {
            label("Windows must also be updated to extend its deadlines. Its missing-heartbeat limit follows the recovery window plus 5 seconds. A longer window waits for connectivity; Android still chooses when to leave Wi-Fi.")
        }
        if (group == ConnectionSettingsGroup.AUDIO) {
            label("How long to wait for the selected Bluetooth device to return. Audio stays gated until that device is verified. This is separate from network recovery and does not extend initial route verification or input-switch teardown.")
        }
        fun order(title: String, value: ConnectionOrder): Spinner {
            val heading = label(title)
            return Spinner(context).apply {
                id = android.view.View.generateViewId(); heading.labelFor = id
                adapter = ArrayAdapter(context, android.R.layout.simple_spinner_item,
                    ConnectionOrder.entries.map { it.label }).apply { setDropDownViewResource(android.R.layout.simple_spinner_dropdown_item) }
                setSelection(value.ordinal); body.addView(this)
            }
        }
        val initial = if (group == ConnectionSettingsGroup.RECOVERY) order("Initial Connect / manual Reconnect", current.initialOrder) else null
        val recovery = if (group == ConnectionSettingsGroup.RECOVERY) order("Automatic recovery", current.recoveryOrder) else null
        val inputs = ConnectionTimeout.entries.filter { it.group == group }.associateWith { timeout ->
            val heading = label("${timeout.label} (${ConnectionTimeout.seconds(timeout.minimumMs)}–${ConnectionTimeout.seconds(timeout.maximumMs)} s)")
            EditText(context).apply {
                id = android.view.View.generateViewId(); heading.labelFor = id
                inputType = InputType.TYPE_CLASS_NUMBER or InputType.TYPE_NUMBER_FLAG_DECIMAL
                setSingleLine(); setText(ConnectionTimeout.seconds(current[timeout])); body.addView(this)
            }
        }
        val restarts = if (group == ConnectionSettingsGroup.RECOVERY) {
            val heading = label("Maximum ICE restarts per interruption (1–10)")
            EditText(context).apply {
                id = android.view.View.generateViewId(); heading.labelFor = id
                inputType = InputType.TYPE_CLASS_NUMBER; setSingleLine(); setText(current.maxRestarts.toString()); body.addView(this)
            }
        } else null
        val dialog = AlertDialog.Builder(context).setTitle(group.label)
            .setView(ScrollView(context).apply { addView(body) })
            .setNegativeButton(android.R.string.cancel, null).setNeutralButton("Defaults", null)
            .setPositiveButton("Save", null).create()
        dialog.setOnShowListener {
            dialog.getButton(AlertDialog.BUTTON_NEUTRAL).setOnClickListener {
                for ((key, input) in inputs) input.setText(ConnectionTimeout.seconds(key.defaultMs))
                initial?.setSelection(ConnectionOrder.LAN_FIRST.ordinal)
                recovery?.setSelection(ConnectionOrder.RENDEZVOUS_FIRST.ordinal)
                restarts?.setText("2")
            }
            dialog.getButton(AlertDialog.BUTTON_POSITIVE).setOnClickListener {
                var valid = true
                val timeouts = inputs.mapValues { (key, input) ->
                    val parsed = key.parseSeconds(input.text.toString().trim())
                    input.error = if (parsed == null) "Enter ${ConnectionTimeout.seconds(key.minimumMs)}–${ConnectionTimeout.seconds(key.maximumMs)} seconds" else null
                    if (parsed == null) valid = false
                    parsed ?: key.defaultMs
                }
                val count = restarts?.text?.toString()?.toIntOrNull() ?: if (restarts == null) current.maxRestarts else 0
                if (count !in 1..10) { restarts?.error = "Enter 1–10"; valid = false }
                if (valid) {
                    val latest = AppConnectionSettings.load(context)
                    AppConnectionSettings.save(context, latest.copy(timeouts = latest.timeouts + timeouts,
                        initialOrder = initial?.let { ConnectionOrder.entries[it.selectedItemPosition] } ?: latest.initialOrder,
                        recoveryOrder = recovery?.let { ConnectionOrder.entries[it.selectedItemPosition] } ?: latest.recoveryOrder,
                        maxRestarts = if (restarts != null) count else latest.maxRestarts))
                    saved(); dialog.dismiss()
                }
            }
        }
        dialog.show()
    }
}
