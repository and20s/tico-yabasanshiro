package org.uoyabause.android

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class BenchmarkLadderTest {
    private val native = RecommendedSettings.RESOLUTION_NATIVE
    private val twoX = RecommendedSettings.RESOLUTION_2X

    private fun rung(
        discId: Int,
        label: String,
        resolution: String = native,
    ) = BenchmarkLadder.forDisc(discId, resolution).single { it.label == label }

    private val gl = BenchmarkLadder.OPENGL_FLOOR

    @Test
    fun `NBG is measured first because it decides the resolution`() {
        assertEquals(
            listOf(BenchmarkLadder.DISC_VDP2_NBG, BenchmarkLadder.DISC_VDP2_RBG, BenchmarkLadder.DISC_VDP1),
            BenchmarkLadder.SWEEP_ORDER,
        )
    }

    @Test
    fun `the NBG ladder is per-pixel native, fast native, fast 2x`() {
        val nbg = BenchmarkLadder.forDisc(BenchmarkLadder.DISC_VDP2_NBG, native).reversed()
        assertEquals(
            listOf(Vdp2Composite.VALUE_NEW, Vdp2Composite.VALUE_LEGACY, Vdp2Composite.VALUE_LEGACY),
            nbg.map { it.vdp2Composite },
        )
        assertEquals(listOf(native, native, twoX), nbg.map { it.resolution })
        assertTrue(nbg.all { it.videoCore == VideoCore.VULKAN })
    }

    @Test
    fun `the NBG ladder ignores the resolution it is given`() {
        assertEquals(
            BenchmarkLadder.forDisc(BenchmarkLadder.DISC_VDP2_NBG, native),
            BenchmarkLadder.forDisc(BenchmarkLadder.DISC_VDP2_NBG, twoX),
        )
    }

    @Test
    fun `RBG and VDP1 run at the resolution NBG settled on`() {
        listOf(BenchmarkLadder.DISC_VDP2_RBG, BenchmarkLadder.DISC_VDP1).forEach { disc ->
            assertTrue(BenchmarkLadder.forDisc(disc, twoX).all { it.resolution == twoX })
        }
    }

    @Test
    fun `the RBG ladder is compute native then compute 2x`() {
        val rbg = BenchmarkLadder.forDisc(BenchmarkLadder.DISC_VDP2_RBG, native).reversed()
        assertEquals(
            listOf(BenchmarkVerdict.RBG_NATIVE, RecommendedSettings.RBG_2X),
            rbg.map { it.rbgResolution },
        )
        assertTrue(rbg.all { it.useComputeShader })
    }

    @Test
    fun `the VDP1 ladder is compute rasterizer then tessellation`() {
        assertEquals(
            listOf(RecommendedSettings.POLYGON_COMPUTE_RASTERIZER, RecommendedSettings.POLYGON_GPU_TESSELLATION),
            BenchmarkLadder.forDisc(BenchmarkLadder.DISC_VDP1, native).reversed().map { it.polygonGeneration },
        )
    }

    @Test
    fun `the resolution is the NBG rung's, or native once NBG is OpenGL`() {
        assertEquals(native, BenchmarkLadder.resolutionOf(emptyMap()))
        assertEquals(
            twoX,
            BenchmarkLadder.resolutionOf(
                mapOf(BenchmarkLadder.DISC_VDP2_NBG to rung(BenchmarkLadder.DISC_VDP2_NBG, "vk-legacy-composite@2x")),
            ),
        )
        assertEquals(native, BenchmarkLadder.resolutionOf(mapOf(BenchmarkLadder.DISC_VDP2_NBG to gl)))
    }

    @Test
    fun `nothing is measured on Vulkan without Vulkan`() {
        BenchmarkLadder.SWEEP_ORDER.forEach {
            assertFalse(BenchmarkLadder.measuresOnVulkan(it, emptyMap(), vulkanUsable = false))
        }
    }

    @Test
    fun `an OpenGL disc stops every later disc from being measured on Vulkan`() {
        val nbgOnGl = mapOf(BenchmarkLadder.DISC_VDP2_NBG to gl)
        assertFalse(BenchmarkLadder.measuresOnVulkan(BenchmarkLadder.DISC_VDP2_RBG, nbgOnGl, true))
        assertFalse(BenchmarkLadder.measuresOnVulkan(BenchmarkLadder.DISC_VDP1, nbgOnGl, true))

        val rbgOnGl =
            mapOf(
                BenchmarkLadder.DISC_VDP2_NBG to rung(BenchmarkLadder.DISC_VDP2_NBG, "vk-legacy-composite"),
                BenchmarkLadder.DISC_VDP2_RBG to gl,
            )
        assertFalse(BenchmarkLadder.measuresOnVulkan(BenchmarkLadder.DISC_VDP1, rbgOnGl, true))
    }

    @Test
    fun `every disc is measured on Vulkan while the earlier ones held`() {
        assertTrue(BenchmarkLadder.measuresOnVulkan(BenchmarkLadder.DISC_VDP2_NBG, emptyMap(), true))
        val vdp2 =
            mapOf(
                BenchmarkLadder.DISC_VDP2_NBG to rung(BenchmarkLadder.DISC_VDP2_NBG, "vk-legacy-composite"),
                BenchmarkLadder.DISC_VDP2_RBG to rung(BenchmarkLadder.DISC_VDP2_RBG, "vk-rbg-2x"),
            )
        assertTrue(BenchmarkLadder.measuresOnVulkan(BenchmarkLadder.DISC_VDP1, vdp2, true))
    }

    @Test
    fun `OpenGL's polygon path is measured only when VDP2 went to OpenGL`() {
        val vdp2OnVulkan =
            mapOf(
                BenchmarkLadder.DISC_VDP2_NBG to rung(BenchmarkLadder.DISC_VDP2_NBG, "vk-legacy-composite"),
                BenchmarkLadder.DISC_VDP2_RBG to rung(BenchmarkLadder.DISC_VDP2_RBG, "vk-rbg-2x"),
            )
        assertFalse(BenchmarkLadder.measuresOpenGlPolygon(vdp2OnVulkan + (BenchmarkLadder.DISC_VDP1 to gl)))
        assertTrue(BenchmarkLadder.measuresOpenGlPolygon(vdp2OnVulkan + (BenchmarkLadder.DISC_VDP2_RBG to gl)))
        assertTrue(BenchmarkLadder.measuresOpenGlPolygon(mapOf(BenchmarkLadder.DISC_VDP2_NBG to gl)))
    }

    @Test
    fun `three Vulkan discs combine into one Vulkan configuration`() {
        val outcome =
            BenchmarkLadder.outcomeOf(
                mapOf(
                    BenchmarkLadder.DISC_VDP2_NBG to rung(BenchmarkLadder.DISC_VDP2_NBG, "vk-legacy-composite@2x"),
                    BenchmarkLadder.DISC_VDP2_RBG to rung(BenchmarkLadder.DISC_VDP2_RBG, "vk-rbg-native", twoX),
                    BenchmarkLadder.DISC_VDP1 to rung(BenchmarkLadder.DISC_VDP1, "vk-compute-rasterizer", twoX),
                ),
            )
        assertEquals(VideoCore.VULKAN, outcome.videoCore)
        assertEquals(RecommendedSettings.POLYGON_COMPUTE_RASTERIZER, outcome.polygonGeneration)
        assertEquals(Vdp2Composite.VALUE_LEGACY, outcome.vdp2Composite)
        assertEquals(BenchmarkVerdict.RBG_NATIVE, outcome.rbgResolution)
        assertEquals(twoX, outcome.resolution)
        assertTrue(outcome.useComputeShader)
    }

    @Test
    fun `one OpenGL disc makes the device OpenGL at the NBG resolution`() {
        val outcome =
            BenchmarkLadder.outcomeOf(
                mapOf(
                    BenchmarkLadder.DISC_VDP2_NBG to rung(BenchmarkLadder.DISC_VDP2_NBG, "vk-legacy-composite@2x"),
                    BenchmarkLadder.DISC_VDP2_RBG to rung(BenchmarkLadder.DISC_VDP2_RBG, "vk-rbg-2x", twoX),
                    BenchmarkLadder.DISC_VDP1 to gl,
                ),
                openGlPolygon = RecommendedSettings.POLYGON_GPU_TESSELLATION,
            )
        assertEquals(VideoCore.OPENGL, outcome.videoCore)
        assertEquals(RecommendedSettings.POLYGON_GPU_TESSELLATION, outcome.polygonGeneration)
        assertEquals(RecommendedSettings.RBG_ORIGINAL, outcome.rbgResolution)
        assertEquals(twoX, outcome.resolution)
        assertFalse(outcome.useComputeShader)
    }

    @Test
    fun `a sweep missing a disc is not evidence for the expensive side`() {
        val outcome =
            BenchmarkLadder.outcomeOf(
                mapOf(BenchmarkLadder.DISC_VDP1 to rung(BenchmarkLadder.DISC_VDP1, "vk-compute-rasterizer")),
            )
        assertEquals(VideoCore.OPENGL, outcome.videoCore)
        assertEquals(RecommendedSettings.POLYGON_TRIANGLE, outcome.polygonGeneration)
    }

    @Test
    fun `the OpenGL tessellation rung differs from the triangle rung only in polygon generation`() {
        assertEquals(
            BenchmarkLadder.openGl(twoX).copy(
                label = "gl-tessellation",
                polygonGeneration = RecommendedSettings.POLYGON_GPU_TESSELLATION,
            ),
            BenchmarkLadder.openGlTessellation(twoX),
        )
    }
}
