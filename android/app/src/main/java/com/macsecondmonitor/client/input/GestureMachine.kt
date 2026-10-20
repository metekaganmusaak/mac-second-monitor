package com.macsecondmonitor.client.input

import com.macsecondmonitor.client.protocol.InputEvent
import kotlin.math.hypot

/** Schedules delayed work; Android implementation uses a Handler, tests use a fake. */
interface Scheduler {
    fun schedule(delayMs: Long, task: () -> Unit): Any
    fun cancel(token: Any)
}

data class TouchPoint(val x: Float, val y: Float)

/**
 * Turns finger touches into mouse semantics (docs/PROTOCOL.md, "Recommended touch mapping"):
 * tap = click, drag after the slop = left drag, long press = right click, two-finger tap =
 * right click, two-finger drag = trackpad-style scroll with momentum, three-finger tap = menu.
 *
 * Coordinates are view pixels; [width] and [height] normalize them.
 */
class GestureMachine(
    private val sink: (InputEvent) -> Unit,
    private val scheduler: Scheduler,
    private val clock: () -> Long,
    private val slopPx: Float,
    private val onMenuRequested: () -> Unit = {},
    private val onLongPress: () -> Unit = {},
) {
    var width = 1f
    var height = 1f
    /** Touch-screen style: one finger scrolls instead of dragging. */
    var oneFingerScroll = false

    private enum class State { IDLE, PENDING, DRAGGING, SCROLLING_ONE, LONG_PRESSED, MULTI, DONE }

    private var state = State.IDLE
    private var down = TouchPoint(0f, 0f)
    private var downTime = 0L
    private var longPressToken: Any? = null

    // Multi-finger tracking.
    private var maxFingers = 0
    private var multiStart = TouchPoint(0f, 0f)
    private var multiStartTime = 0L
    private var lastCentroid = TouchPoint(0f, 0f)
    private var scrolling = false
    private val samples = ArrayDeque<Triple<Long, Float, Float>>()

    // Momentum.
    private var momentumToken: Any? = null
    private var velocityX = 0f
    private var velocityY = 0f
    private var momentumPoint = TouchPoint(0f, 0f)

    fun fingerDown(point: TouchPoint) {
        stopMomentum()
        state = State.PENDING
        down = point
        downTime = clock()
        maxFingers = 1
        // The cursor jumps to the finger right away, which is the visual feedback.
        pointer(InputEvent.ACTION_MOVE, InputEvent.BUTTON_LEFT, point)
        longPressToken = scheduler.schedule(LONG_PRESS_MS) { longPressFired() }
    }

    fun fingersChanged(points: List<TouchPoint>) {
        if (points.size < 2) return
        maxFingers = maxOf(maxFingers, points.size)
        when (state) {
            State.PENDING, State.IDLE -> {
                cancelLongPress()
                beginMulti(points)
            }
            State.DRAGGING -> {
                pointer(InputEvent.ACTION_UP, InputEvent.BUTTON_LEFT, points.first())
                beginMulti(points)
            }
            State.SCROLLING_ONE -> {
                scroll(InputEvent.PHASE_ENDED, points.first(), 0f, 0f)
                beginMulti(points)
            }
            State.MULTI -> {
                // Restart tracking so adding a finger doesn't jump the centroid.
                lastCentroid = centroid(points)
                samples.clear()
            }
            State.LONG_PRESSED, State.DONE -> state = State.DONE
        }
    }

    fun move(points: List<TouchPoint>) {
        when (state) {
            State.PENDING -> {
                val point = points.first()
                if (distance(point, down) <= slopPx) return
                cancelLongPress()
                if (oneFingerScroll) {
                    state = State.SCROLLING_ONE
                    lastCentroid = down
                    samples.clear()
                    scrollBy(point, InputEvent.PHASE_BEGAN)
                } else {
                    state = State.DRAGGING
                    pointer(InputEvent.ACTION_DOWN, InputEvent.BUTTON_LEFT, down)
                    pointer(InputEvent.ACTION_MOVE, InputEvent.BUTTON_LEFT, point)
                }
            }
            State.DRAGGING -> pointer(InputEvent.ACTION_MOVE, InputEvent.BUTTON_LEFT, points.first())
            State.SCROLLING_ONE -> scrollBy(points.first(), InputEvent.PHASE_CHANGED)
            State.MULTI -> {
                if (points.size < 2) return
                val center = centroid(points)
                if (!scrolling) {
                    if (distance(center, multiStart) <= slopPx) return
                    scrolling = true
                    scrollBy(center, InputEvent.PHASE_BEGAN)
                } else {
                    scrollBy(center, InputEvent.PHASE_CHANGED)
                }
            }
            else -> Unit
        }
    }

    /** A finger lifted; [remaining] are the fingers still down. */
    fun fingerUp(lifted: TouchPoint, remaining: List<TouchPoint>) {
        when (state) {
            State.PENDING -> if (remaining.isEmpty()) {
                cancelLongPress()
                pointer(InputEvent.ACTION_DOWN, InputEvent.BUTTON_LEFT, down)
                pointer(InputEvent.ACTION_UP, InputEvent.BUTTON_LEFT, down)
                state = State.IDLE
            }
            State.DRAGGING -> if (remaining.isEmpty()) {
                pointer(InputEvent.ACTION_UP, InputEvent.BUTTON_LEFT, lifted)
                state = State.IDLE
            }
            State.SCROLLING_ONE -> if (remaining.isEmpty()) {
                endScroll(lifted)
                state = State.IDLE
            }
            State.MULTI -> {
                if (scrolling) {
                    endScroll(lastCentroid)
                } else if (clock() - multiStartTime <= MULTI_TAP_MS) {
                    if (maxFingers >= 3) {
                        onMenuRequested()
                    } else {
                        pointer(InputEvent.ACTION_MOVE, InputEvent.BUTTON_RIGHT, multiStart)
                        pointer(InputEvent.ACTION_DOWN, InputEvent.BUTTON_RIGHT, multiStart)
                        pointer(InputEvent.ACTION_UP, InputEvent.BUTTON_RIGHT, multiStart)
                    }
                }
                state = if (remaining.isEmpty()) State.IDLE else State.DONE
            }
            State.LONG_PRESSED, State.DONE -> if (remaining.isEmpty()) state = State.IDLE
            State.IDLE -> Unit
        }
    }

    fun cancel() {
        cancelLongPress()
        when {
            state == State.DRAGGING -> pointer(InputEvent.ACTION_CANCEL, InputEvent.BUTTON_LEFT, down)
            state == State.SCROLLING_ONE || (state == State.MULTI && scrolling) -> scroll(InputEvent.PHASE_ENDED, lastCentroid, 0f, 0f)
        }
        state = State.IDLE
    }

    private fun longPressFired() {
        longPressToken = null
        if (state != State.PENDING) return
        state = State.LONG_PRESSED
        onLongPress()
        pointer(InputEvent.ACTION_DOWN, InputEvent.BUTTON_RIGHT, down)
        pointer(InputEvent.ACTION_UP, InputEvent.BUTTON_RIGHT, down)
    }

    private fun beginMulti(points: List<TouchPoint>) {
        state = State.MULTI
        scrolling = false
        multiStart = centroid(points)
        multiStartTime = clock()
        lastCentroid = multiStart
        samples.clear()
    }

    private fun scrollBy(point: TouchPoint, phase: Int) {
        val dx = point.x - lastCentroid.x
        val dy = point.y - lastCentroid.y
        lastCentroid = point
        val now = clock()
        samples.addLast(Triple(now, point.x, point.y))
        while (samples.size > 2 && now - samples.first().first > VELOCITY_WINDOW_MS) samples.removeFirst()
        scroll(phase, point, dx, dy)
    }

    private fun endScroll(point: TouchPoint) {
        scroll(InputEvent.PHASE_ENDED, point, 0f, 0f)
        val first = samples.firstOrNull()
        val last = samples.lastOrNull()
        samples.clear()
        if (first == null || last == null) return
        val dt = (last.first - first.first).coerceAtLeast(1)
        // Finger lifted after pausing: no fling.
        if (clock() - last.first > VELOCITY_WINDOW_MS) return
        velocityX = (last.second - first.second) / dt * 1000f
        velocityY = (last.third - first.third) / dt * 1000f
        if (hypot(velocityX, velocityY) < MIN_FLING_VELOCITY) return
        momentumPoint = point
        momentumToken = scheduler.schedule(FRAME_MS) { momentumStep() }
    }

    private fun momentumStep() {
        momentumToken = null
        velocityX *= FRICTION_PER_FRAME
        velocityY *= FRICTION_PER_FRAME
        if (hypot(velocityX, velocityY) < MIN_MOMENTUM_VELOCITY) {
            scroll(InputEvent.PHASE_MOMENTUM_ENDED, momentumPoint, 0f, 0f)
            return
        }
        scroll(InputEvent.PHASE_MOMENTUM, momentumPoint, velocityX * FRAME_MS / 1000f, velocityY * FRAME_MS / 1000f)
        momentumToken = scheduler.schedule(FRAME_MS) { momentumStep() }
    }

    private fun stopMomentum() {
        val token = momentumToken ?: return
        scheduler.cancel(token)
        momentumToken = null
        scroll(InputEvent.PHASE_MOMENTUM_ENDED, momentumPoint, 0f, 0f)
    }

    private fun cancelLongPress() {
        longPressToken?.let(scheduler::cancel)
        longPressToken = null
    }

    private fun pointer(action: Int, button: Int, point: TouchPoint) {
        sink(InputEvent.Pointer(action, button, InputEvent.TOOL_FINGER, nx(point.x), ny(point.y)))
    }

    private fun scroll(phase: Int, point: TouchPoint, dxPx: Float, dyPx: Float) {
        sink(InputEvent.Scroll(phase, InputEvent.UNIT_NORMALIZED, nx(point.x), ny(point.y), dxPx / width, dyPx / height))
    }

    private fun nx(x: Float) = (x / width).coerceIn(0f, 1f)
    private fun ny(y: Float) = (y / height).coerceIn(0f, 1f)

    private fun centroid(points: List<TouchPoint>) = TouchPoint(points.sumOf { it.x.toDouble() }.toFloat() / points.size, points.sumOf { it.y.toDouble() }.toFloat() / points.size)

    private fun distance(a: TouchPoint, b: TouchPoint) = hypot(a.x - b.x, a.y - b.y)

    companion object {
        const val LONG_PRESS_MS = 500L
        const val MULTI_TAP_MS = 300L
        const val FRAME_MS = 16L
        const val VELOCITY_WINDOW_MS = 100L
        const val MIN_FLING_VELOCITY = 400f
        const val MIN_MOMENTUM_VELOCITY = 40f
        const val FRICTION_PER_FRAME = 0.95f
    }
}
