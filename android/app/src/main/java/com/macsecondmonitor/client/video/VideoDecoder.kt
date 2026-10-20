package com.macsecondmonitor.client.video

import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaCodecList
import android.media.MediaFormat
import android.os.Build
import android.util.Log
import android.view.Surface
import com.macsecondmonitor.client.protocol.StreamConfig
import com.macsecondmonitor.client.protocol.VideoFrame
import java.nio.ByteBuffer
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicBoolean

/** Splits Annex-B data into NAL units and finds parameter sets. */
object AnnexB {
    /** Start offsets (after the start code) and end offsets of each NAL unit. */
    fun units(data: ByteArray, offset: Int = 0, length: Int = data.size): List<IntRange> {
        val end = offset + length
        val ranges = mutableListOf<IntRange>()
        var start = -1
        var i = offset
        while (i + 2 < end) {
            if (data[i].toInt() == 0 && data[i + 1].toInt() == 0 && data[i + 2].toInt() == 1) {
                if (start >= 0) {
                    var unitEnd = i
                    // A 4-byte start code's leading zero belongs to the start code.
                    if (unitEnd > start && data[unitEnd - 1].toInt() == 0) unitEnd--
                    ranges += start until unitEnd
                }
                i += 3
                start = i
            } else {
                i++
            }
        }
        if (start in 0 until end) ranges += start until end
        return ranges
    }

    fun isParameterSet(data: ByteArray, unit: IntRange, hevc: Boolean): Boolean {
        val header = data[unit.first].toInt() and 0xFF
        return if (hevc) ((header shr 1) and 0x3F) in 32..34 else (header and 0x1F) in 7..8
    }

    /** Parameter sets of a keyframe, each with a 4-byte start code (MediaCodec csd format). */
    fun parameterSets(frame: VideoFrame, hevc: Boolean): List<ByteArray> =
        units(frame.data, frame.offset, frame.length)
            .filter { isParameterSet(frame.data, it, hevc) }
            .map { byteArrayOf(0, 0, 0, 1) + frame.data.copyOfRange(it.first, it.last + 1) }
}

/**
 * Hardware decoder rendering straight to a Surface with every low-latency switch the device
 * offers. Frames are shown as soon as they are decoded; if several are ready at once only the
 * newest is rendered.
 */
class VideoDecoder(private val listener: Listener) {
    interface Listener {
        /** The decoder (re)started or lost its references: ask the host for a keyframe. */
        fun onKeyframeNeeded()
        fun onFrameRendered(captureTimeMicros: Long)
    }

    private val lock = Any()
    private val statsLock = Any()
    private var surface: Surface? = null
    private var config: StreamConfig? = null
    private var session: Session? = null
    private var parameterSets: List<ByteArray> = emptyList()
    private var waitingForKeyframe = true
    private var lastKeyframeRequest = 0L

    @Volatile var decoderName: String? = null
        private set

    // Stats window, read by the connection's STATS timer.
    private var decodeMicrosTotal = 0L
    private var decodedFrames = 0
    @Volatile private var droppedFrames = 0

    fun setSurface(surface: Surface?) {
        synchronized(lock) {
            if (surface === this.surface) return
            stopSession()
            this.surface = surface
            waitingForKeyframe = true
        }
        if (surface != null) listener.onKeyframeNeeded()
    }

    fun configure(config: StreamConfig) {
        synchronized(lock) {
            if (config == this.config) return
            stopSession()
            this.config = config
            waitingForKeyframe = true
        }
    }

    /** Called on the network thread for every VIDEO frame. */
    fun submit(frame: VideoFrame) {
        synchronized(lock) {
            val surface = surface ?: return
            val config = config ?: return
            val hevc = config.codec == "hevc"

            if (frame.isKeyframe) {
                val sets = AnnexB.parameterSets(frame, hevc)
                if (session == null || !sameParameterSets(sets)) {
                    stopSession()
                    session = startSession(config, surface, sets)
                    parameterSets = sets
                }
                waitingForKeyframe = session == null
            }
            val session = session
            if (session == null || waitingForKeyframe) {
                droppedFrames++
                requestKeyframe()
                return
            }
            if (!session.queue(frame)) {
                Log.w(TAG, "Decoder did not accept a frame; restarting")
                stopSession()
                waitingForKeyframe = true
                requestKeyframe()
            }
        }
    }

    fun release() = synchronized(lock) {
        stopSession()
        surface = null
    }

