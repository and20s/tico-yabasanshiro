package org.uoyabause.android

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class BenchmarkStatusTest {
    // Raw bytes exactly as they appear in Saturn Work RAM: magic 0x53424E43 stored
    // little-endian reads back as 43 4E 42 53.
    private fun block(
        magic: ByteArray = byteArrayOf(0x43, 0x4E, 0x42, 0x53),
        version: Int = 1,
        disc: Int = 1,
        level: Int = 3,
        levelCount: Int = 12,
        frame: Long = 0x1234L,
    ): ByteArray {
        val b = ByteArray(16)
        magic.copyInto(b, 0)
        b[4] = (version and 0xFF).toByte()
        b[5] = ((version shr 8) and 0xFF).toByte()
        b[6] = (disc and 0xFF).toByte()
        b[7] = ((disc shr 8) and 0xFF).toByte()
        b[8] = (level and 0xFF).toByte()
        b[9] = ((level shr 8) and 0xFF).toByte()
        b[10] = (levelCount and 0xFF).toByte()
        b[11] = ((levelCount shr 8) and 0xFF).toByte()
        b[12] = (frame and 0xFF).toByte()
        b[13] = ((frame shr 8) and 0xFF).toByte()
        b[14] = ((frame shr 16) and 0xFF).toByte()
        b[15] = ((frame shr 24) and 0xFF).toByte()
        return b
    }

    @Test
    fun `a well formed block is parsed`() {
        val result = BenchmarkStatus.parse(block())
        assertEquals(1, result!!.disc)
        assertEquals(3, result.level)
        assertEquals(12, result.levelCount)
        assertEquals(0x1234L, result.frame)
    }

    @Test
    fun `a wrong magic is not a status block`() {
        assertNull(BenchmarkStatus.parse(block(magic = byteArrayOf(0, 0, 0, 0))))
    }

    @Test
    fun `an unknown format version is rejected`() {
        assertNull(BenchmarkStatus.parse(block(version = 2)))
    }

    @Test
    fun `a short or absent read is not a status block`() {
        assertNull(BenchmarkStatus.parse(null))
        assertNull(BenchmarkStatus.parse(ByteArray(8)))
    }

    @Test
    fun `a level outside its own level count is rejected`() {
        assertNull(BenchmarkStatus.parse(block(level = 0)))
        assertNull(BenchmarkStatus.parse(block(level = 13, levelCount = 12)))
    }

    @Test
    fun `the frame counter is unsigned`() {
        val result = BenchmarkStatus.parse(block(frame = 0xFFFFFFFFL))
        assertEquals(0xFFFFFFFFL, result!!.frame)
    }
}
