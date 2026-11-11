package com.maskarauder.micdrop

import android.content.Intent
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.util.Log

// Kept out of release builds. The component permission is enforced by Android
// before delivery, including for explicit intents and onNewIntent.
class AdbControlActivity : MainActivity() {
    private val commands = Handler(Looper.getMainLooper())
    private var pending: AdbCommand? = null
    private var deadline = 0L
    private val dispatch = object : Runnable {
        override fun run() {
            val command = pending ?: return
            if (SystemClock.elapsedRealtime() >= deadline) {
                pending = null; result(command.name, "activity_not_ready"); return
            }
            // Remove ownership before calling UI code: binding and permission
            // callbacks must never execute the same start action twice.
            pending = null
            val outcome = try { debugCommand(command.name, command.mode, command.enabled, command.invitation) }
                catch (_: Exception) { "command_failed" }
            if (outcome == null) {
                pending = command; commands.postDelayed(this, 50)
            } else result(command.name, outcome)
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Recreation is not a second ADB request. No pending command or secret
        // is persisted across rotation/process death.
        if (savedInstanceState == null) receive(intent)
    }
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        receive(intent)
    }
    private fun receive(incoming: Intent) {
        commands.removeCallbacks(dispatch)
        pending?.let { result(it.name, "superseded") }
        pending = null
        try {
            val extras = incoming.extras
            @Suppress("DEPRECATION")
            val values = extras?.keySet()?.associateWith { extras.get(it) } ?: emptyMap()
            pending = AdbCommand.parse(values)
            deadline = SystemClock.elapsedRealtime() + 5000
            commands.post(dispatch)
        } catch (_: Exception) { result("invalid", "invalid_arguments") }
        finally { setIntent(Intent(this, AdbControlActivity::class.java)) }
    }
    override fun onPause() {
        commands.removeCallbacks(dispatch)
        pending?.let { result(it.name, "activity_hidden") }
        pending = null
        super.onPause()
    }
    override fun onDestroy() {
        commands.removeCallbacks(dispatch); pending = null
        super.onDestroy()
    }
    private fun result(command: String, outcome: String) {
        Log.i("MicDropAdb", "command=$command result=$outcome")
    }
}
