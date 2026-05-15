package com.localagent.local_agent

import android.content.pm.PackageManager
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
