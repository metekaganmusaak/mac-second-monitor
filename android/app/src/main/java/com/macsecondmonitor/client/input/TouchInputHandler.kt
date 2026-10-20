package com.macsecondmonitor.client.input

import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.view.MotionEvent
import com.macsecondmonitor.client.protocol.InputEvent

/**
 * Routes MotionEvents from the stream view: fingers go through [GestureMachine], a stylus
 * and a mouse map directly to the pointer (no slop, hover moves the cursor).
 */
class TouchInputHandler(
    private val sink: (InputEvent) -> Unit,
    slopPx: Float,
    onMenuRequested: () -> Unit,
    onLongPress: () -> Unit,
) {
    private val handler = Handler(Looper.getMainLooper())
    private val gestures = GestureMachine(
        sink = sink,
        scheduler = object : Scheduler {
            override fun schedule(delayMs: Long, task: () -> Unit): Any {
                val runnable = Runnable(task)
                handler.postDelayed(runnable, delayMs)
                return runnable
            }

            override fun cancel(token: Any) = handler.removeCallbacks(token as Runnable)
        },
        clock = SystemClock::uptimeMillis,
        slopPx = slopPx,
        onMenuRequested = onMenuRequested,
        onLongPress = onLongPress,
    )

    private var width = 1f
    private var height = 1f
    private var stylusButton = InputEvent.BUTTON_LEFT
    private var stylusDown = false

    var oneFingerScroll: Boolean
        get() = gestures.oneFingerScroll
        set(value) {
            gestures.oneFingerScroll = value
        }

    fun setSize(width: Int, height: Int) {
        this.width = width.coerceAtLeast(1).toFloat()
        this.height = height.coerceAtLeast(1).toFloat()
        gestures.width = this.width
        gestures.height = this.height
    }

    fun onTouchEvent(event: MotionEvent): Boolean {
        return when (event.getToolType(event.actionIndex)) {
            MotionEvent.TOOL_TYPE_STYLUS, MotionEvent.TOOL_TYPE_ERASER -> handleStylus(event)
            MotionEvent.TOOL_TYPE_MOUSE -> handleMouse(event)
            else -> handleFingers(event)
        }
    }

    /** Hover (stylus / mouse) and mouse wheel. */
    fun onGenericMotionEvent(event: MotionEvent): Boolean {
        val tool = event.getToolType(0)
        return when (event.actionMasked) {
            MotionEvent.ACTION_HOVER_MOVE, MotionEvent.ACTION_HOVER_ENTER -> {
                val kind = if (tool == MotionEvent.TOOL_TYPE_MOUSE) InputEvent.TOOL_MOUSE else InputEvent.TOOL_STYLUS
                sink(InputEvent.Pointer(InputEvent.ACTION_MOVE, InputEvent.BUTTON_LEFT, kind, nx(event.x), ny(event.y)))
                true
            }
            MotionEvent.ACTION_SCROLL -> {
                val vertical = event.getAxisValue(MotionEvent.AXIS_VSCROLL)
                val horizontal = event.getAxisValue(MotionEvent.AXIS_HSCROLL)
                // AXIS_VSCROLL > 0 is "wheel up", which moves content down: same sign as the protocol.
                sink(InputEvent.Scroll(InputEvent.PHASE_NONE, InputEvent.UNIT_LINES, nx(event.x), ny(event.y), -horizontal, vertical))
                true
            }
            else -> false
        }
    }

    private fun handleFingers(event: MotionEvent): Boolean {
        when (event.actionMasked) {
            MotionEvent.ACTION_DOWN -> gestures.fingerDown(point(event, 0))
            MotionEvent.ACTION_POINTER_DOWN -> gestures.fingersChanged(points(event))
            MotionEvent.ACTION_MOVE -> gestures.move(points(event))
            MotionEvent.ACTION_POINTER_UP -> {
                val lifted = point(event, event.actionIndex)
                gestures.fingerUp(lifted, points(event).filterIndexed { index, _ -> index != event.actionIndex })
            }
            MotionEvent.ACTION_UP -> gestures.fingerUp(point(event, 0), emptyList())
            MotionEvent.ACTION_CANCEL -> gestures.cancel()
        }
        return true
    }

    private fun handleStylus(event: MotionEvent): Boolean {
        val x = nx(event.x)
        val y = ny(event.y)
        val pressure = event.pressure.coerceIn(0f, 1f)
        when (event.actionMasked) {
            MotionEvent.ACTION_DOWN -> {
                stylusButton = if (event.buttonState and MotionEvent.BUTTON_STYLUS_PRIMARY != 0) InputEvent.BUTTON_RIGHT else InputEvent.BUTTON_LEFT
                stylusDown = true
                sink(InputEvent.Pointer(InputEvent.ACTION_MOVE, stylusButton, InputEvent.TOOL_STYLUS, x, y, pressure))
                sink(InputEvent.Pointer(InputEvent.ACTION_DOWN, stylusButton, InputEvent.TOOL_STYLUS, x, y, pressure))
            }
            MotionEvent.ACTION_MOVE -> if (stylusDown) {
                sink(InputEvent.Pointer(InputEvent.ACTION_MOVE, stylusButton, InputEvent.TOOL_STYLUS, x, y, pressure))
            }
            MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> if (stylusDown) {
                stylusDown = false
                val action = if (event.actionMasked == MotionEvent.ACTION_UP) InputEvent.ACTION_UP else InputEvent.ACTION_CANCEL
                sink(InputEvent.Pointer(action, stylusButton, InputEvent.TOOL_STYLUS, x, y, 0f))
            }
        }
        return true
    }

    private fun handleMouse(event: MotionEvent): Boolean {
        val x = nx(event.x)
        val y = ny(event.y)
        when (event.actionMasked) {
            MotionEvent.ACTION_BUTTON_PRESS -> sink(InputEvent.Pointer(InputEvent.ACTION_DOWN, mouseButton(event.actionButton), InputEvent.TOOL_MOUSE, x, y))
            MotionEvent.ACTION_BUTTON_RELEASE -> sink(InputEvent.Pointer(InputEvent.ACTION_UP, mouseButton(event.actionButton), InputEvent.TOOL_MOUSE, x, y))
            MotionEvent.ACTION_MOVE -> sink(InputEvent.Pointer(InputEvent.ACTION_MOVE, InputEvent.BUTTON_LEFT, InputEvent.TOOL_MOUSE, x, y))
        }
        return true
    }

    private fun mouseButton(button: Int) = when (button) {
        MotionEvent.BUTTON_SECONDARY -> InputEvent.BUTTON_RIGHT
        MotionEvent.BUTTON_TERTIARY -> InputEvent.BUTTON_MIDDLE
        else -> InputEvent.BUTTON_LEFT
    }

    private fun point(event: MotionEvent, index: Int) = TouchPoint(event.getX(index), event.getY(index))

    private fun points(event: MotionEvent) = (0 until event.pointerCount).map { point(event, it) }

    private fun nx(x: Float) = (x / width).coerceIn(0f, 1f)
    private fun ny(y: Float) = (y / height).coerceIn(0f, 1f)
}
