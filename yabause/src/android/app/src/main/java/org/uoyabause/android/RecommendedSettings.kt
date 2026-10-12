package org.uoyabause.android

/**
 * The settings recommended for one device.
 *
 * [needsBenchmark] is true when the GPU is not in the database yet: the values
 * below are then the cheap fallback, and running the benchmark replaces them.
 */
data class RecommendedSettings(
    val videoCore: String,
    val polygonGeneration: String,
    val useComputeShader: Boolean,
    val vdp2Composite: String,
    val rbgResolution: String,
    val useSh2Cache: Boolean,
    val needsBenchmark: Boolean,
    /** Internal rendering resolution, a pref_resolution value. */
    val resolution: String = RESOLUTION_NATIVE,
) {
    companion object {
        const val POLYGON_TRIANGLE = "0"
        const val POLYGON_GPU_TESSELLATION = "2"
        const val POLYGON_COMPUTE_RASTERIZER = "3"
        const val RBG_ORIGINAL = "0"
        const val RBG_2X = "1"

        // pref_resolution values (RESOLUTION_MODE in ygl.h). Native is the
        // preference's XML default.
        const val RESOLUTION_NATIVE = "0"
        const val RESOLUTION_2X = "2"
        const val RESOLUTION_ORIGINAL = "3"

        // Provisional threshold. Calibrate once several devices have been measured.
        const val SH2_CACHE_CPU_THRESHOLD_KHZ = 2_000_000

        fun forDevice(
            caps: DeviceCapabilities,
            profile: GpuProfile?,
        ): RecommendedSettings {
            val sh2Cache = (caps.cpuMaxClockKHz ?: 0) >= SH2_CACHE_CPU_THRESHOLD_KHZ

            // Google Play Games on PC keeps the settings it has always used.
            if (caps.isPc) {
                return RecommendedSettings(
                    videoCore = VideoCore.OPENGL,
                    polygonGeneration = POLYGON_TRIANGLE,
                    useComputeShader = true,
                    vdp2Composite = Vdp2Composite.DEFAULT_VALUE,
                    rbgResolution = RBG_ORIGINAL,
                    useSh2Cache = sh2Cache,
                    needsBenchmark = false,
                    resolution = RESOLUTION_NATIVE,
                )
            }

            // canUseVulkan, not vulkanSupported: a device that advertises Vulkan
            // without the tessellation and geometry shader features cannot run
            // any polygon path the Vulkan core offers (Triangle is rewritten to
            // GPU tessellation there), so it belongs on OpenGL with the
            // perspective-corrected triangle path.
            val videoCore = if (caps.canUseVulkan) VideoCore.VULKAN else VideoCore.OPENGL
            val computeShader =
                caps.canUseVulkan || caps.glEsVersion >= DeviceCapabilities.GL_ES_31

            if (profile != null) {
                // A measured profile can name the video core, because the benchmark
                // is allowed to conclude that a Vulkan-capable GPU should still run
                // OpenGL. Only OpenGL is honoured: a profile asking for Vulkan on a
                // device without it would be unrunnable, and an unspecified value
                // keeps the capability-based choice.
                val profileCore =
                    if (profile.videoCore == VideoCore.OPENGL) VideoCore.OPENGL else videoCore
                val sanitized = sanitize(caps, profile, profileCore)
                return RecommendedSettings(
                    videoCore = profileCore,
                    polygonGeneration = sanitized.polygonGeneration,
                    useComputeShader = computeShader && profile.useComputeShader,
                    vdp2Composite = compositeFor(caps, sanitized.vdp2Composite),
                    rbgResolution = sanitized.rbgResolution,
                    useSh2Cache = sh2Cache,
                    needsBenchmark = false,
                    resolution = sanitized.resolution,
                )
            }

            // Unknown GPU: take the cheap side until the benchmark says otherwise.
            val polygon =
                if (caps.canUseVulkan || caps.hasTessellation) {
                    POLYGON_GPU_TESSELLATION
                } else {
                    POLYGON_TRIANGLE
                }
            return RecommendedSettings(
                videoCore = videoCore,
                polygonGeneration = polygon,
                useComputeShader = computeShader,
                vdp2Composite = compositeFor(caps, Vdp2Composite.VALUE_LEGACY),
                rbgResolution = RBG_ORIGINAL,
                useSh2Cache = sh2Cache,
                needsBenchmark = true,
                resolution = RESOLUTION_NATIVE,
            )
        }

        /**
         * Only the Vulkan renderer interprets the compositor setting, so other
         * cores report the default instead of a value that would look wrong once
         * the user switches to Vulkan.
         */
        private fun compositeFor(
            caps: DeviceCapabilities,
            value: String,
        ): String = if (caps.canUseVulkan) value else Vdp2Composite.DEFAULT_VALUE

        /** Result of [sanitize]: the recommendable profile fields, all guaranteed legal. */
        private data class SanitizedProfile(
            val polygonGeneration: String,
            val vdp2Composite: String,
            val rbgResolution: String,
            val resolution: String,
        )

        // Legal value sets, mirrored from res/values/arrays.xml. Keep in sync by hand;
        // there is no shared source of truth between Kotlin and the preference XML.
        private val LEGAL_RBG_RESOLUTIONS = setOf("0", "1", "2", "3", "4", "5")
        private val LEGAL_RESOLUTIONS = setOf("0", "1", "2", "3", "4", "5")
        private val LEGAL_VDP2_COMPOSITES = setOf(Vdp2Composite.VALUE_NEW, Vdp2Composite.VALUE_LEGACY)

        // Compute Rasterizer is Vulkan-only: the OpenGL core has no such path, so a
        // profile naming it there falls back to the triangle path.
        // Under Vulkan, Triangle ("0") is not recommendable - the app rewrites it to
        // "2" in InGamePreference, Yabause and SettingsActivity, so recommending it
        // would produce a setting that never takes effect.
        private val LEGAL_POLYGON_MODES_VULKAN =
            setOf(POLYGON_GPU_TESSELLATION, POLYGON_COMPUTE_RASTERIZER)
        private val LEGAL_POLYGON_MODES_OPENGL = setOf(POLYGON_TRIANGLE, POLYGON_GPU_TESSELLATION)
        private val LEGAL_POLYGON_MODES_OPENGL_NO_TESSELLATION = setOf(POLYGON_TRIANGLE)

        /**
         * Validates a [GpuProfile]'s recommendable fields before they become a
         * setting. Profile values can come from Firebase Remote Config, i.e. from
         * outside the APK: a database typo (or a malicious payload) must never
         * reach a native call unchecked (e.g. pref_rbg_resolution.toInt() in
         * Yabause.kt, which has no validation of its own). This function is the
         * single trust boundary for that data. Any value outside its legal set
         * falls back to the safe (lighter) side instead of being forwarded as-is.
         */
        private fun sanitize(
            caps: DeviceCapabilities,
            profile: GpuProfile,
            selectedCore: String,
        ): SanitizedProfile {
            // Both the legal set and the fallback depend on the video core that will
            // actually be selected for this device, because "0" is inert under Vulkan.
            val onVulkan = selectedCore == VideoCore.VULKAN
            val legalPolygonModes =
                when {
                    onVulkan -> LEGAL_POLYGON_MODES_VULKAN
                    caps.hasTessellation -> LEGAL_POLYGON_MODES_OPENGL
                    // OpenGL without the tessellation extension: only the
                    // perspective-corrected triangle path is left, so a profile
                    // naming GPU tessellation has to be rewritten.
                    else -> LEGAL_POLYGON_MODES_OPENGL_NO_TESSELLATION
                }
            val polygonFallback = if (onVulkan) POLYGON_GPU_TESSELLATION else POLYGON_TRIANGLE
            val polygonGeneration =
                profile.polygonGeneration.takeIf { it in legalPolygonModes }
                    ?: polygonFallback

            val vdp2Composite =
                profile.vdp2Composite.takeIf { it in LEGAL_VDP2_COMPOSITES }
                    ?: Vdp2Composite.DEFAULT_VALUE

            val rbgResolution =
                profile.rbgResolution.takeIf { it in LEGAL_RBG_RESOLUTIONS }
                    ?: RBG_ORIGINAL

            // Native is the preference's own default, and every device rendered
            // at it before the benchmark could lower it.
            val resolution =
                profile.resolution.takeIf { it in LEGAL_RESOLUTIONS }
                    ?: RESOLUTION_NATIVE

            return SanitizedProfile(polygonGeneration, vdp2Composite, rbgResolution, resolution)
        }
    }
}
