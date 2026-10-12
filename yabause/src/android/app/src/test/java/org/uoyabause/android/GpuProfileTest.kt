package org.uoyabause.android

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [28])
class GpuProfileTest {
    private val sample =
        """
        {
          "version": 1,
          "profiles": [
            {
              "key": "vk:5143:6030001",
              "name": "Adreno 650",
              "polygonGeneration": "2",
              "vdp2Composite": "1",
              "rbgResolution": "4",
              "source": "measured"
            }
          ]
        }
        """.trimIndent()

    @Test
    fun `profiles are parsed and keyed`() {
        val profiles = GpuProfile.parseAll(sample)
        val profile = profiles["vk:5143:6030001"]!!
        assertEquals("Adreno 650", profile.name)
        assertEquals("2", profile.polygonGeneration)
        assertEquals("1", profile.vdp2Composite)
        assertEquals("4", profile.rbgResolution)
        assertEquals("measured", profile.source)
        // Entries written before resolution was measured render at native.
        assertEquals(RecommendedSettings.RESOLUTION_NATIVE, profile.resolution)
    }

    @Test
    fun `a resolution survives a json round trip`() {
        val profile =
            GpuProfile
                .parseAll(sample)
                .values
                .single()
                .copy(resolution = RecommendedSettings.RESOLUTION_2X)
        assertEquals(
            RecommendedSettings.RESOLUTION_2X,
            GpuProfile
                .parseAll(GpuProfile.toJson(listOf(profile)))
                .values
                .single()
                .resolution,
        )
    }

    // A broken database must never stop the app from starting.
    @Test
    fun `malformed input yields an empty map`() {
        assertTrue(GpuProfile.parseAll(null).isEmpty())
        assertTrue(GpuProfile.parseAll("").isEmpty())
        assertTrue(GpuProfile.parseAll("not json").isEmpty())
        assertTrue(GpuProfile.parseAll("""{"profiles": "wrong type"}""").isEmpty())
    }

    @Test
    fun `entries missing a key are skipped`() {
        val json = """{"profiles":[{"name":"no key"},{"key":"gl:x","name":"ok"}]}"""
        val profiles = GpuProfile.parseAll(json)
        assertEquals(1, profiles.size)
        assertEquals("ok", profiles["gl:x"]!!.name)
    }

    @Test
    fun `round trip through json preserves the entries`() {
        val original = GpuProfile.parseAll(sample).values
        val reparsed = GpuProfile.parseAll(GpuProfile.toJson(original))
        assertEquals(GpuProfile.parseAll(sample), reparsed)
    }
}
