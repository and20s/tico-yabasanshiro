package org.uoyabause.android

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.ByteArrayInputStream
import java.io.InputStream

class BenchmarkAssetsTest {
    private fun sources(vararg payloads: ByteArray): List<() -> InputStream> =
        payloads.map { bytes -> { ByteArrayInputStream(bytes) as InputStream } }

    @Test
    fun `the same bytes always give the same version`() {
        val a = BenchmarkAssets.discSetVersionOf(sources("one".toByteArray(), "two".toByteArray()))
        val b = BenchmarkAssets.discSetVersionOf(sources("one".toByteArray(), "two".toByteArray()))
        assertEquals(a, b)
    }

    @Test
    fun `one changed byte changes the version`() {
        // This is the whole point: a reworked benchmark ROM must not keep the
        // version of the one it replaced, or measurements of different loads mix.
        val before = BenchmarkAssets.discSetVersionOf(sources("one".toByteArray(), "two".toByteArray()))
        val after = BenchmarkAssets.discSetVersionOf(sources("one".toByteArray(), "twp".toByteArray()))
        assertNotEquals(before, after)
    }

    @Test
    fun `the order of the discs is part of the version`() {
        val forwards = BenchmarkAssets.discSetVersionOf(sources("one".toByteArray(), "two".toByteArray()))
        val backwards = BenchmarkAssets.discSetVersionOf(sources("two".toByteArray(), "one".toByteArray()))
        assertNotEquals(forwards, backwards)
    }

    @Test
    fun `the version is sixteen lowercase hex characters`() {
        val version = BenchmarkAssets.discSetVersionOf(sources(ByteArray(1) { 0xFF.toByte() }))
        assertEquals(16, version.length)
        assertTrue(version, version.all { it in "0123456789abcdef" })
    }

    @Test
    fun `an empty disc set still produces a version`() {
        assertEquals(16, BenchmarkAssets.discSetVersionOf(emptyList()).length)
    }
}
