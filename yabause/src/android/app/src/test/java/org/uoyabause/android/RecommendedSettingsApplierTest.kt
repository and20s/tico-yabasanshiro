package org.uoyabause.android

import android.content.Context
import android.content.SharedPreferences
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [28])
class RecommendedSettingsApplierTest {
    private lateinit var prefs: SharedPreferences

    private val settings =
        RecommendedSettings(
            videoCore = VideoCore.VULKAN,
            polygonGeneration = "2",
            useComputeShader = true,
            vdp2Composite = Vdp2Composite.VALUE_LEGACY,
            rbgResolution = "0",
            useSh2Cache = true,
            needsBenchmark = false,
            resolution = RecommendedSettings.RESOLUTION_2X,
        )

    @Before
    fun setUp() {
        prefs =
            RuntimeEnvironment.getApplication().getSharedPreferences("applier", Context.MODE_PRIVATE)
        prefs.edit().clear().apply()
    }

    @Test
    fun `all seven settings are written`() {
        RecommendedSettingsApplier.apply(prefs, settings)

        assertEquals(VideoCore.VULKAN, prefs.getString(VideoCore.KEY, null))
        assertEquals("2", prefs.getString("pref_polygon_generation", null))
        assertEquals(true, prefs.getBoolean("pref_use_compute_shader", false))
        assertEquals(Vdp2Composite.VALUE_LEGACY, prefs.getString(Vdp2Composite.KEY, null))
        assertEquals("0", prefs.getString("pref_rbg_resolution", null))
        assertEquals(RecommendedSettings.RESOLUTION_2X, prefs.getString("pref_resolution", null))
        assertEquals(true, prefs.getBoolean("pref_use_sh2_cache", false))
    }

    // Fix 8: this feature may only ever write these seven keys. A binding
    // constraint with no test is one careless edit from being violated.
    @Test
    fun `apply writes exactly the seven keys this feature owns`() {
        RecommendedSettingsApplier.apply(prefs, settings)

        val expectedKeys =
            setOf(
                VideoCore.KEY,
                "pref_polygon_generation",
                "pref_use_compute_shader",
                Vdp2Composite.KEY,
                "pref_rbg_resolution",
                "pref_resolution",
                "pref_use_sh2_cache",
            )
        assertEquals(expectedKeys, prefs.all.keys)
    }

    @Test
    fun `the diff lists only the settings that would change`() {
        prefs.edit().putString(VideoCore.KEY, VideoCore.VULKAN).apply()

        val diff = RecommendedSettingsApplier.diff(prefs, settings)

        assertTrue(diff.none { it.key == VideoCore.KEY })
        assertTrue(diff.any { it.key == Vdp2Composite.KEY })
    }

    @Test
    fun `applying twice leaves nothing to change`() {
        RecommendedSettingsApplier.apply(prefs, settings)
        assertTrue(RecommendedSettingsApplier.diff(prefs, settings).isEmpty())
    }

    // Fix 6: the app never calls PreferenceManager.setDefaultValues, so an
    // untouched key does not exist in SharedPreferences -- but the XML default
    // (res/xml/preferences.xml) is what is actually in effect. diff() must
    // compare against those defaults, not against "" / false, or it reports
    // changes that would not actually happen.
    @Test
    fun `a recommendation equal to the XML defaults produces an empty diff on an untouched store`() {
        val defaultSettings =
            RecommendedSettings(
                videoCore = VideoCore.UNSET,
                polygonGeneration = RecommendedSettings.POLYGON_TRIANGLE,
                useComputeShader = false,
                vdp2Composite = Vdp2Composite.DEFAULT_VALUE,
                rbgResolution = RecommendedSettings.RBG_ORIGINAL,
                useSh2Cache = true,
                needsBenchmark = false,
                resolution = RecommendedSettings.RESOLUTION_NATIVE,
            )

        assertTrue(prefs.all.isEmpty())
        assertTrue(RecommendedSettingsApplier.diff(prefs, defaultSettings).isEmpty())
    }
}
