package org.uoyabause.android

import android.content.Context
import android.content.DialogInterface
import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.os.SystemClock
import android.util.Log
import androidx.activity.OnBackPressedCallback
import androidx.activity.result.ActivityResultLauncher
import androidx.activity.result.contract.ActivityResultContracts
import androidx.appcompat.app.AppCompatActivity
import androidx.lifecycle.lifecycleScope
import androidx.preference.PreferenceManager
import com.google.android.material.dialog.MaterialAlertDialogBuilder
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import org.devmiyax.yabasanshiro.BuildConfig
import org.devmiyax.yabasanshiro.R
import org.devmiyax.yabasanshiro.databinding.ActivityBenchmarkBinding
import java.io.File

/**
 * Walks each benchmark disc down its ladder and turns the outcome into a saved
 * [GpuProfile].
 *
 * The discs run in [BenchmarkLadder.SWEEP_ORDER] - VDP2 NBG, VDP2 RBG, VDP1 -
 * each starting at its most expensive Vulkan rung and stepping down until one
 * holds 60fps on every level. A disc that holds none settles on OpenGL without
 * running it, and the discs after it are not measured on Vulkan.
 *
 * When VDP2 is what put the device on OpenGL, one question is left that no 60fps
 * verdict can answer: whether OpenGL should draw VDP1 polygons with GPU
 * tessellation or with the perspective-corrected triangle path. The VDP1 disc is
 * then run on both, triangle first, and tessellation is taken when it ran to the
 * end and stayed close to the triangle run on every level (see
 * [BenchmarkVerdict.openGlPolygon]).
 *
 * Per the contract of BenchmarkRequest, only RESULT_OK carries a real
 * measurement - a stall, a user pause/exit, or an extraction failure all mean the
 * run did not complete, and this activity backs out with RESULT_CANCELED without
 * saving anything. This is deliberate: a partial run must never be mistaken for a
 * measured device.
 */
class BenchmarkActivity : AppCompatActivity() {
    private lateinit var binding: ActivityBenchmarkBinding

    private var gpuKey: String? = null
    private var gpuName: String = ""

    /** Index into [BenchmarkLadder.SWEEP_ORDER] of the disc being measured. */
    private var stepIndex = 0

    /** Index into the current disc's ladder; walked downwards. */
    private var rungIndex = 0

    /** Why the sweep gave up, for the report. Null while it is still running. */
    private var cancelReason: String? = null

    // BenchmarkAssets.DISCS ids are 1 (VDP1), 2 (VDP2 NBG), 3 (VDP2 RBG), which are
    // also the BenchmarkLadder disc ids.
    private val chosenRungs = mutableMapOf<Int, BenchmarkRung>()

    // Every rung that was actually run, with its per-level fps. Kept as evidence -
    // see writeReport().
    private val attempts = mutableListOf<Attempt>()

    /** The OpenGL VDP1 run in flight, or null when none is. */
    private var openGlRung: BenchmarkRung? = null

    /** Per-level fps of the OpenGL triangle run, once it completed a cycle. */
    private var openGlTriangleFps: Map<Int, Double> = emptyMap()

    /** The polygon path the OpenGL comparison settled on, for the report. */
    private var openGlPolygonChoice: String? = null

    private class Attempt(
        val discId: Int,
        val rung: BenchmarkRung,
        val passed: Boolean,
        val reason: String,
        val levelFps: DoubleArray,
    )

    private val discLauncher =
        registerForActivityResult(ActivityResultContracts.StartActivityForResult()) { result ->
            if (stepIndex >= BenchmarkLadder.SWEEP_ORDER.size) {
                // Stray callback after the run already ended; ignore it.
                return@registerForActivityResult
            }
            val disc = discOf(BenchmarkLadder.SWEEP_ORDER[stepIndex])
            val rung = ladderFor(disc.id)[rungIndex]
            val passed =
                result.resultCode == RESULT_OK &&
                    (result.data?.getBooleanExtra(BenchmarkRequest.EXTRA_PASSED, false) ?: false)
            attempts +=
                Attempt(
                    discId = disc.id,
                    rung = rung,
                    passed = passed,
                    reason = result.data?.getStringExtra(BenchmarkRequest.EXTRA_END_REASON) ?: "none",
                    levelFps =
                        result.data?.getDoubleArrayExtra(BenchmarkRequest.EXTRA_LEVEL_FPS)
                            ?: DoubleArray(0),
                )
            // Written after every run, not only at the end: a sweep that ends
            // without a verdict is exactly the one worth looking at, and it would
            // otherwise leave nothing behind.
            writeReport(null)

            if (result.resultCode != RESULT_OK) {
                cancelRun("run did not report a measurement")
                return@registerForActivityResult
            }

            if (passed) {
                chosenRungs[disc.id] = rung
                startStep(stepIndex + 1)
            } else if (rungIndex > 0) {
                // Step down to the next cheaper rung of the same disc.
                rungIndex--
                runCurrentRung()
            } else {
                // Every Vulkan rung fell short: the disc settles on OpenGL,
                // which is taken without measuring it.
                chosenRungs[disc.id] = BenchmarkLadder.OPENGL_FLOOR
                startStep(stepIndex + 1)
            }
        }

