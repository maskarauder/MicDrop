package com.maskarauder.micdrop

import android.media.AudioFormat
import android.media.AudioTrack
import android.os.Process
import android.os.SystemClock
import org.webrtc.audio.MicDropBufferTuner
import java.util.concurrent.Semaphore
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.math.PI
import kotlin.math.sin

internal object AudioSessionOwner { val lock = Semaphore(1) }

// Audio-only baseline below WebRTC's network/decoder/jitter buffer. Matches its
// PCM16 / 48 kHz / stereo / MEDIA-MUSIC / low-latency AudioTrack and 10 ms writes,
// including the same adaptive buffer manager from the pinned AAR.
internal class LocalOutputProbe(private val onSnapshot: (OutputSnapshot) -> Unit,
    private val onEnded: (String) -> Unit) {
    private val closed = AtomicBoolean(false)
    private val click = AtomicBoolean(false) // At most one pending click, no growing queue.
    private val trackLock = Any()
    private var track: AudioTrack? = null
    private val worker = Thread({ run() }, "MicDrop-local-output")
    fun start() = worker.start()
    fun playClick() { if (!closed.get()) click.set(true) }
    fun close() {
        closed.set(true)
        worker.interrupt()
        // Nonblocking writes keep teardown responsive. Do not release on the UI thread.
        synchronized(trackLock) { try { track?.setVolume(0f) } catch (_: RuntimeException) { } }
    }

    private fun run() {
        var ownsSession = false
        var message = "Local output test stopped."
        try {
            AudioSessionOwner.lock.acquire(); ownsSession = true
            if (closed.get()) return
            Process.setThreadPriority(Process.THREAD_PRIORITY_AUDIO)
            val size = AudioTrack.getMinBufferSize(48000, AudioFormat.CHANNEL_OUT_STEREO, AudioFormat.ENCODING_PCM_16BIT)
            check(size > 0)
            val output = AudioTrack.Builder().setAudioAttributes(PlaybackEnvironment.attributes())
                .setAudioFormat(AudioFormat.Builder().setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                    .setSampleRate(48000).setChannelMask(AudioFormat.CHANNEL_OUT_STEREO).build())
                .setTransferMode(AudioTrack.MODE_STREAM).setBufferSizeInBytes(size)
                .setPerformanceMode(AudioTrack.PERFORMANCE_MODE_LOW_LATENCY).build()
            synchronized(trackLock) { track = output; if (closed.get()) output.setVolume(0f) }
            if (closed.get()) return
            check(output.state == AudioTrack.STATE_INITIALIZED)
            val diagnostics = OutputDiagnostics("local_audiotrack")
            val tuner = MicDropBufferTuner()
            val block = ShortArray(960)
            var writtenFrames = 0L
            var nextReport = 0L
            var lastProgress = SystemClock.elapsedRealtime()
            output.play()
            while (!closed.get()) {
                block.fill(0)
                if (click.getAndSet(false)) {
                    // A short tapered chirp, 0.05 peak (~ -26 dBFS), identical channels.
                    for (i in 0 until 480) {
                        val t = i / 48000.0
                        val sample = (1638 * sin(PI * i / 479).let { it * it } *
                            sin(2 * PI * (800 * t + 60000 * t * t))).toInt().toShort()
                        block[2 * i] = sample; block[2 * i + 1] = sample
                    }
                }
                var offset = 0
                while (offset < block.size && !closed.get()) {
                    val count = output.write(block, offset, block.size - offset, AudioTrack.WRITE_NON_BLOCKING)
                    check(count >= 0 && count % 2 == 0)
                    if (count == 0) {
                        check(SystemClock.elapsedRealtime() - lastProgress < 3000)
                        Thread.sleep(1)
                    } else {
                        offset += count; writtenFrames += count / 2
                        lastProgress = SystemClock.elapsedRealtime()
                    }
                }
                if (closed.get()) break
                tuner.adjust(output)
                val now = SystemClock.elapsedRealtime()
                if (now >= nextReport) {
                    diagnostics.snapshot(output, writtenFrames)?.let(onSnapshot)
                    nextReport = now + 500
                }
            }
        } catch (_: InterruptedException) {
            // Stop, focus loss, rotation and a noisy route all end the probe.
        } catch (_: Exception) {
            message = "Local output test failed. Stop and choose the output again."
        } finally {
            Thread.interrupted()
            synchronized(trackLock) {
                track?.let { output ->
                    try { output.pause(); output.flush() } catch (_: RuntimeException) { }
                    try { output.release() } catch (_: RuntimeException) { }
                }
                track = null
            }
            if (ownsSession) AudioSessionOwner.lock.release()
            onEnded(message)
        }
    }
}
