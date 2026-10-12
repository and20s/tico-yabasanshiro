package org.uoyabause.android

import android.content.Context
import android.content.SharedPreferences
import android.util.Log
import org.devmiyax.yabasanshiro.BuildConfig
import org.json.JSONArray
import org.json.JSONObject

/**
 * Which games the free version may play.
 *
 * The list used to be truncated to [BuildConfig.MAX_FREE_GAMES] entries, so the
 * answer was whatever the current sort happened to put first: sorting by name
 * and then by date handed the free slots to a different set of games. Now every
 * game is shown and the ones outside the allowance are locked, which makes that
 * instability visible, so the rule lives here instead - one place that the list,
 * the launcher and the disc-swap picker all ask.
 *
 * The free slots are the first [BuildConfig.MAX_FREE_GAMES] games *by arrival*,
 * never by the order they happen to be shown in. Sorting or searching therefore
 * cannot move a slot, and the games someone has been playing keep working when a
 * fourth file appears.
 */
object FreeGameSlots {
    private const val TAG = "FreeGameSlots"
    private const val PREFS_NAME = "free_game_slots"

    // path -> arrival time in epoch millis.
    private const val KEY_ARRIVALS = "arrivals"

    // Set once the arrival ledger has been written for the first time.
    private const val KEY_INITIALIZED = "initialized"

    // The last answer published by the list, for callers that hold no library.
    private const val KEY_UNLOCKED = "unlocked"
    private const val KEY_LIMITED = "limited"

    /**
     * Arrival time for games that were already in the library when the ledger
     * was first written. They all share it, so [arrivalOrder] falls back to the
     * path and the answer is the same on every launch - stamping them with the
     * current time instead would rank them by the order the scan walked the disk
     * in, which is not stable.
     */
    private const val ARRIVED_BEFORE_LEDGER = 0L

    /**
     * Arrival time for a path the ledger has never seen. It sorts last, so a
     * game that has not been recorded yet reads as locked rather than as one of
     * the free slots: unknown means not allowed, and a launch route that skips
     * the list cannot slip past the limit that way.
     */
    private const val ARRIVAL_UNKNOWN = Long.MAX_VALUE

    /**
     * The paths a limited build may play, or null when there is no limit.
     *
     * null rather than "all of them": callers read it as "no limit at all", so a
     * library that grew after this was computed cannot come out half locked.
     *
     * @param isSubscribed the billing flow's answer, which is fresher than the
     *   copy [YabauseApplication.isPro] reads back out of preferences.
     */
    fun unlockedPaths(
        games: List<GameInfo>,
        isSubscribed: Boolean = false,
        context: Context = YabauseApplication.appContext,
    ): Set<String>? {
        if (hasNoLimit(isSubscribed)) {
            publish(context, unlocked = null)
            return null
        }
        // Cloud-only rows hold no local file (file_path is empty), so they
        // cannot take a slot from an installed game. Downloading one makes it a
        // local game, which arrives then like any other import.
        val installed = games.filter { !it.isCloudOnly && it.file_path.isNotEmpty() }
        val arrivals = recordArrivals(context, installed.map { it.file_path })
        val unlocked = installed
            .sortedWith(arrivalOrder(arrivals))
            .take(BuildConfig.MAX_FREE_GAMES)
            .map { it.file_path }
            .toSet()
        publish(context, unlocked)
        return unlocked
    }

    /**
     * Whether this game is outside the free allowance.
     *
     * A cloud-only row is never locked: it holds no local file, so it took no
     * slot, and choosing it downloads rather than launches. The local game it
     * becomes is judged like any other arrival.
     */
    fun isLocked(game: GameInfo, unlocked: Set<String>?): Boolean {
        if (unlocked == null) return false
        if (game.isCloudOnly || game.file_path.isEmpty()) return false
        return !unlocked.contains(game.file_path)
    }

    /**
     * The same answer for callers that hold no library, read from the snapshot
     * the list publishes on every load. The entitlement is asked first, so a
     * purchase that landed after the snapshot was written unlocks immediately
     * instead of waiting for the next scan.
     */
    fun isLockedNow(
        game: GameInfo,
        context: Context = YabauseApplication.appContext,
    ): Boolean {
        if (game.isCloudOnly || game.file_path.isEmpty()) return false
        if (hasNoLimit(isSubscribed = false)) return false
        val prefs = prefs(context)
        if (!prefs.getBoolean(KEY_LIMITED, false)) return false
        return !readUnlocked(prefs).contains(game.file_path)
    }

