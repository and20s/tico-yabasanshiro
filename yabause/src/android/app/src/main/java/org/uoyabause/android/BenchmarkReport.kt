package org.uoyabause.android

import org.json.JSONArray
import org.json.JSONObject

/** One rung that was actually run, with the fps of every level it closed. */
data class BenchmarkAttemptRecord(
    val discId: Int,
    val rung: String,
    val passed: Boolean,
    val reason: String,
    val levelFps: Map<Int, Double>,
)

/**
 * One completed benchmark sweep, in the shape it is stored and uploaded in.
 *
 * Holds no Android or Firebase types so that the payload rules - what goes in,
 * what must never go in, and how it survives being parked on disk - can be
 * pinned by JVM tests. The uploader adds the server timestamp; nothing here
 * reads a clock.
 *
 * Only complete sweeps are represented. A cancelled sweep has no verdict, so it
 * is not evidence about a GPU and is not uploaded - its record stays in the
 * device-local benchmark_result.txt.
 */
data class BenchmarkReport(
    val installId: String,
    val gpuKey: String,
    val gpuName: String,
    val deviceModel: String,
    val androidRelease: String,
    val androidSdk: Int,
    val appVersionName: String,
    val appVersionCode: Int,
    val discSetVersion: String,
    val capabilities: DeviceCapabilities,
    val chosen: Map<Int, String>,
    val attempts: List<BenchmarkAttemptRecord>,
    val verdict: BenchmarkOutcome,
) {
    /**
     * One document per device per measurement condition.
     *
     * Re-running the same discs on the same app version overwrites the previous
     * result instead of adding a second vote, so the aggregation's "number of
     * reports" is a number of devices. Changing either the discs or the app
     * makes it a different document, which is what lets a renderer fix be
     * compared against the measurements that preceded it.
     */
    fun documentId(): String = "${installId}_${discSetVersion}_$appVersionCode"

    /** The Firestore document body. See the schema in the design doc, section 3.2. */
    fun toFields(): Map<String, Any?> =
        mapOf(
            "schemaVersion" to SCHEMA_VERSION,
            "installId" to installId,
            "gpuKey" to gpuKey,
            "gpuName" to gpuName,
            "deviceModel" to deviceModel,
            "androidRelease" to androidRelease,
            "androidSdk" to androidSdk,
            "appVersionName" to appVersionName,
            "appVersionCode" to appVersionCode,
            "discSetVersion" to discSetVersion,
            "capabilities" to
                mapOf(
                    "vulkanSupported" to capabilities.vulkanSupported,
                    "vulkanTessellation" to capabilities.vulkanTessellation,
                    "glEsVersion" to capabilities.glEsVersion,
                    "hasTessellation" to capabilities.hasTessellation,
                    "cpuMaxClockKHz" to capabilities.cpuMaxClockKHz,
                    "isPc" to capabilities.isPc,
                ),
            "chosen" to chosen.entries.associate { it.key.toString() to it.value },
            "attempts" to
                attempts.map { attempt ->
                    mapOf(
                        "disc" to attempt.discId,
                        "rung" to attempt.rung,
                        "passed" to attempt.passed,
                        "reason" to attempt.reason,
                        "levelFps" to attempt.levelFps.entries.associate { it.key.toString() to it.value },
                    )
                },
            "verdict" to
                mapOf(
                    "videoCore" to verdict.videoCore,
                    "polygonGeneration" to verdict.polygonGeneration,
                    "useComputeShader" to verdict.useComputeShader,
                    "vdp2Composite" to verdict.vdp2Composite,
                    "rbgResolution" to verdict.rbgResolution,
                    "resolution" to verdict.resolution,
                ),
        )

    /**
     * The same shape as [toFields], for the file the report waits in until it
     * can be sent. Built explicitly rather than converted from the map so that
     * the two cannot drift into different shapes unnoticed - a test asserts they
     * carry the same keys.
     */
    fun toJson(): String =
        JSONObject()
            .put("schemaVersion", SCHEMA_VERSION)
            .put("installId", installId)
            .put("gpuKey", gpuKey)
            .put("gpuName", gpuName)
            .put("deviceModel", deviceModel)
            .put("androidRelease", androidRelease)
            .put("androidSdk", androidSdk)
            .put("appVersionName", appVersionName)
            .put("appVersionCode", appVersionCode)
            .put("discSetVersion", discSetVersion)
            .put(
                "capabilities",
                JSONObject()
                    .put("vulkanSupported", capabilities.vulkanSupported)
                    .put("vulkanTessellation", capabilities.vulkanTessellation)
                    .put("glEsVersion", capabilities.glEsVersion)
                    .put("hasTessellation", capabilities.hasTessellation)
                    .put("cpuMaxClockKHz", capabilities.cpuMaxClockKHz ?: JSONObject.NULL)
                    .put("isPc", capabilities.isPc),
            ).put(
                "chosen",
                JSONObject().also { out -> chosen.forEach { out.put(it.key.toString(), it.value) } },
            ).put(
                "attempts",
                JSONArray().also { array ->
                    attempts.forEach { attempt ->
                        array.put(
                            JSONObject()
                                .put("disc", attempt.discId)
                                .put("rung", attempt.rung)
                                .put("passed", attempt.passed)
                                .put("reason", attempt.reason)
                                .put(
                                    "levelFps",
                                    JSONObject().also { out ->
                                        attempt.levelFps.forEach { out.put(it.key.toString(), it.value) }
                                    },
                                ),
                        )
                    }
                },
            ).put(
                "verdict",
                JSONObject()
                    .put("videoCore", verdict.videoCore)
                    .put("polygonGeneration", verdict.polygonGeneration)
                    .put("useComputeShader", verdict.useComputeShader)
                    .put("vdp2Composite", verdict.vdp2Composite)
                    .put("rbgResolution", verdict.rbgResolution)
                    .put("resolution", verdict.resolution),
            ).toString()

    companion object {
        const val SCHEMA_VERSION = 1

        /**
         * The measured levels of one run, as a map.
         *
         * The array is indexed by level, so index 0 is not a level at all, and a
         * level whose window never closed is left at 0.0. Neither is a
         * measurement, so neither is reported.
         */
        fun levelFpsOf(levelFps: DoubleArray): Map<Int, Double> =
            levelFps
                .withIndex()
                .filter { it.index > 0 && it.value > 0.0 }
                .associate { it.index to it.value }

        /** Parses what [toJson] wrote, or null when the file is unusable. */
        fun fromJson(json: String?): BenchmarkReport? {
            if (json.isNullOrBlank()) return null
            return try {
                val root = JSONObject(json)
                val caps = root.getJSONObject("capabilities")
                BenchmarkReport(
                    installId = root.getString("installId"),
                    gpuKey = root.getString("gpuKey"),
                    gpuName = root.getString("gpuName"),
                    deviceModel = root.getString("deviceModel"),
                    androidRelease = root.getString("androidRelease"),
                    androidSdk = root.getInt("androidSdk"),
                    appVersionName = root.getString("appVersionName"),
                    appVersionCode = root.getInt("appVersionCode"),
                    discSetVersion = root.getString("discSetVersion"),
                    capabilities =
                        DeviceCapabilities(
                            vulkanSupported = caps.getBoolean("vulkanSupported"),
                            glEsVersion = caps.getInt("glEsVersion"),
                            hasTessellation = caps.getBoolean("hasTessellation"),
                            cpuMaxClockKHz = if (caps.isNull("cpuMaxClockKHz")) null else caps.getInt("cpuMaxClockKHz"),
                            isPc = caps.getBoolean("isPc"),
                            // Not stored separately: the report's gpuKey comes
                            // from these very capabilities, so writing it twice
                            // would only create a way for the two to disagree.
                            gpuKey = root.getString("gpuKey"),
                            vulkanTessellation = caps.getBoolean("vulkanTessellation"),
                        ),
                    chosen = intKeyedStrings(root.getJSONObject("chosen")),
                    attempts = attemptsOf(root.getJSONArray("attempts")),
                    verdict =
                        root.getJSONObject("verdict").let {
                            BenchmarkOutcome(
                                videoCore = it.getString("videoCore"),
                                polygonGeneration = it.getString("polygonGeneration"),
                                useComputeShader = it.getBoolean("useComputeShader"),
                                vdp2Composite = it.getString("vdp2Composite"),
                                rbgResolution = it.getString("rbgResolution"),
                                // Absent in reports parked before resolution
                                // was measured, which all rendered at native.
                                resolution = it.optString("resolution", RecommendedSettings.RESOLUTION_NATIVE),
                            )
                        },
                )
            } catch (e: Exception) {
                null
            }
        }

        private fun intKeyedStrings(source: JSONObject): Map<Int, String> {
            val result = LinkedHashMap<Int, String>()
            source.keys().forEach { key -> result[key.toInt()] = source.getString(key) }
            return result
        }

        private fun intKeyedDoubles(source: JSONObject): Map<Int, Double> {
            val result = LinkedHashMap<Int, Double>()
            source.keys().forEach { key -> result[key.toInt()] = source.getDouble(key) }
            return result
        }

        private fun attemptsOf(array: JSONArray): List<BenchmarkAttemptRecord> =
            (0 until array.length()).map { index ->
                val entry = array.getJSONObject(index)
                BenchmarkAttemptRecord(
                    discId = entry.getInt("disc"),
                    rung = entry.getString("rung"),
                    passed = entry.getBoolean("passed"),
                    reason = entry.getString("reason"),
                    levelFps = intKeyedDoubles(entry.getJSONObject("levelFps")),
                )
            }
    }
}
