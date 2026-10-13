/*  Copyright 2026 tico

    This file is part of YabaSanshiro.

    YabaSanshiro is free software; you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation; either version 2 of the License, or
    (at your option) any later version.
*/

/* AMD FidelityFX Super Resolution 1.0, shared by both renderers' upscale to
   the screen (vulkan/FsrUpscaler.cpp, ygl_fsr.c). These are the compute
   shaders' bodies: each renderer puts its own header before them, which
   declares Source (sampler2D, binding 0), Dest (rgba8 image2D, binding 1),
   the 8x8 work group and pc, holding
     vec2 scale;     source size / output size
     vec2 offset;    0.5 * scale - 0.5
     ivec2 outSize;
     ivec2 srcMax;   the last texel Source has
     float sharpness; RCAS's, linear: exp2(-stops)

   They follow AMD's ffx_fsr1.h (MIT licence) through libretro's SM 4.0 port
   of EASU (fsr-pass0.slang: twelve texelFetch taps instead of
   textureGather), as tico's other cores run them; RCAS is FsrRcasF without
   the denoise option. */

#ifndef FSR_SHADERS_H
#define FSR_SHADERS_H

static const char *const kFsrEasuBody =
    "\n"
    "float rcpLo(float a) { return uintBitsToFloat(0x7ef07ebbu - floatBitsToUint(a)); }\n"
    "float rsqLo(float a) { return uintBitsToFloat(0x5f347d74u - (floatBitsToUint(a) >> 1u)); }\n"
    "vec3 tap(ivec2 p) { return texelFetch(Source, clamp(p, ivec2(0), pc.srcMax), 0).rgb; }\n"
    "float luma2(vec3 c) { return c.b * 0.5 + (c.r * 0.5 + c.g); }\n"
    "\n"
    "// One bilinear quadrant's direction and edge length (FsrEasuSetF)\n"
    "void quadrant(inout vec2 dir, inout float len, float w,\n"
    "              float lL, float cL, float rL, float uL, float dL) {\n"
    "  float lenX = max(abs(rL - cL), abs(cL - lL));\n"
    "  lenX = rcpLo(lenX);\n"
    "  float dirX = rL - lL;\n"
    "  dir.x += dirX * w;\n"
    "  lenX = clamp(abs(dirX) * lenX, 0.0, 1.0);\n"
    "  lenX *= lenX;\n"
    "  len += lenX * w;\n"
    "  float lenY = max(abs(dL - cL), abs(cL - uL));\n"
    "  lenY = rcpLo(lenY);\n"
    "  float dirY = dL - uL;\n"
    "  dir.y += dirY * w;\n"
    "  lenY = clamp(abs(dirY) * lenY, 0.0, 1.0);\n"
    "  lenY *= lenY;\n"
    "  len += lenY * w;\n"
    "}\n"
    "\n"
    "void main() {\n"
    "  ivec2 gxy = ivec2(gl_GlobalInvocationID.xy);\n"
    "  if (any(greaterThanEqual(gxy, pc.outSize)))\n"
    "    return;\n"
    "  vec2 pp = vec2(gxy) * pc.scale + pc.offset;\n"
    "  vec2 fp = floor(pp);\n"
    "  pp -= fp;\n"
    "  ivec2 sp = ivec2(fp);\n"
    "  //    b c\n"
    "  //  e f g h\n"
    "  //  i j k l\n"
    "  //    n o\n"
    "  vec3 b = tap(sp + ivec2( 0, -1)), c = tap(sp + ivec2( 1, -1));\n"
    "  vec3 e = tap(sp + ivec2(-1,  0)), f = tap(sp + ivec2( 0,  0));\n"
    "  vec3 g = tap(sp + ivec2( 1,  0)), h = tap(sp + ivec2( 2,  0));\n"
    "  vec3 i = tap(sp + ivec2(-1,  1)), j = tap(sp + ivec2( 0,  1));\n"
    "  vec3 k = tap(sp + ivec2( 1,  1)), l = tap(sp + ivec2( 2,  1));\n"
    "  vec3 n = tap(sp + ivec2( 0,  2)), o = tap(sp + ivec2( 1,  2));\n"
    "  float bL = luma2(b), cL = luma2(c), eL = luma2(e), fL = luma2(f), gL = luma2(g), hL = luma2(h);\n"
    "  float iL = luma2(i), jL = luma2(j), kL = luma2(k), lL = luma2(l), nL = luma2(n), oL = luma2(o);\n"
    "\n"
    "  vec2 dir = vec2(0.0);\n"
    "  float len = 0.0;\n"
    "  quadrant(dir, len, (1.0 - pp.x) * (1.0 - pp.y), eL, fL, gL, bL, jL);\n"
    "  quadrant(dir, len, pp.x * (1.0 - pp.y),         fL, gL, hL, cL, kL);\n"
    "  quadrant(dir, len, (1.0 - pp.x) * pp.y,         iL, jL, kL, fL, nL);\n"
    "  quadrant(dir, len, pp.x * pp.y,                 jL, kL, lL, gL, oL);\n"
    "\n"
    "  vec2 dir2 = dir * dir;\n"
    "  float dirR = dir2.x + dir2.y;\n"
    "  bool zro = dirR < (1.0 / 32768.0);\n"
    "  dirR = rsqLo(dirR);\n"
    "  dirR = zro ? 1.0 : dirR;\n"
    "  dir.x = zro ? 1.0 : dir.x;\n"
    "  dir *= vec2(dirR);\n"
    "\n"
    "  len = len * 0.5;\n"
    "  len *= len;\n"
    "  float stretch = (dir.x * dir.x + dir.y * dir.y) * rcpLo(max(abs(dir.x), abs(dir.y)));\n"
    "  vec2 len2 = vec2(1.0 + (stretch - 1.0) * len, 1.0 - 0.5 * len);\n"
    "  float lob = 0.5 + ((1.0 / 4.0 - 0.04) - 0.5) * len;\n"
    "  float clp = rcpLo(lob);\n"
    "\n"
    "  vec3 min4 = min(min(f, g), min(j, k));\n"
    "  vec3 max4 = max(max(f, g), max(j, k));\n"
    "\n"
    "  vec3 aC = vec3(0.0);\n"
    "  float aW = 0.0;\n"
    "#define TAP(OX, OY, COLOR) { \\\n"
    "    vec2 v; \\\n"
    "    v.x = ((OX) - pp.x) * dir.x + ((OY) - pp.y) * dir.y; \\\n"
    "    v.y = ((OX) - pp.x) * (-dir.y) + ((OY) - pp.y) * dir.x; \\\n"
    "    v *= len2; \\\n"
    "    float d2 = min(v.x * v.x + v.y * v.y, clp); \\\n"
    "    float wB = (2.0 / 5.0) * d2 - 1.0; \\\n"
    "    float wA = lob * d2 - 1.0; \\\n"
    "    wB *= wB; wA *= wA; \\\n"
    "    wB = (25.0 / 16.0) * wB - (25.0 / 16.0 - 1.0); \\\n"
    "    float w = wB * wA; \\\n"
    "    aC += (COLOR) * w; aW += w; }\n"
    "  TAP( 0.0, -1.0, b) TAP( 1.0, -1.0, c) TAP(-1.0,  1.0, i) TAP( 0.0,  1.0, j)\n"
    "  TAP( 0.0,  0.0, f) TAP(-1.0,  0.0, e) TAP( 1.0,  1.0, k) TAP( 2.0,  1.0, l)\n"
    "  TAP( 2.0,  0.0, h) TAP( 1.0,  0.0, g) TAP( 1.0,  2.0, o) TAP( 0.0,  2.0, n)\n"
    "#undef TAP\n"
    "\n"
    "  vec3 pix = min(max4, max(min4, aC * (1.0 / aW)));\n"
    "  imageStore(Dest, gxy, vec4(pix, 1.0));\n"
    "}\n";

