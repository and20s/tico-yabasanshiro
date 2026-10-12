package org.uoyabause.android

import android.content.SharedPreferences

/** Writes [RecommendedSettings] into the global settings, and explains the change. */
object RecommendedSettingsApplier {
    const val KEY_POLYGON = "pref_polygon_generation"
    const val KEY_COMPUTE_SHADER = "pref_use_compute_shader"
    const val KEY_RBG_RESOLUTION = "pref_rbg_resolution"
    const val KEY_RESOLUTION = "pref_resolution"
    const val KEY_SH2_CACHE = "pref_use_sh2_cache"

    fun apply(
        prefs: SharedPreferences,
        settings: RecommendedSettings,
    ) {
        prefs
            .edit()
            .putString(VideoCore.KEY, settings.videoCore)
            .putString(KEY_POLYGON, settings.polygonGeneration)
            .putBoolean(KEY_COMPUTE_SHADER, settings.useComputeShader)
            .putString(Vdp2Composite.KEY, settings.vdp2Composite)
            .putString(KEY_RBG_RESOLUTION, settings.rbgResolution)
            .putString(KEY_RESOLUTION, settings.resolution)
            .putBoolean(KEY_SH2_CACHE, settings.useSh2Cache)
            .apply()
    }

    /**
     * One setting the recommendation writes, as its raw preference value.
     *
     * Same split as [SettingChange]: the values stay raw here so the rules can be
     * tested without Android, and [RecommendedSettingsLabels] turns them into
     * display text.
     */
    data class SettingValue(
        val key: String,
        val value: String,
    )

    /**
     * Every setting [apply] writes, in the order a summary should list them.
     * Kept next to [apply] so a setting cannot be added to one without the other.
     */
    fun values(settings: RecommendedSettings): List<SettingValue> =
        listOf(
            SettingValue(VideoCore.KEY, settings.videoCore),
            SettingValue(KEY_POLYGON, settings.polygonGeneration),
            SettingValue(KEY_COMPUTE_SHADER, settings.useComputeShader.toString()),
            SettingValue(Vdp2Composite.KEY, settings.vdp2Composite),
            SettingValue(KEY_RBG_RESOLUTION, settings.rbgResolution),
            SettingValue(KEY_RESOLUTION, settings.resolution),
            SettingValue(KEY_SH2_CACHE, settings.useSh2Cache.toString()),
        )

    // The app never calls PreferenceManager.setDefaultValues, so a key the user
    // never touched simply does not exist in SharedPreferences -- but the XML
    // default (res/xml/preferences.xml) is what is actually in effect for it.
    // diff() must compare against these same defaults, not against "" / false,
    // or it reports changes that would not actually happen.
    private const val DEFAULT_VIDEO_CORE = VideoCore.UNSET
    private const val DEFAULT_POLYGON = RecommendedSettings.POLYGON_TRIANGLE
    private const val DEFAULT_COMPUTE_SHADER = false
    private const val DEFAULT_VDP2_COMPOSITE = Vdp2Composite.DEFAULT_VALUE
    private const val DEFAULT_RBG_RESOLUTION = RecommendedSettings.RBG_ORIGINAL
    private const val DEFAULT_RESOLUTION = RecommendedSettings.RESOLUTION_NATIVE
    private const val DEFAULT_SH2_CACHE = true

    /**
     * One setting the recommendation would change.
     *
     * Values are the raw preference values, not display text: turning them into
     * something a user can read needs resources, and keeping this side free of
     * Android lets the comparison rules stay under JVM tests. See
     * [RecommendedSettingsLabels] for the presentation.
     */
    data class SettingChange(
        val key: String,
        val current: String,
        val recommended: String,
    )

    /** The settings whose value would change. */
    fun diff(
        prefs: SharedPreferences,
        settings: RecommendedSettings,
    ): List<SettingChange> {
        val changes = mutableListOf<SettingChange>()

        fun compareString(
            key: String,
            defaultValue: String,
            recommended: String,
        ) {
            val current = prefs.getStringSafe(key, defaultValue)
            if (current != recommended) changes.add(SettingChange(key, current, recommended))
        }

        fun compareBoolean(
            key: String,
            defaultValue: Boolean,
            recommended: Boolean,
        ) {
            val current = prefs.getBoolean(key, defaultValue)
            if (current != recommended) {
                changes.add(SettingChange(key, current.toString(), recommended.toString()))
            }
        }
        compareString(VideoCore.KEY, DEFAULT_VIDEO_CORE, settings.videoCore)
        compareString(KEY_POLYGON, DEFAULT_POLYGON, settings.polygonGeneration)
        compareBoolean(KEY_COMPUTE_SHADER, DEFAULT_COMPUTE_SHADER, settings.useComputeShader)
        compareString(Vdp2Composite.KEY, DEFAULT_VDP2_COMPOSITE, settings.vdp2Composite)
        compareString(KEY_RBG_RESOLUTION, DEFAULT_RBG_RESOLUTION, settings.rbgResolution)
        compareString(KEY_RESOLUTION, DEFAULT_RESOLUTION, settings.resolution)
        compareBoolean(KEY_SH2_CACHE, DEFAULT_SH2_CACHE, settings.useSh2Cache)
        return changes
    }
}
