package org.uoyabause.android.news

import androidx.test.core.app.ApplicationProvider
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner

@RunWith(RobolectricTestRunner::class)
class NewsSeenStoreTest {
    private val store = NewsSeenStore(ApplicationProvider.getApplicationContext())

    @Test
    fun startsEmpty() {
        assertTrue(store.seenIds().isEmpty())
        assertNull(store.lastShownDate())
    }

    @Test
    fun persistsMarkedIds() {
        store.markShown("a", "2026-01-01")
        store.markShown("b", "2026-02-01")
        assertEquals(setOf("a", "b"), store.seenIds())
    }

    @Test
    fun markShownIsIdempotent() {
        store.markShown("a", "2026-01-01")
        store.markShown("a", "2026-01-01")
        assertEquals(setOf("a"), store.seenIds())
        assertEquals("2026-01-01", store.lastShownDate())
    }

    @Test
    fun markShownRecordsTheDate() {
        store.markShown("a", "2026-01-01")
        assertEquals("2026-01-01", store.lastShownDate())
    }

    @Test
    fun theMarkNeverMovesBackwards() {
        store.markShown("b", "2026-02-01")
        store.markShown("a", "2026-01-01")
        assertEquals("2026-02-01", store.lastShownDate())
    }

    @Test
    fun raiseWatermarkMovesForwardOnly() {
        store.raiseWatermark("2026-02-01")
        assertEquals("2026-02-01", store.lastShownDate())
        store.raiseWatermark("2026-01-01")
        assertEquals("2026-02-01", store.lastShownDate())
        store.raiseWatermark("2026-03-01")
        assertEquals("2026-03-01", store.lastShownDate())
    }

    @Test
    fun raiseWatermarkIgnoresNull() {
        store.raiseWatermark("2026-02-01")
        store.raiseWatermark(null)
        assertEquals("2026-02-01", store.lastShownDate())
    }

    /**
     * An install upgrading from a build that recorded ids but no date: the
     * derived mark is stored on the first launch, so a feed that later drops
     * the item we stopped at cannot lower it again.
     */
    @Test
    fun migratedMarkIsPersisted() {
        val feed = listOf(
            AppNewsItem("newest", "2026-03-01", null, null, mapOf("en" to "t"), mapOf("en" to "b")),
            AppNewsItem("older", "2026-01-01", null, null, mapOf("en" to "t"), mapOf("en" to "b")),
        )
        // What the previous build left behind, written the way it wrote it:
        // the id set alone, under the same file and key.
        ApplicationProvider
            .getApplicationContext<android.content.Context>()
            .getSharedPreferences("news_prefs", android.content.Context.MODE_PRIVATE)
            .edit()
            .putStringSet("seen_ids", setOf("newest"))
            .commit()
        assertEquals(setOf("newest"), store.seenIds())
        assertNull(store.lastShownDate())

        store.raiseWatermark(NewsLogic.watermark(feed, store.seenIds(), store.lastShownDate()))
        assertEquals("2026-03-01", store.lastShownDate())

        // The feed drops the item we stopped at; the mark holds.
        val trimmed = feed.drop(1)
        val mark = NewsLogic.watermark(trimmed, store.seenIds(), store.lastShownDate())
        assertEquals("2026-03-01", mark)
        assertNull(NewsLogic.selectNext(trimmed, mark))
    }
}