    private val openGlLauncher =
        registerForActivityResult(ActivityResultContracts.StartActivityForResult()) { result ->
            val rung = openGlRung ?: return@registerForActivityResult
            openGlRung = null
            val tessellation = rung.polygonGeneration == RecommendedSettings.POLYGON_GPU_TESSELLATION
            if (tessellation) {
                // The run came back, so it did not take the process down with it.
                clearTessellationTrial()
            }
            val reason = result.data?.getStringExtra(BenchmarkRequest.EXTRA_END_REASON) ?: "none"
            val levelFpsArray =
                result.data?.getDoubleArrayExtra(BenchmarkRequest.EXTRA_LEVEL_FPS) ?: DoubleArray(0)
            val levelFps = BenchmarkReport.levelFpsOf(levelFpsArray)

            fun record(passed: Boolean) {
                attempts += Attempt(BenchmarkLadder.DISC_VDP1, rung, passed, reason, levelFpsArray)
                writeReport(null)
            }

            if (result.resultCode != RESULT_OK) {
                record(passed = false)
                if (reason == BenchmarkRequest.REASON_STALL || reason == BenchmarkRequest.REASON_NOT_READY) {
                    // The configuration itself did not run on this device. That is
                    // an answer to the comparison, not a sweep the user abandoned:
                    // the triangle path stays.
                    finishWithProfile(RecommendedSettings.POLYGON_TRIANGLE)
                } else {
                    cancelRun("OpenGL ${rung.label} run did not report a measurement")
                }
                return@registerForActivityResult
            }

            if (!tessellation) {
                val measured = reason == BenchmarkRequest.REASON_CYCLE && levelFps.isNotEmpty()
                record(passed = measured)
                if (!measured) {
                    finishWithProfile(RecommendedSettings.POLYGON_TRIANGLE)
                    return@registerForActivityResult
                }
                openGlTriangleFps = levelFps
                runOpenGl(
                    BenchmarkLadder.openGlTessellation(BenchmarkLadder.resolutionOf(chosenRungs)),
                    BenchmarkVerdict.tessellationFloor(levelFps),
                )
            } else {
                val polygon = BenchmarkVerdict.openGlPolygon(openGlTriangleFps, levelFps)
                record(passed = polygon == RecommendedSettings.POLYGON_GPU_TESSELLATION)
                finishWithProfile(polygon)
            }
        }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        binding = ActivityBenchmarkBinding.inflate(layoutInflater)
        setContentView(binding.root)

        gpuKey = intent.getStringExtra(EXTRA_GPU_KEY)
        gpuName = intent.getStringExtra(EXTRA_GPU_NAME).orEmpty()

        onBackPressedDispatcher.addCallback(
            this,
            object : OnBackPressedCallback(true) {
                override fun handleOnBackPressed() {
                    cancelRun("back pressed")
                }
            },
        )

        if (gpuKey == null) {
            // No key to save a profile under - back out the same way an
            // unmeasurable disc does, without an error dialog.
            cancelRun("no GPU key")
            return
        }

