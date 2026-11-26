package net.tadel.reaprime

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.net.wifi.WifiManager
import android.os.Build
import android.os.Bundle
import android.os.Process
import android.os.UserManager
import android.provider.Settings
import android.util.Log
import android.webkit.WebView
import android.widget.Toast
import androidx.activity.result.contract.ActivityResultContracts
import androidx.core.content.FileProvider
import com.github.dart_lang.jni.JniPlugin
import com.github.dart_lang.jni_flutter.JniFlutterPlugin
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.plugins.util.GeneratedPluginRegister
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.Collections
import java.util.WeakHashMap

class MainActivity: FlutterFragmentActivity() {
    private val CHANNEL = "com.reaprime.updater/apk_installer"
    private val NETWORK_CHANNEL = "com.reaprime/network"
    private val ADMISSION_CHANNEL = "com.reaprime/recovery_plugins"
    private val ADMIT_PLUGINS = "admitPlugins"
    private val TAG = "MainActivity"
    private var installPermissionResult: MethodChannel.Result? = null
    private val installPermissionLauncher = registerForActivityResult(
        ActivityResultContracts.StartActivityForResult()
    ) {
        val result = installPermissionResult
        installPermissionResult = null
        result?.success(null)
    }

    companion object {
        private const val MULTICAST_LOCK_TAG = "reaprime-multicast"

        private var multicastLock: WifiManager.MulticastLock? = null

        private val admittedEngines: MutableSet<FlutterEngine> =
            Collections.synchronizedSet(
                Collections.newSetFromMap(WeakHashMap<FlutterEngine, Boolean>())
            )
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        if (isRunningInClonedEnvironment()) {
            Log.w(TAG, "App running in cloned environment - not supported")
            Toast.makeText(this, "App cloning is not supported for security reasons", 
                Toast.LENGTH_LONG).show()
            finish()
            return
        }
        
        if (!isTaskRoot && intent.hasCategory(Intent.CATEGORY_LAUNCHER) && 
            intent.action == Intent.ACTION_MAIN) {
            Log.w(TAG, "Duplicate launcher instance detected - finishing")
            finish()
            return
        }
        
        Log.d(TAG, "onCreate - valid instance starting")
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        
        Log.d(TAG, "onNewIntent - action: ${intent.action}, categories: ${intent.categories}")
        
    }

    override fun onDestroy() {
        val result = installPermissionResult
        installPermissionResult = null
        result?.error("PERMISSION_CANCELLED", "Installation permission request cancelled", null)
        super.onDestroy()
    }

    private fun isRunningInClonedEnvironment(): Boolean {
        val reason = cloneEnvironmentReason(
            Process.myUid(),
            filesDir.absolutePath,
            packageName,
            Build.VERSION.SDK_INT,
            ::currentUserIsProfile,
        ) ?: return false
        Log.w(TAG, reason)
        return true
    }

    private fun currentUserIsProfile(): Boolean =
        Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU ||
            getSystemService(UserManager::class.java).isProfile

