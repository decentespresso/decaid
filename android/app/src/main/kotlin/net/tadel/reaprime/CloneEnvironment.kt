package net.tadel.reaprime

import android.os.Build

private const val PER_USER_RANGE = 100000

/**
 * Explains why the app looks like it is running in a cloned environment
 * (Parallel Space, Island, an OEM dual-app profile, etc.), or returns null.
 * Normal path: /data/user/<current user>/com.example.app/files
 * Cloned path: /data/data/com.ludashi.dualspace/virtual/data/user/0/com.example.app/files
 * OEM clone: /data/user/999/com.example.app/files (a profile, not a full user)
 *
 * The data path is compared with the user the app is actually running as.
 * Devices in headless system user mode (for example Amazon's Alexa Tablet)
 * keep user 0 for the system and run every person, including the owner, as
 * user 10 or higher, so user 0 cannot be assumed.
 */
internal fun cloneEnvironmentReason(
    uid: Int,
    filesDir: String,
    packageName: String,
    sdkInt: Int,
    isProfile: () -> Boolean,
): String? {
    val userId = uid / PER_USER_RANGE
    val normalPath = "/data/user/$userId/$packageName"
    if (!filesDir.startsWith(normalPath)) {
        return "Clone detected - expected: $normalPath, actual: $filesDir"
    }
    if (userId == 0) {
        return null
    }
    if (sdkInt < Build.VERSION_CODES.TIRAMISU || isProfile()) {
        return "Clone detected - running in profile or non-primary user $userId"
    }
    return null
}
