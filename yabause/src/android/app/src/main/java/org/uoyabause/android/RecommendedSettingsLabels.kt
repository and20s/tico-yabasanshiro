package org.uoyabause.android

import android.content.Context
import org.devmiyax.yabasanshiro.R

/**
 * Turns a [RecommendedSettingsApplier.SettingChange] into the words the settings
 * screen uses for it.
 *
 * The confirmation dialog used to print the raw preference key and value
 * ("pref_rbg_resolution: 0 -> 4"), which is only meaningful to someone who has
 * read the source. A user is being asked to approve a change to settings they
 * know by their labels, so the dialog names them the same way the settings screen
 * does.
 *
 * The value labels come from the same string-arrays the ListPreferences are
 * built from, so the two screens cannot drift apart. A key or value this does not
 * know falls back to the raw text rather than hiding the change.
 */
object RecommendedSettingsLabels {
    /** "<setting>: <current> -> <recommended>", all in display text. */
    fun describe(
        context: Context,
        change: RecommendedSettingsApplier.SettingChange,
    ): String {
        val title = titleOf(context, change.key)
        val from = valueLabel(context, change.key, change.current)
        val to = valueLabel(context, change.key, change.recommended)
        return "$title: $from → $to"
    }

    /**
     * "<setting>: <value>", all in display text.
     *
     * Used where there is nothing to compare against - the benchmark's own
     * summary states what the device ended up with, not what changed, because a
     * measurement that confirms the current settings is still a result the user
     * asked for.
     */
    fun describe(
        context: Context,
        value: RecommendedSettingsApplier.SettingValue,
    ): String = "${titleOf(context, value.key)}: ${valueLabel(context, value.key, value.value)}"

    private fun titleOf(
        context: Context,
        key: String,
    ): String =
        when (key) {
            VideoCore.KEY -> context.getString(R.string.video_core)
            RecommendedSettingsApplier.KEY_POLYGON -> context.getString(R.string.polygon_generation_type)
            RecommendedSettingsApplier.KEY_COMPUTE_SHADER -> context.getString(R.string.str_use_compute_shader)
            Vdp2Composite.KEY -> context.getString(R.string.vdp2_composite_type)
            RecommendedSettingsApplier.KEY_RBG_RESOLUTION -> context.getString(R.string.rbg_resolution)
            RecommendedSettingsApplier.KEY_RESOLUTION -> context.getString(R.string.video_resolution)
            RecommendedSettingsApplier.KEY_SH2_CACHE -> context.getString(R.string.use_sh2_cache)
            else -> key
        }

    private fun valueLabel(
        context: Context,
        key: String,
        value: String,
    ): String =
        when (key) {
            // The video core list is built at runtime in the settings screen (the
            // entries depend on what the device supports), so there is no array to
            // read here - these are the same two strings it uses.
            VideoCore.KEY ->
                when (value) {
                    VideoCore.OPENGL -> context.getString(R.string.opengl_video_interface)
                    VideoCore.VULKAN -> context.getString(R.string.vulkan_video_interface)
                    else -> value
                }

            RecommendedSettingsApplier.KEY_POLYGON ->
                fromArray(
                    context,
                    R.array.entryvalues_polygon_generation_type,
                    R.array.entries_polygon_generation_type,
                    value,
                )

            Vdp2Composite.KEY ->
                fromArray(
                    context,
                    R.array.entryvalues_vdp2_composite,
                    R.array.entries_vdp2_composite,
                    value,
                )

            RecommendedSettingsApplier.KEY_RBG_RESOLUTION ->
                fromArray(
                    context,
                    R.array.entryvalues_rbg_resolution_list_preference,
                    R.array.entries_rbg_resolution_list_preference,
                    value,
                )

            RecommendedSettingsApplier.KEY_RESOLUTION ->
                fromArray(
                    context,
                    R.array.entryvalues_video_resolution_list_preference,
                    R.array.entries_video_resolution_list_preference,
                    value,
                )

            RecommendedSettingsApplier.KEY_COMPUTE_SHADER,
            RecommendedSettingsApplier.KEY_SH2_CACHE,
            ->
                when (value) {
                    "true" -> context.getString(R.string.setting_on)
                    "false" -> context.getString(R.string.setting_off)
                    else -> value
                }

            else -> value
        }

    private fun fromArray(
        context: Context,
        valuesId: Int,
        entriesId: Int,
        value: String,
    ): String {
        val values = context.resources.getStringArray(valuesId)
        val entries = context.resources.getStringArray(entriesId)
        val index = values.indexOf(value)
        return if (index in entries.indices) entries[index] else value
    }
}
