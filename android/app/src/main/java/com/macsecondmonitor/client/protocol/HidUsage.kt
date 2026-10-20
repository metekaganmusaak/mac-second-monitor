package com.macsecondmonitor.client.protocol

import android.view.KeyEvent

/**
 * Android key codes to USB HID Keyboard/Keypad usages (page 0x07). Both describe physical
 * key positions; the Mac's input source decides which character a key produces.
 */
object HidUsage {
    const val RETURN = 0x28
    const val BACKSPACE = 0x2A
    const val TAB = 0x2B
    const val ESCAPE = 0x29
    const val LEFT_CONTROL = 0xE0
    const val LEFT_GUI = 0xE3
    const val RIGHT_CONTROL = 0xE4
    const val RIGHT_GUI = 0xE7

    private val table: Map<Int, Int> = buildMap {
        for (i in 0..25) put(KeyEvent.KEYCODE_A + i, 0x04 + i)
        for (i in 1..9) put(KeyEvent.KEYCODE_1 + i - 1, 0x1E + i - 1)
        put(KeyEvent.KEYCODE_0, 0x27)
        put(KeyEvent.KEYCODE_ENTER, RETURN)
        put(KeyEvent.KEYCODE_ESCAPE, ESCAPE)
        put(KeyEvent.KEYCODE_DEL, BACKSPACE)
        put(KeyEvent.KEYCODE_TAB, TAB)
        put(KeyEvent.KEYCODE_SPACE, 0x2C)
        put(KeyEvent.KEYCODE_MINUS, 0x2D)
        put(KeyEvent.KEYCODE_EQUALS, 0x2E)
        put(KeyEvent.KEYCODE_LEFT_BRACKET, 0x2F)
        put(KeyEvent.KEYCODE_RIGHT_BRACKET, 0x30)
        put(KeyEvent.KEYCODE_BACKSLASH, 0x31)
        put(KeyEvent.KEYCODE_SEMICOLON, 0x33)
        put(KeyEvent.KEYCODE_APOSTROPHE, 0x34)
        put(KeyEvent.KEYCODE_GRAVE, 0x35)
        put(KeyEvent.KEYCODE_COMMA, 0x36)
        put(KeyEvent.KEYCODE_PERIOD, 0x37)
        put(KeyEvent.KEYCODE_SLASH, 0x38)
        put(KeyEvent.KEYCODE_CAPS_LOCK, 0x39)
        for (i in 0..11) put(KeyEvent.KEYCODE_F1 + i, 0x3A + i)
        put(KeyEvent.KEYCODE_SYSRQ, 0x46)
        put(KeyEvent.KEYCODE_SCROLL_LOCK, 0x47)
        put(KeyEvent.KEYCODE_BREAK, 0x48)
        put(KeyEvent.KEYCODE_INSERT, 0x49)
        put(KeyEvent.KEYCODE_MOVE_HOME, 0x4A)
        put(KeyEvent.KEYCODE_PAGE_UP, 0x4B)
        put(KeyEvent.KEYCODE_FORWARD_DEL, 0x4C)
        put(KeyEvent.KEYCODE_MOVE_END, 0x4D)
        put(KeyEvent.KEYCODE_PAGE_DOWN, 0x4E)
        put(KeyEvent.KEYCODE_DPAD_RIGHT, 0x4F)
        put(KeyEvent.KEYCODE_DPAD_LEFT, 0x50)
        put(KeyEvent.KEYCODE_DPAD_DOWN, 0x51)
        put(KeyEvent.KEYCODE_DPAD_UP, 0x52)
        put(KeyEvent.KEYCODE_NUM_LOCK, 0x53)
        put(KeyEvent.KEYCODE_NUMPAD_DIVIDE, 0x54)
        put(KeyEvent.KEYCODE_NUMPAD_MULTIPLY, 0x55)
        put(KeyEvent.KEYCODE_NUMPAD_SUBTRACT, 0x56)
        put(KeyEvent.KEYCODE_NUMPAD_ADD, 0x57)
        put(KeyEvent.KEYCODE_NUMPAD_ENTER, 0x58)
        for (i in 1..9) put(KeyEvent.KEYCODE_NUMPAD_1 + i - 1, 0x59 + i - 1)
        put(KeyEvent.KEYCODE_NUMPAD_0, 0x62)
        put(KeyEvent.KEYCODE_NUMPAD_DOT, 0x63)
        put(KeyEvent.KEYCODE_NUMPAD_EQUALS, 0x67)
        put(KeyEvent.KEYCODE_MENU, 0x65)
        put(KeyEvent.KEYCODE_CTRL_LEFT, LEFT_CONTROL)
        put(KeyEvent.KEYCODE_SHIFT_LEFT, 0xE1)
        put(KeyEvent.KEYCODE_ALT_LEFT, 0xE2)
        put(KeyEvent.KEYCODE_META_LEFT, LEFT_GUI)
        put(KeyEvent.KEYCODE_CTRL_RIGHT, RIGHT_CONTROL)
        put(KeyEvent.KEYCODE_SHIFT_RIGHT, 0xE5)
        put(KeyEvent.KEYCODE_ALT_RIGHT, 0xE6)
        put(KeyEvent.KEYCODE_META_RIGHT, RIGHT_GUI)
    }

    /**
     * @param swapControlCommand PC keyboards have Ctrl where Mac users expect ⌘; swapping makes
     *   Ctrl+C copy on the Mac.
     */
    fun usage(keyCode: Int, swapControlCommand: Boolean = false): Int? {
        val usage = table[keyCode] ?: return null
        if (!swapControlCommand) return usage
        return when (usage) {
            LEFT_CONTROL -> LEFT_GUI
            LEFT_GUI -> LEFT_CONTROL
            RIGHT_CONTROL -> RIGHT_GUI
            RIGHT_GUI -> RIGHT_CONTROL
            else -> usage
        }
    }

    fun modifiers(metaState: Int, swapControlCommand: Boolean = false): Int {
        var modifiers = 0
        val control = metaState and KeyEvent.META_CTRL_ON != 0
        val command = metaState and KeyEvent.META_META_ON != 0
        if (metaState and KeyEvent.META_SHIFT_ON != 0) modifiers = modifiers or InputEvent.MOD_SHIFT
        if (if (swapControlCommand) command else control) modifiers = modifiers or InputEvent.MOD_CONTROL
        if (if (swapControlCommand) control else command) modifiers = modifiers or InputEvent.MOD_COMMAND
        if (metaState and KeyEvent.META_ALT_ON != 0) modifiers = modifiers or InputEvent.MOD_OPTION
        if (metaState and KeyEvent.META_CAPS_LOCK_ON != 0) modifiers = modifiers or InputEvent.MOD_CAPS_LOCK
        if (metaState and KeyEvent.META_FUNCTION_ON != 0) modifiers = modifiers or InputEvent.MOD_FUNCTION
        return modifiers
    }
}
