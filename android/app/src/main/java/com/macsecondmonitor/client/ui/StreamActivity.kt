package com.macsecondmonitor.client.ui

import android.annotation.SuppressLint
import android.content.Context
import android.content.Intent
import android.content.pm.ActivityInfo
import android.net.wifi.WifiManager
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.util.DisplayMetrics
import android.view.HapticFeedbackConstants
import android.view.KeyEvent
import android.view.LayoutInflater
import android.view.MotionEvent
import android.view.PointerIcon
import android.view.SurfaceHolder
import android.view.SurfaceView
import android.view.View
import android.view.ViewConfiguration
import android.widget.Button
import android.widget.FrameLayout
import android.widget.PopupMenu
import android.widget.TextView
import androidx.activity.OnBackPressedCallback
import androidx.appcompat.app.AlertDialog
import androidx.appcompat.app.AppCompatActivity
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsControllerCompat
import com.google.android.material.dialog.MaterialAlertDialogBuilder
import com.google.android.material.textfield.TextInputEditText
import com.google.android.material.textfield.TextInputLayout
import com.macsecondmonitor.client.BuildConfig
import com.macsecondmonitor.client.R
import com.macsecondmonitor.client.data.AppSettings
import com.macsecondmonitor.client.input.HardwareKeyboard
import com.macsecondmonitor.client.input.SoftKeyboardView
import com.macsecondmonitor.client.input.TouchInputHandler
import com.macsecondmonitor.client.net.CloseReason
import com.macsecondmonitor.client.net.HostConnection
import com.macsecondmonitor.client.net.UsbTunnel
import com.macsecondmonitor.client.protocol.DisplayInfo
import com.macsecondmonitor.client.protocol.Hello
import com.macsecondmonitor.client.protocol.HostError
import com.macsecondmonitor.client.protocol.InputEvent
import com.macsecondmonitor.client.protocol.PairRequest
import com.macsecondmonitor.client.protocol.StreamConfig
import com.macsecondmonitor.client.protocol.VideoFrame
import com.macsecondmonitor.client.protocol.Welcome
import com.macsecondmonitor.client.video.VideoDecoder
import java.util.Locale

/** Full-screen display: decodes the host's stream and sends touch / keyboard input back. */
class StreamActivity : AppCompatActivity(), VideoDecoder.Listener, SurfaceHolder.Callback {
    private lateinit var settings: AppSettings
    private lateinit var host: String
    private var port = 0
    private var hostName: String? = null
    private val isUsb get() = host == UsbTunnel.HOST

    private val main = Handler(Looper.getMainLooper())
    private var connection: HostConnection? = null
    /** Callbacks from a replaced connection are ignored. */
    private var connectionGeneration = 0
    private val decoder = VideoDecoder(this)
    private lateinit var touch: TouchInputHandler
    private lateinit var keyboard: HardwareKeyboard
    private lateinit var softKeyboard: SoftKeyboardView
    private var wifiLock: WifiManager.WifiLock? = null
    private var pairingDialog: AlertDialog? = null

    private lateinit var surface: SurfaceView
    private lateinit var stats: TextView
    private lateinit var menuHandle: View
    private lateinit var statusOverlay: View
    private lateinit var statusTitle: TextView
    private lateinit var statusDetail: TextView
    private lateinit var statusProgress: View
    private lateinit var statusButtons: View

    private var streaming = false
    private var reconnectAttempts = 0
    private var leaving = false
    private var backgroundedAt = 0L

    // Render-side latency, read by the STATS timer and the overlay.
    private val latencyLock = Any()
    private var latencySumMicros = 0L
    private var latencyCount = 0
    @Volatile private var lastLatencyMs: Double? = null
    @Volatile private var firstFrameShown = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        isActive = true
        setContentView(R.layout.activity_stream)
        settings = AppSettings(this)
        host = intent.getStringExtra(EXTRA_HOST) ?: UsbTunnel.HOST
        port = intent.getIntExtra(EXTRA_PORT, 0)
        hostName = intent.getStringExtra(EXTRA_NAME)