    /** (average decode ms, dropped frames) since the last call. */
    fun takeStats(): Pair<Double, Int> = synchronized(statsLock) {
        val average = if (decodedFrames > 0) decodeMicrosTotal / 1000.0 / decodedFrames else 0.0
        val dropped = droppedFrames
        decodeMicrosTotal = 0
        decodedFrames = 0
        droppedFrames = 0
        average to dropped
    }

    private fun sameParameterSets(sets: List<ByteArray>) =
        sets.size == parameterSets.size && sets.indices.all { sets[it].contentEquals(parameterSets[it]) }

    private fun requestKeyframe() {
        val now = System.nanoTime()
        // At most a few requests per second while waiting.
        if (now - lastKeyframeRequest < 300_000_000L) return
        lastKeyframeRequest = now
        listener.onKeyframeNeeded()
    }

    private fun stopSession() {
        session?.stop()
        session = null
    }

    private fun startSession(config: StreamConfig, surface: Surface, sets: List<ByteArray>): Session? {
        val mime = config.mimeType
        val info = selectDecoder(mime, config.width, config.height)
        return try {
            val codec = createConfigured(info, mime, config, surface, sets, lowLatency = true)
                ?: createConfigured(info, mime, config, surface, sets, lowLatency = false)
                ?: return null
            codec.start()
            decoderName = codec.name
            Log.i(TAG, "Decoder ${codec.name} ${config.width}x${config.height} ${config.codec}")
            Session(codec)
        } catch (error: Exception) {
            Log.e(TAG, "Could not start decoder", error)
            null
        }
    }

