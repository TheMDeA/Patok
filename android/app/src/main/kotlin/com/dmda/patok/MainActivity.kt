package com.dmda.patok

import android.content.Context
import android.content.Intent
import android.location.GnssStatus
import android.location.LocationManager
import android.net.Uri
import android.os.Build
import android.provider.OpenableColumns
import android.provider.Settings
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        setupGnssChannel(flutterEngine)
        setupUpdateChannel(flutterEngine)
        setupShareChannel(flutterEngine)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        handleShareIntent(intent)
    }

    // Streams GNSS satellite counts to Dart: {"used": n, "total": m}.
    // "used" = satellites contributing to the current fix.
    private fun setupGnssChannel(flutterEngine: FlutterEngine) {
        EventChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "patok/gnss",
        ).setStreamHandler(object : EventChannel.StreamHandler {
            private var callback: GnssStatus.Callback? = null

            override fun onListen(args: Any?, events: EventChannel.EventSink) {
                val lm =
                    getSystemService(Context.LOCATION_SERVICE) as LocationManager
                callback = object : GnssStatus.Callback() {
                    override fun onSatelliteStatusChanged(status: GnssStatus) {
                        var used = 0
                        val total = status.satelliteCount
                        for (i in 0 until total) {
                            if (status.usedInFix(i)) used++
                        }
                        events.success(mapOf("used" to used, "total" to total))
                    }
                }
                try {
                    lm.registerGnssStatusCallback(callback!!, null)
                } catch (e: SecurityException) {
                    events.error("PERMISSION", "Location permission missing", null)
                }
            }

            override fun onCancel(args: Any?) {
                val lm =
                    getSystemService(Context.LOCATION_SERVICE) as LocationManager
                callback?.let {
                    try {
                        lm.unregisterGnssStatusCallback(it)
                    } catch (_: Exception) {
                    }
                }
                callback = null
            }
        })
    }

    // In-app updater: installs a downloaded APK through the system installer.
    private fun setupUpdateChannel(flutterEngine: FlutterEngine) {
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "patok/update",
        ).setMethodCallHandler { call, result ->
            if (call.method == "installApk") {
                val path = call.argument<String>("path")
                if (path.isNullOrEmpty()) {
                    result.error("ARG", "Missing APK path", null)
                    return@setMethodCallHandler
                }
                // Android 8+: installing from the app requires the user to
                // allow "unknown sources" for this package first. Send
                // them to the system toggle; the Dart side explains it.
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
                    !packageManager.canRequestPackageInstalls()
                ) {
                    startActivity(
                        Intent(
                            Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                            Uri.parse("package:$packageName"),
                        ),
                    )
                    result.error("UNKNOWN_SOURCES", "Unknown sources not allowed", null)
                    return@setMethodCallHandler
                }
                try {
                    val uri: Uri = FileProvider.getUriForFile(
                        this,
                        "${applicationContext.packageName}.fileprovider",
                        File(path),
                    )
                    val intent = Intent(Intent.ACTION_VIEW).apply {
                        setDataAndType(uri, "application/vnd.android.package-archive")
                        addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                        addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                    }
                    startActivity(intent)
                    result.success(null)
                } catch (e: Exception) {
                    result.error("INSTALL", e.message, null)
                }
            } else {
                result.notImplemented()
            }
        }
    }

    // "Open with Patok": a PDF shared from another app arrives as
    // ACTION_SEND (EXTRA_STREAM) or ACTION_VIEW (data). The content URI is
    // copied into the app cache and its path is delivered to Dart —
    // buffered when nobody is listening yet (cold start), pushed live when
    // the stream is active (app already running).
    private var shareSink: EventChannel.EventSink? = null
    private var pendingSharedPdf: String? = null

    private fun setupShareChannel(flutterEngine: FlutterEngine) {
        EventChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "patok/share",
        ).setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(args: Any?, events: EventChannel.EventSink) {
                shareSink = events
                pendingSharedPdf?.let {
                    events.success(it)
                    pendingSharedPdf = null
                }
            }

            override fun onCancel(args: Any?) {
                shareSink = null
            }
        })
        // Cold start: the share intent arrived before the engine existed.
        handleShareIntent(intent)
    }

    private fun handleShareIntent(intent: Intent?) {
        val action = intent?.action ?: return
        val uri: Uri? = when (action) {
            Intent.ACTION_SEND -> {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                    intent.getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java)
                } else {
                    @Suppress("DEPRECATION")
                    intent.getParcelableExtra<Uri>(Intent.EXTRA_STREAM)
                }
            }
            Intent.ACTION_VIEW -> intent.data
            else -> null
        }
        val safeUri = uri ?: return
        val path = copySharedPdfToCache(safeUri) ?: return
        shareSink?.success(path) ?: run { pendingSharedPdf = path }
    }

    private fun copySharedPdfToCache(uri: Uri): String? {
        return try {
            // Preserve the sender's filename (e.g. from WhatsApp) so the
            // library shows the real map name instead of "shared_<millis>".
            val displayName = contentResolver.query(uri, null, null, null, null)?.use { c ->
                val idx = c.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                if (idx >= 0 && c.moveToFirst()) c.getString(idx) else null
            }
            val base = displayName
                ?.takeIf { it.isNotBlank() }
                ?.replace(Regex("[/\\\\]"), "_")
                ?.let { if (it.endsWith(".pdf", ignoreCase = true)) it else "$it.pdf" }
                ?: "shared_${System.currentTimeMillis()}.pdf"
            // Avoid overwriting a previous share with the same name.
            var dest = File(cacheDir, base)
            var n = 1
            while (dest.exists()) {
                dest = File(cacheDir, "${base.removeSuffix(".pdf")} (${n++}).pdf")
            }
            contentResolver.openInputStream(uri)?.use { input ->
                dest.outputStream().use { output -> input.copyTo(output) }
            } ?: return null
            dest.absolutePath
        } catch (_: Exception) {
            null
        }
    }
}
