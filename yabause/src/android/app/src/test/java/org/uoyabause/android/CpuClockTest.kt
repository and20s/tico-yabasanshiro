package org.uoyabause.android

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class CpuClockTest {
    @Test
    fun `a sysfs value is parsed as kHz`() {
        assertEquals(2841600, CpuClock.parseKhz("2841600\n"))
        assertEquals(1804800, CpuClock.parseKhz("1804800"))
    }

    // sysfs is vendor specific: a missing or unreadable file is normal, not an error.
    @Test
    fun `unreadable values yield null`() {
        assertNull(CpuClock.parseKhz(null))
        assertNull(CpuClock.parseKhz(""))
        assertNull(CpuClock.parseKhz("   "))
        assertNull(CpuClock.parseKhz("unknown"))
    }

    @Test
    fun `zero and negative values are rejected`() {
        assertNull(CpuClock.parseKhz("0"))
        assertNull(CpuClock.parseKhz("-1"))
    }
}