    private fun createConfigured(info: MediaCodecInfo?, mime: String, config: StreamConfig, surface: Surface, sets: List<ByteArray>, lowLatency: Boolean): MediaCodec? {
        val codec = if (info != null) MediaCodec.createByCodecName(info.name) else MediaCodec.createDecoderByType(mime)
        val format = MediaFormat.createVideoFormat(mime, config.width, config.height)
        format.setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, maxOf(config.width * config.height, 1 shl 20))
        if (config.codec == "hevc") {
            format.setByteBuffer("csd-0", ByteBuffer.wrap(sets.fold(ByteArray(0)) { acc, set -> acc + set }))
        } else if (sets.size >= 2) {
            format.setByteBuffer("csd-0", ByteBuffer.wrap(sets[0]))
            format.setByteBuffer("csd-1", ByteBuffer.wrap(sets[1]))
        }
        if (lowLatency) applyLowLatency(format, codec.name, info, mime)
        return try {
            codec.configure(format, surface, null, 0)
            codec
        } catch (error: Exception) {
            Log.w(TAG, "configure(lowLatency=$lowLatency) failed on ${codec.name}", error)
            codec.release()
            null
        }
    }

    private fun applyLowLatency(format: MediaFormat, name: String, info: MediaCodecInfo?, mime: String) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            val supported = info?.getCapabilitiesForType(mime)?.isFeatureSupported(MediaCodecInfo.CodecCapabilities.FEATURE_LowLatency) == true
            if (supported) format.setInteger(MediaFormat.KEY_LOW_LATENCY, 1)
        }
        // Vendor switches, as used by low-latency game streaming clients.
        val lower = name.lowercase()
        when {
            lower.startsWith("omx.qcom") || lower.startsWith("c2.qti") -> {
                format.setInteger("vendor.qti-ext-dec-picture-order.enable", 1)
                format.setInteger("vendor.qti-ext-dec-low-latency.enable", 1)
                // Run the decoder at full clock instead of pacing to the content's frame rate.
                format.setInteger(MediaFormat.KEY_OPERATING_RATE, Short.MAX_VALUE.toInt())
            }
            lower.startsWith("omx.hisi") || lower.startsWith("c2.hisi") -> {
                format.setInteger("vendor.hisi-ext-low-latency-video-dec.video-scene-for-low-latency-req", 1)
                format.setInteger("vendor.hisi-ext-low-latency-video-dec.video-scene-for-low-latency-rdy", -1)
            }
            lower.startsWith("omx.exynos") || lower.startsWith("c2.exynos") ->
                format.setInteger("vendor.rtc-ext-dec-low-latency.enable", 1)
            lower.startsWith("omx.amlogic") || lower.startsWith("c2.amlogic") ->
                format.setInteger("vendor.low-latency.enable", 1)
            else -> format.setInteger(MediaFormat.KEY_PRIORITY, 0)
        }
    }

    private inner class Session(val codec: MediaCodec) {
        private val running = AtomicBoolean(true)
        private val queuedAt = ConcurrentHashMap<Long, Long>()
        private val output = Thread(::outputLoop, "msm-decoder-out").apply {
            priority = Thread.MAX_PRIORITY
            start()
        }

        fun queue(frame: VideoFrame): Boolean {
            repeat(INPUT_ATTEMPTS) {
                val index = try {
                    codec.dequeueInputBuffer(INPUT_TIMEOUT_US)
                } catch (error: IllegalStateException) {
                    return false
                }
                if (index < 0) return@repeat
                val buffer = codec.getInputBuffer(index) ?: return false
                if (frame.length > buffer.capacity()) {
                    codec.queueInputBuffer(index, 0, 0, 0, 0)
                    return false
                }
                buffer.clear()
                buffer.put(frame.data, frame.offset, frame.length)
                if (queuedAt.size > 240) queuedAt.clear()
                queuedAt[frame.captureTimeMicros] = System.nanoTime()
                val flags = if (frame.isKeyframe) MediaCodec.BUFFER_FLAG_KEY_FRAME else 0
                codec.queueInputBuffer(index, 0, frame.length, frame.captureTimeMicros, flags)
                return true
            }
            return false
        }

        private fun outputLoop() {
            val info = MediaCodec.BufferInfo()
            while (running.get()) {
                try {
                    var index = codec.dequeueOutputBuffer(info, OUTPUT_TIMEOUT_US)
                    if (index < 0) continue
                    var pts = info.presentationTimeUs
                    // Latest frame wins: skip outputs that are already stale.
                    while (true) {
                        val next = codec.dequeueOutputBuffer(info, 0)
                        if (next < 0) break
                        codec.releaseOutputBuffer(index, false)
                        queuedAt.remove(pts)
                        droppedFrames++
                        index = next
                        pts = info.presentationTimeUs
                    }
                    codec.releaseOutputBuffer(index, true)
                    queuedAt.remove(pts)?.let { queued ->
                        synchronized(statsLock) {
                            decodeMicrosTotal += (System.nanoTime() - queued) / 1000
                            decodedFrames++
                        }
                    }
                    listener.onFrameRendered(pts)
                } catch (error: IllegalStateException) {
                    if (running.get()) {
                        Log.w(TAG, "Decoder output failed", error)
                        running.set(false)
                        listener.onKeyframeNeeded()
                    }
                }
            }
        }

        fun stop() {
            running.set(false)
            output.join(200)
            runCatching { codec.stop() }
            runCatching { codec.release() }
        }
    }

    companion object {
        private const val TAG = "VideoDecoder"
        private const val INPUT_ATTEMPTS = 20
        private const val INPUT_TIMEOUT_US = 10_000L
        private const val OUTPUT_TIMEOUT_US = 20_000L

        /** Decodable codec names for HELLO, in order of preference. */
        fun supportedCodecs(): List<String> = buildList {
            add("h264")
            if (selectDecoder("video/hevc", 1920, 1080) != null) add("hevc")
        }

        /** Prefers hardware decoders that advertise low-latency support. */
        fun selectDecoder(mime: String, width: Int, height: Int): MediaCodecInfo? {
            val candidates = MediaCodecList(MediaCodecList.REGULAR_CODECS).codecInfos.filter { info ->
                !info.isEncoder && info.supportedTypes.any { it.equals(mime, ignoreCase = true) } &&
                    runCatching { info.getCapabilitiesForType(mime).videoCapabilities.isSizeSupported(width, height) }.getOrDefault(false)
            }
            fun isHardware(info: MediaCodecInfo) = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                info.isHardwareAccelerated
            } else {
                val name = info.name.lowercase()
                !name.startsWith("omx.google.") && !name.startsWith("c2.android.")
            }
            fun lowLatency(info: MediaCodecInfo) = Build.VERSION.SDK_INT >= Build.VERSION_CODES.R &&
                info.getCapabilitiesForType(mime).isFeatureSupported(MediaCodecInfo.CodecCapabilities.FEATURE_LowLatency)
            return candidates.sortedWith(compareByDescending<MediaCodecInfo> { isHardware(it) }.thenByDescending { lowLatency(it) }).firstOrNull()
        }
    }
}
