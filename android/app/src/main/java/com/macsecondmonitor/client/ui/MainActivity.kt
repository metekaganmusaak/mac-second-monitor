package com.macsecondmonitor.client.ui

import android.content.Intent
import android.os.Bundle
import android.view.LayoutInflater
import android.view.View
import android.view.inputmethod.EditorInfo
import android.widget.Button
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.TextView
import androidx.appcompat.app.AppCompatActivity
import androidx.core.content.ContextCompat
import androidx.core.view.ViewCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.isVisible
import androidx.core.view.updatePadding
import com.google.android.material.textfield.TextInputEditText
import com.google.android.material.textfield.TextInputLayout
import com.macsecondmonitor.client.R
import com.macsecondmonitor.client.data.AppSettings
import com.macsecondmonitor.client.net.DiscoveredHost
import com.macsecondmonitor.client.net.HostDiscovery
import com.macsecondmonitor.client.net.UsbTunnel
import com.macsecondmonitor.client.protocol.ProtocolInfo
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledExecutorService
import java.util.concurrent.TimeUnit

/** Connect screen: USB tunnel status, Macs found on the network, recent and manual hosts. */
class MainActivity : AppCompatActivity() {
    private lateinit var settings: AppSettings
    private lateinit var discovery: HostDiscovery
    private var probe: ScheduledExecutorService? = null
    private var usbReachable = false

    /** Set when the user leaves a USB stream, so we don't reconnect until the cable is replugged. */
    private var suppressUsbAutoConnect = false

    private lateinit var usbStatus: TextView
    private lateinit var usbIcon: ImageView
    private lateinit var usbConnect: Button
    private lateinit var networkList: LinearLayout
    private lateinit var networkEmpty: TextView
    private lateinit var recentList: LinearLayout
    private lateinit var recentTitle: TextView

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_main)
        settings = AppSettings(this)

        val root = findViewById<View>(R.id.root)
        ViewCompat.setOnApplyWindowInsetsListener(root) { view, insets ->
            val bars = insets.getInsets(WindowInsetsCompat.Type.systemBars())
            view.updatePadding(top = bars.top, bottom = bars.bottom)
            insets
        }

        usbStatus = findViewById(R.id.usbStatus)
        usbIcon = findViewById(R.id.usbIcon)
        usbConnect = findViewById(R.id.usbConnect)
        networkList = findViewById(R.id.networkList)
        networkEmpty = findViewById(R.id.networkEmpty)
        recentList = findViewById(R.id.recentList)
        recentTitle = findViewById(R.id.recentTitle)

        findViewById<View>(R.id.settingsButton).setOnClickListener {
            startActivity(Intent(this, SettingsActivity::class.java))
        }
        usbConnect.setOnClickListener { startUsbStream() }
        val help = findViewById<View>(R.id.usbHelp)
        findViewById<View>(R.id.usbHelpToggle).setOnClickListener {
            help.isVisible = !help.isVisible
        }

        val manualLayout = findViewById<TextInputLayout>(R.id.manualLayout)
        val manualAddress = findViewById<TextInputEditText>(R.id.manualAddress)
        val connectManual = {
            val parsed = parseAddress(manualAddress.text?.toString().orEmpty())
            if (parsed == null) {
                manualLayout.error = getString(R.string.connect_manual_invalid)
            } else {
                manualLayout.error = null
                startStream(parsed.first, parsed.second, null)
            }
        }
        findViewById<View>(R.id.manualConnect).setOnClickListener { connectManual() }
        manualAddress.setOnEditorActionListener { _, actionId, _ ->
            if (actionId == EditorInfo.IME_ACTION_GO) {
                connectManual()
                true
            } else {
                false
            }
        }

        discovery = HostDiscovery(this, ::showDiscovered)
    }

    override fun onResume() {
        super.onResume()
        showRecent()
        discovery.start()
        val probe = Executors.newSingleThreadScheduledExecutor()
        probe.scheduleWithFixedDelay({
            val reachable = UsbTunnel.isHostReachable()
            runOnUiThread { updateUsb(reachable) }
        }, 0, 2, TimeUnit.SECONDS)
        this.probe = probe
    }

    override fun onPause() {
        super.onPause()
        discovery.stop()
        probe?.shutdownNow()
        probe = null
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == REQUEST_USB_STREAM) suppressUsbAutoConnect = true
    }

    private fun updateUsb(reachable: Boolean) {
        if (isFinishing) return
        usbReachable = reachable
        usbConnect.isEnabled = reachable
        usbStatus.setText(if (reachable) R.string.connect_usb_ready else R.string.connect_usb_absent)
        usbIcon.setColorFilter(ContextCompat.getColor(this, if (reachable) R.color.status_ok else R.color.status_idle))
        if (!reachable) {
            suppressUsbAutoConnect = false
        } else if (settings.autoConnectUsb && !suppressUsbAutoConnect && !StreamActivity.isActive) {
            startUsbStream()
        }
    }

    private fun startUsbStream() {
        @Suppress("DEPRECATION")
        startActivityForResult(StreamActivity.intent(this, UsbTunnel.HOST, ProtocolInfo.NATIVE_PORT, null), REQUEST_USB_STREAM)
    }

    private fun startStream(address: String, port: Int, name: String?) {
        startActivity(StreamActivity.intent(this, address, port, name))
    }

    private fun showDiscovered(hosts: List<DiscoveredHost>) {
        networkList.removeAllViews()
        networkEmpty.isVisible = hosts.isEmpty()
        for (host in hosts) {
            networkList.addView(hostRow(host.name, host.address, host.port) { startStream(host.address, host.port, host.name) })
        }
    }

    private fun showRecent() {
        recentList.removeAllViews()
        val recent = settings.recentHosts.filter { it.address != UsbTunnel.HOST }
        recentTitle.isVisible = recent.isNotEmpty()
        for (host in recent) {
            recentList.addView(hostRow(host.name, host.address, host.port) { startStream(host.address, host.port, host.name) })
        }
    }

    private fun hostRow(name: String, address: String, port: Int, onClick: () -> Unit): View {
        val row = LayoutInflater.from(this).inflate(R.layout.item_host, networkList, false)
        row.findViewById<TextView>(R.id.hostName).text = name.ifEmpty { address }
        row.findViewById<TextView>(R.id.hostDetail).text = getString(R.string.connect_host_detail, address, port)
        row.setOnClickListener { onClick() }
        return row
    }

    companion object {
        private const val REQUEST_USB_STREAM = 1

        /** Accepts `host`, `host:port` and `[ipv6]:port`. */
        fun parseAddress(input: String): Pair<String, Int>? {
            val text = input.trim()
            if (text.isEmpty() || text.contains(' ')) return null
            if (text.startsWith("[")) {
                val end = text.indexOf(']')
                if (end < 0) return null
                val port = text.substring(end + 1).removePrefix(":").toIntOrNull() ?: ProtocolInfo.NATIVE_PORT
                return text.substring(1, end) to port
            }
            val parts = text.split(':')
            return when (parts.size) {
                1 -> text to ProtocolInfo.NATIVE_PORT
                2 -> parts[1].toIntOrNull()?.takeIf { it in 1..65535 }?.let { parts[0] to it }
                // A bare IPv6 address.
                else -> text to ProtocolInfo.NATIVE_PORT
            }
        }
    }
}
