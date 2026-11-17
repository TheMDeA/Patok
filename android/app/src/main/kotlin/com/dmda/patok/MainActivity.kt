package com.dmda.patok

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.location.GnssStatus
import android.location.LocationManager
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.OpenableColumns
import android.provider.Settings
import android.util.Log
import androidx.core.content.ContextCompat
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.concurrent.Executors

class MainActivity : FlutterActivity() {
    companion object {
        private const val REQUEST_INSTALL_APK = 9001
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        setupGnssChannel(flutterEngine)
        setupUpdateChannel(flutterEngine)
        setupShareChannel(flutterEngine)
        setupTrackChannel(flutterEngine)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        handleShareIntent(intent)
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == REQUEST_INSTALL_APK) {
            val result = pendingInstallResult
            pendingInstallResult = null
            if (resultCode == Activity.RESULT_OK) {
                result?.success(null)
            } else {
                result?.error("INSTALL_CANCELLED", "Install was cancelled", null)
            }
        }
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
    // The result reflects the real outcome: success only when the installer
    // reports RESULT_OK, an error when the user cancels or it fails —
    // not the moment the installer intent fires.
    private var pendingInstallResult: MethodChannel.Result? = null

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
                if (pendingInstallResult != null) {
                    result.error(
                        "INSTALL_IN_PROGRESS",
                        "Another install is already running",
                        null,
                    )
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
                    pendingInstallResult = result
                    startActivityForResult(intent, REQUEST_INSTALL_APK)
                } catch (e: Exception) {
                    pendingInstallResult = null
                    result.error("INSTALL", e.message, null)
                }
            } else {
                result.notImplemented()
            }
        }
    }

    // Track recording foreground service: started when a recording starts,
    // stopped when it ends, so GPS fixes keep flowing while the phone is
    // locked. The Dart side (TrackRecorder) calls this and ignores a
    // missing handler (unit tests), so recording still works without it.
    private fun setupTrackChannel(flutterEngine: FlutterEngine) {
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "patok/track",
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "start" -> {
                    ContextCompat.startForegroundService(
                        this,
                        Intent(this, TrackRecordingService::class.java),
                    )
                    result.success(null)
                }
                "stop" -> {
                    stopService(Intent(this, TrackRecordingService::class.java))
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    // "Open with Patok": a PDF shared from another app arrives as
    // ACTION_SEND (EXTRA_STREAM), ACTION_SEND_MULTIPLE (a list of streams)
    // or ACTION_VIEW (data). The content URI is copied into the app cache
    // on a background thread and its path is delivered to Dart — buffered
    // when nobody is listening yet (cold start), pushed live when the
    // stream is active (app already running). Copy failures are reported
    // to Dart instead of failing silently.
    private var shareSink: EventChannel.EventSink? = null
    private val pendingSharedPdfs = mutableListOf<String>()
    private val pendingShareErrors = mutableListOf<String>()
    private val shareExecutor = Executors.newSingleThreadExecutor()
    private val mainHandler = Handler(Looper.getMainLooper())

    private fun setupShareChannel(flutterEngine: FlutterEngine) {
        EventChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "patok/share",
        ).setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(args: Any?, events: EventChannel.EventSink) {
                shareSink = events
                pendingSharedPdfs.forEach { events.success(it) }
                pendingSharedPdfs.clear()
                pendingShareErrors.forEach {
                    events.error("SHARE_COPY", it, null)
                }
                pendingShareErrors.clear()
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
            Intent.ACTION_SEND_MULTIPLE -> {
                // Several files shared at once: import the first PDF.
                val uris: List<Uri>? =
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                        intent.getParcelableArrayListExtra(
                            Intent.EXTRA_STREAM,
                            Uri::class.java,
                        )
                    } else {
                        @Suppress("DEPRECATION")
                        intent.getParcelableArrayListExtra<Uri>(Intent.EXTRA_STREAM)
                    }
                uris?.firstOrNull()
            }
            Intent.ACTION_VIEW -> intent.data
            else -> null
        }
        val safeUri = uri ?: return
        // A 50–200 MB GeoPDF copy blocks the UI thread for seconds on slow
        // storage, so copy on a background thread and deliver on the main
        // thread.
        shareExecutor.execute {
            try {
                val path = copySharedPdfToCache(safeUri)
                mainHandler.post { deliverSharedPdf(path) }
            } catch (e: Exception) {
                Log.e("Patok", "Failed to copy shared PDF", e)
                mainHandler.post {
                    deliverShareError(
                        "Couldn't open the shared file: ${e.message ?: "copy failed"}",
                    )
                }
            }
        }
    }

    private fun deliverSharedPdf(path: String) {
        shareSink?.success(path) ?: run { pendingSharedPdfs.add(path) }
        // The share has been handled: clear the intent so an engine
        // re-creation (e.g. process restore) doesn't import the same
        // file a second time.
        clearShareIntent()
    }

    private fun deliverShareError(message: String) {
        shareSink?.error("SHARE_COPY", message, null)
            ?: run { pendingShareErrors.add(message) }
        clearShareIntent()
    }

    private fun clearShareIntent() {
        // handleShareIntent only acts on SEND / SEND_MULTIPLE / VIEW.
        setIntent(Intent(Intent.ACTION_MAIN))
    }

    private fun copySharedPdfToCache(uri: Uri): String {
        // Preserve the sender's filename (e.g. from WhatsApp) so the
        // library shows the real map name instead of "shared_<millis>".
        // Only the DISPLAY_NAME column is requested, not all columns.
        val displayName = contentResolver.query(
            uri,
            arrayOf(OpenableColumns.DISPLAY_NAME),
            null,
            null,
            null,
        )?.use { c ->
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
        try {
            contentResolver.openInputStream(uri)?.use { input ->
                dest.outputStream().use { output ->
                    input.copyTo(output, 256 * 1024)
                }
            } ?: throw IllegalStateException("Could not open shared file")
            return dest.absolutePath
        } catch (e: Exception) {
            // Don't leave a partial copy behind for the next share to find.
            dest.delete()
            throw e
        }
    }
}
