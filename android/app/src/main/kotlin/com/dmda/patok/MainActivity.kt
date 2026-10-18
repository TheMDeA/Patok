package com.dmda.patok

import android.content.Context
import android.location.GnssStatus
import android.location.LocationManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // Streams GNSS satellite counts to Dart: {"used": n, "total": m}.
        // "used" = satellites contributing to the current fix.
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
}