    /**
     * The generated registrant is not run here: it is deferred to
     * [admitPlugins], which the Dart recovery gate calls only after it admits
     * normal startup. `FlutterFragmentActivity`'s own override does nothing
     * else, and this activity never injects a pre-built engine.
     */
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        bootstrapRecoveryPlugins(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "isValidApk" -> {
                    val path = call.argument<String>("apkPath")
                    result.success(path != null && isValidApk(path))
                }
                "installApk" -> {
                    val apkPath = call.argument<String>("apkPath")
                    if (apkPath != null) {
                        try {
                            installApk(apkPath)
                            result.success(true)
                        } catch (e: InvalidApkException) {
                            result.error("INVALID_APK", "APK file is invalid", null)
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
                    requestInstallPermission(result)
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
                        "moveTaskToBack" -> {
                            result.success(moveTaskToBack(true))
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

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, ADMISSION_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    ADMIT_PLUGINS -> {
                        try {
                            admitPlugins(flutterEngine)
                            result.success(true)
                        } catch (error: Throwable) {
                            Log.e(TAG, "Plugin registration failed; normal startup stays blocked", error)
                            result.error(
                                "PLUGIN_REGISTRATION_FAILED",
                                error.message ?: error.toString(),
                                null
                            )
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    /**
     * path_provider is a Dart-FFI plugin on Android: it needs the jni class
     * loader and the jni_flutter application context before the recovery gate
     * can resolve its own directory. Nothing else is attached early.
     */
    private fun bootstrapRecoveryPlugins(flutterEngine: FlutterEngine) {
        flutterEngine.plugins.add(JniPlugin())
        flutterEngine.plugins.add(JniFlutterPlugin())
    }

    private fun admitPlugins(flutterEngine: FlutterEngine) {
        synchronized(admittedEngines) {
            if (admittedEngines.contains(flutterEngine)) {
                Log.d(TAG, "Plugins already admitted for this engine")
                return
            }
            requireGeneratedRegistrant()
            enableWebViewDebugging()
            GeneratedPluginRegister.registerGeneratedPlugins(flutterEngine)
            admittedEngines.add(flutterEngine)
            Log.i(TAG, "Plugins admitted for this engine")
        }
    }

    private fun requireGeneratedRegistrant() {
        Class.forName("io.flutter.plugins.GeneratedPluginRegistrant")
            .getDeclaredMethod("registerWith", FlutterEngine::class.java)
    }

    private fun enableWebViewDebugging() {
        try {
            WebView.setWebContentsDebuggingEnabled(true)
            Log.d(TAG, "WebView debugging enabled")
        } catch (e: Exception) {
            Log.w(TAG, "Failed to enable WebView debugging", e)
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
        
        if (!isValidApk(apkPath)) {
            throw InvalidApkException()
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

    private fun isValidApk(path: String): Boolean {
        return try {
            val file = File(path)
            if (!file.isFile || file.length() == 0L) return false
            val flags = PackageManager.GET_SIGNING_CERTIFICATES
            val archive = packageManager.getPackageArchiveInfo(path, flags) ?: return false
            if (archive.packageName != packageName) return false
            val candidate = archive.signingInfo ?: return false
            val installed = packageManager.getPackageInfo(packageName, flags).signingInfo ?: return false
            val candidateSigners = candidate.apkContentsSigners?.toSet().orEmpty()
            val installedSigners = installed.apkContentsSigners?.toSet().orEmpty()
            if (candidateSigners.isEmpty() || installedSigners.isEmpty()) return false
            if (candidateSigners == installedSigners) return true
            if (candidate.hasMultipleSigners() || installed.hasMultipleSigners()) return false
            val installedSigner = installedSigners.singleOrNull() ?: return false
            candidate.signingCertificateHistory?.contains(installedSigner) == true
        } catch (_: Exception) {
            false
        }
    }

    private fun requestInstallPermission(result: MethodChannel.Result) {
        if (installPermissionResult != null) {
            result.error("PERMISSION_REQUEST_PENDING", "Installation settings are already open", null)
            return
        }
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O || packageManager.canRequestPackageInstalls()) {
            result.success(null)
            return
        }
        installPermissionResult = result
        try {
            val intent = Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES).apply {
                data = Uri.parse("package:$packageName")
            }
            installPermissionLauncher.launch(intent)
        } catch (_: Exception) {
            if (installPermissionResult === result) {
                installPermissionResult = null
                result.error("PERMISSION_REQUEST_FAILED", "Could not open installation settings", null)
            }
        }
    }

    private fun recreateSafely() {
        val activity: Activity = this

        activity.runOnUiThread {
            try {
                activity.recreate()
            } catch (e: Exception) {
                e.printStackTrace()
            }
        }
    }
}

private class InvalidApkException : Exception("APK file is invalid")

