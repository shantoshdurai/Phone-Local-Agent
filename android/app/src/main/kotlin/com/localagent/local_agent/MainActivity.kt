package com.localagent.local_agent

import android.app.role.RoleManager
import android.content.ClipboardManager
import android.content.Intent
import android.content.pm.PackageManager
import android.media.MediaPlayer
import android.net.Uri
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {
    private val channelName = "com.localagent/apps"
    private val assistantChannelName = "com.localagent/assistant"

    private var assistantChannel: MethodChannel? = null

    /**
     * A launch intent can arrive before Dart has attached its handler (cold
     * start from the assist gesture or a share sheet). Hold it here until the
     * Dart side calls `consumeLaunchEvent`.
     */
    private var pendingLaunch: Map<String, Any?>? = null
    private var dartReady = false

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "getAppSizes" -> result.success(collectAppSizes())
                    else -> result.notImplemented()
                }
            }

        val channel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            assistantChannelName
        )
        assistantChannel = channel
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "isDefaultAssistant" -> result.success(isDefaultAssistant())
                "requestDefaultAssistant" -> {
                    requestDefaultAssistant()
                    result.success(true)
                }
                "consumeLaunchEvent" -> {
                    dartReady = true
                    val event = pendingLaunch
                    pendingLaunch = null
                    result.success(event)
                }
                "playCue" -> {
                    playCue(call.argument<String>("name") ?: "")
                    result.success(true)
                }
                "getClipboardImage" -> result.success(readClipboardImage())
                else -> result.notImplemented()
            }
        }

        captureLaunch(intent)
    }

    // singleTop + taskAffinity means an assist/share invocation while the app
    // is alive arrives here rather than creating a second activity.
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        captureLaunch(intent)
    }

    private fun captureLaunch(intent: Intent?) {
        if (intent == null) return
        val action = intent.action ?: return

        val event: Map<String, Any?> = when {
            action == Intent.ACTION_ASSIST ||
                action == "android.intent.action.VOICE_COMMAND" ->
                mapOf("type" to "assistant")

            action == Intent.ACTION_SEND && intent.type?.startsWith("image/") == true -> {
                val uri = sharedImageUri(intent)
                val path = if (uri != null) {
                    copyImageToCache(uri, intent.type ?: "image/jpeg")
                } else null
                mapOf(
                    "type" to "share",
                    "text" to (intent.getCharSequenceExtra(Intent.EXTRA_TEXT)?.toString() ?: ""),
                    "imagePath" to path
                )
            }

            action == Intent.ACTION_SEND && intent.type == "text/plain" ->
                mapOf(
                    "type" to "share",
                    "text" to (intent.getCharSequenceExtra(Intent.EXTRA_TEXT)?.toString() ?: "")
                )

            action == Intent.ACTION_PROCESS_TEXT ->
                mapOf(
                    "type" to "share",
                    "text" to (intent.getCharSequenceExtra(Intent.EXTRA_PROCESS_TEXT)?.toString() ?: "")
                )

            else -> return
        }

        if (dartReady) {
            assistantChannel?.invokeMethod("onLaunchEvent", event)
        } else {
            pendingLaunch = event
        }

        // Consume the action so a configuration change or a later getIntent()
        // does not replay the same share into a new session.
        intent.action = null
    }

    private fun sharedImageUri(intent: Intent): Uri? {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            intent.getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java)
        } else {
            @Suppress("DEPRECATION")
            intent.getParcelableExtra(Intent.EXTRA_STREAM)
        }
    }

    /**
     * WhatsApp (and most apps) share images as a content:// URI whose permission
     * dies with the intent. Copy it into our cache so the chat can keep using it.
     */
    private fun copyImageToCache(uri: Uri, mime: String): String? {
        return try {
            val ext = when {
                mime.contains("png") -> "png"
                mime.contains("webp") -> "webp"
                mime.contains("gif") -> "gif"
                else -> "jpg"
            }
            val dir = File(cacheDir, "shared").apply { mkdirs() }
            val out = File(dir, "share_${System.currentTimeMillis()}.$ext")
            contentResolver.openInputStream(uri)?.use { input ->
                out.outputStream().use { output -> input.copyTo(output) }
            } ?: return null
            out.absolutePath
        } catch (_: Exception) {
            null
        }
    }

    /** If the clipboard holds an image URI, copy it and return the path. */
    private fun readClipboardImage(): String? {
        return try {
            val cm = getSystemService(ClipboardManager::class.java) ?: return null
            val clip = cm.primaryClip ?: return null
            if (clip.itemCount == 0) return null
            val desc = clip.description
            if (!desc.hasMimeType("image/*")) return null
            val uri = clip.getItemAt(0).uri ?: return null
            copyImageToCache(uri, desc.getMimeType(0) ?: "image/jpeg")
        } catch (_: Exception) {
            null
        }
    }

    private fun isDefaultAssistant(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return false
        val rm = getSystemService(RoleManager::class.java) ?: return false
        return rm.isRoleAvailable(RoleManager.ROLE_ASSISTANT) &&
            rm.isRoleHeld(RoleManager.ROLE_ASSISTANT)
    }

    private fun requestDefaultAssistant() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return
        val rm = getSystemService(RoleManager::class.java) ?: return
        if (!rm.isRoleAvailable(RoleManager.ROLE_ASSISTANT)) return
        if (rm.isRoleHeld(RoleManager.ROLE_ASSISTANT)) return
        startActivityForResult(
            rm.createRequestRoleIntent(RoleManager.ROLE_ASSISTANT),
            REQUEST_ASSISTANT
        )
    }

    // ── Soft UI cues ────────────────────────────────────────────────────────
    // Two very quiet, short chimes ("listening" / "done") rendered natively so
    // the app doesn't need an audio plugin or any Google system sounds. The
    // player is released as soon as the cue ends to avoid leaking a codec.
    private var cuePlayer: MediaPlayer? = null

    private fun playCue(name: String) {
        val resId = when (name) {
            "listen" -> R.raw.cue_listen
            "done" -> R.raw.cue_done
            else -> return
        }
        try {
            cuePlayer?.release()
            cuePlayer = MediaPlayer.create(this, resId)?.apply {
                setVolume(0.32f, 0.32f)
                setOnCompletionListener {
                    it.release()
                    if (cuePlayer === it) cuePlayer = null
                }
                start()
            }
        } catch (_: Exception) {
            // Audio is decorative; never let it break the voice loop.
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

    companion object {
        private const val REQUEST_ASSISTANT = 4101
    }
}
