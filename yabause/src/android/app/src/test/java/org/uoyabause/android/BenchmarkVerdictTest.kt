package org.uoyabause.android

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class BenchmarkVerdictTest {
    @Test
    fun `a rung passes only when every level held the target`() {
        assertTrue(BenchmarkVerdict.passed(mapOf(2 to 120.0, 3 to 59.0, 4 to 61.0)))
    }

    @Test
    fun `a level that snapped to the refresh rate passes either side of sixty`() {
        // Presentation snaps a level that just keeps up to exactly 60, which
        // measures 59.9x on one run and 60.0x on the next.
        assertTrue(BenchmarkVerdict.passed(mapOf(2 to 120.0, 3 to 59.97)))
        assertTrue(BenchmarkVerdict.passed(mapOf(2 to 120.0, 3 to 60.02)))
    }

    @Test
    fun `one slow level fails the rung even if the rest recovered`() {
        // The user plays every game with the chosen configuration, so a level that
        // drops below 60fps is a game that stutters - a later fast level does not
        // buy it back.
        assertFalse(BenchmarkVerdict.passed(mapOf(2 to 120.0, 3 to 58.9, 4 to 80.0)))
    }

    @Test
    fun `an empty measurement never passes`() {
        assertFalse(BenchmarkVerdict.passed(emptyMap()))
    }

    @Test
    fun `a measured profile records the whole outcome and its source`() {
        val outcome =
            BenchmarkOutcome(
                videoCore = VideoCore.VULKAN,
                polygonGeneration = RecommendedSettings.POLYGON_GPU_TESSELLATION,
                useComputeShader = true,
                vdp2Composite = Vdp2Composite.VALUE_NEW,
                rbgResolution = BenchmarkVerdict.RBG_NATIVE,
                resolution = RecommendedSettings.RESOLUTION_2X,
            )
        val profile = BenchmarkVerdict.toProfile("vk:5143:6050002", "Adreno 650", outcome)
        assertEquals("vk:5143:6050002", profile.key)
        assertEquals("Adreno 650", profile.name)
        assertEquals(GpuProfile.SOURCE_MEASURED, profile.source)
        assertEquals(VideoCore.VULKAN, profile.videoCore)
        assertEquals(RecommendedSettings.POLYGON_GPU_TESSELLATION, profile.polygonGeneration)
        assertTrue(profile.useComputeShader)
        assertEquals(Vdp2Composite.VALUE_NEW, profile.vdp2Composite)
        assertEquals(BenchmarkVerdict.RBG_NATIVE, profile.rbgResolution)
        assertEquals(RecommendedSettings.RESOLUTION_2X, profile.resolution)
    }

    private val triangle = mapOf(2 to 50.0, 3 to 40.0, 4 to 80.0)

    @Test
    fun `tessellation within ninety percent on every level is chosen`() {
        assertEquals(
            RecommendedSettings.POLYGON_GPU_TESSELLATION,
            BenchmarkVerdict.openGlPolygon(triangle, mapOf(2 to 45.0, 3 to 36.0, 4 to 90.0)),
        )
    }

    @Test
    fun `one level below ninety percent keeps perspective correction`() {
        assertEquals(
            RecommendedSettings.POLYGON_TRIANGLE,
            BenchmarkVerdict.openGlPolygon(triangle, mapOf(2 to 60.0, 3 to 35.9, 4 to 90.0)),
        )
    }

    @Test
    fun `a tessellation run that did not reach every level keeps perspective correction`() {
        // The tessellation run stops at the first level under its floor, so a
        // missing level is a level it did not hold - never a level to skip.
        assertEquals(
            RecommendedSettings.POLYGON_TRIANGLE,
            BenchmarkVerdict.openGlPolygon(triangle, mapOf(2 to 50.0, 3 to 40.0)),
        )
    }

    @Test
    fun `without a triangle reference there is nothing to compare against`() {
        assertEquals(
            RecommendedSettings.POLYGON_TRIANGLE,
            BenchmarkVerdict.openGlPolygon(emptyMap(), mapOf(2 to 50.0)),
        )
    }

    @Test
    fun `the tessellation floor is ninety percent of the triangle run, indexed by level`() {
        val floor = BenchmarkVerdict.tessellationFloor(triangle)
        assertEquals(5, floor.size)
        assertEquals(0.0, floor[1], 0.0)
        assertEquals(45.0, floor[2], 1e-9)
        assertEquals(36.0, floor[3], 1e-9)
        assertEquals(72.0, floor[4], 1e-9)
    }
}
