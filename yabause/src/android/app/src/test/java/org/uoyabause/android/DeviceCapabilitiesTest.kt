package org.uoyabause.android

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Test

class DeviceCapabilitiesTest {
    @Test
    fun `unknown device falls back to the safe side`() {
        val caps =
            DeviceCapabilities(
                vulkanSupported = false,
                glEsVersion = 0,
                hasTessellation = false,
                cpuMaxClockKHz = null,
                isPc = false,
                gpuKey = null,
                vulkanTessellation = false,
            )
        assertFalse(caps.vulkanSupported)
        assertNull(caps.cpuMaxClockKHz)
        assertNull(caps.gpuKey)
        assertEquals(0, caps.glEsVersion)
    }

    @Test
    fun `vulkan without tessellation is not a vulkan device`() {
        // Some devices advertise Vulkan but have neither the tessellation nor
        // the geometry shader feature. The Vulkan core has no polygon path left
        // for them, so they are not candidates for it.
        val caps =
            DeviceCapabilities(
                vulkanSupported = true,
                glEsVersion = 0x30002,
                hasTessellation = false,
                cpuMaxClockKHz = 2_000_000,
                isPc = false,
                gpuKey = "vk:1:1",
                vulkanTessellation = false,
            )
        assertFalse(caps.canUseVulkan)
    }
}
