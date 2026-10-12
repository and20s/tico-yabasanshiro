package org.uoyabause.android

/**
 * Accumulates one benchmark run from status-block samples.
 *
 * Holds no clock of its own: the caller passes a monotonic timestamp with every
 * sample, so the whole measurement rule can be pinned by JVM tests. A level
 * window is closed when the ROM reports a different level, and the run ends when
 * the level wraps back to 1 - the discs cycle forever, so nothing else marks the
 * end.
 *
 * Level 1 is deliberately dropped: the emulator compiles shaders during the first
 * moments after launch, which inflates that window's wall time. Level 1 is also
 * the lightest level, so dropping it costs almost nothing - a device that cannot
 * hold it is at the bottom of the scale either way.
 */
class BenchmarkSession(
    /**
     * The fps each level has to hold, indexed by level, or null for the normal
     * [BenchmarkVerdict.TARGET_FPS] on every level. A level beyond the array's end
     * has no floor, so an empty array measures the whole cycle however slow it is.
     */
    private val levelFpsFloor: DoubleArray? = null,
) {
    private val fps = mutableMapOf<Int, Double>()

    private var currentLevel = 0
    private var levelStartFrame = 0L
    private var levelStartNanos = 0L

    private var lastFrame = -1L
    private var lastProgressNanos = 0L
    private var hasSample = false

    // Written by the polling coroutine, read by the activity on the main thread
    // when it decides whether a run still needs cancelling. A stale read there
    // would cancel a run that had just completed, so publish it.
    @Volatile
    var isComplete: Boolean = false
        private set

    /**
     * True once a completed level window came in under its floor - by default
     * [BenchmarkVerdict.TARGET_FPS].
     *
     * A rung passes only when every level holds its floor, so the first level that
     * does not settles the run: there is nothing left to learn from the remaining
     * levels. The caller ends the run here rather than sitting through the rest,
     * which matters because a failing rung is exactly the slow one - measuring a
     * whole cycle at 15fps takes minutes.
     *
     * Published for the same reason as [isComplete]: written by the polling
     * coroutine, read by the activity.
     */
    @Volatile
    var hasSlowLevel: Boolean = false
        private set

    val levelFps: Map<Int, Double> get() = fps.toMap()

    fun onSample(
        status: BenchmarkStatus,
        elapsedNanos: Long,
    ) {
        if (isComplete || hasSlowLevel) return

        hasSample = true

        if (status.frame != lastFrame) {
            lastFrame = status.frame
            lastProgressNanos = elapsedNanos
        }

        if (status.level == currentLevel) return

        // The level just changed: close the window that ended, then open the new one.
        if (currentLevel >= LOWEST_MEASURED_LEVEL) {
            val frames = status.frame - levelStartFrame
            val nanos = elapsedNanos - levelStartNanos
            if (frames > 0 && nanos > 0) {
                val measured = frames.toDouble() * NANOS_PER_SECOND / nanos
                fps[currentLevel] = measured
                if (measured < floorOf(currentLevel)) hasSlowLevel = true
            }
        }

        if (currentLevel > status.level) {
            // Wrapped back to the first level: one full cycle is measured.
            isComplete = true
            return
        }

        currentLevel = status.level
        levelStartFrame = status.frame
        levelStartNanos = elapsedNanos
    }

    private fun floorOf(level: Int): Double {
        val floor = levelFpsFloor ?: return BenchmarkVerdict.TARGET_FPS
        return floor.getOrElse(level) { 0.0 }
    }

    /**
     * True when the ROM's own frame counter has not advanced for [STALL_TIMEOUT_NANOS].
     * The emulator can be alive while the guest is wedged, so the guest's counter is
     * the only honest progress signal. Before the first sample arrives - e.g. during
     * a slow BIOS boot, before the ROM has written its first status block - there is
     * no progress signal yet, so this reports false rather than a false stall.
     */
    fun isStalled(elapsedNanos: Long): Boolean = hasSample && elapsedNanos - lastProgressNanos > STALL_TIMEOUT_NANOS

    companion object {
        private const val LOWEST_MEASURED_LEVEL = 2
        private const val NANOS_PER_SECOND = 1_000_000_000.0

        // Provisional value. A level is 300 guest frames, i.e. 5 seconds of guest
        // time; five seconds without a single frame means the guest is wedged, not
        // slow. Calibrate after measuring several devices.
        private const val STALL_TIMEOUT_NANOS = 5_000_000_000L
    }
}
