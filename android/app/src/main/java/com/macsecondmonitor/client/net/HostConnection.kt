package com.macsecondmonitor.client.net

import android.util.Log
import com.macsecondmonitor.client.protocol.Hello
import com.macsecondmonitor.client.protocol.HostError
import com.macsecondmonitor.client.protocol.InputEvent
import com.macsecondmonitor.client.protocol.Message
import com.macsecondmonitor.client.protocol.MessageType
import com.macsecondmonitor.client.protocol.Messages
import com.macsecondmonitor.client.protocol.PairRequest
import com.macsecondmonitor.client.protocol.StreamConfig
import com.macsecondmonitor.client.protocol.VideoFrame
import com.macsecondmonitor.client.protocol.Welcome
import java.io.BufferedInputStream
import java.io.BufferedOutputStream
import java.io.DataInputStream
import java.io.IOException
import java.net.InetSocketAddress
import java.net.Socket
import java.util.concurrent.Executors
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.ScheduledExecutorService
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

/** Monotonic client clock in µs. Only differences and the PING/PONG offset are used. */
fun nowMicros(): Long = System.nanoTime() / 1_000

sealed class CloseReason {
    data class Host(val error: HostError) : CloseReason()
    data class Bye(val reason: String) : CloseReason()
    data class Network(val message: String) : CloseReason()
    data object User : CloseReason()
}

/**
 * One TCP connection to the host (Wi-Fi or the `adb reverse` USB tunnel on 127.0.0.1).
 * A reader thread parses messages; a writer thread sends them so callers never block on
 * the socket (and the UI thread never touches the network).
 */
