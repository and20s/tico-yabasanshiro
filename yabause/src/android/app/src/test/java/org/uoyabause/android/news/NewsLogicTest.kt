package org.uoyabause.android.news

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class NewsLogicTest {
    private fun item(id: String, date: String) =
        AppNewsItem(id, date, null, null, mapOf("en" to "t"), mapOf("en" to "b"))

    // A feed as published: newest first, one item per announcement date.
    private val feed = listOf(
        item("newest", "2026-03-01"),
        item("middle", "2026-02-01"),
        item("oldest", "2026-01-01"),
    )

    @Test
    fun freshInstallShowsOnlyTheNewest() {
        val mark = NewsLogic.watermark(feed, emptySet(), null)
        assertNull(mark)
        assertEquals("newest", NewsLogic.selectNext(feed, mark)?.id)
    }

    @Test
    fun nothingIsShownOnceTheNewestHasBeenClosed() {
        val mark = NewsLogic.watermark(feed, setOf("newest"), "2026-03-01")
        assertNull(NewsLogic.selectNext(feed, mark))
    }

    /**
     * The reported defect: closing the newest announcement used to leave the
     * rest of the feed unseen, so every relaunch produced one more popup until
     * the whole history had been replayed.
     */
    @Test
    fun theFeedDoesNotReplayOneLaunchAtATime() {
        var mark = NewsLogic.watermark(feed, emptySet(), null)
        val shown = NewsLogic.selectNext(feed, mark)
        assertEquals("newest", shown?.id)

        // Every later launch asks again with what that first one recorded.
        repeat(3) {
            mark = NewsLogic.watermark(feed, setOf("newest"), shown?.date)
            assertNull(NewsLogic.selectNext(feed, mark))
        }
    }

    @Test
    fun aNewerItemIsShown() {
        val withNewer = feed + item("newer", "2026-04-01")
        val mark = NewsLogic.watermark(withNewer, setOf("newest"), "2026-03-01")
        assertEquals("newer", NewsLogic.selectNext(withNewer, mark)?.id)
    }

    @Test
    fun anItemPublishedTheSameDayIsNotShownAgain() {
        val sameDay = feed + item("sibling", "2026-03-01")
        val mark = NewsLogic.watermark(sameDay, setOf("newest"), "2026-03-01")
        assertNull(NewsLogic.selectNext(sameDay, mark))
    }

    @Test
    fun watermarkIsNullWhenNothingHasBeenSeen() {
        assertNull(NewsLogic.watermark(feed, emptySet(), null))
    }

    /** An install upgrading from a build that stored ids but no date. */
    @Test
    fun watermarkMigratesFromSeenIds() {
        assertEquals("2026-03-01", NewsLogic.watermark(feed, setOf("newest"), null))
        assertEquals("2026-02-01", NewsLogic.watermark(feed, setOf("middle", "oldest"), null))
    }

    @Test
    fun watermarkTakesTheLaterOfStoredAndSeenIds() {
        // Stored date ahead of the ids: the ids must not pull it back.
        assertEquals("2026-03-01", NewsLogic.watermark(feed, setOf("oldest"), "2026-03-01"))
        // Ids ahead of the stored date, which is what migration looks like.
        assertEquals("2026-03-01", NewsLogic.watermark(feed, setOf("newest"), "2026-01-01"))
    }

    @Test
    fun watermarkIgnoresIdsNoLongerInTheFeed() {
        assertNull(NewsLogic.watermark(feed, setOf("dropped-from-the-feed"), null))
    }

    @Test
    fun selectNextOnAnEmptyFeed() {
        assertNull(NewsLogic.selectNext(emptyList(), null))
        assertNull(NewsLogic.selectNext(emptyList(), "2026-03-01"))
    }

    @Test
    fun selectNextIgnoresFeedOrder() {
        val shuffled = listOf(feed[2], feed[0], feed[1])
        assertEquals("newest", NewsLogic.selectNext(shuffled, null)?.id)
    }

    @Test
    fun mapsLocaleToNewsKey() {
        assertEquals("zh-CN", NewsLogic.toNewsLangKey("zh", "CN"))
        assertEquals("pt-BR", NewsLogic.toNewsLangKey("pt", "BR"))
        assertEquals("ja", NewsLogic.toNewsLangKey("ja", "JP"))
        assertEquals("de", NewsLogic.toNewsLangKey("de", "DE"))
    }

    @Test
    fun resolvesTextWithEnglishFallback() {
        val m = mapOf("en" to "hello", "ja" to "konnichiwa")
        assertEquals("konnichiwa", NewsLogic.resolveText(m, "ja"))
        assertEquals("hello", NewsLogic.resolveText(m, "fr"))
        assertNull(NewsLogic.resolveText(mapOf("de" to "x"), "fr"))
    }

    @Test
    fun updateButtonShowsWhenOlder() {
        assertTrue(NewsLogic.shouldShowUpdate(1000, 1001))
        assertFalse(NewsLogic.shouldShowUpdate(1001, 1001))
        assertFalse(NewsLogic.shouldShowUpdate(1002, 1001))
        assertFalse(NewsLogic.shouldShowUpdate(1000, null))
    }

    @Test
    fun playStoreUrlByAppId() {
        assertTrue(NewsLogic.playStoreUrl("org.devmiyax.yabasanshioro2").endsWith("id=org.devmiyax.yabasanshioro2"))
        assertTrue(NewsLogic.playStoreUrl("org.devmiyax.yabasanshioro2.debug").endsWith("id=org.devmiyax.yabasanshioro2.pro"))
        assertTrue(NewsLogic.playStoreUrl("org.devmiyax.yabasanshioro2.pro").endsWith("id=org.devmiyax.yabasanshioro2.pro"))
    }
}
