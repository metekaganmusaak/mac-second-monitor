package com.macsecondmonitor.client.protocol

import android.view.KeyEvent
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class HidUsageTest {
    @Test
    fun mapsCommonKeys() {
        assertEquals(0x04, HidUsage.usage(KeyEvent.KEYCODE_A))
        assertEquals(0x1D, HidUsage.usage(KeyEvent.KEYCODE_Z))
        assertEquals(0x27, HidUsage.usage(KeyEvent.KEYCODE_0))
        assertEquals(0x1E, HidUsage.usage(KeyEvent.KEYCODE_1))
        assertEquals(0x28, HidUsage.usage(KeyEvent.KEYCODE_ENTER))
        assertEquals(0x45, HidUsage.usage(KeyEvent.KEYCODE_F12))
        assertEquals(0x52, HidUsage.usage(KeyEvent.KEYCODE_DPAD_UP))
        assertNull(HidUsage.usage(KeyEvent.KEYCODE_VOLUME_UP))
    }

    @Test
    fun swapsControlAndCommand() {
        assertEquals(HidUsage.LEFT_GUI, HidUsage.usage(KeyEvent.KEYCODE_CTRL_LEFT, swapControlCommand = true))
        assertEquals(InputEvent.MOD_COMMAND, HidUsage.modifiers(KeyEvent.META_CTRL_ON, swapControlCommand = true))
        assertEquals(InputEvent.MOD_CONTROL, HidUsage.modifiers(KeyEvent.META_CTRL_ON))
    }
}
