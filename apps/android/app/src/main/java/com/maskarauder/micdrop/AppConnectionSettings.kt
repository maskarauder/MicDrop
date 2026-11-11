package com.maskarauder.micdrop

import android.content.Context

internal object AppConnectionSettings {
    fun load(context: Context) = ConnectionPreferences.from(
        context.getSharedPreferences("connection-settings", Context.MODE_PRIVATE).all)

    fun save(context: Context, preferences: ConnectionPreferences) {
        val edit = context.getSharedPreferences("connection-settings", Context.MODE_PRIVATE).edit()
        for ((key, value) in preferences.fields()) when (value) {
            is Int -> edit.putInt(key, value)
            is String -> edit.putString(key, value)
        }
        edit.apply()
    }
}
