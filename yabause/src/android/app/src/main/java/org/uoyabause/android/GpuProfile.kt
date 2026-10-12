package org.uoyabause.android

import org.json.JSONArray
import org.json.JSONObject

/**
 * The settings recommended for one GPU. Missing fields fall back to the
 * cheaper option so that a partially filled entry is still usable.
 */
data class GpuProfile(
    val key: String,
    val name: String,
    val polygonGeneration: String,
    val vdp2Composite: String,
    val rbgResolution: String,
    val source: String,
    /**
     * The video core the benchmark settled on, or [VIDEO_CORE_UNSPECIFIED] for
     * entries that do not name one. A measured profile can conclude that a GPU
     * should run OpenGL even though it advertises Vulkan, which no other field
     * can express; curated entries predating this stay unspecified and leave the
     * choice to the device capabilities.
     */
    val videoCore: String = VIDEO_CORE_UNSPECIFIED,
    /**
     * Whether the rotation path should use the compute shader. Only meaningful
     * together with [videoCore]: the OpenGL rung of the ladder is the CPU path.
     */
    val useComputeShader: Boolean = true,
    /**
     * Internal rendering resolution (a pref_resolution value). Entries predating
     * it are native, which is what every device rendered at before the benchmark
     * could lower it.
     */
    val resolution: String = RecommendedSettings.RESOLUTION_NATIVE,
) {
    companion object {
        const val SOURCE_MEASURED = "measured"
        const val SOURCE_CURATED = "curated"

        /**
         * Produced by aggregating measurements from several devices, as opposed
         * to SOURCE_CURATED, which a person wrote by hand. Informational: the
         * recommendation logic does not read it.
         */
        const val SOURCE_AGGREGATED = "aggregated"

        /** No video core recorded; the caller decides from the device capabilities. */
        const val VIDEO_CORE_UNSPECIFIED = ""

        fun parseAll(json: String?): Map<String, GpuProfile> {
            if (json.isNullOrBlank()) return emptyMap()
            val array =
                try {
                    JSONObject(json).optJSONArray("profiles") ?: return emptyMap()
                } catch (e: Exception) {
                    return emptyMap()
                }
            val result = LinkedHashMap<String, GpuProfile>()
            for (i in 0 until array.length()) {
                val entry = array.optJSONObject(i) ?: continue
                val key = entry.optString("key").takeIf { it.isNotBlank() } ?: continue
                result[key] =
                    GpuProfile(
                        key = key,
                        name = entry.optString("name", key),
                        polygonGeneration = entry.optString("polygonGeneration", "0"),
                        vdp2Composite = entry.optString("vdp2Composite", Vdp2Composite.VALUE_LEGACY),
                        rbgResolution = entry.optString("rbgResolution", "0"),
                        source = entry.optString("source", SOURCE_CURATED),
                        videoCore = entry.optString("videoCore", VIDEO_CORE_UNSPECIFIED),
                        useComputeShader = entry.optBoolean("useComputeShader", true),
                        resolution = entry.optString("resolution", RecommendedSettings.RESOLUTION_NATIVE),
                    )
            }
            return result
        }

        fun toJson(profiles: Collection<GpuProfile>): String {
            val array = JSONArray()
            for (profile in profiles) {
                array.put(
                    JSONObject()
                        .put("key", profile.key)
                        .put("name", profile.name)
                        .put("polygonGeneration", profile.polygonGeneration)
                        .put("vdp2Composite", profile.vdp2Composite)
                        .put("rbgResolution", profile.rbgResolution)
                        .put("source", profile.source)
                        .put("videoCore", profile.videoCore)
                        .put("useComputeShader", profile.useComputeShader)
                        .put("resolution", profile.resolution),
                )
            }
            return JSONObject().put("version", 1).put("profiles", array).toString()
        }
    }
}
