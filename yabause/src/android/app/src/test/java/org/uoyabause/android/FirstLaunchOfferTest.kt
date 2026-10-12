package org.uoyabause.android

import org.junit.Assert.assertEquals
import org.junit.Test

class FirstLaunchOfferTest {
    private fun caps(
        pc: Boolean = false,
        gpuKey: String? = "vk:5143:6010300",
    ) = DeviceCapabilities(
        vulkanSupported = true,
        glEsVersion = 0x30002,
        hasTessellation = true,
        cpuMaxClockKHz = 2_400_000,
        isPc = pc,
        gpuKey = gpuKey,
        vulkanTessellation = true,
    )

    private val profile =
        GpuProfile("vk:5143:6010300", "Adreno A12", "2", "0", "4", GpuProfile.SOURCE_AGGREGATED)

    @Test
    fun `a GPU in the database is offered its recommended settings`() {
        assertEquals(FirstLaunchOffer.RECOMMENDED_SETTINGS, FirstLaunchOffer.decide(caps(), profile))
    }

    @Test
    fun `a GPU missing from the database is offered the benchmark`() {
        assertEquals(FirstLaunchOffer.BENCHMARK, FirstLaunchOffer.decide(caps(), null))
    }

    @Test
    fun `PC is offered nothing`() {
        assertEquals(FirstLaunchOffer.NONE, FirstLaunchOffer.decide(caps(pc = true), profile))
        assertEquals(FirstLaunchOffer.NONE, FirstLaunchOffer.decide(caps(pc = true), null))
    }

    @Test
    fun `a GPU that could not be identified is offered nothing`() {
        assertEquals(FirstLaunchOffer.NONE, FirstLaunchOffer.decide(caps(gpuKey = null), null))
    }
}
