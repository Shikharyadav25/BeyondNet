package com.offlinekaro.offline_karo

import android.Manifest
import android.bluetooth.BluetoothManager
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.location.LocationManager
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.os.Build
import androidx.core.content.ContextCompat
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodChannel

/** One application-scoped engine owns SQLite, BLE and timers. The Activity is
 * only a view onto it; the foreground service retains it without an Activity. */
object RelayEngineHost {
    private var engine: FlutterEngine? = null
    private var control: MethodChannel? = null
    var activityVisible = false
    var dartReady = false

    fun preferences(context: Context) =
        context.getSharedPreferences("beyondnet_relay", Context.MODE_PRIVATE)

    fun enabled(context: Context) = preferences(context).getBoolean("enabled", false)

    fun setEnabled(context: Context, enabled: Boolean) {
        // Synchronous persistence: a stop action must survive process death.
        check(preferences(context).edit().putBoolean("enabled", enabled).commit())
    }

    fun readiness(context: Context): String? {
        val permissions = if (Build.VERSION.SDK_INT >= 31) listOf(
            Manifest.permission.BLUETOOTH_SCAN,
            Manifest.permission.BLUETOOTH_CONNECT,
            Manifest.permission.BLUETOOTH_ADVERTISE
        ) else listOf(Manifest.permission.ACCESS_FINE_LOCATION)
        if (permissions.any { ContextCompat.checkSelfPermission(context, it) != PackageManager.PERMISSION_GRANTED })
            return "Bluetooth permissions need attention. Open BeyondNet to grant them."
        if (Build.VERSION.SDK_INT <= 30 &&
            !(context.getSystemService(Context.LOCATION_SERVICE) as LocationManager).isLocationEnabled)
            return "Turn Location on for Android 10–11 Bluetooth discovery."
        val adapter = (context.getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager).adapter
        return if (adapter?.isEnabled == true) null else "Turn Bluetooth on to resume relaying."
    }

    fun get(context: Context): FlutterEngine {
        engine?.let { return it }
        val app = context.applicationContext
        val created = FlutterEngine(app) // Automatically registers Flutter plugins.
        engine = created
        MethodChannel(created.dartExecutor.binaryMessenger, "beyondnet/network")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "androidSdkVersion" -> result.success(Build.VERSION.SDK_INT)
                    "hasInternet" -> {
                        val manager = app.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
                        result.success(manager.getNetworkCapabilities(manager.activeNetwork)
                            ?.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED) == true)
                    }
                    else -> result.notImplemented()
                }
            }
        control = MethodChannel(created.dartExecutor.binaryMessenger, "beyondnet/relay")
        control!!.setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "ready" -> {
                        dartReady = true
                        // Only an explicit previous opt-in is resumed. Launch
                        // restrictions are respected when no Activity is visible.
                        if (enabled(app) && !RelayService.running && activityVisible && readiness(app) == null)
                            ContextCompat.startForegroundService(app, Intent(app, RelayService::class.java))
                        result.success(status(app))
                    }
                    "status" -> result.success(status(app))
                    "start" -> {
                        check(activityVisible) { "Open BeyondNet to enable background relay." }
                        check(readiness(app) == null) { readiness(app) ?: "Bluetooth unavailable" }
                        setEnabled(app, true)
                        try {
                            ContextCompat.startForegroundService(app, Intent(app, RelayService::class.java))
                        } catch (error: Exception) {
                            setEnabled(app, false)
                            throw error
                        }
                        result.success(true)
                    }
                    "stop" -> {
                        setEnabled(app, false)
                        app.stopService(Intent(app, RelayService::class.java))
                        result.success(true)
                    }
                    "update" -> {
                        val args = call.arguments as? Map<*, *>
                        RelayService.instance?.updateStatus(args?.get("text") as? String ?: "Relaying encrypted payments")
                        result.success(true)
                    }
                    "batterySettings" -> {
                        app.startActivity(Intent(android.provider.Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS)
                            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            } catch (error: Exception) {
                result.error("relay", error.message ?: "Background relay unavailable", null)
            }
        }
        created.dartExecutor.executeDartEntrypoint(DartExecutor.DartEntrypoint.createDefault())
        return created
    }

    fun status(context: Context) = mapOf(
        "enabled" to enabled(context), "running" to RelayService.running,
        "blocked" to readiness(context)
    )

    fun changed(context: Context) {
        if (dartReady) control?.invokeMethod("stateChanged", status(context))
    }

    fun resume() { engine?.lifecycleChannel?.appIsResumed() }
}
