package org.uoyabause.android

import org.junit.Assert.assertEquals
import org.junit.Test

class VideoCoreTest {
    @Test
    fun `software falls back to Vulkan when the device supports it`() {
        assertEquals(
            VideoCore.VULKAN,
            VideoCore.resolve(VideoCore.SOFTWARE, vulkanSupported = true),
        )
    }

    @Test
    fun `software falls back to OpenGL when the device has no Vulkan`() {
        assertEquals(
            VideoCore.OPENGL,
            VideoCore.resolve(VideoCore.SOFTWARE, vulkanSupported = false),
        )
    }

    @Test
    fun `other cores are kept as they are`() {
        assertEquals(VideoCore.OPENGL, VideoCore.resolve(VideoCore.OPENGL, vulkanSupported = true))
        assertEquals(VideoCore.VULKAN, VideoCore.resolve(VideoCore.VULKAN, vulkanSupported = true))
    }

    @Test
    fun `the unset marker survives so first run detection still works`() {
        assertEquals(VideoCore.UNSET, VideoCore.resolve(VideoCore.UNSET, vulkanSupported = true))
        assertEquals(VideoCore.UNSET, VideoCore.resolve(null, vulkanSupported = true))
        assertEquals(VideoCore.UNSET, VideoCore.resolve("", vulkanSupported = true))
    }

    @Test
    fun `software is no longer offered as a choice`() {
        assertEquals(false, VideoCore.isSelectable(VideoCore.SOFTWARE))
        assertEquals(true, VideoCore.isSelectable(VideoCore.OPENGL))
        assertEquals(true, VideoCore.isSelectable(VideoCore.VULKAN))
    }
}
