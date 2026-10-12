package org.uoyabause.android

import org.junit.Assert.assertEquals
import org.junit.Test

class Vdp2CompositeTest {
    // The Vulkan renderer is the only video core that interprets
    // VDP_SETTING_VDP2_NEW_COMPOSITE, so the preference only takes effect there.
    private val vulkan = 4
    private val openGl = 1
    private val software = 2

    @Test
    fun `legacy composite is selected on Vulkan when the preference says so`() {
        assertEquals(
            Vdp2Composite.MODE_LEGACY,
            Vdp2Composite.resolveMode(vulkan, Vdp2Composite.VALUE_LEGACY),
        )
    }

    @Test
    fun `new composite is selected on Vulkan when the preference says so`() {
        assertEquals(
            Vdp2Composite.MODE_NEW,
            Vdp2Composite.resolveMode(vulkan, Vdp2Composite.VALUE_NEW),
        )
    }

    @Test
    fun `missing preference falls back to the new composite`() {
        assertEquals(Vdp2Composite.MODE_NEW, Vdp2Composite.resolveMode(vulkan, null))
    }

    @Test
    fun `unknown preference value falls back to the new composite`() {
        assertEquals(Vdp2Composite.MODE_NEW, Vdp2Composite.resolveMode(vulkan, "7"))
        assertEquals(Vdp2Composite.MODE_NEW, Vdp2Composite.resolveMode(vulkan, ""))
    }

    @Test
    fun `non Vulkan cores keep the new composite regardless of the preference`() {
        assertEquals(Vdp2Composite.MODE_NEW, Vdp2Composite.resolveMode(openGl, Vdp2Composite.VALUE_LEGACY))
        assertEquals(Vdp2Composite.MODE_NEW, Vdp2Composite.resolveMode(software, Vdp2Composite.VALUE_LEGACY))
        assertEquals(Vdp2Composite.MODE_NEW, Vdp2Composite.resolveMode(-1, Vdp2Composite.VALUE_LEGACY))
    }

    @Test
    fun `the preference is only editable on Vulkan`() {
        assertEquals(true, Vdp2Composite.isSelectable(vulkan))
        assertEquals(false, Vdp2Composite.isSelectable(openGl))
        assertEquals(false, Vdp2Composite.isSelectable(software))
        assertEquals(false, Vdp2Composite.isSelectable(-1))
    }
}
