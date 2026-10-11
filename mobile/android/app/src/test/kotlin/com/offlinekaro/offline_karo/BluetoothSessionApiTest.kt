package com.offlinekaro.offline_karo

import dev.zeekr.bluetooth_low_energy_android.PeripheralManagerHostApi
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.StandardMessageCodec
import java.lang.reflect.Proxy
import java.nio.ByteBuffer
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

/** Real plugin-generated Android host bindings, standard-codec void requests.
 * GATT hardware is replaced; this validates the lifecycle adapter's wire/API
 * contract against the pinned dependency instead of assuming channel names. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [29, 34], manifest = Config.NONE)
class BluetoothSessionApiTest {
    class Messenger : BinaryMessenger {
        val handlers = mutableMapOf<String, BinaryMessenger.BinaryMessageHandler>()
        override fun setMessageHandler(channel: String, handler: BinaryMessenger.BinaryMessageHandler?) {
            if (handler == null) handlers.remove(channel) else handlers[channel] = handler
        }
        override fun send(channel: String, message: ByteBuffer?) { }
        override fun send(channel: String, message: ByteBuffer?, reply: BinaryMessenger.BinaryReply?) { }
        fun call(method: String): List<*> {
            val key = "dev.flutter.pigeon.bluetooth_low_energy_android.PeripheralManagerHostApi.$method"
            val handler = handlers[key] ?: throw AssertionError("Missing $key")
            val request = StandardMessageCodec.INSTANCE.encodeMessage(null)
            request?.flip()
            var response: ByteBuffer? = null
            handler.onMessage(request) { bytes -> response = bytes }
            val bytes = response ?: throw AssertionError("No GATT reply")
            bytes.flip()
            return StandardMessageCodec.INSTANCE.decodeMessage(bytes) as List<*>
        }
    }

    private fun bind(messenger: Messenger, call: (String) -> Unit) {
        val host = Proxy.newProxyInstance(PeripheralManagerHostApi::class.java.classLoader,
            arrayOf(PeripheralManagerHostApi::class.java)) { _, method, _ ->
            call(method.name); null
        } as PeripheralManagerHostApi
        PeripheralManagerHostApi.setUp(messenger, host)
    }

    @Test fun lifecycleChannelsAcceptStandardCodecAndReturnVoidSuccess() {
        val messenger = Messenger()
        val calls = mutableListOf<String>()
        bind(messenger) { calls.add(it) }
        assertEquals(listOf<Any?>(null), messenger.call("closeGATTServer"))
        assertEquals(listOf<Any?>(null), messenger.call("openGATTServer"))
        assertEquals(listOf("closeGATTServer", "openGATTServer"), calls)
    }

    @Test fun nativeLifecycleFailuresReturnAnErrorReplyRatherThanSuccess() {
        val messenger = Messenger()
        bind(messenger) { throw IllegalStateException("GATT not ready") }
        val reply = messenger.call("openGATTServer")
        assertEquals(3, reply.size)
        assertEquals("IllegalStateException", reply[0])
        assertTrue(reply[1].toString().contains("GATT not ready"))
    }
}
