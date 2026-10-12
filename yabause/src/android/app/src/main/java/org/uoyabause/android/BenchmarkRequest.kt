package org.uoyabause.android

import android.content.Context
import android.content.Intent

/**
 * Launches the emulator in benchmark mode and carries the measurement back.
 *
 * Benchmark mode differs from a normal launch in three ways: the graphics
 * configuration comes from the intent instead of the preferences, the frame
 * limiter is off (otherwise every level sits at 60fps and nothing is measured),
 * and the activity finishes itself once the run has been decided - either by a
 * full level cycle or by the first level that fell short of its floor
 * ([BenchmarkVerdict.TARGET_FPS] unless the request says otherwise).
 */
object BenchmarkRequest {
    const val EXTRA_BENCHMARK_DISC = "org.uoyabause.android.BenchmarkDisc"
    const val EXTRA_LEVEL_FPS = "org.uoyabause.android.BenchmarkLevelFps"

    /**
     * The fps each level has to hold, indexed by level (see [BenchmarkSession]).
     * Absent for a ladder rung, which is held to [BenchmarkVerdict.TARGET_FPS] on every level.
     */
    const val EXTRA_LEVEL_FPS_FLOOR = "org.uoyabause.android.BenchmarkLevelFpsFloor"

    /** True when every measured level held [BenchmarkVerdict.TARGET_FPS]. */
    const val EXTRA_PASSED = "org.uoyabause.android.BenchmarkPassed"

    /**
     * Why the run ended, one of the REASON_ values below. Carried on both result
     * codes: a cancelled sweep is otherwise indistinguishable from a crash, and on
     * devices whose ROM drops non-error logs there is no other way to find out.
     */
    const val EXTRA_END_REASON = "org.uoyabause.android.BenchmarkEndReason"

    /** One full level cycle was measured. */
    const val REASON_CYCLE = "cycle"

    /** A level came in under its floor, which already decides the rung. */
    const val REASON_SLOW = "slow"

    /** The guest's own frame counter stopped advancing. */
    const val REASON_STALL = "stall"

    /** The ROM never reached its main loop. */
    const val REASON_NOT_READY = "not-ready"

    /** The activity was paused before the run was decided. */
    const val REASON_PAUSED = "paused"

    // The rung under test. Passed as separate extras rather than a parcelable so
    // that the emulator activity can apply them without knowing about the ladder.
    const val EXTRA_VIDEO_CORE = "org.uoyabause.android.BenchmarkVideoCore"
    const val EXTRA_POLYGON_GENERATION = "org.uoyabause.android.BenchmarkPolygonGeneration"
    const val EXTRA_COMPUTE_SHADER = "org.uoyabause.android.BenchmarkComputeShader"
    const val EXTRA_VDP2_COMPOSITE = "org.uoyabause.android.BenchmarkVdp2Composite"
    const val EXTRA_RBG_RESOLUTION = "org.uoyabause.android.BenchmarkRbgResolution"
    const val EXTRA_RESOLUTION = "org.uoyabause.android.BenchmarkResolution"

    fun intent(
        context: Context,
        cuePath: String,
        disc: BenchmarkDisc,
        rung: BenchmarkRung,
        levelFpsFloor: DoubleArray? = null,
    ): Intent =
        Intent(context, Yabause::class.java).apply {
            levelFpsFloor?.let { putExtra(EXTRA_LEVEL_FPS_FLOOR, it) }
            putExtra("org.uoyabause.android.FileNameEx", cuePath)
            putExtra("org.uoyabause.android.gamecode", disc.gameCode)
            putExtra(EXTRA_BENCHMARK_DISC, disc.id)
            putExtra(EXTRA_VIDEO_CORE, rung.videoCore)
            putExtra(EXTRA_POLYGON_GENERATION, rung.polygonGeneration)
            putExtra(EXTRA_COMPUTE_SHADER, rung.useComputeShader)
            putExtra(EXTRA_VDP2_COMPOSITE, rung.vdp2Composite)
            putExtra(EXTRA_RBG_RESOLUTION, rung.rbgResolution)
            putExtra(EXTRA_RESOLUTION, rung.resolution)
        }
}
