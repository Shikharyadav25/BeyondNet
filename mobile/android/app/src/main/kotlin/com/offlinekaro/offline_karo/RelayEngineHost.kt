package com.offlinekaro.offline_karo

import android.Manifest
import android.bluetooth.BluetoothManager
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import androidx.core.app.NotificationCompat
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
    private const val INVITATIONS = "beyondnet_relay_requests_v2"
    private fun notice(context: Context, id: String, title: String, detail: String, tab: Int = 2) {
        if (Build.VERSION.SDK_INT >= 33 &&
            ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) return
        val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        manager.createNotificationChannel(NotificationChannel(
            INVITATIONS, "Payment relay requests", NotificationManager.IMPORTANCE_HIGH))
        val open = PendingIntent.getActivity(context, id.hashCode(),
            Intent(context, MainActivity::class.java).putExtra("notificationTab", tab),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        manager.notify(id.hashCode(), NotificationCompat.Builder(context, INVITATIONS)
            .setSmallIcon(R.drawable.ic_relay)
            .setContentTitle(title)
            .setContentText(detail)
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setVisibility(NotificationCompat.VISIBILITY_PRIVATE)
            .setStyle(NotificationCompat.BigTextStyle().bigText(detail))
            .setContentIntent(open)
            .setAutoCancel(true)
            .build())
    }
    private var pendingTab: Int? = null
    fun openNotification(intent: Intent?) {
        if (intent?.hasExtra("notificationTab") == true) {
            val tab = intent.getIntExtra("notificationTab", 2)
            if (tab in 0..2) pendingTab = tab
            intent.removeExtra("notificationTab")
        }
    }
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
        return try {
            val adapter = (context.getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager).adapter
            if (adapter?.isEnabled != true) "Turn Bluetooth on to resume relaying."
            else if (!context.packageManager.hasSystemFeature(PackageManager.FEATURE_BLUETOOTH_LE) ||
                !adapter.isMultipleAdvertisementSupported || adapter.bluetoothLeAdvertiser == null)
                "This phone does not support Bluetooth LE relaying. Online payments remain available."
            else null
        } catch (_: SecurityException) {
            "Bluetooth permissions changed. Open BeyondNet and allow Nearby devices."
        }
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
                        result.success(status(app) + mapOf("notificationTab" to pendingTab))
                        pendingTab = null
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
                    "noticeRequest" -> {
                        val args = call.arguments as? Map<*, *>
                        val id = args?.get("id") as? String ?: "relay"
                        notice(app, id, "Nearby payment request",
                            "Help carry an encrypted request. Open BeyondNet to accept or decline. Your money is never used.")
                        result.success(true)
                    }
                    "noticeConnection", "noticeConnectionReady", "noticeSubmitted" -> {
                        val args = call.arguments as? Map<*, *>
                        val id = args?.get("id") as? String ?: "relay"
                        val name = (args?.get("name") as? String ?: "A nearby phone").take(60)
                        when (call.method) {
                            "noticeConnection" -> notice(app, "connection:$id", "Connection approval requested", "$name wants to connect for an offline payment. Tap to accept or reject.")
                            "noticeConnectionReady" -> notice(app, "connection-ready:$id", "Relay connection approved", "You can now make a payment without internet. Keep Bluetooth and Nearby relay on.", 0)
                            else -> notice(app, "submitted:$id", "Payment sent to bank", "The bank returned signed receipts. BeyondNet will deliver them to the offline phone over Bluetooth.")
                        }
                        result.success(true)
                    }
                    "noticeResult" -> {
                        val args = call.arguments as? Map<*, *>
                        val id = args?.get("id") as? String ?: "payment"
                        val status = args?.get("status") as? String ?: "updated"
                        notice(app, "result:$id", "Bank payment $status",
                            "Open BeyondNet Activity for the signed receipt.", 1)
                        result.success(true)
                    }
                    "clearRequest" -> {
                        val id = (call.arguments as? Map<*, *>)?.get("id") as? String
                        if (id != null) (app.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager)
                            .cancel(id.hashCode())
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
