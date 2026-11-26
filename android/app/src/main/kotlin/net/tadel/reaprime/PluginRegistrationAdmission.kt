package net.tadel.reaprime

import java.util.Collections
import java.util.WeakHashMap

/**
 * Per-engine plugin registration state for the deferred generated registrant.
 *
 * An engine is admitted only after its registration call returned normally. An
 * engine whose registration threw stays failed for its whole life: the plugin
 * registry keeps a plugin it recorded before `onAttachedToEngine` threw, so a
 * retry would skip that half-attached plugin and report success it never
 * achieved. A fresh engine is the only recovery boundary.
 *
 * No throwable is stored and both sets are weak, so a recorded engine is not
 * retained here.
 */
internal class PluginRegistrationAdmission<T : Any> {
    private val admitted: MutableSet<T> = weakSet()
    private val failed: MutableSet<T> = weakSet()

    fun admit(engine: T, register: () -> Unit) {
        synchronized(admitted) {
            if (admitted.contains(engine)) return
            if (failed.contains(engine)) {
                throw IllegalStateException(
                    "Plugin registration already failed for this engine; a fresh engine is required",
                )
            }
            try {
                register()
            } catch (error: Throwable) {
                failed.add(engine)
                throw error
            }
            admitted.add(engine)
        }
    }

    fun isAdmitted(engine: T): Boolean = synchronized(admitted) { admitted.contains(engine) }

    fun isFailed(engine: T): Boolean = synchronized(admitted) { failed.contains(engine) }
}

private fun <T : Any> weakSet(): MutableSet<T> =
    Collections.synchronizedSet(Collections.newSetFromMap(WeakHashMap<T, Boolean>()))