        // The virtual display is created at this orientation; keep it while streaming.
        requestedOrientation = ActivityInfo.SCREEN_ORIENTATION_LOCKED
        enterImmersive()
        preferHighestRefreshRate()

        surface = findViewById(R.id.surface)
        stats = findViewById(R.id.stats)
        menuHandle = findViewById(R.id.menuHandle)
        statusOverlay = findViewById(R.id.statusOverlay)
        statusTitle = findViewById(R.id.statusTitle)
        statusDetail = findViewById(R.id.statusDetail)
        statusProgress = findViewById(R.id.statusProgress)
        statusButtons = findViewById(R.id.statusButtons)
        findViewById<Button>(R.id.statusBack).setOnClickListener { leave() }
        findViewById<Button>(R.id.statusRetry).setOnClickListener { connect() }

        touch = TouchInputHandler(
            sink = ::sendInput,
            slopPx = ViewConfiguration.get(this).scaledTouchSlop.toFloat(),
            onMenuRequested = ::showMenu,
            onLongPress = { surface.performHapticFeedback(HapticFeedbackConstants.LONG_PRESS) },
        )
        keyboard = HardwareKeyboard(::sendInput)
        softKeyboard = SoftKeyboardView(this, ::sendInput)
        findViewById<FrameLayout>(R.id.root).addView(softKeyboard, FrameLayout.LayoutParams(1, 1))

        setUpSurface()
        menuHandle.setOnClickListener { showMenu() }

        onBackPressedDispatcher.addCallback(this, object : OnBackPressedCallback(true) {
            override fun handleOnBackPressed() = confirmLeave()
        })

