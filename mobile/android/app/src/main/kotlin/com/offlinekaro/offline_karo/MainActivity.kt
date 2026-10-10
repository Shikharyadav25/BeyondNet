package com.offlinekaro.offline_karo

import android.content.Context
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterFragmentActivity() {
    override fun provideFlutterEngine(context: Context): FlutterEngine = RelayEngineHost.get(context)
    override fun shouldDestroyEngineWithHost(): Boolean = false

    override fun onResume() {
        super.onResume()
        RelayEngineHost.activityVisible = true
        RelayEngineHost.changed(this)
    }

    override fun onPause() {
        RelayEngineHost.activityVisible = false
        super.onPause()
        // The service's Dart engine must keep scheduling relay work while the
        // Activity is paused/removed. No screen is kept awake or opened.
        if (RelayService.running) RelayEngineHost.resume()
    }

    override fun onStop() {
        super.onStop()
        if (RelayService.running) RelayEngineHost.resume()
    }

    override fun onDestroy() {
        super.onDestroy()
        if (RelayService.running) RelayEngineHost.resume()
    }
}
