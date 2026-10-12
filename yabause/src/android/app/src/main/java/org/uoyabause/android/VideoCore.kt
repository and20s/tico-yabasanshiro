package org.uoyabause.android

/**
 * Video core selection (`pref_video`).
 *
 * The software renderer is no longer supported. It is gone from the settings
 * screens, and any value still stored on a device is read as Vulkan (or as
 * OpenGL ES on devices without Vulkan, where Vulkan would not start at all).
 */
object VideoCore {
    const val KEY = "pref_video"

    /** Written on first run, before the device capabilities have been checked. */
    const val UNSET = "-1"
    const val OPENGL = "1"
    const val SOFTWARE = "2"
    const val VULKAN = "4"

    /** One-shot migration of the global setting (see PreferencesManager). */
    const val MIGRATION_KEY_DROP_SOFTWARE = "video_core_drop_software"

    /** False for cores that must no longer be offered or kept. */
    fun isSelectable(value: String?): Boolean = value == OPENGL || value == VULKAN

    /**
     * Maps a stored value to the core to actually use. [UNSET] is preserved so
     * that first-run detection keeps working.
     */
    fun resolve(
        stored: String?,
        vulkanSupported: Boolean,
    ): String =
        when {
            stored.isNullOrEmpty() -> UNSET
            stored == SOFTWARE -> if (vulkanSupported) VULKAN else OPENGL
            else -> stored
        }
}