static const char *const kFsrRcasBody =
    "\n"
    "#define FSR_RCAS_LIMIT (0.25 - (1.0 / 16.0))\n"
    "float rcpMed(float a) {\n"
    "  float b = uintBitsToFloat(0x7ef19fffu - floatBitsToUint(a));\n"
    "  return b * (-b * a + 2.0);\n"
    "}\n"
    "vec3 load(ivec2 p) { return texelFetch(Source, clamp(p, ivec2(0), pc.srcMax), 0).rgb; }\n"
    "float maxOf3(float x, float y, float z) { return max(x, max(y, z)); }\n"
    "float minOf3(float x, float y, float z) { return min(x, min(y, z)); }\n"
    "\n"
    "void main() {\n"
    "  ivec2 sp = ivec2(gl_GlobalInvocationID.xy);\n"
    "  if (any(greaterThanEqual(sp, pc.outSize)))\n"
    "    return;\n"
    "  //    b\n"
    "  //  d e f\n"
    "  //    h\n"
    "  vec3 b = load(sp + ivec2( 0, -1));\n"
    "  vec3 d = load(sp + ivec2(-1,  0));\n"
    "  vec3 e = load(sp);\n"
    "  vec3 f = load(sp + ivec2( 1,  0));\n"
    "  vec3 h = load(sp + ivec2( 0,  1));\n"
    "  vec3 mn4 = min(min(b, d), min(f, h));\n"
    "  vec3 mx4 = max(max(b, d), max(f, h));\n"
    "  vec2 peakC = vec2(1.0, -4.0);\n"
    "  vec3 hitMin = min(mn4, e) * (1.0 / (4.0 * mx4));\n"
    "  vec3 hitMax = (peakC.x - max(mx4, e)) * (1.0 / (4.0 * mn4 + peakC.y));\n"
    "  vec3 lobeRGB = max(-hitMin, hitMax);\n"
    "  float lobe = max(-FSR_RCAS_LIMIT, min(maxOf3(lobeRGB.r, lobeRGB.g, lobeRGB.b), 0.0)) * pc.sharpness;\n"
    "  float rcpL = rcpMed(4.0 * lobe + 1.0);\n"
    "  vec3 pix = (lobe * b + lobe * d + lobe * h + lobe * f + e) * rcpL;\n"
    "  imageStore(Dest, sp, vec4(pix, 1.0));\n"
    "}\n";

#endif