        startStep(0)
    }

    /**
     * What this device can do, read once.
     *
     * [DeviceCapabilities.forContext] creates a Vulkan instance to read the GPU
     * ids, so it is far from free - and calling it per ladder lookup put that
     * probe in the middle of the previous run's teardown, where creating a second
     * Vulkan device while the emulator is destroying its own wedged the Adreno
     * driver: the render loop never left YabauseDeInit, isRunning() stayed 1 for
     * good, and every later run was refused. None of this can change during a
     * sweep anyway.
     */
    private val capabilities: DeviceCapabilities by lazy { DeviceCapabilities.forContext(this) }

    private fun discOf(discId: Int): BenchmarkDisc = BenchmarkAssets.DISCS.first { it.id == discId }

    /**
     * The Vulkan ladder of [discId]. Recomputed rather than cached: RBG and VDP1
     * run at the resolution NBG settled on, which is only known once NBG is done.
     */
    private fun ladderFor(discId: Int): List<BenchmarkRung> =
        BenchmarkLadder.forDisc(discId, BenchmarkLadder.resolutionOf(chosenRungs))

    /**
     * Starts the disc at [index] of the sweep order at the top of its ladder, or
     * finishes the sweep.
     *
     * A disc that is not measured on Vulkan - no usable Vulkan, or an earlier disc
     * already settled on OpenGL - settles on OpenGL without running anything.
     */
    private fun startStep(index: Int) {
        stepIndex = index
        val order = BenchmarkLadder.SWEEP_ORDER
        if (stepIndex >= order.size) {
            finishSweep()
            return
        }
        val discId = order[stepIndex]
        // canUseVulkan, not vulkanSupported: RecommendedSettings puts a Vulkan
        // device without the tessellation feature on OpenGL whatever the
        // measurement says, so measuring its Vulkan rungs would spend minutes
        // producing a verdict that is then overridden.
        if (!BenchmarkLadder.measuresOnVulkan(discId, chosenRungs, capabilities.canUseVulkan)) {
            chosenRungs[discId] = BenchmarkLadder.OPENGL_FLOOR
            startStep(stepIndex + 1)
            return
        }
        rungIndex = ladderFor(discId).lastIndex
        runCurrentRung()
    }

    private fun runCurrentRung() {
        val disc = discOf(BenchmarkLadder.SWEEP_ORDER[stepIndex])
        launchRun(disc, ladderFor(disc.id)[rungIndex], discLauncher, stepIndex + 1)
    }

    /**
     * Ends the sweep, deciding OpenGL's polygon path first when there is one to
     * decide.
     *
     * It is measured only when VDP2 put the device on OpenGL (see
     * [BenchmarkLadder.measuresOpenGlPolygon]), and only where there is a choice:
     * a GPU without the GL tessellation extension has only the triangle path, and
     * Google Play Games on PC ignores measured profiles altogether.
     */
    private fun finishSweep() {
        val outcome = BenchmarkLadder.outcomeOf(chosenRungs)
        if (outcome.videoCore != VideoCore.OPENGL ||
            !BenchmarkLadder.measuresOpenGlPolygon(chosenRungs) ||
            !capabilities.hasTessellation ||
            capabilities.isPc
        ) {
            finishWithProfile(RecommendedSettings.POLYGON_TRIANGLE)
            return
        }
        val resolution = BenchmarkLadder.resolutionOf(chosenRungs)
        if (consumeTessellationTrial()) {
            // The previous sweep died inside the tessellation run. A native crash
            // takes this activity down with the emulator, so this is the only
            // place that can notice - and running it again would crash again.
            attempts +=
                Attempt(
                    BenchmarkLadder.DISC_VDP1,
                    BenchmarkLadder.openGlTessellation(resolution),
                    passed = false,
                    reason = REASON_CRASHED,
                    levelFps = DoubleArray(0),
                )
            finishWithProfile(RecommendedSettings.POLYGON_TRIANGLE)
            return
        }
        // An empty floor measures the whole cycle: the triangle run is the
        // reference, so every level is needed however slow it is.
        runOpenGl(BenchmarkLadder.openGl(resolution), DoubleArray(0))
    }

    private fun runOpenGl(
        rung: BenchmarkRung,
        levelFpsFloor: DoubleArray,
    ) {
        openGlRung = rung
        val step = BenchmarkLadder.SWEEP_ORDER.indexOf(BenchmarkLadder.DISC_VDP1) + 1
        launchRun(discOf(BenchmarkLadder.DISC_VDP1), rung, openGlLauncher, step, levelFpsFloor) {
            if (rung.polygonGeneration == RecommendedSettings.POLYGON_GPU_TESSELLATION) markTessellationTrial()
        }
    }

    /**
     * Runs [rung] on [disc] once the previous core is gone.
     *
     * [beforeLaunch] runs right before the emulator is started, after every step
     * that can still end the sweep without starting it.
     */
    private fun launchRun(
        disc: BenchmarkDisc,
        rung: BenchmarkRung,
        launcher: ActivityResultLauncher<Intent>,
        step: Int,
        levelFpsFloor: DoubleArray? = null,
        beforeLaunch: () -> Unit = {},
    ) {
        updateProgress(disc, rung, step)
        lifecycleScope.launch {
            if (!awaitEmulatorShutdown()) {
                cancelRun("previous core never shut down")
                return@launch
            }
            val cuePath = BenchmarkAssets.extract(this@BenchmarkActivity, disc)
            if (cuePath == null) {
                cancelRun("disc ${disc.baseName} could not be extracted")
                return@launch
            }
            beforeLaunch()
            launcher.launch(
                BenchmarkRequest.intent(this@BenchmarkActivity, cuePath, disc, rung, levelFpsFloor),
            )
        }
    }

    /**
     * Waits until the previous disc's emulator core has finished tearing down.
     *
     * Android starts the next activity before destroying the previous one, so
     * launching the next disc as soon as a result arrives would initialize a second
     * emulator core while the first is still alive in the same process. The first
     * one's teardown then clears CurrentSH2 out from under the other's still-running
     * dynarec, which crashes in memGetByte. Normal play never hits this because
     * leaving a game kills the process outright.
     *
     * isRunning() drops to 0 only after the render loop has exited and
     * YabauseDeInit has run, so it is the signal to wait on. Returns false if the
     * previous core never shut down, which ends the run rather than risking the
     * crash.
     */
    private suspend fun awaitEmulatorShutdown(): Boolean {
        val deadline = SystemClock.elapsedRealtime() + EMULATOR_SHUTDOWN_TIMEOUT_MS
        while (YabauseRunnable.isRunning() != 0) {
            if (SystemClock.elapsedRealtime() > deadline) return false
            delay(EMULATOR_SHUTDOWN_POLL_MS)
        }
        return true
    }

    /**
     * Remembers, across a process death, that the tessellation run is in flight.
     *
     * commit(), not apply(): the point is to survive the native crash this guards
     * against, and apply() writes to disk later.
     */
    private fun markTessellationTrial() {
        getSharedPreferences(STATE_PREFS, MODE_PRIVATE)
            .edit()
            .putString(KEY_TESSELLATION_TRIAL_GPU, gpuKey)
            .commit()
    }

    private fun clearTessellationTrial() {
        getSharedPreferences(STATE_PREFS, MODE_PRIVATE)
            .edit()
            .remove(KEY_TESSELLATION_TRIAL_GPU)
            .commit()
    }

    /**
     * True when the previous sweep on this GPU never came back from its
     * tessellation run. The mark is cleared here, so a later sweep - after an app
     * update, say - tries again instead of being locked out for good.
     */
    private fun consumeTessellationTrial(): Boolean {
        val crashed =
            getSharedPreferences(STATE_PREFS, MODE_PRIVATE)
                .getString(KEY_TESSELLATION_TRIAL_GPU, null) == gpuKey
        if (crashed) clearTessellationTrial()
        return crashed
    }

    private fun updateProgress(
        disc: BenchmarkDisc,
        rung: BenchmarkRung,
        step: Int,
    ) {
        binding.benchmarkStep.text =
            getString(R.string.benchmark_progress_step, step, BenchmarkAssets.DISCS.size)
        binding.benchmarkDiscName.text = "${discDisplayName(disc)} (${rung.label})"
    }

    private fun discDisplayName(disc: BenchmarkDisc): String =
        when (disc.id) {
            1 -> getString(R.string.benchmark_disc_name_1)
            2 -> getString(R.string.benchmark_disc_name_2)
            3 -> getString(R.string.benchmark_disc_name_3)
            else -> disc.baseName
        }

    private fun finishWithProfile(openGlPolygon: String) {
        val key = gpuKey
        if (key == null) {
            cancelRun("no GPU key")
            return
        }
        val outcome = BenchmarkLadder.outcomeOf(chosenRungs, openGlPolygon)
        if (outcome.videoCore == VideoCore.OPENGL) openGlPolygonChoice = openGlPolygon
        val profile =
            BenchmarkVerdict.toProfile(
                key = key,
                name = gpuName.ifBlank { key },
                outcome = outcome,
            )
        // Info level, not debug: some retro-handheld ROMs drop debug logs
        // device-wide, and a measurement that cannot be read back off the device
        // is worthless.
        Log.i(
            TAG,
            "benchmark complete: core=${profile.videoCore} polygon=${profile.polygonGeneration} " +
                "compute=${profile.useComputeShader} composite=${profile.vdp2Composite} " +
                "rbgResolution=${profile.rbgResolution} resolution=${profile.resolution}",
        )
        writeReport(profile)
        GpuProfileStore.saveLocal(this, profile)
        val recommended = applyMeasuredSettings(profile)
        // After the profile is saved and the settings are applied, never before:
        // the measurement is the product, and the report must not be able to
        // cost the user any part of it. buildReport() runs inside this same
        // try/catch - as an argument to enqueue() it would otherwise execute
        // outside enqueue()'s own try/catch and could throw straight into this
        // activity.
        try {
            if (BenchmarkReportUploader.enqueue(this, buildReport(profile))) {
                BenchmarkReportUploader.flushInBackground(this)
            }
        } catch (e: Exception) {
            Log.i(TAG, "benchmark report could not be built or queued", e)
        }
        showResult(recommended)
    }

    /**
     * Shows what the sweep settled on, then ends the run.
     *
     * The measurement is applied silently, so without this the several minutes
     * the user just spent produce no visible answer - the settings screen only
     * shows the values one by one, and nothing says which of them the benchmark
     * decided. Every applied setting is listed, not just the ones that changed:
     * a run that confirms the current settings still answered the question.
     *
     * RESULT_OK is set before the dialog so a caller that is still alive refreshes
     * itself even if this activity is destroyed while the dialog is up.
     */
    private fun showResult(recommended: RecommendedSettings) {
        setResult(RESULT_OK)
        val settings =
            RecommendedSettingsApplier
                .values(recommended)
                .joinToString("\n") { RecommendedSettingsLabels.describe(this, it) }
        val dialog =
            MaterialAlertDialogBuilder(this)
                .setTitle(R.string.benchmark_result_title)
                .setMessage(
                    getString(R.string.benchmark_result_message) + "\n\n" + settings + "\n\n" +
                        getString(R.string.recommended_settings_scope_note),
                ).setPositiveButton(android.R.string.ok) { _, _ -> finish() }
                .setCancelable(false)
                .create()
        // Nothing to undo here, so the default D-pad focus goes to the only button.
        dialog.setOnShowListener {
            val button = dialog.getButton(DialogInterface.BUTTON_POSITIVE)
            button?.post {
                button.isFocusable = true
                button.isFocusableInTouchMode = true
                button.requestFocus()
            }
        }
        dialog.show()
    }

    /**
     * Turns the saved profile into the device's settings.
     *
     * The callers that launch this activity also re-derive the settings when the
     * result comes back, but a sweep runs the emulator up to six times over
     * several minutes and the screen behind it does not reliably survive that: on
     * an AYN Thor the launching activity was gone by the time the sweep finished,
     * its result callback never ran, and the device kept the safe-side defaults
     * even though the measurement had been saved. Applying here means the
     * measurement takes effect whether or not anything is left to return to.
     *
     * This is the same single code path the callers use ([RecommendedSettings.forDevice]
     * over the store), so a caller that does survive re-derives the same values
     * and only refreshes its own UI.
     */
    private fun applyMeasuredSettings(profile: GpuProfile): RecommendedSettings {
        val recommended = RecommendedSettings.forDevice(capabilities, profile)
        RecommendedSettingsApplier.apply(
            PreferenceManager.getDefaultSharedPreferences(this),
            recommended,
        )
        Log.i(
            TAG,
            "settings applied: core=${recommended.videoCore} polygon=${recommended.polygonGeneration} " +
                "compute=${recommended.useComputeShader} composite=${recommended.vdp2Composite} " +
                "rbgResolution=${recommended.rbgResolution} resolution=${recommended.resolution} " +
                "sh2Cache=${recommended.useSh2Cache}",
        )
        return recommended
    }

    /**
     * Turns this sweep into the report that is shared.
     *
     * Same content as the local benchmark_result.txt, minus everything that
     * identifies the device's owner - see BenchmarkReport for what the payload
     * may and may not carry.
     */
    private fun buildReport(profile: GpuProfile) =
        BenchmarkReport(
            installId = BenchmarkReportUploader.installId(this),
            gpuKey = profile.key,
            gpuName = profile.name,
            deviceModel = "${Build.MANUFACTURER} ${Build.MODEL}".trim(),
            androidRelease = Build.VERSION.RELEASE.orEmpty(),
            androidSdk = Build.VERSION.SDK_INT,
            appVersionName = BuildConfig.VERSION_NAME,
            appVersionCode = BuildConfig.VERSION_CODE,
            discSetVersion = BenchmarkAssets.discSetVersion(this),
            capabilities = capabilities,
            chosen = chosenRungs.entries.associate { it.key to it.value.label },
            attempts =
                attempts.map { attempt ->
                    BenchmarkAttemptRecord(
                        discId = attempt.discId,
                        rung = attempt.rung.label,
                        passed = attempt.passed,
                        reason = attempt.reason,
                        levelFps = BenchmarkReport.levelFpsOf(attempt.levelFps),
                    )
                },
            verdict =
                BenchmarkOutcome(
                    videoCore = profile.videoCore,
                    polygonGeneration = profile.polygonGeneration,
                    useComputeShader = profile.useComputeShader,
                    vdp2Composite = profile.vdp2Composite,
                    rbgResolution = profile.rbgResolution,
                    resolution = profile.resolution,
                ),
        )

    /**
     * Writes the raw measurement next to the saved profile.
     *
     * A [GpuProfile] only records the verdict, but the numbers behind it are what
     * makes a surprising recommendation checkable. Logcat is not a reliable place
     * to keep them: several retro-handheld ROMs drop everything below error level,
     * so a measurement taken on exactly the kind of low-end device the sweep
     * exists for would be unreadable. A file survives that.
     *
     * Failing to write the report never fails the run - the profile is the
     * product, this is only evidence.
     */
    private fun writeReport(profile: GpuProfile?) {
        try {
            val dir = getExternalFilesDir(null) ?: return
            val text =
                buildString {
                    appendLine("gpu: ${gpuName.ifBlank { gpuKey.orEmpty() }} (${gpuKey.orEmpty()})")
                    appendLine("device: ${Build.MANUFACTURER} ${Build.MODEL} / Android ${Build.VERSION.RELEASE}")
                    if (profile == null) {
                        appendLine("status: incomplete${cancelReason?.let { " - $it" } ?: ""}")
                    }
                    attempts.forEach { attempt ->
                        val levels =
                            attempt.levelFps
                                .withIndex()
                                .filter { it.index > 0 && it.value > 0.0 }
                                .joinToString(" ") { "LV%02d=%.1f".format(it.index, it.value) }
                        appendLine(
                            "disc ${attempt.discId} ${attempt.rung.label}: " +
                                "${if (attempt.passed) "PASS" else "FAIL"} (${attempt.reason}) $levels",
                        )
                    }
                    BenchmarkAssets.DISCS.forEach { disc ->
                        appendLine("disc ${disc.id} chose: ${chosenRungs[disc.id]?.label ?: "-"}")
                    }
                    openGlPolygonChoice?.let { appendLine("opengl polygon: $it") }
                    if (profile != null) {
                        appendLine(
                            "verdict: core=${profile.videoCore} polygon=${profile.polygonGeneration} " +
                                "compute=${profile.useComputeShader} composite=${profile.vdp2Composite} " +
                                "rbgResolution=${profile.rbgResolution} resolution=${profile.resolution}",
                        )
                    }
                }
            File(dir, REPORT_NAME).writeText(text)
        } catch (e: Exception) {
            Log.i(TAG, "benchmark report could not be written", e)
        }
    }

    private fun cancelRun(why: String) {
        cancelReason = why
        Log.i(TAG, "benchmark cancelled: $why")
        writeReport(null)
        setResult(RESULT_CANCELED)
        finish()
    }

    companion object {
        private const val TAG = "BenchmarkActivity"
        private const val REPORT_NAME = "benchmark_result.txt"

        /** Attempt reason for a tessellation run the previous sweep never came back from. */
        private const val REASON_CRASHED = "crashed"

        private const val STATE_PREFS = "benchmark_state"
        private const val KEY_TESSELLATION_TRIAL_GPU = "gl_tessellation_trial_gpu"
        private const val EXTRA_GPU_KEY = "org.uoyabause.android.BenchmarkGpuKey"
        private const val EXTRA_GPU_NAME = "org.uoyabause.android.BenchmarkGpuName"

        // Provisional values. The emulator's own deinit waits up to 5 seconds for its
        // render loop to exit, so this has to outlast that; calibrate after measuring
        // several devices.
        private const val EMULATOR_SHUTDOWN_TIMEOUT_MS = 15_000L
        private const val EMULATOR_SHUTDOWN_POLL_MS = 50L

        fun intent(
            context: Context,
            gpuKey: String,
            gpuName: String,
        ): Intent =
            Intent(context, BenchmarkActivity::class.java).apply {
                putExtra(EXTRA_GPU_KEY, gpuKey)
                putExtra(EXTRA_GPU_NAME, gpuName)
            }
    }
}
