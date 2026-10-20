package com.macsecondmonitor.client.ui

import android.app.Activity
import android.os.Bundle
import com.macsecondmonitor.client.data.AppSettings
import com.macsecondmonitor.client.net.UsbTunnel
import com.macsecondmonitor.client.protocol.ProtocolInfo

/**
 * Started by the Mac over ADB (`am start -a …USB_CONNECT`) right after it set up the USB tunnel.
 * Brings an existing stream to the front, or starts one. Shows no UI of its own.
 */
class UsbConnectActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Only adb (the Mac) knows this secret; it proves to the Mac that the connection through
        // the tunnel comes from this app and not from another app on the device.
        intent.getStringExtra(EXTRA_SECRET)?.takeIf { it.length >= 32 }?.let { AppSettings(this).saveUsbSecret(it) }
        if (!StreamActivity.isActive) {
            startActivity(StreamActivity.intent(this, UsbTunnel.HOST, ProtocolInfo.NATIVE_PORT, null))
        }
        finish()
    }

    companion object {
        const val EXTRA_SECRET = "com.macsecondmonitor.client.extra.SECRET"
    }
}
