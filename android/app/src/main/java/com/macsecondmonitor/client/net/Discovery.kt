package com.macsecondmonitor.client.net

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.os.Handler
import android.os.Looper
import android.util.Log
import com.macsecondmonitor.client.protocol.ProtocolInfo
import java.io.IOException
import java.net.Inet4Address
import java.net.InetSocketAddress
import java.net.Socket
import java.net.SocketTimeoutException

data class DiscoveredHost(val name: String, val address: String, val port: Int)

/**
 * Finds Macs advertising `_macsecondmon._tcp` on the local network. Results are delivered on
 * the main thread.
 */
class HostDiscovery(context: Context, private val onChange: (List<DiscoveredHost>) -> Unit) {
    private val nsd = context.getSystemService(NsdManager::class.java)
    private val main = Handler(Looper.getMainLooper())
    private val hosts = linkedMapOf<String, DiscoveredHost>()
    private val pending = ArrayDeque<NsdServiceInfo>()
    private var resolving = false
    private var listener: NsdManager.DiscoveryListener? = null

    fun start() {
        if (listener != null || nsd == null) return
        val discovery = object : NsdManager.DiscoveryListener {
            override fun onDiscoveryStarted(serviceType: String) = Unit
            override fun onDiscoveryStopped(serviceType: String) = Unit
            override fun onStartDiscoveryFailed(serviceType: String, errorCode: Int) {
                Log.w(TAG, "Discovery failed: $errorCode")
            }
            override fun onStopDiscoveryFailed(serviceType: String, errorCode: Int) = Unit

            override fun onServiceFound(service: NsdServiceInfo) {
                main.post {
                    pending.addLast(service)
                    resolveNext()
                }
            }

            override fun onServiceLost(service: NsdServiceInfo) {
                main.post {
                    if (hosts.remove(service.serviceName) != null) publish()
                }
            }
        }
        listener = discovery
        nsd.discoverServices(ProtocolInfo.SERVICE_TYPE, NsdManager.PROTOCOL_DNS_SD, discovery)
    }

    fun stop() {
        listener?.let { runCatching { nsd?.stopServiceDiscovery(it) } }
        listener = null
        pending.clear()
        resolving = false
    }

    // The legacy resolve API handles one request at a time on every Android version we support.
    @Suppress("DEPRECATION")
    private fun resolveNext() {
        if (resolving || nsd == null) return
        val service = pending.removeFirstOrNull() ?: return
        resolving = true
        nsd.resolveService(service, object : NsdManager.ResolveListener {
            override fun onResolveFailed(serviceInfo: NsdServiceInfo, errorCode: Int) {
                main.post {
                    resolving = false
                    resolveNext()
                }
            }

            override fun onServiceResolved(serviceInfo: NsdServiceInfo) {
                main.post {
                    resolving = false
                    val address = serviceInfo.host
                    // Prefer IPv4: easier to show and works through every router.
                    if (address != null && (address is Inet4Address || !hosts.containsKey(serviceInfo.serviceName))) {
                        hosts[serviceInfo.serviceName] = DiscoveredHost(serviceInfo.serviceName, address.hostAddress ?: "", serviceInfo.port)
                        publish()
                    }
                    resolveNext()
                }
            }
        })
    }

    private fun publish() = onChange(hosts.values.toList())

    companion object {
        private const val TAG = "HostDiscovery"
    }
}

/**
 * Detects the USB tunnel. With `adb reverse` active, 127.0.0.1:7100 on the device always
 * accepts connections (adbd listens), but ADB drops them at once if nothing listens on the Mac.
 * A connection that stays open means the host app is running. Call off the main thread.
 */
object UsbTunnel {
    const val HOST = "127.0.0.1"

    fun isHostReachable(port: Int = ProtocolInfo.NATIVE_PORT): Boolean {
        return try {
            Socket().use { socket ->
                socket.connect(InetSocketAddress(HOST, port), 300)
                socket.soTimeout = 400
                try {
                    socket.getInputStream().read() != -1
                } catch (_: SocketTimeoutException) {
                    // Still open and silent: the host is waiting for our HELLO.
                    true
                }
            }
        } catch (_: IOException) {
            false
        }
    }
}
