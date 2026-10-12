package org.uoyabause.android

/**
 * Keys used to look a GPU up in the profile database.
 *
 * Vulkan devices are identified by the vendor/device id pair reported by
 * VkPhysicalDeviceProperties, which is stable across driver updates. Devices
 * that only have OpenGL ES fall back to the GL_RENDERER string.
 */
object GpuIdentity {
    fun vulkanKey(
        vendorId: Int,
        deviceId: Int,
    ): String = "vk:%x:%x".format(vendorId, deviceId)

    /**
     * [renderer] is the vendor+renderer string as returned by
     * [DeviceInfo.gpuRenderer] (e.g. "Qualcomm Adreno (TM) 650"), not the raw
     * GL_RENDERER string alone. Case is folded and internal whitespace is
     * collapsed to a single space so curated database entries match what
     * production actually reports.
     */
    fun openGlKey(renderer: String?): String? {
        val normalised =
            renderer
                ?.lowercase()
                ?.replace(Regex("\\s+"), " ")
                ?.trim()
                .orEmpty()
        if (normalised.isEmpty()) return null
        return "gl:$normalised"
    }
}
