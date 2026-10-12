package org.uoyabause.android

import android.content.Context
import android.util.Log
import java.io.File
import java.io.IOException
import java.io.InputStream
import java.security.MessageDigest

/** One benchmark disc: which asset it is, and which setting its result decides. */
data class BenchmarkDisc(
    val id: Int,
    val baseName: String,
    val gameCode: String,
)

/**
 * Copies the bundled benchmark discs out of the APK so the emulator can open them.
 *
 * The emulator takes a file path, and a cue sheet references its iso by a relative
 * name, so both files of a pair must land in the same real directory - an asset
 * stream is not enough.
 */
object BenchmarkAssets {
    private const val TAG = "BenchmarkAssets"
    private const val ASSET_DIR = "benchmark"

    /**
     * Returned when the discs cannot be read. A report filed under this is
     * excluded by the aggregation's version filter rather than being attributed
     * to whichever disc set happened to ship.
     */
    const val UNKNOWN_DISC_SET_VERSION = "unknown"

    private const val VERSION_BYTES = 8
    private const val HASH_BUFFER_BYTES = 64 * 1024

    @Volatile
    private var cachedDiscSetVersion: String? = null

    val DISCS =
        listOf(
            BenchmarkDisc(1, "01_vdp1_distort", "SBENCH-01"),
            BenchmarkDisc(2, "02_vdp2_nbg", "SBENCH-02"),
            BenchmarkDisc(3, "03_vdp2_rbg", "SBENCH-03"),
        )

    /**
     * Returns the absolute path of the disc's cue sheet, extracting the pair from
     * the APK, or null when the disc cannot be made available. A caller must
     * treat null as "cannot benchmark" and fall back to the safe-side settings.
     *
     * The pair is written every time rather than only when missing. An earlier
     * version skipped the copy if the files existed, which meant a device that had
     * ever run the benchmark kept running whatever disc it extracted first: an app
     * update shipping a corrected or reworked benchmark ROM had no effect on
     * exactly the devices already in the profile database, and the measurement
     * silently no longer matched the disc in the APK. Three discs are 576 KB, so
     * there is nothing to save by caching them across runs - the files exist only
     * because the emulator opens a path, not a stream.
     */
    fun extract(
        context: Context,
        disc: BenchmarkDisc,
    ): String? = try {
        val dir = File(context.cacheDir, ASSET_DIR)
        dir.mkdirs()
        val cue = File(dir, "${disc.baseName}.cue")
        val iso = File(dir, "${disc.baseName}.iso")
        copyAsset(context, "${disc.baseName}.iso", iso)
        copyAsset(context, "${disc.baseName}.cue", cue)
        cue.absolutePath
    } catch (e: Exception) {
        Log.d(TAG, "benchmark disc ${disc.baseName} is unavailable", e)
        null
    }

    /**
     * Identifies the benchmark discs currently in the APK.
     *
     * Computed from the disc bytes rather than a hand-maintained constant: a
     * reworked benchmark ROM changes what a rung's result means, and a constant
     * that someone forgot to raise makes measurements of two different loads
     * indistinguishable in the database - the least visible kind of corruption
     * there is. The discs are 576 KB in total and extract() already streams all
     * of them on every run, so reading them once more costs nothing.
     */
    fun discSetVersion(context: Context): String {
        cachedDiscSetVersion?.let { return it }
        val version =
            try {
                discSetVersionOf(
                    DISCS.map { disc -> { context.assets.open("$ASSET_DIR/${disc.baseName}.iso") } },
                )
            } catch (e: Exception) {
                Log.i(TAG, "the benchmark disc set version could not be computed", e)
                UNKNOWN_DISC_SET_VERSION
            }
        cachedDiscSetVersion = version
        return version
    }

    /**
     * SHA-256 over [sources] in order, as the first [VERSION_BYTES] bytes in hex.
     * Kept free of Context so the rule can be pinned by JVM tests.
     *
     * The cue sheets are left out: they only name the iso beside them, so they
     * carry no load of their own.
     */
    fun discSetVersionOf(sources: List<() -> InputStream>): String {
        val digest = MessageDigest.getInstance("SHA-256")
        val buffer = ByteArray(HASH_BUFFER_BYTES)
        sources.forEach { open ->
            open().use { input ->
                while (true) {
                    val read = input.read(buffer)
                    if (read <= 0) break
                    digest.update(buffer, 0, read)
                }
            }
        }
        return digest
            .digest()
            .take(VERSION_BYTES)
            .joinToString("") { "%02x".format(it.toInt() and 0xFF) }
    }

    /**
     * Copies an asset into [target] via a temp file in the same directory, then
     * renames it into place. This makes "the file exists" imply "the copy
     * finished": a process killed mid-write, or a full disk, leaves only the temp
     * file behind, which the next call overwrites and which never gets treated as
     * a real, usable disc. A leftover temp file from an interrupted run is
     * harmless.
     */
    private fun copyAsset(
        context: Context,
        name: String,
        target: File,
    ) {
        val temp = File(target.parentFile, "${target.name}.tmp")
        context.assets.open("$ASSET_DIR/$name").use { input ->
            temp.outputStream().use { output -> input.copyTo(output) }
        }
        // rename() will not replace an existing file on every filesystem, and the
        // target is expected to exist here because the pair is rewritten on every
        // call.
        target.delete()
        if (!temp.renameTo(target)) {
            temp.delete()
            throw IOException("failed to move $name into place")
        }
    }
}
