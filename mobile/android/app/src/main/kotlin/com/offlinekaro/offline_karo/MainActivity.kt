package com.offlinekaro.offline_karo

import android.content.Context
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.os.Build
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterFragmentActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "beyondnet/network")
            .setMethodCallHandler { call, result ->
                if (call.method == "androidSdkVersion") {
                    result.success(Build.VERSION.SDK_INT)
                } else if (call.method == "hasInternet") {
                    val manager = getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
                    val capabilities = manager.getNetworkCapabilities(manager.activeNetwork)
                    result.success(capabilities?.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED) == true)
                } else result.notImplemented()
            }
    }
}
