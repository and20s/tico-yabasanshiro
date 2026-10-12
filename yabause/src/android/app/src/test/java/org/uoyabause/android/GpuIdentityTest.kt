package org.uoyabause.android

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class GpuIdentityTest {
    @Test
    fun `vulkan key is lower case hex of vendor and device id`() {
        assertEquals("vk:5143:6030001", GpuIdentity.vulkanKey(0x5143, 0x6030001))
    }

    @Test
    fun `opengl key is normalised`() {
        // Input is the vendor+renderer string DeviceInfo.gpuRenderer() actually
        // produces in production (GL_VENDOR + " " + GL_RENDERER), not GL_RENDERER
        // alone: a curated database entry must match this real form.
        assertEquals("gl:qualcomm adreno (tm) 650", GpuIdentity.openGlKey("Qualcomm Adreno (TM) 650"))
        assertEquals("gl:qualcomm adreno (tm) 650", GpuIdentity.openGlKey("  Qualcomm   Adreno   (TM)   650  "))
    }

    @Test
    fun `an unusable renderer string yields no key`() {
        assertNull(GpuIdentity.openGlKey(null))
        assertNull(GpuIdentity.openGlKey(""))
        assertNull(GpuIdentity.openGlKey("   "))
    }
}
