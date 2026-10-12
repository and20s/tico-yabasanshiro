package org.uoyabause.android

/**
 * What the first launch on a device offers once the game list is up.
 *
 * The first launch writes the safe-side settings without asking, because the app
 * needs settings before anything else happens. What comes after depends on
 * whether the GPU is in the profile database (bundled asset or Remote Config):
 * a known GPU is offered its recommended settings, an unknown one the benchmark
 * that would measure them.
 *
 * Pure so the rule is pinned by JVM tests.
 */
enum class FirstLaunchOffer {
    NONE,
    RECOMMENDED_SETTINGS,
    BENCHMARK,
    ;

    companion object {
        /**
         * Google Play Games on PC ignores profiles altogether, and a GPU that
         * could not be identified has no key to look a profile up under or to
         * save a measurement with - neither is offered anything.
         */
        fun decide(
            caps: DeviceCapabilities,
            profile: GpuProfile?,
        ): FirstLaunchOffer =
            when {
                caps.isPc || caps.gpuKey == null -> NONE
                profile != null -> RECOMMENDED_SETTINGS
                else -> BENCHMARK
            }
    }
}
