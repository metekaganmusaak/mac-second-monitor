package com.macsecondmonitor.client.input

import com.macsecondmonitor.client.protocol.InputEvent
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

class GestureMachineTest {
    private val events = mutableListOf<InputEvent>()
    private var now = 0L
    private val tasks = mutableListOf<Pair<Long, () -> Unit>>()
    private var menuRequests = 0
    private lateinit var machine: GestureMachine

    private val scheduler = object : Scheduler {
        override fun schedule(delayMs: Long, task: () -> Unit): Any {
            val entry = (now + delayMs) to task
            tasks += entry
            return entry
        }

        override fun cancel(token: Any) {
            tasks.remove(token)
        }
    }

    @Before
    fun setUp() {
        machine = GestureMachine({ events += it }, scheduler, { now }, slopPx = 10f, onMenuRequested = { menuRequests++ })
        machine.width = 1000f
        machine.height = 500f
    }

    private fun advance(ms: Long) {
        val target = now + ms
        while (true) {
            val next = tasks.filter { it.first <= target }.minByOrNull { it.first } ?: break
            tasks.remove(next)
            now = next.first
            next.second()
        }
        now = target
    }

    private fun pointers() = events.filterIsInstance<InputEvent.Pointer>()
    private fun scrolls() = events.filterIsInstance<InputEvent.Scroll>()

    @Test
    fun tapClicksAtTouchDown() {
        machine.fingerDown(TouchPoint(500f, 250f))
        advance(80)
        machine.move(listOf(TouchPoint(503f, 251f)))
        machine.fingerUp(TouchPoint(503f, 251f), emptyList())
        val actions = pointers().map { it.action to it.button }
        assertEquals(listOf(InputEvent.ACTION_MOVE to 0, InputEvent.ACTION_DOWN to 0, InputEvent.ACTION_UP to 0), actions)
        assertEquals(0.5f, pointers()[1].x)
        assertEquals(0.5f, pointers()[2].y)
    }

    @Test
    fun dragStartsAfterSlop() {
        machine.fingerDown(TouchPoint(100f, 100f))
        machine.move(listOf(TouchPoint(105f, 100f)))
        assertEquals(1, pointers().size)
        machine.move(listOf(TouchPoint(150f, 100f)))
        machine.move(listOf(TouchPoint(200f, 100f)))
        machine.fingerUp(TouchPoint(200f, 100f), emptyList())
        val actions = pointers().map { it.action }
        assertEquals(listOf(InputEvent.ACTION_MOVE, InputEvent.ACTION_DOWN, InputEvent.ACTION_MOVE, InputEvent.ACTION_MOVE, InputEvent.ACTION_UP), actions)
        assertEquals(0.1f, pointers()[1].x)
    }

    @Test
    fun longPressRightClicks() {
        machine.fingerDown(TouchPoint(100f, 100f))
        advance(GestureMachine.LONG_PRESS_MS + 10)
        machine.fingerUp(TouchPoint(100f, 100f), emptyList())
        val rights = pointers().filter { it.button == InputEvent.BUTTON_RIGHT }.map { it.action }
        assertEquals(listOf(InputEvent.ACTION_DOWN, InputEvent.ACTION_UP), rights)
        assertTrue(pointers().none { it.button == InputEvent.BUTTON_LEFT && it.action == InputEvent.ACTION_DOWN })
    }

    @Test
    fun twoFingerTapRightClicks() {
        machine.fingerDown(TouchPoint(100f, 100f))
        machine.fingersChanged(listOf(TouchPoint(100f, 100f), TouchPoint(200f, 100f)))
        advance(100)
        machine.fingerUp(TouchPoint(200f, 100f), listOf(TouchPoint(100f, 100f)))
        machine.fingerUp(TouchPoint(100f, 100f), emptyList())
        val rights = pointers().filter { it.button == InputEvent.BUTTON_RIGHT }.map { it.action }
        assertEquals(listOf(InputEvent.ACTION_MOVE, InputEvent.ACTION_DOWN, InputEvent.ACTION_UP), rights)
        assertEquals(0.15f, pointers().last().x)
        advance(1000)
        assertTrue("no long press after a two-finger tap", pointers().count { it.button == InputEvent.BUTTON_RIGHT } == 3)
    }

    @Test
    fun twoFingerDragScrollsWithMomentum() {
        machine.fingerDown(TouchPoint(100f, 100f))
        machine.fingersChanged(listOf(TouchPoint(100f, 100f), TouchPoint(200f, 100f)))
        for (step in 1..6) {
            advance(16)
            machine.move(listOf(TouchPoint(100f, 100f + step * 20), TouchPoint(200f, 100f + step * 20)))
        }
        machine.fingerUp(TouchPoint(200f, 220f), listOf(TouchPoint(100f, 220f)))
        val phases = scrolls().map { it.phase }
        assertEquals(InputEvent.PHASE_BEGAN, phases.first())
        assertEquals(InputEvent.PHASE_ENDED, phases.last())
        // Finger moved down: content moves down → positive dy.
        assertTrue(scrolls().filter { it.phase == InputEvent.PHASE_CHANGED }.all { it.dy > 0 })
        val total = scrolls().sumOf { it.dy.toDouble() } * 500
        assertEquals(120.0, total, 0.5)

        advance(3000)
        val momentum = scrolls().map { it.phase }.filter { it >= InputEvent.PHASE_MOMENTUM }
        assertTrue(momentum.size > 3)
        assertEquals(InputEvent.PHASE_MOMENTUM_ENDED, momentum.last())
    }

    @Test
    fun threeFingerTapOpensMenu() {
        machine.fingerDown(TouchPoint(100f, 100f))
        machine.fingersChanged(listOf(TouchPoint(100f, 100f), TouchPoint(200f, 100f)))
        machine.fingersChanged(listOf(TouchPoint(100f, 100f), TouchPoint(200f, 100f), TouchPoint(300f, 100f)))
        machine.fingerUp(TouchPoint(300f, 100f), listOf(TouchPoint(100f, 100f), TouchPoint(200f, 100f)))
        assertEquals(1, menuRequests)
        assertTrue(pointers().none { it.button == InputEvent.BUTTON_RIGHT })
    }

    @Test
    fun oneFingerScrollMode() {
        machine.oneFingerScroll = true
        machine.fingerDown(TouchPoint(100f, 300f))
        machine.move(listOf(TouchPoint(100f, 250f)))
        machine.move(listOf(TouchPoint(100f, 200f)))
        advance(200)
        machine.fingerUp(TouchPoint(100f, 200f), emptyList())
        assertTrue(pointers().none { it.action == InputEvent.ACTION_DOWN })
        assertEquals(listOf(InputEvent.PHASE_BEGAN, InputEvent.PHASE_CHANGED, InputEvent.PHASE_ENDED), scrolls().map { it.phase })
        assertTrue(scrolls()[1].dy < 0)
    }
}
