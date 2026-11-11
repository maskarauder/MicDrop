package com.maskarauder.micdrop

// Stop may interrupt a registered Java wait, never an in-flight JNI call.
// Registration/exit share a lock with cancellation so an interrupt cannot
// arrive after a completed wait and leak into native setup or disposal.
internal class SessionWorkerWait(private val worker: Thread, private val cancelled: () -> Boolean) {
    private val lock = Any()
    private var waiting = false

    fun checkpoint() {
        if (cancelled()) throw InterruptedException("Session stopped")
    }

    fun cancel() {
        synchronized(lock) { if (waiting) worker.interrupt() }
    }

    // Only interruptible Java waits belong here: semaphore/latch/future waits,
    // sleep and Object.wait. Invoke WebRTC operations before entering this scope.
    fun <T> await(operation: () -> T): T {
        check(Thread.currentThread() === worker)
        synchronized(lock) { checkpoint(); waiting = true }
        val result = try { operation() } finally {
            synchronized(lock) { waiting = false; Thread.interrupted() }
        }
        checkpoint() // A completed callback cannot authorize work after Stop.
        return result
    }
}
