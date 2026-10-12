package org.uoyabause.android.news

import android.content.Context

// Local, device-only record of how far through the news feed the reader has
// been taken: a high-water mark date, plus the ids that produced it.
class NewsSeenStore(
    context: Context,
) {
    private val prefs = context.applicationContext
        .getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)

    fun seenIds(): Set<String> = prefs.getStringSet(KEY_SEEN, emptySet()) ?: emptySet()

    /** The date of the newest item ever shown, or null before anything was. */
    fun lastShownDate(): String? = prefs.getString(KEY_LAST_SHOWN_DATE, null)

    /**
     * Moves the mark forward, never back.
     *
     * Called with the mark derived from the ids as well as with a date just
     * shown, so an install that predates the mark stores its starting point on
     * the first launch after the update. Without that, a feed that later drops
     * the item we stopped at would derive an earlier mark and show items in
     * between all over again.
     */
    fun raiseWatermark(date: String?) {
        if (date == null) return
        val current = lastShownDate()
        if (current != null && current >= date) return
        prefs.edit().putString(KEY_LAST_SHOWN_DATE, date).apply()
    }

    /**
     * Records an item as shown.
     *
     * The id is still kept alongside the date. It is what an install upgrading
     * from a build without the mark derives its starting point from, and it
     * keeps this store readable by those builds if one is ever rolled back to.
     */
    fun markShown(id: String, date: String) {
        // Copy: the returned set from getStringSet must not be mutated in place.
        val updated = HashSet(seenIds())
        updated.add(id)
        prefs.edit().putStringSet(KEY_SEEN, updated).apply()
        raiseWatermark(date)
    }

    companion object {
        private const val PREFS_NAME = "news_prefs"
        private const val KEY_SEEN = "seen_ids"
        private const val KEY_LAST_SHOWN_DATE = "last_shown_date"
    }
}
