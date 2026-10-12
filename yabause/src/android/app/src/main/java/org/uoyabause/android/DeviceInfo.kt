package org.uoyabause.android

import android.opengl.EGL14
import android.opengl.EGLConfig
import android.opengl.EGLDisplay
import android.opengl.EGLExt
import android.opengl.GLES20
import android.os.Build

/**
 * Lightweight device information for bug reports and capability detection. The GPU
 * renderer string and GL extension string are queried together (best-effort) from a
 * single throwaway EGL PBuffer context and cached; failures yield "" for both.
 */
object DeviceInfo {
    fun model(): String = "${Build.MANUFACTURER} ${Build.MODEL}".trim()

    fun osVersion(): String = "Android ${Build.VERSION.RELEASE} (API ${Build.VERSION.SDK_INT})"

    /** Result of probing the throwaway GL context once: renderer string and extension string. */
    private data class GlProbeResult(
        val renderer: String,
        val extensions: String,
    )

    @Volatile
    private var cachedGlProbe: GlProbeResult? = null

    /**
     * GL_VENDOR + GL_RENDERER (e.g. "Qualcomm Adreno (TM) 650"), or "" if it cannot
     * be determined. Backed by the same cached probe as [glExtensions]; only one
     * throwaway EGL context is ever created. Safe to call from a background thread;
     * it creates and tears down its own EGL context and does not touch any context
     * current on other threads.
     */
    fun gpuRenderer(): String = glProbe().renderer

    /**
     * GL_EXTENSIONS of the same throwaway context used by [gpuRenderer], or "" when
     * it cannot be queried. Backed by the same cached probe, so calling both
     * [gpuRenderer] and [glExtensions] only ever creates one EGL context in total.
     */
    fun glExtensions(): String = glProbe().extensions

    private fun glProbe(): GlProbeResult {
        cachedGlProbe?.let { return it }
        val result = queryGl()
        cachedGlProbe = result
        return result
    }

    /** Picks the first config advertising [renderableTypeBit], or null if none does. */
    private fun chooseConfig(
        display: EGLDisplay,
        renderableTypeBit: Int,
    ): EGLConfig? {
        val configAttribs =
            intArrayOf(
                EGL14.EGL_RENDERABLE_TYPE,
                renderableTypeBit,
                EGL14.EGL_SURFACE_TYPE,
                EGL14.EGL_PBUFFER_BIT,
                EGL14.EGL_NONE,
            )
        val configs = arrayOfNulls<EGLConfig>(1)
        val numConfig = IntArray(1)
        val ok = EGL14.eglChooseConfig(display, configAttribs, 0, configs, 0, 1, numConfig, 0)
        return if (ok && numConfig[0] > 0) configs[0] else null
    }

    private fun queryGl(): GlProbeResult {
        val empty = GlProbeResult("", "")
        var display = EGL14.EGL_NO_DISPLAY
        var context = EGL14.EGL_NO_CONTEXT
        var surface = EGL14.EGL_NO_SURFACE
        try {
            display = EGL14.eglGetDisplay(EGL14.EGL_DEFAULT_DISPLAY)
            if (display == EGL14.EGL_NO_DISPLAY) return empty
            val version = IntArray(2)
            if (!EGL14.eglInitialize(display, version, 0, version, 1)) return empty

            // Prefer an ES3 context: some drivers only advertise ES3.1-only
            // extensions (e.g. GL_ANDROID_extension_pack_es31a) to a context that
            // was actually negotiated as ES3+, not to a plain ES2 context. Fall
            // back to ES2 if no ES3 config is available or context creation fails,
            // so this probe still works on genuinely ES2-only devices.
            var config = chooseConfig(display, EGLExt.EGL_OPENGL_ES3_BIT_KHR)
            var clientVersion = 3
            if (config == null) {
                config = chooseConfig(display, EGL14.EGL_OPENGL_ES2_BIT)
                clientVersion = 2
            }
            if (config == null) return empty

            var contextAttribs = intArrayOf(EGL14.EGL_CONTEXT_CLIENT_VERSION, clientVersion, EGL14.EGL_NONE)
            context = EGL14.eglCreateContext(display, config, EGL14.EGL_NO_CONTEXT, contextAttribs, 0)
            if (context == EGL14.EGL_NO_CONTEXT && clientVersion == 3) {
                // The ES3 config existed but the context refused to be created;
                // retry once with ES2 before giving up.
                config = chooseConfig(display, EGL14.EGL_OPENGL_ES2_BIT)
                if (config == null) return empty
                clientVersion = 2
                contextAttribs = intArrayOf(EGL14.EGL_CONTEXT_CLIENT_VERSION, clientVersion, EGL14.EGL_NONE)
                context = EGL14.eglCreateContext(display, config, EGL14.EGL_NO_CONTEXT, contextAttribs, 0)
            }
            if (context == EGL14.EGL_NO_CONTEXT) return empty

            val surfaceAttribs = intArrayOf(EGL14.EGL_WIDTH, 1, EGL14.EGL_HEIGHT, 1, EGL14.EGL_NONE)
            surface = EGL14.eglCreatePbufferSurface(display, config, surfaceAttribs, 0)
            if (surface == EGL14.EGL_NO_SURFACE) return empty

            if (!EGL14.eglMakeCurrent(display, surface, surface, context)) return empty

            val vendor = GLES20.glGetString(GLES20.GL_VENDOR) ?: ""
            val renderer = GLES20.glGetString(GLES20.GL_RENDERER) ?: ""
            val rendererString = listOf(vendor, renderer).filter { it.isNotBlank() }.joinToString(" ").trim()
            val extensions = GLES20.glGetString(GLES20.GL_EXTENSIONS) ?: ""
            return GlProbeResult(rendererString, extensions)
        } catch (e: Exception) {
            return empty
        } finally {
            if (display != EGL14.EGL_NO_DISPLAY) {
                EGL14.eglMakeCurrent(
                    display,
                    EGL14.EGL_NO_SURFACE,
                    EGL14.EGL_NO_SURFACE,
                    EGL14.EGL_NO_CONTEXT,
                )
                if (surface != EGL14.EGL_NO_SURFACE) EGL14.eglDestroySurface(display, surface)
                if (context != EGL14.EGL_NO_CONTEXT) EGL14.eglDestroyContext(display, context)
                EGL14.eglTerminate(display)
            }
        }
    }
}
