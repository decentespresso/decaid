package net.tadel.reaprime

import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

class PluginRegistrationAdmissionTest {
    private class Engine

    private class Recorder {
        var calls = 0

        fun succeeding() {
            calls++
        }

        fun failing(error: Throwable): Nothing {
            calls++
            throw error
        }
    }

    @Test
    fun `a successful registration is admitted once per engine`() {
        val admission = PluginRegistrationAdmission<Engine>()
        val engine = Engine()
        val recorder = Recorder()

        admission.admit(engine) { recorder.succeeding() }
        admission.admit(engine) { recorder.succeeding() }

        assertEquals(1, recorder.calls)
        assertTrue(admission.isAdmitted(engine))
        assertFalse(admission.isFailed(engine))
    }

    @Test
    fun `a registration exception is rethrown and never admits the engine`() {
        val admission = PluginRegistrationAdmission<Engine>()
        val engine = Engine()
        val recorder = Recorder()
        val failure = IllegalStateException("constructor threw")

        val thrown =
            runCatching { admission.admit(engine) { recorder.failing(failure) } }.exceptionOrNull()

        assertSame(failure, thrown)
        assertTrue(admission.isFailed(engine))
        assertFalse(admission.isAdmitted(engine))
    }

    @Test
    fun `an escaping error latches the engine just like an exception`() {
        val admission = PluginRegistrationAdmission<Engine>()
        val engine = Engine()
        val recorder = Recorder()
        val failure = UnsatisfiedLinkError("native library missing")

        val thrown = runCatching { admission.admit(engine) { recorder.failing(failure) } }

        assertSame(failure, thrown.exceptionOrNull())
        assertTrue(admission.isFailed(engine))
        assertFalse(admission.isAdmitted(engine))
    }

    @Test
    fun `a retry after a failure never registers again and never admits`() {
        val admission = PluginRegistrationAdmission<Engine>()
        val engine = Engine()
        val recorder = Recorder()
        runCatching {
            admission.admit(engine) {
                recorder.failing(IllegalStateException("attach threw"))
            }
        }

        for (attempt in 1..3) {
            val refused = runCatching { admission.admit(engine) { recorder.succeeding() } }
            assertTrue("attempt $attempt", refused.exceptionOrNull() is IllegalStateException)
            assertTrue("attempt $attempt", admission.isFailed(engine))
            assertFalse("attempt $attempt", admission.isAdmitted(engine))
        }

        assertEquals(
            "the registry keeps a plugin it inserted before onAttachedToEngine threw, so a " +
                "retry would skip that half-attached plugin and report a success it did not achieve",
            1,
            recorder.calls,
        )
    }

    @Test
    fun `a fresh engine admits after another engine failed`() {
        val admission = PluginRegistrationAdmission<Engine>()
        val failedEngine = Engine()
        val freshEngine = Engine()
        val recorder = Recorder()
        runCatching {
            admission.admit(failedEngine) {
                recorder.failing(IllegalStateException("constructor threw"))
            }
        }

        admission.admit(freshEngine) { recorder.succeeding() }

        assertEquals(2, recorder.calls)
        assertTrue(admission.isAdmitted(freshEngine))
        assertFalse(admission.isFailed(freshEngine))
        assertTrue(admission.isFailed(failedEngine))
        assertFalse(admission.isAdmitted(failedEngine))
    }

    @Test
    fun `concurrent admission registers one engine only once`() {
        val admission = PluginRegistrationAdmission<Engine>()
        val engine = Engine()
        val entered = CountDownLatch(1)
        val release = CountDownLatch(1)
        val started = CountDownLatch(2)
        val registrations = java.util.concurrent.atomic.AtomicInteger()

        val threads =
            (1..2).map {
                Thread {
                    started.countDown()
                    entered.await(5, TimeUnit.SECONDS)
                    admission.admit(engine) {
                        registrations.incrementAndGet()
                        release.await(5, TimeUnit.SECONDS)
                    }
                }.apply { start() }
            }
        started.await(5, TimeUnit.SECONDS)
        entered.countDown()
        while (registrations.get() == 0) {
            Thread.sleep(10)
        }
        release.countDown()
        threads.forEach { it.join(5_000) }

        assertEquals(1, registrations.get())
        assertTrue(admission.isAdmitted(engine))
    }
}
