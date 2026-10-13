/*  Copyright 2026 tico

    This file is part of YabaSanshiro.

    YabaSanshiro is free software; you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation; either version 2 of the License, or
    (at your option) any later version.
*/

/* AMD FidelityFX Super Resolution 1.0 for the OpenGL renderer's upscale to
   the screen: EASU then RCAS as two compute passes, as the Vulkan renderer
   runs them (vulkan/FsrUpscaler.cpp). Switch only (desktop GL 4.3). */

#ifndef YGL_FSR_H
#define YGL_FSR_H

#ifdef __cplusplus
extern "C" {
#endif

/* 0 the nearest or bilinear blit as before, 1 FSR when the picture grows.
   Sharpness in stops, 0 the sharpest. Any thread; read at every frame. */
void YglFsrSetUpscaling(int mode, float sharpnessStops);
int YglFsrEnabled(void);

/* Upscales the srcWidth x srcHeight of srcTexture into the rectangle at
   dstX, dstY of the framebuffer drawFbo. Returns 0 when FSR cannot run
   (nothing was drawn): the caller blits as before. */
int YglFsrUpscale(unsigned int srcTexture, int srcWidth, int srcHeight, unsigned int drawFbo, int dstX,
                  int dstY, int dstWidth, int dstHeight);

/* Frees the GL objects; the context must be current. */
void YglFsrDeInit(void);

#ifdef __cplusplus
}
#endif

#endif
