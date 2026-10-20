package com.macsecondmonitor.client.protocol

import org.json.JSONArray
import org.json.JSONObject
import java.io.DataInputStream
import java.io.EOFException
import java.io.IOException
import java.nio.ByteBuffer
import java.nio.ByteOrder

/** Wire protocol v1. See docs/PROTOCOL.md. */
object ProtocolInfo {
    const val VERSION = 1
    const val NATIVE_PORT = 7100
    const val SERVICE_TYPE = "_macsecondmon._tcp."
    const val HEADER_SIZE = 6
    const val MAX_PAYLOAD = 16 * 1024 * 1024
}

object MessageType {
    const val HELLO = 0x01
    const val WELCOME = 0x02
    const val PAIR_REQUEST = 0x03
    const val PAIR = 0x04
    const val ERROR = 0x05
    const val CONFIG = 0x10
    const val VIDEO = 0x11
    const val KEYFRAME_REQ = 0x12
    const val ACK = 0x13
    const val INPUT = 0x20
    const val PING = 0x30
    const val PONG = 0x31
    const val STATS = 0x32
    const val BYE = 0x7F
}

class Message(val type: Int, val flags: Int, val payload: ByteArray) {
    fun serialize(): ByteArray {
        val buffer = ByteBuffer.allocate(ProtocolInfo.HEADER_SIZE + payload.size).order(ByteOrder.BIG_ENDIAN)
        buffer.put(type.toByte())
        buffer.put(flags.toByte())
        buffer.putInt(payload.size)
        buffer.put(payload)
        return buffer.array()
    }

    fun json(): JSONObject = JSONObject(String(payload, Charsets.UTF_8))

    companion object {
        fun json(type: Int, value: JSONObject) = Message(type, 0, value.toString().toByteArray(Charsets.UTF_8))

        /**
         * Reads the next message from a blocking stream. Unknown types are returned too;
         * callers ignore them.
         */
        fun read(input: DataInputStream): Message {
            val type = input.read()
            if (type < 0) throw EOFException()
            val flags = input.readUnsignedByte()
            val length = input.readInt()
            if (length < 0 || length > ProtocolInfo.MAX_PAYLOAD) throw IOException("payload too large: $length")
            val payload = ByteArray(length)
            input.readFully(payload)
            return Message(type, flags, payload)
        }
    }
}

data class DisplayInfo(val width: Int, val height: Int, val dpi: Double, val refreshRate: Double)

data class Hello(
    val deviceId: String,
    val deviceName: String,
    val appVersion: String,
    val display: DisplayInfo,
    val codecs: List<String>,
    val locale: String,
    val token: String?,
) {
    fun message(): Message {
        val json = JSONObject()
            .put("protocol", ProtocolInfo.VERSION)
            .put("deviceId", deviceId)
            .put("deviceName", deviceName)
            .put("platform", "android")
            .put("appVersion", appVersion)
            .put(
                "display",
                JSONObject()
                    .put("width", display.width)
                    .put("height", display.height)
                    .put("dpi", display.dpi)
                    .put("refreshRate", display.refreshRate),
            )
            .put("codecs", JSONArray(codecs))
            .put("locale", locale)
        if (token != null) json.put("token", token)
        return Message.json(MessageType.HELLO, json)
    }
}

data class Welcome(val hostName: String, val sessionId: String, val transport: String, val token: String?) {
    companion object {
        fun parse(json: JSONObject) = Welcome(
            hostName = json.optString("hostName"),
            sessionId = json.optString("sessionId"),
            transport = json.optString("transport"),
            token = if (json.has("token") && !json.isNull("token")) json.getString("token") else null,
        )
    }
}

data class PairRequest(val codeLength: Int, val attemptsLeft: Int, val retry: Boolean) {
    companion object {
        fun parse(json: JSONObject) = PairRequest(
            codeLength = json.optInt("codeLength", 6),
            attemptsLeft = json.optInt("attemptsLeft", 3),
            retry = json.optBoolean("retry", false),
        )
    }
}

data class StreamConfig(val codec: String, val codecString: String, val width: Int, val height: Int, val fps: Int, val mode: String) {
    val mimeType: String get() = if (codec == "hevc") "video/hevc" else "video/avc"

    companion object {
        fun parse(json: JSONObject) = StreamConfig(
            codec = json.optString("codec", "h264"),
            codecString = json.optString("codecString"),
            width = json.getInt("width"),
            height = json.getInt("height"),
            fps = json.optInt("fps", 60),
            mode = json.optString("mode", "extend"),
        )
    }
}

data class HostError(val code: String, val message: String) {
    companion object {
        fun parse(json: JSONObject) = HostError(json.optString("code", "internal"), json.optString("message"))
    }
}

/** VIDEO payload: `seq: u32, captureTime: u64 µs, Annex-B data`. Flag 0x01 = keyframe. */
class VideoFrame(val seq: Long, val captureTimeMicros: Long, val isKeyframe: Boolean, val data: ByteArray, val offset: Int, val length: Int) {
    companion object {
        const val HEADER_SIZE = 12

        fun parse(message: Message): VideoFrame {
            if (message.payload.size < HEADER_SIZE) throw IOException("short VIDEO payload")
            val buffer = ByteBuffer.wrap(message.payload).order(ByteOrder.BIG_ENDIAN)
            val seq = buffer.int.toLong() and 0xFFFF_FFFFL
            val capture = buffer.long
            return VideoFrame(seq, capture, message.flags and 0x01 != 0, message.payload, HEADER_SIZE, message.payload.size - HEADER_SIZE)
        }
    }
}

object Messages {
    fun pair(code: String) = Message.json(MessageType.PAIR, JSONObject().put("code", code))

    fun ack(seq: Long): Message = Message(MessageType.ACK, 0, ByteBuffer.allocate(4).putInt(seq.toInt()).array())

    fun keyframeRequest() = Message(MessageType.KEYFRAME_REQ, 0, ByteArray(0))

    fun ping(timeMicros: Long): Message = Message(MessageType.PING, 0, ByteBuffer.allocate(8).putLong(timeMicros).array())

    fun pong(echoed: Long, now: Long): Message = Message(MessageType.PONG, 0, ByteBuffer.allocate(16).putLong(echoed).putLong(now).array())

    fun bye(reason: String) = Message.json(MessageType.BYE, JSONObject().put("reason", reason))

    fun stats(fps: Double, decodeMs: Double, latencyMs: Double?, rttMs: Double?, dropped: Int, bitrateKbps: Double): Message {
        val json = JSONObject()
            .put("fps", fps)
            .put("decodeMs", decodeMs)
            .put("droppedFrames", dropped)
            .put("bitrateKbps", bitrateKbps)
        if (latencyMs != null) json.put("latencyMs", latencyMs)
        if (rttMs != null) json.put("rttMs", rttMs)
        return Message.json(MessageType.STATS, json)
    }

    /** Returns (echoedTime, responderTime). */
    fun parsePong(message: Message): Pair<Long, Long> {
        val buffer = ByteBuffer.wrap(message.payload)
        return buffer.long to buffer.long
    }

    fun parsePing(message: Message): Long = ByteBuffer.wrap(message.payload).long
}
