package com.offlinekaro.offline_karo

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.IntentFilter
import android.bluetooth.BluetoothAdapter
import android.location.LocationManager
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.PowerManager
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat
import androidx.core.content.ContextCompat

/** Explicit, user-visible opt-in. No boot receiver or hidden auto-start. */
open class RelayService : Service() {
    companion object {
        const val STOP = "com.beyondnet.STOP_RELAY"
        const val CHANNEL = "beyondnet_relay"
        const val NOTIFICATION = 7301
        var running = false
            private set
        var instance: RelayService? = null
            private set
    }

    private val handler = Handler(Looper.getMainLooper())
    private var wakeLock: PowerManager.WakeLock? = null
    private var lastText = "Starting encrypted payment relay…"
    private val radioChanges = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            if (running) {
                handler.removeCallbacks(maintain)
                maintain.run()
            }
        }
    }
    private val maintain = object : Runnable {
        override fun run() {
            if (!RelayEngineHost.enabled(this@RelayService)) {
                stopSelf()
                return
            }
            // A timed lease prevents a stalled process holding the CPU forever.
            // The user can stop it from the app or this service's notification.
            val blocked = RelayEngineHost.readiness(this@RelayService)
            if (blocked == null) wakeLock?.acquire(15 * 60 * 1000L)
            else {
                wakeLock?.let { if (it.isHeld) it.release() }
                updateStatus(blocked)
            }
            notifyEngine()
            handler.postDelayed(this, 5 * 60 * 1000L)
        }
    }

    override fun onCreate() {
        super.onCreate()
        instance = this
        (getSystemService(NOTIFICATION_SERVICE) as NotificationManager).createNotificationChannel(
            NotificationChannel(CHANNEL, "Nearby payment relay", NotificationManager.IMPORTANCE_LOW)
        )
        // Both actions are protected Android broadcasts. Readiness is checked
        // from the system rather than trusting values inside the broadcast.
        ContextCompat.registerReceiver(this, radioChanges, IntentFilter().apply {
            addAction(BluetoothAdapter.ACTION_STATE_CHANGED)
            addAction(LocationManager.MODE_CHANGED_ACTION)
        }, ContextCompat.RECEIVER_EXPORTED)
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == STOP) {
            RelayEngineHost.setEnabled(this, false)
            notifyEngine()
            stopSelf()
            return START_NOT_STICKY
        }
        if (!RelayEngineHost.enabled(this)) {
            stopSelf()
            return START_NOT_STICKY
        }
        try {
            var types = ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE
            // Android 10–11 BLE scanning uses foreground Location permission.
            if (Build.VERSION.SDK_INT <= 30) types = types or ServiceInfo.FOREGROUND_SERVICE_TYPE_LOCATION
            ServiceCompat.startForeground(this, NOTIFICATION, notification(), types)
            running = true
            if (wakeLock == null) {
                wakeLock = (getSystemService(POWER_SERVICE) as PowerManager)
                    .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "BeyondNet:Relay")
                    .also { it.setReferenceCounted(false) }
            }
            handler.removeCallbacks(maintain)
            maintain.run()
            startRelayEngine()
            notifyEngine()
            return START_STICKY
        } catch (error: Exception) {
            // Keep opt-in saved, but never claim the radio is running. Reopening
            // the app can recover after a permission or OS launch restriction.
            running = false
            android.util.Log.w("BeyondNet", "Relay service could not start", error)
            stopSelf()
            return START_NOT_STICKY
        }
    }

    protected open fun startRelayEngine() {
        RelayEngineHost.get(this)
        RelayEngineHost.resume()
    }
    protected open fun notifyEngine() { RelayEngineHost.changed(this) }

    fun updateStatus(text: String) {
        if (text == lastText || !running) return
        lastText = text.take(160)
        (getSystemService(NOTIFICATION_SERVICE) as NotificationManager)
            .notify(NOTIFICATION, notification())
    }

    private fun notification(): Notification {
        val open = PendingIntent.getActivity(this, 0,
            Intent(this, MainActivity::class.java), PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        val stop = PendingIntent.getService(this, 1,
            Intent(this, RelayService::class.java).setAction(STOP), PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        return NotificationCompat.Builder(this, CHANNEL)
            .setSmallIcon(R.drawable.ic_relay)
            .setContentTitle(if (RelayEngineHost.readiness(this) == null)
                "BeyondNet relay active" else "BeyondNet relay paused")
            .setContentText(lastText)
            .setContentIntent(open)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .addAction(R.drawable.ic_relay, "Stop relay", stop)
            .build()
    }

    override fun onDestroy() {
        handler.removeCallbacksAndMessages(null)
        unregisterReceiver(radioChanges)
        wakeLock?.let { if (it.isHeld) it.release() }
        wakeLock = null
        running = false
        instance = null
        notifyEngine()
        stopForeground(STOP_FOREGROUND_REMOVE)
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null
}
