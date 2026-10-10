package com.offlinekaro.offline_karo

import android.app.Service
import android.content.Intent
import android.os.PowerManager
import android.Manifest
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothAdapter
import android.location.LocationManager
import android.content.Context
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config
import org.robolectric.shadows.ShadowPowerManager
import org.robolectric.Shadows.shadowOf

// Real Android Service lifecycle, preferences, foreground notification and wake
// lock. Only the Flutter JNI bridge is substituted (it needs real hardware).
class ServiceWithoutFlutter : RelayService() {
    var engineStarts = 0
    override fun startRelayEngine() { engineStarts++ }
    override fun notifyEngine() { }
}

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [29, 34], manifest = Config.NONE)
class RelayServiceTest {
    private val app get() = RuntimeEnvironment.getApplication()

    @Before fun setup() {
        RelayEngineHost.setEnabled(app, false)
        ShadowPowerManager.reset()
        shadowOf(app).grantPermissions(Manifest.permission.ACCESS_FINE_LOCATION,
            Manifest.permission.BLUETOOTH_SCAN, Manifest.permission.BLUETOOTH_CONNECT,
            Manifest.permission.BLUETOOTH_ADVERTISE)
        val adapter = (app.getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager).adapter
        shadowOf(adapter).setState(BluetoothAdapter.STATE_ON)
        shadowOf(app.getSystemService(Context.LOCATION_SERVICE) as LocationManager).setLocationEnabled(true)
    }
    @After fun cleanup() {
        RelayEngineHost.setEnabled(app, false)
        RelayService.instance?.onDestroy()
    }

    @Test fun disabledServiceDoesNotStartRadioOrAcquireWakeLock() {
        val controller = Robolectric.buildService(ServiceWithoutFlutter::class.java).create()
        val service = controller.get()
        assertEquals(Service.START_NOT_STICKY, service.onStartCommand(null, 0, 1))
        assertEquals(0, service.engineStarts)
        assertFalse(RelayService.running)
        controller.destroy()
    }

    @Test fun explicitOptInCreatesForegroundServiceAndRetainsItAfterTaskRemoval() {
        RelayEngineHost.setEnabled(app, true)
        val controller = Robolectric.buildService(ServiceWithoutFlutter::class.java).create()
        val service = controller.get()
        assertEquals(Service.START_STICKY, service.onStartCommand(Intent(), 0, 1))
        assertTrue(RelayService.running)
        assertEquals(1, service.engineStarts)
        assertNotNull(shadowOf(service).lastForegroundNotification)
        assertTrue(ShadowPowerManager.getLatestWakeLock().isHeld)
        service.onTaskRemoved(Intent())
        assertTrue(RelayService.running)
        controller.destroy()
        assertFalse(RelayService.running)
        assertFalse(ShadowPowerManager.getLatestWakeLock().isHeld)
    }

    @Test fun stickyProcessRestartRestoresOnlyPreviouslyEnabledRelay() {
        RelayEngineHost.setEnabled(app, true)
        val controller = Robolectric.buildService(ServiceWithoutFlutter::class.java).create()
        val service = controller.get()
        assertEquals(Service.START_STICKY, service.onStartCommand(null, 0, 1))
        assertEquals(1, service.engineStarts)
        controller.destroy()
        assertTrue(RelayEngineHost.enabled(app))
    }

    @Test fun notificationStopPersistsOptOutAndReleasesWakeLock() {
        RelayEngineHost.setEnabled(app, true)
        val controller = Robolectric.buildService(ServiceWithoutFlutter::class.java).create()
        val service = controller.get()
        service.onStartCommand(Intent(), 0, 1)
        assertEquals(Service.START_NOT_STICKY,
            service.onStartCommand(Intent().setAction(RelayService.STOP), 0, 2))
        assertFalse(RelayEngineHost.enabled(app))
        controller.destroy()
        assertFalse(ShadowPowerManager.getLatestWakeLock().isHeld)
        val restarted = Robolectric.buildService(ServiceWithoutFlutter::class.java).create()
        assertEquals(Service.START_NOT_STICKY, restarted.get().onStartCommand(null, 0, 1))
        assertEquals(0, restarted.get().engineStarts)
        restarted.destroy()
    }

    @Test fun bluetoothOffReleasesCpuLeaseAndOnBroadcastRestoresIt() {
        RelayEngineHost.setEnabled(app, true)
        val controller = Robolectric.buildService(ServiceWithoutFlutter::class.java).create()
        val service = controller.get()
        service.onStartCommand(Intent(), 0, 1)
        val adapter = (app.getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager).adapter
        shadowOf(adapter).setState(BluetoothAdapter.STATE_OFF)
        app.sendBroadcast(Intent(BluetoothAdapter.ACTION_STATE_CHANGED))
        shadowOf(android.os.Looper.getMainLooper()).idle()
        assertFalse(ShadowPowerManager.getLatestWakeLock().isHeld)
        shadowOf(adapter).setState(BluetoothAdapter.STATE_ON)
        app.sendBroadcast(Intent(BluetoothAdapter.ACTION_STATE_CHANGED))
        shadowOf(android.os.Looper.getMainLooper()).idle()
        assertTrue(ShadowPowerManager.getLatestWakeLock().isHeld)
        controller.destroy()
    }
}
