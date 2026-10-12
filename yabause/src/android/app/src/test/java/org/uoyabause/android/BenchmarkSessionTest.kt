package org.uoyabause.android

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class BenchmarkSessionTest {
    private val ms = 1_000_000L

    private fun status(
        level: Int,
        frame: Long,
        levelCount: Int = 3,
    ) = BenchmarkStatus(disc = 1, level = level, levelCount = levelCount, frame = frame)

    @Test
    fun `level one is discarded because startup pollutes it`() {
        val session = BenchmarkSession()
        session.onSample(status(1, 0), 0)
        session.onSample(status(1, 299), 5000 * ms)
        session.onSample(status(2, 300), 5001 * ms)
        assertTrue(session.levelFps.isEmpty())
    }

    @Test
    fun `a completed level window becomes fps`() {
        val session = BenchmarkSession()
        session.onSample(status(1, 0), 0)
        // LV02 starts at frame 300 and ends at frame 600, taking 5 seconds:
        // 300 frames / 5 s = 60 fps.
        session.onSample(status(2, 300), 1000 * ms)
        session.onSample(status(3, 600), 6000 * ms)
        assertEquals(60.0, session.levelFps[2]!!, 0.01)
    }

    @Test
    fun `the run completes when the level wraps back to one`() {
        val session = BenchmarkSession()
        session.onSample(status(1, 0), 0)
        session.onSample(status(2, 300), 1000 * ms)
        session.onSample(status(3, 600), 3000 * ms)
        assertFalse(session.isComplete)
        session.onSample(status(1, 900), 5000 * ms)
        assertTrue(session.isComplete)
        assertEquals(setOf(2, 3), session.levelFps.keys)
    }

    @Test
    fun `a stalled frame counter is detected`() {
        val session = BenchmarkSession()
        session.onSample(status(2, 300), 0)
        assertFalse(session.isStalled(4000 * ms))
        assertTrue(session.isStalled(6000 * ms))
    }

    @Test
    fun `a advancing frame counter is not stalled`() {
        val session = BenchmarkSession()
        session.onSample(status(2, 300), 0)
        session.onSample(status(2, 360), 4000 * ms)
        assertFalse(session.isStalled(7000 * ms))
    }

    @Test
    fun `a fresh session is never stalled before the first sample`() {
        val session = BenchmarkSession()
        assertFalse(session.isStalled(0))
        assertFalse(session.isStalled(6000 * ms))
        assertFalse(session.isStalled(Long.MAX_VALUE))
    }

    @Test
    fun `a level under sixty fps ends a normal run`() {
        val session = BenchmarkSession()
        session.onSample(status(1, 0), 0)
        session.onSample(status(2, 300), 1000 * ms)
        // 300 frames in 6 s = 50 fps.
        session.onSample(status(3, 600), 7000 * ms)
        assertTrue(session.hasSlowLevel)
    }

    @Test
    fun `an empty floor measures the whole cycle however slow it is`() {
        val session = BenchmarkSession(levelFpsFloor = DoubleArray(0))
        session.onSample(status(1, 0), 0)
        session.onSample(status(2, 300), 1000 * ms)
        session.onSample(status(3, 600), 21000 * ms)
        assertFalse(session.hasSlowLevel)
        session.onSample(status(1, 900), 41000 * ms)
        assertTrue(session.isComplete)
        assertEquals(15.0, session.levelFps[2]!!, 0.01)
    }

    @Test
    fun `a per-level floor ends the run at the first level under it`() {
        val floor = DoubleArray(4).also {
            it[2] = 20.0
            it[3] = 40.0
        }
        val session = BenchmarkSession(levelFpsFloor = floor)
        session.onSample(status(1, 0), 0)
        session.onSample(status(2, 300), 1000 * ms)
        // LV02: 300 frames / 10 s = 30 fps, above its floor of 20.
        session.onSample(status(3, 600), 11000 * ms)
        assertFalse(session.hasSlowLevel)
        // LV03: 30 fps, under its floor of 40.
        session.onSample(status(1, 900), 21000 * ms)
        assertTrue(session.hasSlowLevel)
    }
}