class HostConnection(
    private val host: String,
    private val port: Int,
    private val hello: Hello,
    private val listener: Listener,
) {
    interface Listener {
        fun onWelcome(welcome: Welcome)
        fun onPairRequest(request: PairRequest)
        fun onConfig(config: StreamConfig)

        /** Called on the reader thread; return once the frame is queued for decoding. */
        fun onFrame(frame: VideoFrame)
        fun onClosed(reason: CloseReason)
    }

    private val closed = AtomicBoolean(false)
    private val outgoing = LinkedBlockingQueue<Message>()
    private var socket: Socket? = null
    private var writer: Thread? = null
    private var timer: ScheduledExecutorService? = null

    @Volatile var rttMicros: Long? = null
        private set

    /** `hostClock - clientClock` from the lowest-RTT PONG. */
    @Volatile var clockOffsetMicros: Long? = null
        private set
    private var bestRtt = Long.MAX_VALUE

    @Volatile private var lastReceived = System.nanoTime()
    @Volatile private var receivedBytes = 0L
    @Volatile private var receivedFrames = 0
    private var windowStart = nowMicros()

    /** Supplies decoder numbers for STATS: (decodeMs, latencyMs, droppedFrames). */
    var statsProvider: (() -> Triple<Double, Double?, Int>)? = null
    @Volatile var lastFps = 0.0
        private set
    @Volatile var lastBitrateKbps = 0.0
        private set

    fun start() {
        Thread(::readLoop, "msm-reader").apply { priority = Thread.MAX_PRIORITY }.start()
    }

    fun send(message: Message) {
        if (!closed.get()) outgoing.offer(message)
    }

    fun send(event: InputEvent) = send(event.message())

    fun sendPairingCode(code: String) = send(Messages.pair(code))

    fun requestKeyframe() = send(Messages.keyframeRequest())

    /** Latency of a frame captured at [captureTimeMicros] (host clock), if the offset is known. */
    fun latencyMicros(captureTimeMicros: Long, now: Long = nowMicros()): Long? {
        val offset = clockOffsetMicros ?: return null
        return now + offset - captureTimeMicros
    }

    fun close() {
        if (closed.getAndSet(true)) return
        // Best effort BYE once the writer has stopped (so writes don't interleave).
        val socket = socket
        val writer = writer
        Thread {
            writer?.join(1000)
            try {
                socket?.getOutputStream()?.let {
                    it.write(Messages.bye("user").serialize())
                    it.flush()
                }
            } catch (_: IOException) {
            }
            shutdown()
        }.start()
        listener.onClosed(CloseReason.User)
    }

    private fun readLoop() {
        val socket = Socket()
        this.socket = socket
        try {
            socket.tcpNoDelay = true
            // AF41 → Wi-Fi WMM video access category.
            socket.trafficClass = 0x88
            socket.receiveBufferSize = 1 shl 20
            socket.connect(InetSocketAddress(host, port), CONNECT_TIMEOUT_MS)
            if (closed.get()) {
                socket.close()
                return
            }

            startWriter(socket)
            send(hello.message())
            startTimer()

            val input = DataInputStream(BufferedInputStream(socket.getInputStream(), 1 shl 18))
            while (!closed.get()) {
                val message = Message.read(input)
                lastReceived = System.nanoTime()
                receivedBytes += message.payload.size + 6
                handle(message)
            }
        } catch (error: IOException) {
            finish(CloseReason.Network(error.message ?: error.javaClass.simpleName))
        } catch (error: RuntimeException) {
            Log.e(TAG, "Protocol error", error)
            finish(CloseReason.Network(error.message ?: error.javaClass.simpleName))
        }
    }

    private fun handle(message: Message) {
        when (message.type) {
            MessageType.WELCOME -> listener.onWelcome(Welcome.parse(message.json()))
            MessageType.PAIR_REQUEST -> listener.onPairRequest(PairRequest.parse(message.json()))
            MessageType.ERROR -> finish(CloseReason.Host(HostError.parse(message.json())))
            MessageType.CONFIG -> listener.onConfig(StreamConfig.parse(message.json()))
            MessageType.VIDEO -> {
                val frame = VideoFrame.parse(message)
                receivedFrames++
                listener.onFrame(frame)
                send(Messages.ack(frame.seq))
            }
            MessageType.PING -> send(Messages.pong(Messages.parsePing(message), nowMicros()))
            MessageType.PONG -> {
                val (echoed, responder) = Messages.parsePong(message)
                val now = nowMicros()
                val rtt = now - echoed
                if (rtt < 0) return
                rttMicros = rtt
                // Assume symmetric paths; the lowest-RTT sample has the least queueing.
                if (rtt <= bestRtt) {
                    bestRtt = rtt
                    clockOffsetMicros = responder - (echoed + rtt / 2)
                }
            }
            MessageType.BYE -> {
                val reason = runCatching { message.json().optString("reason", "bye") }.getOrDefault("bye")
                finish(CloseReason.Bye(reason))
            }
        }
    }

    private fun startWriter(socket: Socket) {
        val output = BufferedOutputStream(socket.getOutputStream(), 64 * 1024)
        writer = Thread({
            try {
                while (!closed.get()) {
                    val message = outgoing.poll(500, TimeUnit.MILLISECONDS) ?: continue
                    output.write(message.serialize())
                    // Batch whatever else is already queued into the same flush.
                    while (true) {
                        val next = outgoing.poll() ?: break
                        output.write(next.serialize())
                    }
                    output.flush()
                }
            } catch (error: IOException) {
                finish(CloseReason.Network(error.message ?: "write failed"))
            } catch (_: InterruptedException) {
            }
        }, "msm-writer").apply {
            priority = Thread.MAX_PRIORITY
            start()
        }
    }

    private fun startTimer() {
        val timer = Executors.newSingleThreadScheduledExecutor { Thread(it, "msm-timer").apply { isDaemon = true } }
        this.timer = timer
        timer.scheduleWithFixedDelay(::tick, 0, 1, TimeUnit.SECONDS)
        // close() may have run between the connect and here.
        if (closed.get()) timer.shutdownNow()
    }

    private fun tick() {
        // The host answers every PING, so silence means the Mac slept or the link died.
        if (System.nanoTime() - lastReceived > SILENCE_TIMEOUT_NS) {
            finish(CloseReason.Network("timeout"))
            return
        }
        send(Messages.ping(nowMicros()))
        // Slowly forget the best RTT so the offset can follow clock drift.
        if (bestRtt != Long.MAX_VALUE) bestRtt += 200

        val now = nowMicros()
        val seconds = (now - windowStart) / 1_000_000.0
        if (seconds <= 0) return
        lastFps = receivedFrames / seconds
        lastBitrateKbps = receivedBytes * 8 / seconds / 1000
        val (decodeMs, latencyMs, dropped) = statsProvider?.invoke() ?: Triple(0.0, null, 0)
        send(Messages.stats(lastFps, decodeMs, latencyMs, rttMicros?.let { it / 1000.0 }, dropped, lastBitrateKbps))
        receivedFrames = 0
        receivedBytes = 0
        windowStart = now
    }

    private fun finish(reason: CloseReason) {
        if (closed.getAndSet(true)) return
        shutdown()
        listener.onClosed(reason)
    }

    private fun shutdown() {
        timer?.shutdownNow()
        try {
            socket?.close()
        } catch (_: IOException) {
        }
    }

    companion object {
        private const val TAG = "HostConnection"
        private const val CONNECT_TIMEOUT_MS = 4000
        private const val SILENCE_TIMEOUT_NS = 10_000_000_000L
    }
}
