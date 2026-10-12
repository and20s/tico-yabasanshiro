package org.uoyabause.android

import androidx.preference.PreferenceManager
import androidx.test.core.app.ApplicationProvider
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import java.io.File

// TestYabauseApplication is required, not optional: the real YabauseApplication
// loads the native library, which is not present in a JVM test and fails with
// UnsatisfiedLinkError before the first assertion runs.
@RunWith(RobolectricTestRunner::class)
@Config(
    sdk = [28],
    application = TestYabauseApplication::class,
)
class BenchmarkReportUploaderTest {
    private val context = ApplicationProvider.getApplicationContext<android.content.Context>()

    private class RecordingWriter(
        val fail: Boolean = false,
    ) : BenchmarkReportUploader.Writer {
        var calls = 0
        var lastDocumentId: String? = null

        override suspend fun write(
            documentId: String,
            fields: Map<String, Any?>,
        ) {
            calls++
            lastDocumentId = documentId
            if (fail) throw IllegalStateException("network is down")
        }
    }

    private fun pendingFile() = File(context.filesDir, "benchmark_report_pending.json")

    private fun report() =
        BenchmarkReport(
            installId = "install-1",
            gpuKey = "vk:5143:6040001",
            gpuName = "Qualcomm Adreno (TM) 650",
            deviceModel = "Retroid Pocket Classic",
            androidRelease = "13",
            androidSdk = 33,
            appVersionName = "1.20.37",
            appVersionCode = 12037,
            discSetVersion = "a3f19c2b4d5e6f70",
            capabilities =
                DeviceCapabilities(
                    vulkanSupported = true,
                    glEsVersion = 0x30002,
                    hasTessellation = true,
                    cpuMaxClockKHz = 2_400_000,
                    isPc = false,
                    gpuKey = "vk:5143:6040001",
                    vulkanTessellation = true,
                ),
            chosen = mapOf(1 to "vk-compute-rasterizer", 2 to "vk-legacy-composite", 3 to "gl"),
            attempts = emptyList(),
            verdict =
                BenchmarkOutcome(
                    videoCore = VideoCore.OPENGL,
                    polygonGeneration = RecommendedSettings.POLYGON_TRIANGLE,
                    useComputeShader = false,
                    vdp2Composite = Vdp2Composite.VALUE_LEGACY,
                    rbgResolution = RecommendedSettings.RBG_ORIGINAL,
                ),
        )

    @Before
    fun reset() {
        pendingFile().delete()
        PreferenceManager
            .getDefaultSharedPreferences(context)
            .edit()
            .clear()
            .commit()
        context
            .getSharedPreferences("benchmark_prefs", android.content.Context.MODE_PRIVATE)
            .edit()
            .clear()
            .commit()
    }

    @After
    fun restoreWriter() {
        BenchmarkReportUploader.resetWriter()
    }

    @Test
    fun `consent defaults to on and follows what the checkbox recorded`() {
        // On by default: the checkbox is shown before every run with this as its
        // initial state, so the default is only ever read for a device that has
        // no measurement to send yet.
        assertTrue(BenchmarkReportUploader.hasConsent(context))
        BenchmarkReportUploader.setConsent(context, false)
        assertFalse(BenchmarkReportUploader.hasConsent(context))
        BenchmarkReportUploader.setConsent(context, true)
        assertTrue(BenchmarkReportUploader.hasConsent(context))
    }

    @Test
    fun `without consent nothing is even written to disk`() {
        BenchmarkReportUploader.setConsent(context, false)
        assertFalse(BenchmarkReportUploader.enqueue(context, report()))
        assertFalse(pendingFile().exists())
    }

    @Test
    fun `with consent the report is parked before anything is sent`() {
        BenchmarkReportUploader.setConsent(context, true)
        assertTrue(BenchmarkReportUploader.enqueue(context, report()))
        assertTrue(pendingFile().exists())
        assertEquals(report(), BenchmarkReport.fromJson(pendingFile().readText()))
    }

    @Test
    fun `a successful send clears the queue`() {
        val writer = RecordingWriter()
        BenchmarkReportUploader.writer = writer
        BenchmarkReportUploader.setConsent(context, true)
        BenchmarkReportUploader.enqueue(context, report())

        assertTrue(runBlocking { BenchmarkReportUploader.flush(context) })
        assertEquals(1, writer.calls)
        assertEquals("install-1_a3f19c2b4d5e6f70_12037", writer.lastDocumentId)
        assertFalse(pendingFile().exists())
    }

    @Test
    fun `a failed send keeps the report queued and throws nothing`() {
        val writer = RecordingWriter(fail = true)
        BenchmarkReportUploader.writer = writer
        BenchmarkReportUploader.setConsent(context, true)
        BenchmarkReportUploader.enqueue(context, report())

        assertFalse(runBlocking { BenchmarkReportUploader.flush(context) })
        assertEquals(1, writer.calls)
        assertTrue(pendingFile().exists())
    }

    @Test
    fun `consent withdrawn after measuring discards the queued report unsent`() {
        val writer = RecordingWriter()
        BenchmarkReportUploader.writer = writer
        BenchmarkReportUploader.setConsent(context, true)
        BenchmarkReportUploader.enqueue(context, report())

        BenchmarkReportUploader.setConsent(context, false)
        assertFalse(runBlocking { BenchmarkReportUploader.flush(context) })
        assertEquals(0, writer.calls)
        assertFalse(pendingFile().exists())
    }

    @Test
    fun `an empty queue sends nothing`() {
        val writer = RecordingWriter()
        BenchmarkReportUploader.writer = writer
        BenchmarkReportUploader.setConsent(context, true)

        assertFalse(runBlocking { BenchmarkReportUploader.flush(context) })
        assertEquals(0, writer.calls)
    }

    @Test
    fun `an unreadable queued file is discarded rather than retried forever`() {
        val writer = RecordingWriter()
        BenchmarkReportUploader.writer = writer
        BenchmarkReportUploader.setConsent(context, true)
        pendingFile().writeText("this is not json")

        assertFalse(runBlocking { BenchmarkReportUploader.flush(context) })
        assertEquals(0, writer.calls)
        assertFalse(pendingFile().exists())
    }

    @Test
    fun `the install id is created once and then stays put`() {
        val first = BenchmarkReportUploader.installId(context)
        assertEquals(first, BenchmarkReportUploader.installId(context))
        assertEquals(36, first.length)
    }
}
