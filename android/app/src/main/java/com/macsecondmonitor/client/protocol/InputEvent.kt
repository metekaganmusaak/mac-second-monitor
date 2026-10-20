package com.macsecondmonitor.client.protocol

import java.nio.ByteBuffer
import java.nio.ByteOrder

/** INPUT messages. Coordinates are normalized to the video frame (0..1). */
sealed class InputEvent {
    abstract fun message(): Message

    data class Pointer(val action: Int, val button: Int, val tool: Int, val x: Float, val y: Float, val pressure: Float = 1f) : InputEvent() {
        override fun message(): Message {
            val buffer = ByteBuffer.allocate(17).order(ByteOrder.BIG_ENDIAN)
            buffer.put(KIND_POINTER)
            buffer.put(action.toByte())
            buffer.put(button.toByte())
            buffer.put(tool.toByte())
            buffer.put(0)
            buffer.putFloat(x)
            buffer.putFloat(y)
            buffer.putFloat(pressure)
            return Message(MessageType.INPUT, 0, buffer.array())
        }
    }

    /** Positive [dy] moves the content down (the finger moved down). */
    data class Scroll(val phase: Int, val unit: Int, val x: Float, val y: Float, val dx: Float, val dy: Float) : InputEvent() {
        override fun message(): Message {
            val buffer = ByteBuffer.allocate(21).order(ByteOrder.BIG_ENDIAN)
            buffer.put(KIND_SCROLL)
            buffer.put(phase.toByte())
            buffer.put(unit.toByte())
            buffer.putShort(0)
            buffer.putFloat(x)
            buffer.putFloat(y)
            buffer.putFloat(dx)
            buffer.putFloat(dy)
            return Message(MessageType.INPUT, 0, buffer.array())
        }
    }

    /** [usage] is a USB HID Keyboard/Keypad page usage; [modifiers] is the state after the event. */
    data class Key(val action: Int, val usage: Int, val modifiers: Int) : InputEvent() {
        override fun message(): Message {
            val buffer = ByteBuffer.allocate(7).order(ByteOrder.BIG_ENDIAN)
            buffer.put(KIND_KEY)
            buffer.put(action.toByte())
            buffer.put(0)
            buffer.putShort(usage.toShort())
            buffer.putShort(modifiers.toShort())
            return Message(MessageType.INPUT, 0, buffer.array())
        }
    }

    data class Text(val text: String) : InputEvent() {
        override fun message(): Message {
            val bytes = text.toByteArray(Charsets.UTF_8)
            return Message(MessageType.INPUT, 0, byteArrayOf(KIND_TEXT) + bytes)
        }
    }

    companion object {
        private const val KIND_POINTER: Byte = 0x01
        private const val KIND_SCROLL: Byte = 0x02
        private const val KIND_KEY: Byte = 0x03
        private const val KIND_TEXT: Byte = 0x04

        const val ACTION_MOVE = 0
        const val ACTION_DOWN = 1
        const val ACTION_UP = 2
        const val ACTION_CANCEL = 3

        const val BUTTON_LEFT = 0
        const val BUTTON_RIGHT = 1
        const val BUTTON_MIDDLE = 2

        const val TOOL_MOUSE = 0
        const val TOOL_FINGER = 1
        const val TOOL_STYLUS = 2

        const val PHASE_NONE = 0
        const val PHASE_BEGAN = 1
        const val PHASE_CHANGED = 2
        const val PHASE_ENDED = 3
        const val PHASE_MOMENTUM = 4
        const val PHASE_MOMENTUM_ENDED = 5

        const val UNIT_NORMALIZED = 0
        const val UNIT_LINES = 1

        const val KEY_DOWN = 1
        const val KEY_UP = 2

        const val MOD_SHIFT = 1
        const val MOD_CONTROL = 1 shl 1
        const val MOD_OPTION = 1 shl 2
        const val MOD_COMMAND = 1 shl 3
        const val MOD_CAPS_LOCK = 1 shl 4
        const val MOD_FUNCTION = 1 shl 5
    }
}
