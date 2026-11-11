package com.maskarauder.micdrop

import org.junit.Assert.*
import org.junit.Test
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Semaphore
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicReference

class SessionWorkerWaitTest {
    private class Owner(private val operation: (Owner) -> Unit) {
        val closed = AtomicBoolean(false)
        val error = AtomicReference<Throwable?>()
        val ended = CountDownLatch(1)
        val worker = Thread({ run() }, "synthetic-session-owner")
        val waits = SessionWorkerWait(worker) { closed.get() }
        private fun run() {
            try { operation(this) } catch (failure: Throwable) { error.set(failure) }
            finally { ended.countDown() }
        }
        fun stop() { closed.set(true); waits.cancel() }
        fun finish() {
            assertTrue("Session owner did not finish", ended.await(5, TimeUnit.SECONDS))
            worker.join(1000)
            assertFalse(worker.isAlive)
        }
    }

    @Test fun stopBeforeTheOwnerStartsCannotCreateNativeResources() {
        val creations = AtomicInteger()
        val owner = Owner { it.waits.checkpoint(); creations.incrementAndGet() }
        owner.stop(); owner.worker.start(); owner.finish()
        assertTrue(owner.error.get() is InterruptedException)
        assertEquals(0, creations.get())
    }

    @Test fun stopDuringInFlightCreationKeepsTheOwnerUninterruptedAndDisposesTheReturnedResource() {
        val creating = CountDownLatch(1)
        val completeCreation = CountDownLatch(1)
        val disposed = AtomicInteger()
        val nextSetup = AtomicInteger()
        val interrupted = AtomicBoolean(false)
        val owner = Owner {
            var owned = false
            try {
                it.waits.checkpoint()
                creating.countDown()
                // Represents in-flight native creation, outside a Java wait scope.
                check(completeCreation.await(5, TimeUnit.SECONDS))
                interrupted.set(Thread.currentThread().isInterrupted)
                owned = true
                it.waits.checkpoint()
                nextSetup.incrementAndGet()
            } finally { if (owned) disposed.incrementAndGet() }
        }
        owner.worker.start()
        try {
            assertTrue(creating.await(5, TimeUnit.SECONDS))
            owner.stop()
        } finally { completeCreation.countDown() }
        owner.finish()
        assertFalse(interrupted.get())
        assertTrue(owner.error.get() is InterruptedException)
        assertEquals(0, nextSetup.get())
        assertEquals(1, disposed.get())
    }

    @Test fun stopWakesBlockedJavaWaitWithoutPassingAnInterruptToCleanup() {
        val waiting = CountDownLatch(1)
        val neverCompletes = CountDownLatch(1)
        val cleanupInterrupted = AtomicBoolean(true)
        val owner = Owner {
            try { it.waits.await { waiting.countDown(); neverCompletes.await(30, TimeUnit.SECONDS) } }
            finally { cleanupInterrupted.set(Thread.currentThread().isInterrupted) }
        }
        owner.worker.start()
        try { assertTrue(waiting.await(5, TimeUnit.SECONDS)); owner.stop(); owner.finish() }
        finally { neverCompletes.countDown() }
        assertTrue(owner.error.get() is InterruptedException)
        assertFalse(cleanupInterrupted.get())
    }

    @Test fun aCompletedWaitAfterStopCannotContinueSetupOrLeaveAnInterrupt() {
        val nextSetup = AtomicInteger()
        val cleanupInterrupted = AtomicBoolean(true)
        val owner = Owner {
            try {
                it.waits.await { it.stop(); "late SDP success" }
                nextSetup.incrementAndGet()
            } finally { cleanupInterrupted.set(Thread.currentThread().isInterrupted) }
        }
        owner.worker.start(); owner.finish()
        assertEquals(0, nextSetup.get())
        assertTrue(owner.error.get() is InterruptedException)
        assertFalse(cleanupInterrupted.get())
    }

    @Test fun stopAfterAcquiringTheAudioPermitReturnsItForTheNextConnection() {
        val audioPermit = Semaphore(1)
        val owner = Owner {
            var acquired = false
            try {
                it.waits.await { audioPermit.acquire(); acquired = true; it.stop() }
                fail("Stopped session continued setup")
            } finally { if (acquired) audioPermit.release() }
        }
        owner.worker.start(); owner.finish()
        assertTrue(owner.error.get() is InterruptedException)
        assertEquals(1, audioPermit.availablePermits())
        val next = Owner {
            var acquired = false
            try { it.waits.await { audioPermit.acquire(); acquired = true } }
            finally { if (acquired) audioPermit.release() }
        }
        next.worker.start(); next.finish()
        assertNull(next.error.get())
        assertEquals(1, audioPermit.availablePermits())
    }

    @Test fun cancellingAQueuedAudioOwnerDoesNotReleaseAnotherSessionsPermit() {
        val audioPermit = Semaphore(0)
        val queued = CountDownLatch(1)
        val owner = Owner {
            var acquired = false
            try { it.waits.await { queued.countDown(); audioPermit.acquire(); acquired = true } }
            finally { if (acquired) audioPermit.release() }
        }
        owner.worker.start()
        try { assertTrue(queued.await(5, TimeUnit.SECONDS)); owner.stop(); owner.finish() }
        finally { audioPermit.release() }
        assertTrue(owner.error.get() is InterruptedException)
        assertEquals(1, audioPermit.availablePermits())
    }

    @Test fun lateAndRepeatedStopCannotInterruptOwnerCleanup() {
        val cleaning = CountDownLatch(1)
        val completeCleanup = CountDownLatch(1)
        val owner = Owner {
            assertEquals("ready", it.waits.await { "ready" })
            cleaning.countDown()
            check(completeCleanup.await(5, TimeUnit.SECONDS))
            assertFalse(Thread.currentThread().isInterrupted)
        }
        owner.worker.start()
        try {
            assertTrue(cleaning.await(5, TimeUnit.SECONDS))
            repeat(20) { owner.stop() }
        } finally { completeCleanup.countDown() }
        owner.finish()
        assertNull(owner.error.get())
    }
}
