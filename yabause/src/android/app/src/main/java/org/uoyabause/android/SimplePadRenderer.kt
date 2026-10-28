package org.uoyabause.android

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.Typeface

/**
 * Simple flat design for the six Saturn action buttons (A B C X Y Z).
 *
 * The buttons are drawn by code instead of loaded from pad_r.png, so each one is a
 * separate circle with a clear gap to its neighbours. The bitmap keeps the same size
 * as the old pad_r image (780x1080), which means drag, scale and saved positions in
 * YabausePad keep working unchanged.
 *
 * The touch rect of each button is the bounding square of its circle, expressed in the
 * same bitmap coordinates, so what you see is what you press.
 */
internal object SimplePadRenderer {
    const val WIDTH = 780
    const val HEIGHT = 1080

    private const val BIG_RADIUS = 98f
    private const val SMALL_RADIUS = 64f
    private const val STROKE = 7f

    /** Circle of one button, in bitmap coordinates. */
    class ButtonSpec(
        val label: String,
        val centerX: Float,
        val centerY: Float,
        val radius: Float,
    ) {
        val left: Int get() = (centerX - radius).toInt()
        val top: Int get() = (centerY - radius).toInt()
        val right: Int get() = (centerX + radius).toInt()
        val bottom: Int get() = (centerY + radius).toInt()
    }

    val A = ButtonSpec("A", 165f, 913f, BIG_RADIUS)
    val B = ButtonSpec("B", 382f, 782f, BIG_RADIUS)
    val C = ButtonSpec("C", 619f, 694f, BIG_RADIUS)
    val X = ButtonSpec("X", 89f, 678f, SMALL_RADIUS)
    val Y = ButtonSpec("Y", 277f, 556f, SMALL_RADIUS)
    val Z = ButtonSpec("Z", 472f, 483f, SMALL_RADIUS)

    private val all = listOf(A, B, C, X, Y, Z)

    fun createRightPad(): Bitmap {
        val bitmap = Bitmap.createBitmap(WIDTH, HEIGHT, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bitmap)

        val fill =
            Paint(Paint.ANTI_ALIAS_FLAG).apply {
                style = Paint.Style.FILL
                color = 0x33000000 // 20% black, keeps the ring readable on bright scenes
            }
        val ring =
            Paint(Paint.ANTI_ALIAS_FLAG).apply {
                style = Paint.Style.STROKE
                strokeWidth = STROKE
                color = 0xFFFFFFFF.toInt()
            }
        val text =
            Paint(Paint.ANTI_ALIAS_FLAG).apply {
                style = Paint.Style.FILL
                color = 0xFFFFFFFF.toInt()
                textAlign = Paint.Align.CENTER
                typeface = Typeface.DEFAULT_BOLD
            }

        for (b in all) {
            canvas.drawCircle(b.centerX, b.centerY, b.radius - STROKE / 2f, fill)
            canvas.drawCircle(b.centerX, b.centerY, b.radius - STROKE / 2f, ring)

            text.textSize = b.radius * 0.95f
            val baseline = b.centerY - (text.ascent() + text.descent()) / 2f
            canvas.drawText(b.label, b.centerX, baseline, text)
        }
        return bitmap
    }
}
