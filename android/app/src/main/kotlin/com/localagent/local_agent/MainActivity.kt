package com.localagent.local_agent

import android.content.pm.PackageManager
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {
    private val channelName = "com.localagent/apps"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "getAppSizes" -> result.success(collectAppSizes())
                    else -> result.notImplemented()
                }
            }
        // Keeps the screen on while a model downloads or generates: with the
        // screen off Android suspends the CPU and a slow on-device reply (or
        // a multi-GB download) stalls.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.localagent/screen")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "keepOn" -> {
                        val on = call.arguments as? Boolean ?: false
                        runOnUiThread {
                            if (on) {
                                window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                            } else {
                                window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                            }
                        }
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    // PackageManager.getPackageSizeInfo (the API that returns code/data/cache
    // breakdown) is hidden + restricted on modern Android. The reliable
    // userspace approximation is: APK size = sourceDir + all splitSourceDirs.
    // That's what every "storage size" UI shows for the installed code base.
    private fun collectAppSizes(): HashMap<String, Long> {
        val sizes = HashMap<String, Long>()
        val apps = packageManager.getInstalledApplications(PackageManager.GET_META_DATA)
        for (app in apps) {
            var total = 0L
            try {
                val main = File(app.sourceDir)
                if (main.exists()) total += main.length()
                app.splitSourceDirs?.forEach { path ->
                    val f = File(path)
                    if (f.exists()) total += f.length()
                }
            } catch (_: Exception) {
                // Skip unreadable entries — they just won't get a size.
            }
            if (total > 0) sizes[app.packageName] = total
        }
        return sizes
    }
}
