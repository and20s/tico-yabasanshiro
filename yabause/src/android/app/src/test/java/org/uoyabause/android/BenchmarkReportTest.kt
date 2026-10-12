package org.uoyabause.android

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class BenchmarkReportTest {
    private val capabilities =
        DeviceCapabilities(
            vulkanSupported = true,
            glEsVersion = 0x30002,
            hasTessellation = true,
            cpuMaxClockKHz = 2_400_000,
            isPc = false,
            gpuKey = "vk:5143:6040001",
            vulkanTessellation = true,
        )

    private fun report() =
        BenchmarkReport(
            installId = "11111111-2222-3333-4444-555555555555",
            gpuKey = "vk:5143:6040001",
            gpuName = "Qualcomm Adreno (TM) 650",
            deviceModel = "Retroid Pocket Classic",
            androidRelease = "13",
            androidSdk = 33,
            appVersionName = "1.20.37",
            appVersionCode = 12037,
            discSetVersion = "a3f19c2b4d5e6f70",
            capabilities = capabilities,
            chosen = mapOf(1 to "vk-compute-rasterizer", 2 to "vk-legacy-composite", 3 to "gl"),
            attempts =
                listOf(
                    BenchmarkAttemptRecord(
                        discId = 1,
                        rung = "vk-compute-rasterizer",
                        passed = true,
                        reason = "cycle",
                        levelFps = mapOf(2 to 60.4, 3 to 60.1),
                    ),
                ),
            verdict =
                BenchmarkOutcome(
                    videoCore = VideoCore.VULKAN,
                    polygonGeneration = RecommendedSettings.POLYGON_COMPUTE_RASTERIZER,
                    useComputeShader = true,
                    vdp2Composite = Vdp2Composite.VALUE_LEGACY,
                    rbgResolution = RecommendedSettings.RBG_ORIGINAL,
                ),
        )

    @Test
    fun `the document id is the install, the disc set version and the app version`() {
        assertEquals(
            "11111111-2222-3333-4444-555555555555_a3f19c2b4d5e6f70_12037",
            report().documentId(),
        )
    }

    @Test
    fun `the fields are exactly the ones the schema names`() {
        // Exact equality, not "contains": a field added by accident is how
        // something that must never leave the device gets uploaded.
        assertEquals(
            setOf(
                "schemaVersion",
                "installId",
                "gpuKey",
                "gpuName",
                "deviceModel",
                "androidRelease",
                "androidSdk",
                "appVersionName",
                "appVersionCode",
                "discSetVersion",
                "capabilities",
                "chosen",
                "attempts",
                "verdict",
            ),
            report().toFields().keys,
        )
    }

    @Test
    fun `the capabilities fields are exactly the ones the schema names`() {
        // Same reasoning as the top-level check, one level down: capabilities is
        // the nested map most likely to grow, and it already deliberately
        // omits gpuKey (the report's own gpuKey field carries that instead).
        @Suppress("UNCHECKED_CAST")
        val capabilitiesFields = report().toFields()["capabilities"] as Map<String, Any?>
        assertEquals(
            setOf(
                "vulkanSupported",
                "vulkanTessellation",
                "glEsVersion",
                "hasTessellation",
                "cpuMaxClockKHz",
                "isPc",
            ),
            capabilitiesFields.keys,
        )
    }

    @Test
    fun `the verdict fields are exactly the ones the schema names`() {
        @Suppress("UNCHECKED_CAST")
        val verdictFields = report().toFields()["verdict"] as Map<String, Any?>
        assertEquals(
            setOf(
                "videoCore",
                "polygonGeneration",
                "useComputeShader",
                "vdp2Composite",
                "rbgResolution",
                "resolution",
            ),
            verdictFields.keys,
        )
    }

    @Test
    fun `no field carries anything that identifies a person`() {
        val flat = report().toFields().toString().lowercase()
        listOf("uid", "email", "account", "gamecode", "gametitle", "androidid", "advertising")
            .forEach { assertTrue(it, !flat.contains(it)) }
    }

    @Test
    fun `level fps drops level zero and levels that were never measured`() {
        // Index 0 is not a level, and BenchmarkSession leaves a level it did not
        // close at 0.0 - neither is a measurement.
        val measured = BenchmarkReport.levelFpsOf(doubleArrayOf(0.0, 0.0, 59.5, 0.0, 60.2))
        assertEquals(mapOf(2 to 59.5, 4 to 60.2), measured)
    }

    @Test
    fun `a report survives a json round trip`() {
        assertEquals(report(), BenchmarkReport.fromJson(report().toJson()))
    }

    @Test
    fun `a report with no cpu clock survives a json round trip`() {
        // CpuClock.maxKhz() returns null routinely - sysfs is unreadable on a
        // lot of devices - so the JSONObject.NULL path this exercises is common,
        // not exotic.
        val withoutClock = report().copy(capabilities = capabilities.copy(cpuMaxClockKHz = null))
        assertEquals(withoutClock, BenchmarkReport.fromJson(withoutClock.toJson()))
    }

    @Test
    fun `the json carries the same keys as the firestore fields`() {
        val json = org.json.JSONObject(report().toJson())
        assertEquals(report().toFields().keys, json.keys().asSequence().toSet())
    }

    @Test
    fun `unreadable json is null rather than a crash`() {
        assertNull(BenchmarkReport.fromJson("not json at all"))
        assertNull(BenchmarkReport.fromJson(""))
        assertNull(BenchmarkReport.fromJson(null))
    }
}
