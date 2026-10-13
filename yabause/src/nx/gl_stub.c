/*  GL/EGL link stubs for the Vulkan-only Switch build.

    The yabause core mixes CPU-side helpers the Vulkan renderer needs at
    runtime (fixVdp2Regs, Vdp2ColorRamGetColor, the rotation-parameter
    readers, the Vulkan shader sources in yglshaderes.c, ...) into the same
    translation units as the OpenGL renderer. Those objects are pulled into
    the link, dragging in GL/EGL references that no library satisfies —
    the NVK stack only provides Vulkan.

    The GL code paths are unreachable at runtime: VIDCore is VIDVulkan, so
    YglInit()/VIDOGL are never invoked. These stubs only exist to satisfy
    the linker. Signatures are intentionally generic (symbol-level linking
    only cares about names); every stub returns 0.

    Generated from a scan of: ygles.c yglcache.c yglshaderes.c vidogl.c
    ygl_texture.cpp nanovg_osdcore.c nanovg_gl.h nanovg_gl_utils.h
*/

/* eglGetProcAddress: provided by NVK (rust_switch_stubs.c) — not stubbed here */
long glActiveTexture(void) { return 0; }
long glAttachShader(void) { return 0; }
long glBindAttribLocation(void) { return 0; }
long glBindBuffer(void) { return 0; }
long glBindBufferBase(void) { return 0; }
long glBindBufferRange(void) { return 0; }
long glBindFramebuffer(void) { return 0; }
long glBindImageTexture(void) { return 0; }
long glBindRenderbuffer(void) { return 0; }
long glBindTexture(void) { return 0; }
long glBindVertexArray(void) { return 0; }
long glBlendFunc(void) { return 0; }
long glBlendFuncSeparate(void) { return 0; }
long glBlitFramebuffer(void) { return 0; }
long glBufferData(void) { return 0; }
long glBufferSubData(void) { return 0; }
long glCheckFramebufferStatus(void) { return 0; }
long glClear(void) { return 0; }
long glClearColor(void) { return 0; }
long glClearDepthf(void) { return 0; }
long glClearStencil(void) { return 0; }
long glColor3ub(void) { return 0; }
long glColorMask(void) { return 0; }
long glColorPointer(void) { return 0; }
long glCompileShader(void) { return 0; }
long glCopyBufferSubData(void) { return 0; }
long glCreateProgram(void) { return 0; }
long glCreateShader(void) { return 0; }
long glCullFace(void) { return 0; }
long glDeleteBuffers(void) { return 0; }
long glDeleteFramebuffers(void) { return 0; }
long glDeleteProgram(void) { return 0; }
long glDeleteRenderbuffers(void) { return 0; }
long glDeleteShader(void) { return 0; }
long glDeleteSync(void) { return 0; }
long glDeleteTextures(void) { return 0; }
long glDeleteVertexArrays(void) { return 0; }
long glDepthFunc(void) { return 0; }
long glDepthMask(void) { return 0; }
long glDetachShader(void) { return 0; }
long glDisable(void) { return 0; }
long glDisableClientState(void) { return 0; }
long glDisableVertexAttribArray(void) { return 0; }
long glDispatchCompute(void) { return 0; }
long glDrawArrays(void) { return 0; }
long glEnable(void) { return 0; }
long glEnableClientState(void) { return 0; }
long glEnableVertexAttribArray(void) { return 0; }
long glFenceSync(void) { return 0; }
long glFinish(void) { return 0; }
long glFramebufferRenderbuffer(void) { return 0; }
long glFramebufferTexture2D(void) { return 0; }
long glFrontFace(void) { return 0; }
long glGenBuffers(void) { return 0; }
long glGenFramebuffers(void) { return 0; }
long glGenRenderbuffers(void) { return 0; }
long glGenTextures(void) { return 0; }
long glGenVertexArrays(void) { return 0; }
long glGenerateMipmap(void) { return 0; }
long glGetAttribLocation(void) { return 0; }
long glGetError(void) { return 0; }
long glGetIntegeri_v(void) { return 0; }
long glGetIntegerv(void) { return 0; }
long glGetProgramInfoLog(void) { return 0; }
long glGetProgramiv(void) { return 0; }
long glGetShaderInfoLog(void) { return 0; }
long glGetShaderiv(void) { return 0; }
long glGetString(void) { return 0; }
long glGetUniformBlockIndex(void) { return 0; }
long glGetUniformLocation(void) { return 0; }
long glLinkProgram(void) { return 0; }
long glMapBufferRange(void) { return 0; }
long glMemoryBarrier(void) { return 0; }
long glPatchParameteriOES(void) { return 0; }
long glPixelStorei(void) { return 0; }
long glPushDebugGroup(void) { return 0; }
long glReadPixels(void) { return 0; }
long glRenderbufferStorage(void) { return 0; }
long glScissor(void) { return 0; }
long glShaderSource(void) { return 0; }
long glStencilFunc(void) { return 0; }
long glStencilMask(void) { return 0; }
long glStencilOp(void) { return 0; }
long glStencilOpSeparate(void) { return 0; }
long glTexImage2D(void) { return 0; }
long glTexParameteri(void) { return 0; }
long glTexStorage2D(void) { return 0; }
long glTexSubImage2D(void) { return 0; }
long glUniform1f(void) { return 0; }
long glUniform1i(void) { return 0; }
long glUniform2f(void) { return 0; }
long glUniform2fv(void) { return 0; }
long glUniform2iv(void) { return 0; }
long glUniform4fv(void) { return 0; }
long glUniformBlockBinding(void) { return 0; }
long glUniformMatrix4fv(void) { return 0; }
long glUnmapBuffer(void) { return 0; }
long glUseProgram(void) { return 0; }
long glVertexAttribPointer(void) { return 0; }
long glVertexPointer(void) { return 0; }
long glViewport(void) { return 0; }
long glWaitSync(void) { return 0; }
