package net.tadel.reaprime

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.net.wifi.WifiManager
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import android.util.Log
import android.webkit.WebView
import android.widget.Toast
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity: FlutterFragmentActivity() {
    private val CHANNEL = "com.reaprime.updater/apk_installer"
    private val NETWORK_CHANNEL = "com.reaprime/network"
    private val TAG = "MainActivity"

    companion object {
        private const val MULTICAST_LOCK_TAG = "reaprime-multicast"

        // Process-level lock held in a static field so it survives Activity
        // recreation (WebView crash reinit, config changes). The OS releases it
        // automatically when the process dies.
        private var multicastLock: WifiManager.MulticastLock? = null
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        // super.onCreate() MUST be called before any early return (incl. finish()).
        // ActivityThread.performLaunchActivity throws SuperNotCalledException if
        // onCreate() returns without the superclass having run — the early-return
        // guards below would otherwise crash the app on launch.
        super.onCreate(savedInstanceState)

        // FIRST: Check for cloned environment (Parallel Space, Island, etc.)
        if (isRunningInClonedEnvironment()) {
            Log.w(TAG, "App running in cloned environment - not supported")
            Toast.makeText(this, "App cloning is not supported for security reasons", 
                Toast.LENGTH_LONG).show()
            finish()
            return
        }
        
        // SECOND: Prevent duplicate instances from launcher
        if (!isTaskRoot && intent.hasCategory(Intent.CATEGORY_LAUNCHER) && 
            intent.action == Intent.ACTION_MAIN) {
            Log.w(TAG, "Duplicate launcher instance detected - finishing")
            finish()
            return
        }
        
        // Enable software rendering for WebView on devices with GPU issues
        // This is a workaround for MediaTek chipsets with broken hardware acceleration
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.KITKAT) {
            try {
                WebView.setWebContentsDebuggingEnabled(true)
                Log.d(TAG, "WebView debugging enabled")
            } catch (e: Exception) {
                Log.w(TAG, "Failed to enable WebView debugging", e)
            }
        }
        
        Log.d(TAG, "onCreate - valid instance starting")
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        
        Log.d(TAG, "onNewIntent - action: ${intent.action}, categories: ${intent.categories}")
        
        // App was relaunched - already handled by bringing existing instance to front
        // Could notify Flutter layer here if needed via MethodChannel
    }

    /**
     * Detects if app is running in a cloned environment (Parallel Space, Island, etc.)
     * Normal path: /data/user/0/com.example.app/files
     * Cloned path: /data/data/com.ludashi.dualspace/virtual/data/user/0/com.example.app/files
     * OEM clone: /data/user/999/com.example.app/files
     */
    private fun isRunningInClonedEnvironment(): Boolean {
        val normalPath = "/data/user/0/$packageName"
        val actualPath = filesDir.absolutePath
        val isCloned = !actualPath.startsWith(normalPath)
        
        if (isCloned) {
            Log.w(TAG, "Clone detected - expected: $normalPath, actual: $actualPath")
        }
        
        return isCloned
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "installApk" -> {
                    val apkPath = call.argument<String>("apkPath")
                    if (apkPath != null) {
                        try {
                            installApk(apkPath)
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("INSTALL_FAILED", e.message, null)
                        }
                    } else {
                        result.error("INVALID_ARGUMENT", "APK path is required", null)
                    }
                }
                "canInstallPackages" -> {
                    val canInstall = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                        packageManager.canRequestPackageInstalls()
                    } else {
                        true
                    }
                    result.success(canInstall)
                }
                "requestInstallPermission" -> {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                        val intent = Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES).apply {
                            data = Uri.parse("package:$packageName")
                        }
                        startActivity(intent)
                    }
                    result.success(true)
                }
                else -> {
                    result.notImplemented()
                }
            }
        }

        MethodChannel(
                    flutterEngine.dartExecutor.binaryMessenger,
                    "app/lifecycle"
                ).setMethodCallHandler { call, result ->
                    when (call.method) {
                        "recreateActivity" -> {
                            recreateSafely()
                            result.success(null)
                        }
                        else -> result.notImplemented()
                    }
                }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, NETWORK_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "acquireMulticastLock" -> {
                        try {
                            result.success(acquireMulticastLock())
                        } catch (e: Exception) {
                            result.error("MULTICAST_LOCK_FAILED", e.message, null)
                        }
                    }
                    "releaseMulticastLock" -> {
                        try {
                            releaseMulticastLock()
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("MULTICAST_LOCK_FAILED", e.message, null)
                        }
                    }
                    "isMulticastLockHeld" -> {
                        result.success(multicastLock?.isHeld ?: false)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    /**
     * Acquire a process-level MulticastLock so the Wi-Fi firmware stops dropping
     * inbound broadcast/multicast frames (including ARP), keeping the gateway
     * reachable on the LAN once the radio idles. Idempotent. Returns whether the
     * lock is held afterwards.
     */
    private fun acquireMulticastLock(): Boolean {
        multicastLock?.let {
            if (it.isHeld) {
                Log.d(TAG, "MulticastLock already held")
                return true
            }
        }

        val wifi = applicationContext.getSystemService(Context.WIFI_SERVICE) as? WifiManager
        if (wifi == null) {
            Log.w(TAG, "WifiManager unavailable; cannot acquire MulticastLock")
            return false
        }

        val lock = multicastLock ?: wifi.createMulticastLock(MULTICAST_LOCK_TAG).apply {
            // Not reference-counted: a single release() always frees it, no
            // matter how many acquire() calls happened.
            setReferenceCounted(false)
        }
        lock.acquire()
        multicastLock = lock
        Log.i(TAG, "MulticastLock acquired (held=${lock.isHeld})")
        return lock.isHeld
    }

    private fun releaseMulticastLock() {
        multicastLock?.let {
            if (it.isHeld) {
                it.release()
                Log.i(TAG, "MulticastLock released")
            }
        }
    }

    private fun installApk(apkPath: String) {
        val apkFile = File(apkPath)
        
        if (!apkFile.exists()) {
            throw IllegalArgumentException("APK file does not exist: $apkPath")
        }

        val intent = Intent(Intent.ACTION_VIEW).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_GRANT_READ_URI_PERMISSION
            
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                val apkUri = FileProvider.getUriForFile(
                    this@MainActivity,
                    "$packageName.fileprovider",
                    apkFile
                )
                setDataAndType(apkUri, "application/vnd.android.package-archive")
            } else {
                setDataAndType(Uri.fromFile(apkFile), "application/vnd.android.package-archive")
            }
        }

        startActivity(intent)
    }

    private fun recreateSafely() {
        val activity: Activity = this

        // Ensure this runs on UI thread
        activity.runOnUiThread {
            try {
                activity.recreate()
            } catch (e: Exception) {
                // Never crash here — just log
                e.printStackTrace()
            }
        }
    }
}

