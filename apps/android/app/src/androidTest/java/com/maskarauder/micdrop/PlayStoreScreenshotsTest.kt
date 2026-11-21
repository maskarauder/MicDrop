// SPDX-License-Identifier: MPL-2.0
package com.maskarauder.micdrop

import android.Manifest
import android.content.Intent
import android.os.ParcelFileDescriptor
import android.os.SystemClock
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.After
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class PlayStoreScreenshotsTest {
    private var activity: MainActivity? = null

    private fun shell(command: String): String {
        val automation = InstrumentationRegistry.getInstrumentation().uiAutomation
        return ParcelFileDescriptor.AutoCloseInputStream(automation.executeShellCommand(command)).use { stream ->
            stream.readBytes().toString(Charsets.UTF_8)
        }
    }

    @After
    fun tearDown() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        activity?.let { current ->
            runCatching { instrumentation.runOnMainSync { current.finish() } }
        }
        activity = null
        runCatching { shell("am broadcast -a com.android.systemui.demo -e command exit") }
    }

    @Test
    fun capturePlayStoreScreenshots() {
        val args = InstrumentationRegistry.getArguments()
        if (args.getString("micdropScreenshots") != "true") return

        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val targetContext = instrumentation.targetContext
        val outputDir = "/data/local/tmp/micdrop-screenshots"

        listOf(
            Manifest.permission.RECORD_AUDIO,
            Manifest.permission.POST_NOTIFICATIONS,
            Manifest.permission.BLUETOOTH_CONNECT
        ).forEach { permission ->
            runCatching { instrumentation.uiAutomation.grantRuntimePermission(targetContext.packageName, permission) }
        }

        shell("mkdir -p $outputDir")
        shell("input keyevent KEYCODE_WAKEUP")
        shell("wm dismiss-keyguard")
        shell("settings put global window_animation_scale 0")
        shell("settings put global transition_animation_scale 0")
        shell("settings put global animator_duration_scale 0")
        shell("settings put global sysui_demo_allowed 1")
        shell("am broadcast -a com.android.systemui.demo -e command enter")
        shell("am broadcast -a com.android.systemui.demo -e command clock -e hhmm 0930")
        shell("am broadcast -a com.android.systemui.demo -e command network -e wifi show -e level 4 -e fully true")
        shell("am broadcast -a com.android.systemui.demo -e command network -e mobile hide")
        shell("am broadcast -a com.android.systemui.demo -e command status -e bluetooth hide -e alarm hide -e zen hide -e volume hide")
        shell("am broadcast -a com.android.systemui.demo -e command battery -e level 100 -e plugged false")
        shell("am broadcast -a com.android.systemui.demo -e command notifications -e visible false")

        val launchIntent = Intent(targetContext, MainActivity::class.java).apply {
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK)
        }
        val launched = instrumentation.startActivitySync(launchIntent) as MainActivity
        activity = launched

        val deadline = SystemClock.elapsedRealtime() + 15_000L
        var ready = false
        while (SystemClock.elapsedRealtime() < deadline) {
            instrumentation.runOnMainSync { ready = launched.debugScreenshotReady() }
            if (ready) break
            Thread.sleep(100)
        }
        assertTrue("MainActivity did not become ready for screenshot capture within 15s", ready)

        val scenes = listOf(
            "connection" to "01-connection-setup.png",
            "connected_output" to "02-connected-audio-output.png",
            "microphone" to "03-microphone-controls.png",
            "diagnostics" to "04-diagnostics-local-test.png"
        )

        for ((scene, fileName) in scenes) {
            instrumentation.runOnMainSync { launched.applyDebugScreenshotScene(scene) }
            instrumentation.waitForIdleSync()
            Thread.sleep(300)
            instrumentation.runOnMainSync { launched.finalizeDebugScreenshotScene(scene) }
            instrumentation.waitForIdleSync()
            Thread.sleep(350)

            val remotePath = "$outputDir/$fileName"
            shell("screencap -p $remotePath")
            val bytes = shell("stat -c %s $remotePath").trim().toLongOrNull() ?: 0L
            assertTrue("Expected non-empty PNG for $fileName, got $bytes bytes", bytes > 15_000L)
        }
    }
}
