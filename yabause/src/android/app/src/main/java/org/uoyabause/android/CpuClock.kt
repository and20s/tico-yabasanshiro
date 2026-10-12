package org.uoyabause.android

import java.io.File

/**
 * Maximum CPU clock as reported by sysfs.
 *
 * Whether these files are readable depends on the vendor and the Android
 * version, so a missing value is expected rather than exceptional.
 */
object CpuClock {
    private const val MAX_CORES = 32

    fun parseKhz(text: String?): Int? {
        val value = text?.trim()?.toIntOrNull() ?: return null
        return if (value > 0) value else null
    }

    /** Highest `cpuinfo_max_freq` across all cores, or null if none can be read. */
    fun maxKhz(): Int? {
        var max: Int? = null
        for (core in 0 until MAX_CORES) {
            val file = File("/sys/devices/system/cpu/cpu$core/cpufreq/cpuinfo_max_freq")
            val text =
                try {
                    if (file.canRead()) file.readText() else null
                } catch (e: Exception) {
                    null
                }
            val khz = parseKhz(text) ?: continue
            if (max == null || khz > max!!) max = khz
        }
        return max
    }
}
