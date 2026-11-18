package com.offlinekaro.offline_karo

import android.app.KeyguardManager
import android.app.Activity
import android.os.Bundle
import io.flutter.plugin.common.MethodChannel
import android.content.Context
import android.content.Intent
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterFragmentActivity() {
    private var credentialResult: MethodChannel.Result? = null
    private lateinit var paymentAuth: MethodChannel
    private val credentialRequest = 9261

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        paymentAuth = MethodChannel(RelayEngineHost.get(this).dartExecutor.binaryMessenger, "beyondnet/payment_auth")
        paymentAuth.setMethodCallHandler { call, result ->
            if (call.method != "confirmDeviceCredential") {
                result.notImplemented()
            } else if (credentialResult != null) {
                result.error("authInProgress", "Phone confirmation is already open", null)
            } else {
                val keyguard = getSystemService(Context.KEYGUARD_SERVICE) as KeyguardManager
                if (!keyguard.isDeviceSecure) {
                    result.error("noScreenLock", "Set a phone PIN, pattern or password first", null)
                } else {
                    @Suppress("DEPRECATION")
                    val confirm = keyguard.createConfirmDeviceCredentialIntent(
                        "Confirm BeyondNet payment", call.argument<String>("reason") ?: "Authorize your payment")
                    if (confirm == null) {
                        result.error("credentialUnavailable", "Android could not open phone confirmation", null)
                    } else {
                        credentialResult = result
                        try {
                            @Suppress("DEPRECATION")
                            startActivityForResult(confirm, credentialRequest)
                        } catch (_: Exception) {
                            credentialResult = null
                            result.error("credentialUnavailable", "Android could not open phone confirmation", null)
                        }
                    }
                }
            }
        }
    }

    @Deprecated("Android credential result compatibility")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == credentialRequest) {
            val pending = credentialResult
            credentialResult = null
            pending?.success(resultCode == Activity.RESULT_OK)
        }
    }

    override fun provideFlutterEngine(context: Context): FlutterEngine = RelayEngineHost.get(context)
    override fun shouldDestroyEngineWithHost(): Boolean = false

    override fun onResume() {
        super.onResume()
        RelayEngineHost.openNotification(intent)
        RelayEngineHost.activityVisible = true
        RelayEngineHost.changed(this)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        RelayEngineHost.openNotification(intent)
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
        credentialResult?.error("authInterrupted", "Phone confirmation was interrupted", null)
        credentialResult = null
        if (::paymentAuth.isInitialized) paymentAuth.setMethodCallHandler(null)
        super.onDestroy()
        if (RelayService.running) RelayEngineHost.resume()
    }
}
