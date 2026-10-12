package org.uoyabause.android

/**
 * Selection of the VDP2 composite path (issue #22).
 *
 * The new per-pixel compositor is more accurate but costs noticeably more GPU
 * time, which hurts older devices. The legacy fixed-function path is still in
 * the renderer and can be selected instead.
 *
 * Only the Vulkan video core interprets VDP_SETTING_VDP2_NEW_COMPOSITE, so on
 * every other core the preference has no meaning and the new path is reported.
 */
object Vdp2Composite {
    const val KEY = "pref_vdp2_composite"

    // Preference values (strings, because the UI is a ListPreference).
    const val VALUE_NEW = "1"
    const val VALUE_LEGACY = "0"
    const val DEFAULT_VALUE = VALUE_NEW

    // Values handed to YabauseRunnable.setVdp2NewComposite().
    const val MODE_NEW = 1
    const val MODE_LEGACY = 0

    private const val VIDEO_INTERFACE_VULKAN = 4

    /** True when the running video core actually honours the preference. */
    fun isSelectable(videoInterface: Int): Boolean = videoInterface == VIDEO_INTERFACE_VULKAN

    /**
     * Resolves the value to pass to the native layer. Unknown or missing
     * preference values fall back to the new compositor.
     */
    fun resolveMode(
        videoInterface: Int,
        prefValue: String?,
    ): Int {
        if (!isSelectable(videoInterface)) return MODE_NEW
        return if (prefValue == VALUE_LEGACY) MODE_LEGACY else MODE_NEW
    }
}
