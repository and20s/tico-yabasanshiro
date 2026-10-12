package org.uoyabause.android.news

// Pure decision logic for the news popup. No Android dependencies so it is unit-testable.
object NewsLogic {
    const val RELEASE_APP_ID = "org.devmiyax.yabasanshioro2"
    private const val PRO_APP_ID = "org.devmiyax.yabasanshioro2.pro"
    private const val PLAY_URL_PREFIX = "https://play.google.com/store/apps/details?id="

    /**
     * How far through the feed the reader has already been taken, or null when
     * they have seen nothing at all.
     *
     * The popup used to pick "the newest item not yet seen", which walked
     * backwards through the feed one launch at a time: closing the newest
     * announcement left the second newest unseen, so it appeared on the next
     * launch, and so on down the whole feed. A high-water mark cannot walk
     * backwards - once an item has been shown, everything published before it
     * is behind us whether or not it was ever displayed.
     *
     * Installs from before the mark existed carry only the ids they marked
     * seen, so their starting point is derived from the dates of those items.
     * The later of the two sources wins, so neither can pull the mark back.
     *
     * Dates are compared as strings: the feed publishes ISO `YYYY-MM-DD`
     * (skills/release/scripts/post_app_news.py) and already orders itself the
     * same way.
     */
    fun watermark(
        items: List<AppNewsItem>,
        seenIds: Set<String>,
        lastShownDate: String?,
    ): String? {
        val fromSeenIds = items.filter { it.id in seenIds }.maxOfOrNull { it.date }
        return laterOf(lastShownDate, fromSeenIds)
    }

    /**
     * The one item to show, or null when nothing in the feed is newer than the
     * mark.
     *
     * Strictly newer: an item dated the same day as the mark is not news the
     * reader has still to be told, it is the announcement they just closed.
     */
    fun selectNext(items: List<AppNewsItem>, watermark: String?): AppNewsItem? {
        val newest = items.maxByOrNull { it.date } ?: return null
        if (watermark != null && newest.date <= watermark) return null
        return newest
    }

    /** The later of two dates, treating null as "no date at all". */
    fun laterOf(first: String?, second: String?): String? =
        when {
            first == null -> second
            second == null -> first
            else -> if (first >= second) first else second
        }

    fun toNewsLangKey(language: String, country: String): String =
        when (language) {
            "zh" -> "zh-CN"
            "pt" -> "pt-BR"
            else -> language
        }

    fun resolveText(map: Map<String, String>, langKey: String): String? =
        map[langKey] ?: map["en"]

    fun shouldShowUpdate(installedVersionCode: Int, latestVersionCode: Int?): Boolean =
        latestVersionCode != null && installedVersionCode < latestVersionCode

    fun playStoreUrl(applicationId: String): String =
        if (applicationId == RELEASE_APP_ID) {
            PLAY_URL_PREFIX + RELEASE_APP_ID
        } else {
            PLAY_URL_PREFIX + PRO_APP_ID
        }
}
