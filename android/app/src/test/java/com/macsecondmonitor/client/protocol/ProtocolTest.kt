package com.macsecondmonitor.client.protocol

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.ByteArrayInputStream
import java.io.DataInputStream

class ProtocolTest {
    @Test
    fun headerIsBigEndian() {
        val bytes = Message(MessageType.VIDEO, 1, byteArrayOf(0xAA.toByte(), 0xBB.toByte())).serialize()
        assertArrayEquals(byteArrayOf(0x11, 0x01, 0, 0, 0, 2, 0xAA.toByte(), 0xBB.toByte()), bytes)
    }

    @Test
    fun readsBackToBackMessages() {
        val stream = Messages.ping(42).serialize() + Messages.keyframeRequest().serialize()
        val input = DataInputStream(ByteArrayInputStream(stream))
        val first = Message.read(input)
        assertEquals(MessageType.PING, first.type)
        assertEquals(42L, Messages.parsePing(first))
        assertEquals(MessageType.KEYFRAME_REQ, Message.read(input).type)
    }

    @Test
    fun parsesVideoFrame() {
        val payload = byteArrayOf(0, 0, 0, 7, 0, 0, 0, 0, 0, 0, 0x30, 0x39, 0, 0, 0, 1, 0x65)
        val frame = VideoFrame.parse(Message(MessageType.VIDEO, 1, payload))
        assertEquals(7L, frame.seq)
        assertEquals(12345L, frame.captureTimeMicros)
        assertTrue(frame.isKeyframe)
        assertEquals(5, frame.length)
        assertEquals(12, frame.offset)
    }

    @Test
    fun ackCarriesUnsignedSequence() {
        val ack = Messages.ack(0xFFFF_FFFEL)
        assertArrayEquals(byteArrayOf(0xFF.toByte(), 0xFF.toByte(), 0xFF.toByte(), 0xFE.toByte()), ack.payload)
    }

    @Test
    fun inputLayoutsMatchSpec() {
        val pointer = InputEvent.Pointer(InputEvent.ACTION_UP, InputEvent.BUTTON_LEFT, InputEvent.TOOL_FINGER, 1f, 0f, 1f).message().payload
        assertEquals(17, pointer.size)
        assertArrayEquals(byteArrayOf(1, 2, 0, 1, 0, 0x3F, 0x80.toByte(), 0, 0), pointer.copyOfRange(0, 9))

        val scroll = InputEvent.Scroll(InputEvent.PHASE_CHANGED, InputEvent.UNIT_NORMALIZED, 0.5f, 0.5f, 0f, 0.25f).message().payload
        assertEquals(21, scroll.size)
        assertArrayEquals(byteArrayOf(2, 2, 0, 0, 0), scroll.copyOfRange(0, 5))

        val key = InputEvent.Key(InputEvent.KEY_DOWN, 0x04, InputEvent.MOD_COMMAND or InputEvent.MOD_SHIFT).message().payload
        assertArrayEquals(byteArrayOf(3, 1, 0, 0, 4, 0, 9), key)

        val text = InputEvent.Text("ğ").message().payload
        assertArrayEquals(byteArrayOf(4, 0xC4.toByte(), 0x9F.toByte()), text)
    }

    @Test
    fun helloJson() {
        val hello = Hello("id", "MatePad 11", "0.1.0", DisplayInfo(2560, 1600, 276.0, 120.0), listOf("h264"), "tr-TR", null)
        val json = hello.message().json()
        assertEquals(1, json.getInt("protocol"))
        assertEquals("android", json.getString("platform"))
        assertEquals(2560, json.getJSONObject("display").getInt("width"))
        assertTrue(!json.has("token"))
    }
}
