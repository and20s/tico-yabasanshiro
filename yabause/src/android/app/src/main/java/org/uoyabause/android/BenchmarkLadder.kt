package org.uoyabause.android

/**
 * One candidate configuration for a benchmark disc.
 *
 * A rung is a complete graphics configuration, not a single setting: the
 * emulator is launched with it as a whole. The axes a disc does not measure are
 * pinned to the cheap side so that the run's outcome is attributable to the axis
 * the disc exists for.
 */
data class BenchmarkRung(
    val label: String,
    val videoCore: String,
    val polygonGeneration: String,
    val useComputeShader: Boolean,
    val vdp2Composite: String,
    val rbgResolution: String,
    /** Internal rendering resolution, a pref_resolution value. */
    val resolution: String,
)

/** The graphics configuration a completed sweep decided on. */
data class BenchmarkOutcome(
    val videoCore: String,
    val polygonGeneration: String,
    val useComputeShader: Boolean,
    val vdp2Composite: String,
    val rbgResolution: String,
    val resolution: String = RecommendedSettings.RESOLUTION_NATIVE,
)

/**
 * The configurations each benchmark disc walks, and how their results combine.
 *
 * The discs run in [SWEEP_ORDER]: VDP2 NBG first, because it decides the internal
 * resolution the other two are measured at; then VDP2 RBG; then VDP1. Each disc
 * tries its Vulkan rungs from the most expensive down and takes the first that
 * holds 60fps on every level. A disc none of whose rungs does falls to OpenGL
 * without measuring it, and an OpenGL disc makes the whole device OpenGL - so the
 * discs after it are not measured on Vulkan either.
 *
 * What OpenGL then uses for VDP1 is decided separately; see
 * [BenchmarkVerdict.openGlPolygon] and [measuresOpenGlPolygon].
 */
object BenchmarkLadder {
    const val DISC_VDP1 = 1
    const val DISC_VDP2_NBG = 2
    const val DISC_VDP2_RBG = 3

    /** The order the discs are measured in. */
    val SWEEP_ORDER = listOf(DISC_VDP2_NBG, DISC_VDP2_RBG, DISC_VDP1)

    /** OpenGL with the perspective-corrected triangle path at [resolution]. */
    fun openGl(resolution: String) =
        BenchmarkRung(
            label = "gl",
            videoCore = VideoCore.OPENGL,
            polygonGeneration = RecommendedSettings.POLYGON_TRIANGLE,
            useComputeShader = false,
            vdp2Composite = Vdp2Composite.VALUE_LEGACY,
            rbgResolution = RecommendedSettings.RBG_ORIGINAL,
            resolution = resolution,
        )

    /** [openGl] with GPU tessellation instead of the triangle path. */
    fun openGlTessellation(resolution: String) =
        openGl(resolution).copy(
            label = "gl-tessellation",
            polygonGeneration = RecommendedSettings.POLYGON_GPU_TESSELLATION,
        )

    /** What a disc records when it settles on OpenGL without being measured there. */
    val OPENGL_FLOOR = openGl(RecommendedSettings.RESOLUTION_NATIVE)

    /** A Vulkan rung with everything not under test pinned to the cheap side. */
    private fun vulkan(
        label: String,
        resolution: String,
        polygonGeneration: String = RecommendedSettings.POLYGON_GPU_TESSELLATION,
        vdp2Composite: String = Vdp2Composite.VALUE_LEGACY,
        rbgResolution: String = RecommendedSettings.RBG_ORIGINAL,
    ) = BenchmarkRung(
        label = label,
        videoCore = VideoCore.VULKAN,
        polygonGeneration = polygonGeneration,
        useComputeShader = true,
        vdp2Composite = vdp2Composite,
        rbgResolution = rbgResolution,
        resolution = resolution,
    )

