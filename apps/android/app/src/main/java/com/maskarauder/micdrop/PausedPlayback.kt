package com.maskarauder.micdrop

import android.app.PendingIntent
import android.content.Context
import android.content.Intent

// Only metadata identifying the encrypted saved link. Media3 owns every media
// notification, including pause and System UI playback resumption.
internal object PausedPlayback {
    const val CHANNEL = "playback"
    const val NOTIFICATION = 1
    private fun prefs(context: Context) = context.getSharedPreferences("paused-playback", Context.MODE_PRIVATE)
    fun ticket(context: Context): ResumeTicket? {
        val prefs = prefs(context)
        val id = prefs.getString("id", null) ?: return null
        val digest = prefs.getString("digest", null) ?: return null
        return ResumeTicket(id, digest, prefs.getBoolean("fast", true))
    }
    fun save(context: Context, ticket: ResumeTicket) {
        prefs(context).edit().putString("id", ticket.id).putString("digest", ticket.digest)
            .putBoolean("fast", ticket.fast).apply()
    }
    fun clear(context: Context) { prefs(context).edit().clear().apply() }
    fun open(context: Context): PendingIntent = PendingIntent.getActivity(context, 0,
        Intent(context, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP),
        PendingIntent.FLAG_IMMUTABLE)
}
