package net.tadel.reaprime

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Test

class CloneEnvironmentTest {
    private val packageName = "net.tadel.reaprime"

    private fun uidFor(userId: Int) = userId * 100000 + 10123

    private fun filesDirFor(userId: Int) = "/data/user/$userId/$packageName/files"

    private class ProfileProbe(private val isProfile: Boolean) : () -> Boolean {
        var calls = 0

        override fun invoke(): Boolean {
            calls++
            return isProfile
        }
    }

    @Test
    fun `user 0 with its own data path is allowed without asking for the profile`() {
        val probe = ProfileProbe(isProfile = true)

        val reason = cloneEnvironmentReason(uidFor(0), filesDirFor(0), packageName, 36, probe)

        assertNull(reason)
        assertEquals(0, probe.calls)
    }

    @Test
    fun `a virtual space path is rejected for user 0`() {
        val probe = ProfileProbe(isProfile = false)
        val virtualPath =
            "/data/data/com.ludashi.dualspace/virtual/data/user/0/$packageName/files"

        val reason = cloneEnvironmentReason(uidFor(0), virtualPath, packageName, 36, probe)

        assertNotNull(reason)
        assertEquals(0, probe.calls)
    }

    @Test
    fun `a data path belonging to another user is rejected`() {
        val probe = ProfileProbe(isProfile = false)

        val reason = cloneEnvironmentReason(uidFor(10), filesDirFor(0), packageName, 36, probe)

        assertNotNull(reason)
        assertEquals(0, probe.calls)
    }

    @Test
    fun `a full secondary user is allowed from Android 13`() {
        for (sdk in listOf(33, 34, 35, 36)) {
            val probe = ProfileProbe(isProfile = false)

            val reason = cloneEnvironmentReason(uidFor(10), filesDirFor(10), packageName, sdk, probe)

            assertNull("API $sdk", reason)
            assertEquals("API $sdk", 1, probe.calls)
        }
    }

    @Test
    fun `a profile is rejected from Android 13`() {
        for (userId in listOf(10, 11, 999)) {
            val probe = ProfileProbe(isProfile = true)

            val reason =
                cloneEnvironmentReason(uidFor(userId), filesDirFor(userId), packageName, 33, probe)

            assertNotNull("user $userId", reason)
            assertEquals("user $userId", 1, probe.calls)
        }
    }

    @Test
    fun `a non-zero user is rejected before Android 13 without asking for the profile`() {
        for (sdk in 28..32) {
            val probe = ProfileProbe(isProfile = false)

            val reason = cloneEnvironmentReason(uidFor(10), filesDirFor(10), packageName, sdk, probe)

            assertNotNull("API $sdk", reason)
            assertEquals("API $sdk", 0, probe.calls)
        }
    }
}
