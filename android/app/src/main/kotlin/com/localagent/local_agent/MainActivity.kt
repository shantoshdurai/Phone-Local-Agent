package com.localagent.local_agent

import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {
    private val channelName = "com.localagent/apps"
    private val assistantChannelName = "com.localagent/assistant"
    private val assistantEventsName = "com.localagent/assistant_events"
    private var assistantEventSink: EventChannel.EventSink? = null

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        val action = intent.action
        if (action == Intent.ACTION_ASSIST || action == Intent.ACTION_VOICE_COMMAND) {
            assistantEventSink?.success("assist")
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        EventChannel(flutterEngine.dartExecutor.binaryMessenger, assistantEventsName)
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    assistantEventSink = events
                }
                override fun onCancel(arguments: Any?) {
                    assistantEventSink = null
                }
            })

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "getAppSizes" -> result.success(collectAppSizes())
                    else -> result.notImplemented()
                }
            }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, assistantChannelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "getLaunchIntent" -> {
                        val action = intent?.action
                        when (action) {
                            Intent.ACTION_ASSIST -> result.success("assist")
                            Intent.ACTION_VOICE_COMMAND -> result.success("voice_command")
                            else -> result.success(null)
                        }
                    }
                    "openAssistantSettings" -> {
                        try {
                            val intent = Intent(Settings.ACTION_VOICE_INPUT_SETTINGS).apply {
                                flags = Intent.FLAG_ACTIVITY_NEW_TASK
                            }
                            startActivity(intent)
                            result.success(true)
                        } catch (_: Exception) {
                            try {
                                val fallback = Intent(Settings.ACTION_MANAGE_DEFAULT_APPS_SETTINGS).apply {
                                    flags = Intent.FLAG_ACTIVITY_NEW_TASK
                                }
                                startActivity(fallback)
                                result.success(true)
                            } catch (e: Exception) {
                                result.success(false)
                            }
                        }
                    }
                    "isOverlayGranted" -> {
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                            result.success(Settings.canDrawOverlays(this@MainActivity))
                        } else {
                            result.success(true)
                        }
                    }
                    "openOverlaySettings" -> {
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                            try {
                                val intent = Intent(
                                    Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
                                    Uri.parse("package:$packageName")
                                ).apply {
                                    flags = Intent.FLAG_ACTIVITY_NEW_TASK
                                }
                                startActivity(intent)
                                result.success(true)
                            } catch (_: Exception) {
                                try {
                                    val fallback = Intent(Settings.ACTION_MANAGE_OVERLAY_PERMISSION).apply {
                                        flags = Intent.FLAG_ACTIVITY_NEW_TASK
                                    }
                                    startActivity(fallback)
                                    result.success(true)
                                } catch (e: Exception) {
                                    result.success(false)
                                }
                            }
                        } else {
                            result.success(false)
                        }
                    }
                    "openBatterySettings" -> {
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                            try {
                                val intent = Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS).apply {
                                    flags = Intent.FLAG_ACTIVITY_NEW_TASK
                                }
                                startActivity(intent)
                                result.success(true)
                            } catch (e: Exception) {
                                result.success(false)
                            }
                        } else {
                            result.success(false)
                        }
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
