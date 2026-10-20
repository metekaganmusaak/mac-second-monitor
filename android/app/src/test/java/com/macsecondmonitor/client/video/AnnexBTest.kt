package com.macsecondmonitor.client.video

import com.macsecondmonitor.client.protocol.VideoFrame
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Test

class AnnexBTest {
    private val stream = byteArrayOf(0, 0, 0, 1, 0x67, 1, 2, 0, 0, 1, 0x68, 3, 0, 0, 0, 1, 0x65, 4, 5, 6)

    @Test
    fun splitsThreeAndFourByteStartCodes() {
        val units = AnnexB.units(stream)
        assertEquals(listOf(4..6, 10..11, 16..19), units)
    }

    @Test
    fun extractsH264ParameterSets() {
        val frame = VideoFrame(0, 0, true, stream, 0, stream.size)
        val sets = AnnexB.parameterSets(frame, hevc = false)
        assertEquals(2, sets.size)
        assertArrayEquals(byteArrayOf(0, 0, 0, 1, 0x67, 1, 2), sets[0])
        assertArrayEquals(byteArrayOf(0, 0, 0, 1, 0x68, 3), sets[1])
    }
}
