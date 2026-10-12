package org.uoyabause.android

/**
 * One sample of the benchmark ROM's status block.
 *
 * The benchmark discs write 16 bytes to a fixed Work RAM address every frame so
 * that the host can tell which load level is on screen without guessing. The
 * emulated frame count cannot be used for that: it includes the HLE BIOS boot,
 * which offsets it from the ROM's own counter by an unknown amount.
 *
 * See the design doc section 5.2 for the byte layout. Values are little-endian
 * even though the SH2 is big-endian - the ROM swaps them before storing.
 */
data class BenchmarkStatus(
    val disc: Int,
    val level: Int,
    val levelCount: Int,
    val frame: Long,
) {
    companion object {
        /** Fixed Work RAM address of the status block (start of WORKRAM-L). */
        const val ADDRESS = 0x00200000

        const val SIZE = 16

        // 'SBNC' as a little-endian u32.
        private const val MAGIC = 0x53424E43L
        private const val SUPPORTED_VERSION = 1

        /**
         * Returns null for anything that is not a valid status block: a short read,
         * a wrong magic (the ROM has not reached its main loop yet, or the address
         * is being used by something else), an unknown format version, or a level
         * outside the block's own level count. A caller must treat null as "not
         * ready" and keep polling, never as an error.
         */
        fun parse(bytes: ByteArray?): BenchmarkStatus? {
            if (bytes == null || bytes.size < SIZE) return null
            if (u32(bytes, 0) != MAGIC) return null
            if (u16(bytes, 4) != SUPPORTED_VERSION) return null

            val level = u16(bytes, 8)
            val levelCount = u16(bytes, 10)
            if (levelCount <= 0 || level < 1 || level > levelCount) return null

            return BenchmarkStatus(
                disc = u16(bytes, 6),
                level = level,
                levelCount = levelCount,
                frame = u32(bytes, 12),
            )
        }

        private fun u16(
            b: ByteArray,
            offset: Int,
        ): Int = (b[offset].toInt() and 0xFF) or ((b[offset + 1].toInt() and 0xFF) shl 8)

        private fun u32(
            b: ByteArray,
            offset: Int,
        ): Long = (u16(b, offset).toLong()) or (u16(b, offset + 2).toLong() shl 16)
    }
}
