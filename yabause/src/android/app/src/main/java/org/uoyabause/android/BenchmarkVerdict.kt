package org.uoyabause.android

/**
 * Turns measured benchmark results into setting values.
 *
 * Each disc walks the ladder of configurations it can decide (see
 * [BenchmarkLadder]) and the device's setting for that axis is the most
 * expensive rung it still ran at full speed. There is no tuned threshold in
 * here: what "fast enough" means is 60fps, and what the candidate values are is
 * fixed by the ladder, so nothing needs calibrating against a fleet of devices.
 *
 * This is a pure object with no Android dependency so that the rules can be
 * pinned by JVM tests.
 */
object BenchmarkVerdict {
    /** RBG resolution "Native". Not defined in RecommendedSettings, which only names the safe side. */
    const val RBG_NATIVE = "4"

    /**
     * Real hardware runs at 60fps, so a configuration that holds it is one the
     * device emulates at full speed. Measured with the frame limiter off.
     *
     * 59, not 60: the frame limiter being off does not free presentation from the
     * display. On Android even the no-wait present mode throttles to a multiple of
     * the refresh rate, so a level that just keeps up snaps to exactly 60 and
     * measures 59.9x or 60.0x run to run. A threshold of 60 decided those levels
     * by noise (Retroid Pocket Classic, VDP2 NBG at 2x: FAIL at 59.9x, PASS at
     * 60.0 on the same build).
     */
    const val TARGET_FPS = 59.0

    /**
     * True when every measured level held [TARGET_FPS].
     *
     * All levels, not the heaviest passing one: a rung is a configuration the
     * user would then play every game with, so a level that drops below 60fps is
     * a game that stutters. A run with no measurements at all never passes -
     * absence of evidence is not evidence the device is fast.
     */
    fun passed(levelFps: Map<Int, Double>): Boolean =
        levelFps.isNotEmpty() && levelFps.values.all { it >= TARGET_FPS }

    /**
     * How close to the perspective-corrected triangle path GPU tessellation has
     * to stay, per level, for OpenGL to take it.
     *
     * Not 1.0: the two runs are measured back to back, and the second one runs
     * on a device the first one has already heated up, so an equal renderer
     * measures a few percent slower. Tessellation runs second on purpose - the
     * drift works against it, never for it.
     */
    const val OPENGL_TESSELLATION_MIN_RATIO = 0.9

    /**
     * The per-level fps the OpenGL tessellation run has to hold, indexed by level.
     *
     * Handed to the emulator so the run ends at the first level that already
     * decides against tessellation, instead of sitting through the rest of a cycle
     * on exactly the devices that are slowest to measure.
     */
    fun tessellationFloor(triangleFps: Map<Int, Double>): DoubleArray {
        val floor = DoubleArray((triangleFps.keys.maxOrNull() ?: 0) + 1)
        triangleFps.forEach { (level, fps) -> floor[level] = fps * OPENGL_TESSELLATION_MIN_RATIO }
        return floor
    }

    /**
     * The polygon path an OpenGL device should use, from its two VDP1 runs.
     *
     * GPU tessellation is the preferred path, so it wins whenever it costs
     * little: it has to reach every level the triangle run measured, each at no
     * less than [OPENGL_TESSELLATION_MIN_RATIO] of the triangle fps. The disc's
     * levels are not monotonic (they switch between command throughput, draw
     * modes and fill rate), so every level is compared rather than a summary.
     *
     * A level missing from the tessellation run is a level it did not hold - the
     * run stops at the first level under its floor - and a triangle run with no
     * levels is nothing to compare against. Both keep the triangle path.
     */
    fun openGlPolygon(
        triangleFps: Map<Int, Double>,
        tessellationFps: Map<Int, Double>,
    ): String {
        if (triangleFps.isEmpty()) return RecommendedSettings.POLYGON_TRIANGLE
        val holds =
            triangleFps.all { (level, fps) ->
                val tessellation = tessellationFps[level] ?: return@all false
                tessellation >= fps * OPENGL_TESSELLATION_MIN_RATIO
            }
        return if (holds) RecommendedSettings.POLYGON_GPU_TESSELLATION else RecommendedSettings.POLYGON_TRIANGLE
    }

    fun toProfile(
        key: String,
        name: String,
        outcome: BenchmarkOutcome,
    ) = GpuProfile(
        key = key,
        name = name,
        videoCore = outcome.videoCore,
        polygonGeneration = outcome.polygonGeneration,
        useComputeShader = outcome.useComputeShader,
        vdp2Composite = outcome.vdp2Composite,
        rbgResolution = outcome.rbgResolution,
        source = GpuProfile.SOURCE_MEASURED,
        resolution = outcome.resolution,
    )
}