    /**
     * The Vulkan rungs of [discId], cheapest first.
     *
     * [resolution] is the internal resolution the NBG disc settled on (see
     * [resolutionOf]); the NBG ladder ignores it because it is the one deciding it.
     */
    fun forDisc(
        discId: Int,
        resolution: String,
    ): List<BenchmarkRung> =
        when (discId) {
            DISC_VDP2_NBG ->
                listOf(
                    vulkan("vk-legacy-composite@2x", RecommendedSettings.RESOLUTION_2X),
                    vulkan("vk-legacy-composite", RecommendedSettings.RESOLUTION_NATIVE),
                    vulkan(
                        "vk-per-pixel-composite",
                        RecommendedSettings.RESOLUTION_NATIVE,
                        vdp2Composite = Vdp2Composite.VALUE_NEW,
                    ),
                )

            DISC_VDP2_RBG ->
                listOf(
                    vulkan("vk-rbg-2x", resolution, rbgResolution = RecommendedSettings.RBG_2X),
                    vulkan("vk-rbg-native", resolution, rbgResolution = BenchmarkVerdict.RBG_NATIVE),
                )

            DISC_VDP1 ->
                listOf(
                    vulkan(
                        "vk-tessellation",
                        resolution,
                        polygonGeneration = RecommendedSettings.POLYGON_GPU_TESSELLATION,
                    ),
                    vulkan(
                        "vk-compute-rasterizer",
                        resolution,
                        polygonGeneration = RecommendedSettings.POLYGON_COMPUTE_RASTERIZER,
                    ),
                )

            else -> emptyList()
        }

    private fun onVulkan(rung: BenchmarkRung?) = rung?.videoCore == VideoCore.VULKAN

    /** The internal resolution the NBG disc settled on; native once NBG is OpenGL. */
    fun resolutionOf(chosen: Map<Int, BenchmarkRung>): String =
        chosen[DISC_VDP2_NBG]?.takeIf { onVulkan(it) }?.resolution
            ?: RecommendedSettings.RESOLUTION_NATIVE

    /**
     * Whether [discId] is measured on Vulkan, given the discs settled before it.
     *
     * Not on a device without a usable Vulkan path, and not once an earlier disc
     * has put the device on OpenGL: a Vulkan verdict could no longer be used.
     */
    fun measuresOnVulkan(
        discId: Int,
        chosen: Map<Int, BenchmarkRung>,
        vulkanUsable: Boolean,
    ): Boolean {
        if (!vulkanUsable) return false
        val earlier = SWEEP_ORDER.takeWhile { it != discId }
        return earlier.all { onVulkan(chosen[it]) }
    }

    /**
     * Whether OpenGL's VDP1 polygon path is measured once the sweep is over.
     *
     * Only when VDP2 is what put the device on OpenGL. A device whose VDP2 held
     * on Vulkan and whose VDP1 did not has already shown that VDP1 is its
     * bottleneck, so it takes the perspective-corrected triangle path unmeasured.
     */
    fun measuresOpenGlPolygon(chosen: Map<Int, BenchmarkRung>): Boolean =
        !onVulkan(chosen[DISC_VDP2_NBG]) || !onVulkan(chosen[DISC_VDP2_RBG])

    /**
     * Combines the rung each disc settled on into one configuration.
     *
     * A device runs a single video core, so if any disc settled on OpenGL - or is
     * missing, which is not evidence for the expensive side - the whole device is
     * OpenGL, with [openGlPolygon] as its polygon path. The internal resolution
     * is the NBG disc's either way.
     */
    fun outcomeOf(
        chosen: Map<Int, BenchmarkRung>,
        openGlPolygon: String = RecommendedSettings.POLYGON_TRIANGLE,
    ): BenchmarkOutcome {
        val resolution = resolutionOf(chosen)
        if (SWEEP_ORDER.any { !onVulkan(chosen[it]) }) {
            val floor = openGl(resolution)
            return BenchmarkOutcome(
                videoCore = floor.videoCore,
                polygonGeneration = openGlPolygon,
                useComputeShader = floor.useComputeShader,
                vdp2Composite = floor.vdp2Composite,
                rbgResolution = floor.rbgResolution,
                resolution = resolution,
            )
        }
        return BenchmarkOutcome(
            videoCore = VideoCore.VULKAN,
            polygonGeneration = chosen.getValue(DISC_VDP1).polygonGeneration,
            useComputeShader = true,
            vdp2Composite = chosen.getValue(DISC_VDP2_NBG).vdp2Composite,
            rbgResolution = chosen.getValue(DISC_VDP2_RBG).rbgResolution,
            resolution = resolution,
        )
    }
}