    /** How many games the limit is keeping out of reach. */
    fun lockedCount(games: List<GameInfo>, unlocked: Set<String>?): Int {
        if (unlocked == null) return 0
        return games.count {
            !it.isCloudOnly && it.file_path.isNotEmpty() && !unlocked.contains(it.file_path)
        }
    }

    private fun hasNoLimit(isSubscribed: Boolean): Boolean = isSubscribed || YabauseApplication.isPro()

    /**
     * Library order: when a game entered the library, then its path.
     *
     * The path is not only a tie-break for files that arrived in the same
     * millisecond. Every game known before the ledger existed carries the same
     * arrival time, and ordering those by path is what keeps the migrated answer
     * stable across launches.
     */
    private fun arrivalOrder(arrivals: Map<String, Long>): Comparator<GameInfo> = compareBy(
        { arrivals[it.file_path] ?: ARRIVAL_UNKNOWN },
        { it.file_path },
    )

    /**
     * Brings the ledger up to date with the library and returns it.
     *
     * A forced rescan empties the GameInfo table and fills it again, so nothing
     * stored on the row survives; the ledger is kept apart from the database for
     * that reason. Writes only when something actually changed, so calling this
     * on every list rebuild costs a read.
     */
    private fun recordArrivals(context: Context, paths: List<String>): Map<String, Long> {
        val prefs = prefs(context)
        val known = HashMap(readArrivals(prefs))
        var changed = false

        // First run after the update: every game in the library was already
        // there, so none of them may take a slot from another.
        val firstRun = !prefs.getBoolean(KEY_INITIALIZED, false)
        val arrivedNow = if (firstRun) ARRIVED_BEFORE_LEDGER else System.currentTimeMillis()
        for (path in paths) {
            if (!known.containsKey(path)) {
                known[path] = arrivedNow
                changed = true
            }
        }

        // Drop games that left the library, so a deleted-and-re-added file
        // arrives again rather than keeping a slot forever. Skipped when the
        // library reads as empty, which a failed or half-finished scan also
        // looks like.
        if (paths.isNotEmpty()) {
            val present = paths.toSet()
            val gone = known.keys.filter { !present.contains(it) }
            if (gone.isNotEmpty()) {
                gone.forEach { known.remove(it) }
                changed = true
            }
        }

        if (changed || firstRun) {
            val json = JSONObject()
            known.forEach { (path, at) -> json.put(path, at) }
            prefs
                .edit()
                .putString(KEY_ARRIVALS, json.toString())
                .putBoolean(KEY_INITIALIZED, true)
                .apply()
        }
        return known
    }

    private fun publish(context: Context, unlocked: Set<String>?) {
        val editor = prefs(context).edit()
        if (unlocked == null) {
            editor.putBoolean(KEY_LIMITED, false).remove(KEY_UNLOCKED)
        } else {
            val array = JSONArray()
            unlocked.forEach { array.put(it) }
            editor.putBoolean(KEY_LIMITED, true).putString(KEY_UNLOCKED, array.toString())
        }
        editor.apply()
    }

    private fun readArrivals(prefs: SharedPreferences): Map<String, Long> {
        val raw = prefs.getString(KEY_ARRIVALS, null) ?: return emptyMap()
        return try {
            val json = JSONObject(raw)
            val result = HashMap<String, Long>(json.length())
            json.keys().forEach { key -> result[key] = json.optLong(key, ARRIVED_BEFORE_LEDGER) }
            result
        } catch (e: Exception) {
            Log.e(TAG, "Unreadable arrival ledger, starting over: ${e.message}")
            emptyMap()
        }
    }

    private fun readUnlocked(prefs: SharedPreferences): Set<String> {
        val raw = prefs.getString(KEY_UNLOCKED, null) ?: return emptySet()
        return try {
            val array = JSONArray(raw)
            val result = HashSet<String>(array.length())
            for (i in 0 until array.length()) {
                result.add(array.getString(i))
            }
            result
        } catch (e: Exception) {
            Log.e(TAG, "Unreadable unlocked snapshot: ${e.message}")
            emptySet()
        }
    }

    private fun prefs(context: Context): SharedPreferences =
        context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
}
