package org.uoyabause.android

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class RecommendedSettingsTest {
    private fun caps(
        vulkan: Boolean = true,
        glEs: Int = 0x30002,
        tessellation: Boolean = true,
        cpuKHz: Int? = 2_841_600,
        pc: Boolean = false,
        gpuKey: String? = "vk:1:1",
        vulkanTessellation: Boolean = true,
    ) = DeviceCapabilities(vulkan, glEs, tessellation, cpuKHz, pc, gpuKey, vulkanTessellation)

    private fun profile(
        polygon: String = "2",
        composite: String = "1",
        rbg: String = "4",
    ) = GpuProfile("vk:1:1", "n", polygon, composite, rbg, GpuProfile.SOURCE_MEASURED)

    @Test
    fun `a measured OpenGL verdict overrides the capability based core`() {
        // The benchmark is allowed to conclude that a Vulkan-capable GPU should
        // still run OpenGL, which is the only way a profile can say so.
        val measured =
            profile().copy(videoCore = VideoCore.OPENGL, useComputeShader = false)
        val result = RecommendedSettings.forDevice(caps(vulkan = true), measured)
        assertEquals(VideoCore.OPENGL, result.videoCore)
        assertFalse(result.useComputeShader)
        // Triangle is legal again once the core is OpenGL, and the polygon value
        // must be sanitized against that core, not against the device's Vulkan
        // capability.
        assertEquals(
            RecommendedSettings.POLYGON_TRIANGLE,
            RecommendedSettings
                .forDevice(
                    caps(vulkan = true),
                    measured.copy(polygonGeneration = RecommendedSettings.POLYGON_TRIANGLE),
                ).polygonGeneration,
        )
    }

    @Test
    fun `a profile asking for Vulkan on a device without it is ignored`() {
        val measured = profile().copy(videoCore = VideoCore.VULKAN)
        assertEquals(
            VideoCore.OPENGL,
            RecommendedSettings.forDevice(caps(vulkan = false), measured).videoCore,
        )
    }

    @Test
    fun `a known GPU uses the database and needs no benchmark`() {
        val result = RecommendedSettings.forDevice(caps(), profile())
        assertEquals("2", result.polygonGeneration)
        assertEquals("1", result.vdp2Composite)
        assertEquals("4", result.rbgResolution)
        assertFalse(result.needsBenchmark)
    }

    @Test
    fun `an unknown GPU takes the cheap side and asks for a benchmark`() {
        val result = RecommendedSettings.forDevice(caps(), null)
        assertEquals(Vdp2Composite.VALUE_LEGACY, result.vdp2Composite)
        assertEquals("0", result.rbgResolution)
        assertTrue(result.needsBenchmark)
    }

    @Test
    fun `vulkan is chosen when supported`() {
        assertEquals(VideoCore.VULKAN, RecommendedSettings.forDevice(caps(vulkan = true), profile()).videoCore)
        assertEquals(VideoCore.OPENGL, RecommendedSettings.forDevice(caps(vulkan = false), profile()).videoCore)
    }

    @Test
    fun `compute shader follows the video core and the ES version`() {
        assertTrue(RecommendedSettings.forDevice(caps(vulkan = true), profile()).useComputeShader)
        assertTrue(
            RecommendedSettings.forDevice(caps(vulkan = false, glEs = 0x30001), profile()).useComputeShader,
        )
        assertFalse(
            RecommendedSettings.forDevice(caps(vulkan = false, glEs = 0x30000), profile()).useComputeShader,
        )
    }

    @Test
    fun `sh2 cache switches on at two gigahertz`() {
        assertTrue(RecommendedSettings.forDevice(caps(cpuKHz = 2_000_000), profile()).useSh2Cache)
        assertFalse(RecommendedSettings.forDevice(caps(cpuKHz = 1_999_999), profile()).useSh2Cache)
        assertFalse(RecommendedSettings.forDevice(caps(cpuKHz = null), profile()).useSh2Cache)
    }

    @Test
    fun `the PC profile wins over the spec based rules and skips the benchmark`() {
        val result = RecommendedSettings.forDevice(caps(vulkan = true, pc = true), null)
        assertEquals(VideoCore.OPENGL, result.videoCore)
        assertEquals("0", result.polygonGeneration)
        assertTrue(result.useComputeShader)
        assertFalse(result.needsBenchmark)
    }

    // Only the Vulkan renderer reads this setting, so OpenGL devices keep the
    // default rather than an arbitrary value.
    @Test
    fun `openGL devices report the default compositor`() {
        val result = RecommendedSettings.forDevice(caps(vulkan = false), null)
        assertEquals(Vdp2Composite.DEFAULT_VALUE, result.vdp2Composite)
    }

    @Test
    fun `polygon generation falls back to triangles without tessellation`() {
        val result = RecommendedSettings.forDevice(caps(vulkan = false, tessellation = false), null)
        assertEquals("0", result.polygonGeneration)
    }

    @Test
    fun `compute rasterizer from database is recommendable under vulkan`() {
        // It is the top rung of the VDP1 ladder, so a measured profile can name it.
        val result = RecommendedSettings.forDevice(caps(vulkan = true), profile(polygon = "3"))
        assertEquals(RecommendedSettings.POLYGON_COMPUTE_RASTERIZER, result.polygonGeneration)
        assertFalse(result.needsBenchmark)
    }

    @Test
    fun `compute rasterizer from database is replaced with triangles without vulkan`() {
        // The OpenGL core has no compute rasterizer path.
        val result = RecommendedSettings.forDevice(caps(vulkan = false), profile(polygon = "3"))
        assertEquals(RecommendedSettings.POLYGON_TRIANGLE, result.polygonGeneration)
        assertFalse(result.needsBenchmark)
    }

    // Fix 1: profile values can come from Firebase Remote Config, i.e. from
    // outside the APK. An out-of-range value for each field must fall back to
    // the safe side rather than reach RecommendedSettingsApplier unchecked.

    @Test
    fun `an out of range polygon generation falls back to tessellation under vulkan`() {
        val result = RecommendedSettings.forDevice(caps(vulkan = true), profile(polygon = "not-a-value"))
        assertEquals(RecommendedSettings.POLYGON_GPU_TESSELLATION, result.polygonGeneration)
    }

    @Test
    fun `an out of range polygon generation falls back to triangles without vulkan`() {
        val result = RecommendedSettings.forDevice(caps(vulkan = false), profile(polygon = "not-a-value"))
        assertEquals(RecommendedSettings.POLYGON_TRIANGLE, result.polygonGeneration)
    }

    @Test
    fun `an out of range vdp2 composite falls back to the default`() {
        val result = RecommendedSettings.forDevice(caps(vulkan = true), profile(composite = "high"))
        assertEquals(Vdp2Composite.DEFAULT_VALUE, result.vdp2Composite)
    }

    @Test
    fun `a measured resolution is recommended`() {
        val measured = profile().copy(resolution = RecommendedSettings.RESOLUTION_ORIGINAL)
        assertEquals(
            RecommendedSettings.RESOLUTION_ORIGINAL,
            RecommendedSettings.forDevice(caps(), measured).resolution,
        )
    }

    @Test
    fun `an out of range resolution falls back to native`() {
        val measured = profile().copy(resolution = "low")
        assertEquals(
            RecommendedSettings.RESOLUTION_NATIVE,
            RecommendedSettings.forDevice(caps(), measured).resolution,
        )
    }

    @Test
    fun `a profile without a resolution and an unknown GPU both render at native`() {
        assertEquals(RecommendedSettings.RESOLUTION_NATIVE, RecommendedSettings.forDevice(caps(), profile()).resolution)
        assertEquals(RecommendedSettings.RESOLUTION_NATIVE, RecommendedSettings.forDevice(caps(), null).resolution)
    }

    @Test
    fun `an out of range rbg resolution falls back to the original`() {
        val result = RecommendedSettings.forDevice(caps(), profile(rbg = "high"))
        assertEquals(RecommendedSettings.RBG_ORIGINAL, result.rbgResolution)
    }

    // Triangle is a legal preference value, but it is inert under Vulkan: the app
    // rewrites it to tessellation elsewhere. Recommending it would show the user a
    // change that never happens, so it must not survive sanitizing on a Vulkan device.
    @Test
    fun `triangles from the database become tessellation under vulkan`() {
        val result = RecommendedSettings.forDevice(caps(vulkan = true), profile(polygon = "0"))
        assertEquals(RecommendedSettings.POLYGON_GPU_TESSELLATION, result.polygonGeneration)
    }

    @Test
    fun `triangles from the database survive without vulkan`() {
        val result = RecommendedSettings.forDevice(caps(vulkan = false), profile(polygon = "0"))
        assertEquals(RecommendedSettings.POLYGON_TRIANGLE, result.polygonGeneration)
    }

    @Test
    fun `a vulkan device without tessellation is recommended OpenGL and the triangle path`() {
        // Advertising Vulkan is not enough: without the tessellation and
        // geometry shader features the Vulkan core has no polygon path (Triangle
        // is rewritten to GPU tessellation there), so the device belongs on
        // OpenGL with perspective-corrected triangles.
        val settings =
            RecommendedSettings.forDevice(
                caps(vulkan = true, tessellation = false, vulkanTessellation = false),
                null,
            )
        assertEquals(VideoCore.OPENGL, settings.videoCore)
        assertEquals(RecommendedSettings.POLYGON_TRIANGLE, settings.polygonGeneration)
        // Only the Vulkan core reads the compositor setting.
        assertEquals(Vdp2Composite.DEFAULT_VALUE, settings.vdp2Composite)
    }

    @Test
    fun `a measured vulkan profile does not put a device without tessellation on vulkan`() {
        val settings =
            RecommendedSettings.forDevice(
                caps(vulkan = true, tessellation = false, vulkanTessellation = false),
                profile(polygon = "2"),
            )
        assertEquals(VideoCore.OPENGL, settings.videoCore)
        assertEquals(RecommendedSettings.POLYGON_TRIANGLE, settings.polygonGeneration)
    }
}
