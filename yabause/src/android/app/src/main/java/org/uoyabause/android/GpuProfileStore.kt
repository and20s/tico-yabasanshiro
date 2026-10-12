package org.uoyabause.android

import android.content.Context
import android.util.Log
import com.google.firebase.remoteconfig.FirebaseRemoteConfig

/**
 * The GPU profile database, assembled from three layers.
 *
 * Priority is local measurement > Firebase > bundled asset: a value measured on
 * this very device beats anything shipped with the app.
 *
 * Note: the Firebase Remote Config layer is fetched asynchronously. On a first
 * launch StartupActivity starts the fetch as soon as it is created and waits a
 * bounded time for it before deciding what to offer (see
 * StartupActivity.whenFirstLaunchProfilesReady); a fetch that has not arrived by
 * then leaves the decision to the bundled asset.
 */
object GpuProfileStore {
    private const val TAG = "GpuProfileStore"
    private const val ASSET_NAME = "gpu_profiles.json"
    private const val REMOTE_CONFIG_KEY = "gpu_profiles_json"
    private const val PREFS_NAME = "gpu_profiles_local"
    private const val PREFS_KEY = "profiles"

    fun merge(
        bundled: String?,
        remote: String?,
        local: String?,
    ): Map<String, GpuProfile> {
        val result = LinkedHashMap<String, GpuProfile>()
        result.putAll(GpuProfile.parseAll(bundled))
        result.putAll(GpuProfile.parseAll(remote))
        result.putAll(GpuProfile.parseAll(local))
        return result
    }

    fun find(
        context: Context,
        key: String?,
    ): GpuProfile? {
        if (key == null) return null
        return merge(readAsset(context), readRemote(), readLocal(context))[key]
    }

    fun saveLocal(
        context: Context,
        profile: GpuProfile,
    ) {
        val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        val existing = GpuProfile.parseAll(prefs.getString(PREFS_KEY, null)).toMutableMap()
        existing[profile.key] = profile
        prefs.edit().putString(PREFS_KEY, GpuProfile.toJson(existing.values)).apply()
    }

    private fun readAsset(context: Context): String? =
        try {
            context.assets
                .open(ASSET_NAME)
                .bufferedReader()
                .use { it.readText() }
        } catch (e: Exception) {
            Log.d(TAG, "bundled GPU profiles are unavailable", e)
            null
        }

    private fun readRemote(): String? =
        try {
            FirebaseRemoteConfig.getInstance().getString(REMOTE_CONFIG_KEY).takeIf { it.isNotBlank() }
        } catch (e: Exception) {
            Log.d(TAG, "remote GPU profiles are unavailable", e)
            null
        }

    private fun readLocal(context: Context): String? =
        context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE).getString(PREFS_KEY, null)
}