        connect()
    }

    @SuppressLint("ClickableViewAccessibility")
    private fun setUpSurface() {
        surface.holder.addCallback(this)
        surface.setOnTouchListener { _, event -> streaming && touch.onTouchEvent(event) }
        surface.setOnGenericMotionListener { _, event -> streaming && touch.onGenericMotionEvent(event) }
        // The Mac draws its own cursor into the stream.
        surface.pointerIcon = PointerIcon.getSystemIcon(this, PointerIcon.TYPE_NULL)
    }

    override fun onStart() {
        super.onStart()
        backgroundedAt = 0
        main.removeCallbacks(backgroundTimeout)
        applyPreferences()
    }

    override fun onStop() {
        super.onStop()
        // Keep the Mac's display while briefly switching apps; give up after a while.
        backgroundedAt = System.currentTimeMillis()
        main.postDelayed(backgroundTimeout, BACKGROUND_TIMEOUT_MS)
    }

    override fun onDestroy() {
        super.onDestroy()
        isActive = false
        main.removeCallbacksAndMessages(null)
        leaving = true
        connection?.close()
        connection = null
        decoder.release()
        releaseWifiLock()
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (hasFocus) enterImmersive()
    }

    private val backgroundTimeout = Runnable {
        if (backgroundedAt != 0L) leave()
    }

    private fun applyPreferences() {
        touch.oneFingerScroll = settings.oneFingerScroll
        keyboard.swapControlCommand = settings.swapControlCommand
        menuHandle.visibility = if (settings.showMenuButton) View.VISIBLE else View.GONE
        stats.visibility = if (settings.showStats) View.VISIBLE else View.GONE
        main.removeCallbacks(statsUpdater)
        if (settings.showStats) main.post(statsUpdater)
    }

    // MARK: Connection

    private fun connect() {
        connection?.close()
        streaming = false
        firstFrameShown = false
        showStatus(getString(R.string.stream_connecting, hostName ?: if (isUsb) getString(R.string.stream_mac) else host), progress = true)

        val hello = Hello(
            deviceId = settings.deviceId,
            deviceName = deviceName(),
            appVersion = BuildConfig.VERSION_NAME,
            display = displayInfo(),
            codecs = VideoDecoder.supportedCodecs(),
            locale = Locale.getDefault().toLanguageTag(),
            // Over USB this is the secret the Mac passed when it launched us (or a pairing token).
            token = settings.token(hostName, host),
        )
        val generation = ++connectionGeneration
        val connection = HostConnection(host, port, hello, Callbacks(generation))
        connection.statsProvider = {
            val (decodeMs, dropped) = decoder.takeStats()
            val latency = synchronized(latencyLock) {
                val value = if (latencyCount > 0) latencySumMicros / 1000.0 / latencyCount else null
                latencySumMicros = 0
                latencyCount = 0
                value
            }
            Triple(decodeMs, latency, dropped)
        }
        this.connection = connection
        if (!isUsb) acquireWifiLock()
        connection.start()
    }

    /** Forwards callbacks of one connection; stale connections are ignored. */
    private inner class Callbacks(private val generation: Int) : HostConnection.Listener {
        private val current get() = generation == connectionGeneration

        override fun onWelcome(welcome: Welcome) = runOnUiThread { if (current) handleWelcome(welcome) }

        override fun onPairRequest(request: PairRequest) = runOnUiThread { if (current) showPairing(request) }

        override fun onConfig(config: StreamConfig) {
            if (current) decoder.configure(config)
        }

        override fun onFrame(frame: VideoFrame) {
            if (current) decoder.submit(frame)
        }

        override fun onClosed(reason: CloseReason) = runOnUiThread { if (current) handleClosed(reason) }
    }

    private fun handleWelcome(welcome: Welcome) {
        reconnectAttempts = 0
        hostName = welcome.hostName
        welcome.token?.let { settings.saveToken(welcome.hostName, host, it) }
        if (!isUsb) settings.rememberHost(welcome.hostName, host, port)
        pairingDialog?.dismiss()
        streaming = true
        showStatus(getString(R.string.stream_starting), progress = true)
    }

    private fun handleClosed(reason: CloseReason) {
        streaming = false
        pairingDialog?.dismiss()
        if (leaving) return
        when (reason) {
            CloseReason.User -> Unit
            // A display that worked before (e.g. lost while the Mac slept) is worth retrying.
            is CloseReason.Host -> if (reason.error.code == "display_unavailable" && firstFrameShown) {
                scheduleReconnect()
            } else {
                showError(errorMessage(reason.error))
            }
            is CloseReason.Bye -> when (reason.reason) {
                "replaced" -> showError(getString(R.string.error_replaced))
                "user" -> leave()
                else -> scheduleReconnect()
            }
            is CloseReason.Network -> if (reconnectAttempts == 0 && !firstFrameShown) {
                // Never connected: report instead of retrying silently.
                showError(getString(R.string.error_network, reason.message))
            } else {
                scheduleReconnect()
            }
        }
    }

    private fun scheduleReconnect() {
        if (reconnectAttempts >= MAX_RECONNECT_ATTEMPTS) {
            showError(getString(R.string.stream_disconnected))
            return
        }
        reconnectAttempts++
        showStatus(getString(R.string.stream_reconnecting), progress = true)
        main.postDelayed({ if (!leaving) connect() }, minOf(500L * reconnectAttempts, 3000L))
    }

    override fun onKeyframeNeeded() {
        connection?.requestKeyframe()
    }

    override fun onFrameRendered(captureTimeMicros: Long) {
        connection?.latencyMicros(captureTimeMicros)?.let { latency ->
            synchronized(latencyLock) {
                latencySumMicros += latency
                latencyCount++
            }
            lastLatencyMs = latency / 1000.0
        }
        if (!firstFrameShown) {
            firstFrameShown = true
            runOnUiThread { hideStatus() }
        }
    }

    private fun sendInput(event: InputEvent) {
        if (streaming) connection?.send(event)
    }

    // MARK: Surface

    override fun surfaceCreated(holder: SurfaceHolder) = Unit

    override fun surfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) {
        touch.setSize(width, height)
        decoder.setSurface(holder.surface)
    }

    override fun surfaceDestroyed(holder: SurfaceHolder) {
        decoder.setSurface(null)
    }

    // MARK: Keyboard

    override fun dispatchKeyEvent(event: KeyEvent): Boolean {
        // Soft keyboard input arrives through SoftKeyboardView's InputConnection instead.
        val fromHardware = event.device?.isVirtual == false
        if (streaming && fromHardware && keyboard.handle(event)) return true
        return super.dispatchKeyEvent(event)
    }

    override fun dispatchGenericMotionEvent(event: MotionEvent): Boolean {
        if (streaming && touch.onGenericMotionEvent(event)) return true
        return super.dispatchGenericMotionEvent(event)
    }

    // MARK: UI

    private fun showMenu() {
        val popup = PopupMenu(this, menuHandle)
        popup.menu.add(0, MENU_KEYBOARD, 0, R.string.stream_menu_keyboard)
        popup.menu.add(0, MENU_STATS, 1, R.string.stream_menu_stats).apply {
            isCheckable = true
            isChecked = settings.showStats
        }
        popup.menu.add(0, MENU_DISCONNECT, 2, R.string.stream_menu_disconnect)
        popup.setOnMenuItemClickListener { item ->
            when (item.itemId) {
                MENU_KEYBOARD -> if (softKeyboard.isShowing) softKeyboard.hide() else softKeyboard.show()
                MENU_STATS -> {
                    settings.setShowStats(!settings.showStats)
                    applyPreferences()
                }
                MENU_DISCONNECT -> leave()
            }
            true
        }
        popup.show()
    }

    private fun showPairing(request: PairRequest) {
        pairingDialog?.dismiss()
        val view = LayoutInflater.from(this).inflate(R.layout.dialog_pairing, null) as TextInputLayout
        val input = view.findViewById<TextInputEditText>(R.id.pairingCode)
        if (request.retry) view.error = resources.getQuantityString(R.plurals.pairing_retry, request.attemptsLeft, request.attemptsLeft)
        showStatus(getString(R.string.stream_connecting, hostName ?: host), progress = true)
        pairingDialog = MaterialAlertDialogBuilder(this)
            .setTitle(getString(R.string.pairing_title, hostName ?: host))
            .setMessage(R.string.pairing_message)
            .setView(view)
            .setCancelable(false)
            .setPositiveButton(R.string.pairing_button) { _, _ ->
                connection?.sendPairingCode(input.text?.toString().orEmpty())
            }
            .setNegativeButton(R.string.pairing_cancel) { _, _ -> leave() }
            .show()
        input.requestFocus()
    }

    private fun showStatus(title: String, progress: Boolean, detail: String? = null, buttons: Boolean = false) {
        statusOverlay.visibility = View.VISIBLE
        statusTitle.text = title
        statusDetail.text = detail
        statusDetail.visibility = if (detail == null) View.GONE else View.VISIBLE
        statusProgress.visibility = if (progress) View.VISIBLE else View.GONE
        statusButtons.visibility = if (buttons) View.VISIBLE else View.GONE
    }

    private fun hideStatus() {
        statusOverlay.visibility = View.GONE
    }

    private fun showError(message: String) {
        releaseWifiLock()
        showStatus(getString(R.string.stream_disconnected), progress = false, detail = message, buttons = true)
    }

    private fun errorMessage(error: HostError): String = when (error.code) {
        "permission_missing" -> getString(R.string.error_permission_missing)
        "pairing_failed" -> getString(R.string.error_pairing_failed)
        "pairing_timeout" -> getString(R.string.error_pairing_timeout)
        "unsupported_protocol" -> getString(R.string.error_unsupported_protocol)
        "display_unavailable" -> getString(R.string.error_display_unavailable)
        "rejected" -> getString(R.string.error_rejected)
        else -> getString(R.string.error_generic, error.message)
    }

    private val statsUpdater = object : Runnable {
        override fun run() {
            val connection = connection
            if (connection != null) {
                val unknown = getString(R.string.stream_stats_unknown)
                val latency = lastLatencyMs?.let { getString(R.string.stream_stats_latency, it) } ?: unknown
                val rtt = connection.rttMicros?.let { String.format(Locale.US, "%.1f ms", it / 1000.0) } ?: unknown
                val link = getString(if (isUsb) R.string.stream_usb else R.string.stream_wifi)
                val line = getString(R.string.stream_stats, connection.lastFps, latency, rtt, connection.lastBitrateKbps / 1000, link)
                stats.text = decoder.decoderName?.let { getString(R.string.stream_stats_decoder, line, it) } ?: line
            }
            main.postDelayed(this, 1000)
        }
    }

    private fun confirmLeave() {
        if (!streaming) {
            leave()
            return
        }
        MaterialAlertDialogBuilder(this)
            .setTitle(R.string.stream_exit_title)
            .setMessage(R.string.stream_exit_message)
            .setPositiveButton(R.string.stream_menu_disconnect) { _, _ -> leave() }
            .setNegativeButton(R.string.pairing_cancel, null)
            .show()
    }

    private fun leave() {
        leaving = true
        connection?.close()
        connection = null
        finish()
    }

    private fun enterImmersive() {
        WindowCompat.setDecorFitsSystemWindows(window, false)
        WindowInsetsControllerCompat(window, window.decorView).apply {
            hide(WindowInsetsCompat.Type.systemBars())
            systemBarsBehavior = WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
        }
    }

    /** 120 Hz panels show each frame up to 8 ms sooner than at 60 Hz. */
    private fun preferHighestRefreshRate() {
        @Suppress("DEPRECATION")
        val display = windowManager.defaultDisplay ?: return
        val current = display.mode
        val best = display.supportedModes
            .filter { it.physicalWidth == current.physicalWidth && it.physicalHeight == current.physicalHeight }
            .maxByOrNull { it.refreshRate } ?: return
        window.attributes = window.attributes.apply { preferredDisplayModeId = best.modeId }
    }

    private fun displayInfo(): DisplayInfo {
        val metrics = DisplayMetrics()
        @Suppress("DEPRECATION")
        val display = windowManager.defaultDisplay
        @Suppress("DEPRECATION")
        display.getRealMetrics(metrics)
        val width = metrics.widthPixels and 1.inv()
        val height = metrics.heightPixels and 1.inv()
        // Some devices report bogus xdpi; fall back to the density bucket.
        val dpi = metrics.xdpi.toDouble().takeIf { it in 100.0..800.0 } ?: metrics.densityDpi.toDouble()
        val refresh = display.supportedModes.maxOfOrNull { it.refreshRate }?.toDouble() ?: display.refreshRate.toDouble()
        return DisplayInfo(width, height, dpi, refresh)
    }

    private fun deviceName(): String {
        val userName = Settings.Global.getString(contentResolver, Settings.Global.DEVICE_NAME)
        if (!userName.isNullOrBlank()) return userName
        val manufacturer = Build.MANUFACTURER.replaceFirstChar { it.titlecase(Locale.ROOT) }
        return if (Build.MODEL.startsWith(Build.MANUFACTURER, ignoreCase = true)) Build.MODEL else "$manufacturer ${Build.MODEL}"
    }

    private fun acquireWifiLock() {
        if (wifiLock != null) return
        val manager = applicationContext.getSystemService(Context.WIFI_SERVICE) as? WifiManager ?: return
        // Low-latency mode keeps Wi-Fi out of power save, which otherwise adds tens of ms.
        val mode = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) WifiManager.WIFI_MODE_FULL_LOW_LATENCY else @Suppress("DEPRECATION") WifiManager.WIFI_MODE_FULL_HIGH_PERF
        wifiLock = manager.createWifiLock(mode, "MacSecondMonitor:stream").apply {
            setReferenceCounted(false)
            acquire()
        }
    }

    private fun releaseWifiLock() {
        wifiLock?.takeIf { it.isHeld }?.release()
        wifiLock = null
    }

    companion object {
        private const val EXTRA_HOST = "host"
        private const val EXTRA_PORT = "port"
        private const val EXTRA_NAME = "name"
        private const val MAX_RECONNECT_ATTEMPTS = 30
        private const val BACKGROUND_TIMEOUT_MS = 5 * 60 * 1000L
        private const val MENU_KEYBOARD = 1
        private const val MENU_STATS = 2
        private const val MENU_DISCONNECT = 3

        @Volatile var isActive = false
            private set

        fun intent(context: Context, host: String, port: Int, name: String?): Intent =
            Intent(context, StreamActivity::class.java)
                .putExtra(EXTRA_HOST, host)
                .putExtra(EXTRA_PORT, port)
                .putExtra(EXTRA_NAME, name)
    }
}
