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
class InGamePreferenceMirrorTest {
    private lateinit var context: Context
    private lateinit var source: SharedPreferences
    private lateinit var destination: SharedPreferences

    @Before
    fun setUp() {
        context = RuntimeEnvironment.getApplication()
        source = context.getSharedPreferences("source", Context.MODE_PRIVATE)
        destination = context.getSharedPreferences("destination", Context.MODE_PRIVATE)
        source.edit().clear().apply()
        destination.edit().clear().apply()
    }

    @Test
    fun `every per-game setting is carried over`() {
        source
            .edit()
            .putBoolean("pref_fps", true)
            .putString("pref_polygon_generation", "3")
            .putString(Vdp2Composite.KEY, Vdp2Composite.VALUE_LEGACY)
            .putString(VideoCore.KEY, VideoCore.VULKAN)
            .apply()

        copyInGamePreferences(source, destination)

        assertEquals(true, destination.getBoolean("pref_fps", false))
        assertEquals("3", destination.getString("pref_polygon_generation", null))
        assertEquals(Vdp2Composite.VALUE_LEGACY, destination.getString(Vdp2Composite.KEY, null))
        assertEquals(VideoCore.VULKAN, destination.getString(VideoCore.KEY, null))
    }

    @Test
    fun `keys missing in the source fall back to their default`() {
        copyInGamePreferences(source, destination)

        for (pref in IN_GAME_PREFS) {
            assertTrue("missing key: ${pref.key}", destination.contains(pref.key))
        }
        assertEquals(
            Vdp2Composite.DEFAULT_VALUE,
            destination.getString(Vdp2Composite.KEY, null),
        )
    }

    // A value stored as Int by an older build must not crash the mirror: this is
    // what getStringSafe exists for.
    @Test
    fun `legacy Int values are carried over as strings`() {
        source.edit().putInt("pref_resolution", 2).apply()

        copyInGamePreferences(source, destination)

        assertEquals("2", destination.getString("pref_resolution", null))
    }

    @Test
    fun `the VDP2 compositing setting is part of the per-game set`() {
        assertTrue(IN_GAME_PREFS.any { it.key == Vdp2Composite.KEY })
        assertTrue(IN_GAME_PREFS.any { it.key == VideoCore.KEY })
    }
}
