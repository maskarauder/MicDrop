package com.maskarauder.micdrop

import android.app.Application

class MicDropApplication : Application() {
    override fun onCreate() {
        super.onCreate()
        val previous = Thread.getDefaultUncaughtExceptionHandler() ?: return
        Thread.setDefaultUncaughtExceptionHandler { thread, error ->
            try {
                // Capture only classes/locations, never exception messages or
                // arbitrary application data. Preserve Android's crash handling.
                runCatching { StoredReports.saveJavaCrash(this,
                    "Java crash captured at: ${java.time.Instant.now()}\n" +
                        "MicDrop ${BuildConfig.VERSION_NAME} · build ${BuildConfig.REVISION}\n" +
                        CrashText.javaStack(error) + "\n" + StoredReports.stream(this).orEmpty()) }
            } finally { previous.uncaughtException(thread, error) }
        }
    }
}
