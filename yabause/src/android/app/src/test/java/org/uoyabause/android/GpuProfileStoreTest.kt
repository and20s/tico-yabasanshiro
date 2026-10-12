package org.uoyabause.android

import org.junit.Assert.assertEquals
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [28])
class GpuProfileStoreTest {
    private fun json(
        key: String,
        composite: String,
        source: String,
    ) = """{"profiles":[{"key":"$key","name":"n","polygonGeneration":"2","vdp2Composite":"$composite","rbgResolution":"0","source":"$source"}]}"""

    @Test
    fun `a locally measured profile wins over remote and bundled`() {
        val merged =
            GpuProfileStore.merge(
                bundled = json("vk:1:1", "0", GpuProfile.SOURCE_CURATED),
                remote = json("vk:1:1", "0", GpuProfile.SOURCE_CURATED),
                local = json("vk:1:1", "1", GpuProfile.SOURCE_MEASURED),
            )
        assertEquals("1", merged["vk:1:1"]!!.vdp2Composite)
        assertEquals(GpuProfile.SOURCE_MEASURED, merged["vk:1:1"]!!.source)
    }

    @Test
    fun `remote wins over bundled`() {
        val merged =
            GpuProfileStore.merge(
                bundled = json("vk:1:1", "0", GpuProfile.SOURCE_CURATED),
                remote = json("vk:1:1", "1", GpuProfile.SOURCE_CURATED),
                local = null,
            )
        assertEquals("1", merged["vk:1:1"]!!.vdp2Composite)
    }

    @Test
    fun `entries from all three layers are combined`() {
        val merged =
            GpuProfileStore.merge(
                bundled = json("vk:1:1", "0", GpuProfile.SOURCE_CURATED),
                remote = json("vk:2:2", "1", GpuProfile.SOURCE_CURATED),
                local = json("gl:x", "1", GpuProfile.SOURCE_MEASURED),
            )
        assertEquals(3, merged.size)
    }

    @Test
    fun `a broken layer does not remove the others`() {
        val merged =
            GpuProfileStore.merge(
                bundled = json("vk:1:1", "0", GpuProfile.SOURCE_CURATED),
                remote = "not json",
                local = null,
            )
        assertEquals(1, merged.size)
    }
}
