/*  Copyright 2026 tico

    This file is part of YabaSanshiro.

    YabaSanshiro is free software; you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation; either version 2 of the License, or
    (at your option) any later version.
*/

/* AMD FSR 1.0 for the OpenGL renderer: see ygl_fsr.h. */

#include "ygl_fsr.h"

#ifdef NX

#include <math.h>
#include <stdio.h>
#include <string.h>

#include "ygl.h"
#include "fsr_shaders.h"

/* The OpenGL side of the shaders' header: pc is a uniform struct here, so
   the bodies read it as they read Vulkan's push constants. */
static const char *const kGlHeader =
    "#version 430\n"
    "layout(local_size_x = 8, local_size_y = 8) in;\n"
    "layout(binding = 0) uniform sampler2D Source;\n"
    "layout(binding = 1, rgba8) uniform writeonly image2D Dest;\n"
    "struct Push {\n"
    "  vec2 scale;\n"
    "  vec2 offset;\n"
    "  ivec2 outSize;\n"
    "  ivec2 srcMax;\n"
    "  float sharpness;\n"
    "};\n"
    "uniform Push pc;\n";

static volatile int s_mode = 0;
static volatile float s_sharpnessStops = 0.2f;

static int s_ready = 0;
static int s_failed = 0;
static GLuint s_programs[2] = {0, 0}; /* EASU, RCAS */
static GLuint s_targets[2] = {0, 0};  /* the upscaled picture, the sharpened one */
static GLuint s_readFbo = 0;          /* the sharpened picture, for the blit */
static int s_width = 0;
static int s_height = 0;

void YglFsrSetUpscaling(int mode, float sharpnessStops)
{
  s_mode = mode;
  s_sharpnessStops = sharpnessStops;
}

int YglFsrEnabled(void) { return s_mode == 1; }

static GLuint Compile(const char *body, const char *name)
{
  const GLchar *sources[2] = {kGlHeader, body};
  GLuint shader = glCreateShader(GL_COMPUTE_SHADER);
  GLint ok = 0;
  glShaderSource(shader, 2, sources, NULL);
  glCompileShader(shader);
  glGetShaderiv(shader, GL_COMPILE_STATUS, &ok);
  if (!ok)
  {
    char info[1024] = {0};
    glGetShaderInfoLog(shader, sizeof(info) - 1, NULL, info);
    printf("YglFsr: %s does not compile: %s\n", name, info);
    glDeleteShader(shader);
    return 0;
  }
  GLuint program = glCreateProgram();
  glAttachShader(program, shader);
  glLinkProgram(program);
  glDeleteShader(shader);
  glGetProgramiv(program, GL_LINK_STATUS, &ok);
  if (!ok)
  {
    printf("YglFsr: %s does not link\n", name);
    glDeleteProgram(program);
    return 0;
  }
  return program;
}

static int Setup(void)
{
  if (s_ready)
    return 1;
  if (s_failed)
    return 0;
  s_failed = 1; /* until both programs exist */
  s_programs[0] = Compile(kFsrEasuBody, "fsr_easu");
  s_programs[1] = Compile(kFsrRcasBody, "fsr_rcas");
  if (!s_programs[0] || !s_programs[1])
    return 0;
  s_failed = 0;
  s_ready = 1;
  return 1;
}

static void DeleteTargets(void)
{
  if (s_readFbo)
    glDeleteFramebuffers(1, &s_readFbo);
  if (s_targets[0] || s_targets[1])
    glDeleteTextures(2, s_targets);
  s_readFbo = 0;
  s_targets[0] = s_targets[1] = 0;
  s_width = s_height = 0;
}

static int Resize(int width, int height)
{
  int i;
  if (width == s_width && height == s_height && s_targets[0])
    return 1;
  DeleteTargets();
  glGenTextures(2, s_targets);
  for (i = 0; i < 2; i++)
  {
    glBindTexture(GL_TEXTURE_2D, s_targets[i]);
    glTexStorage2D(GL_TEXTURE_2D, 1, GL_RGBA8, width, height);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
  }
  glBindTexture(GL_TEXTURE_2D, 0);
  glGenFramebuffers(1, &s_readFbo);
  glBindFramebuffer(GL_READ_FRAMEBUFFER, s_readFbo);
  glFramebufferTexture2D(GL_READ_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, s_targets[1], 0);
  if (glCheckFramebufferStatus(GL_READ_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE)
  {
    glBindFramebuffer(GL_READ_FRAMEBUFFER, 0);
    DeleteTargets();
    return 0;
  }
  glBindFramebuffer(GL_READ_FRAMEBUFFER, 0);
  s_width = width;
  s_height = height;
  return 1;
}

static void SetConstants(GLuint program, int srcWidth, int srcHeight, int dstWidth, int dstHeight,
                         int srcMaxX, int srcMaxY)
{
  const float scaleX = (float)srcWidth / dstWidth, scaleY = (float)srcHeight / dstHeight;
  glUniform2f(glGetUniformLocation(program, "pc.scale"), scaleX, scaleY);
  glUniform2f(glGetUniformLocation(program, "pc.offset"), 0.5f * scaleX - 0.5f, 0.5f * scaleY - 0.5f);
  glUniform2i(glGetUniformLocation(program, "pc.outSize"), dstWidth, dstHeight);
  glUniform2i(glGetUniformLocation(program, "pc.srcMax"), srcMaxX, srcMaxY);
  glUniform1f(glGetUniformLocation(program, "pc.sharpness"), exp2f(-s_sharpnessStops));
}

int YglFsrUpscale(unsigned int srcTexture, int srcWidth, int srcHeight, unsigned int drawFbo, int dstX,
                  int dstY, int dstWidth, int dstHeight)
{
  GLint savedProgram = 0, savedActive = 0, savedTexture = 0;
  const GLuint groupsX = (dstWidth + 7) / 8, groupsY = (dstHeight + 7) / 8;
  if (srcWidth <= 0 || srcHeight <= 0 || dstWidth <= 0 || dstHeight <= 0)
    return 0;
  if (!Setup() || !Resize(dstWidth, dstHeight))
    return 0;

  glGetIntegerv(GL_CURRENT_PROGRAM, &savedProgram);
  glGetIntegerv(GL_ACTIVE_TEXTURE, &savedActive);
  glActiveTexture(GL_TEXTURE0);
  glGetIntegerv(GL_TEXTURE_BINDING_2D, &savedTexture);

  /* EASU: the game's picture, upscaled */
  glUseProgram(s_programs[0]);
  SetConstants(s_programs[0], srcWidth, srcHeight, dstWidth, dstHeight, srcWidth - 1, srcHeight - 1);
  glBindTexture(GL_TEXTURE_2D, srcTexture);
  glBindImageTexture(1, s_targets[0], 0, GL_FALSE, 0, GL_WRITE_ONLY, GL_RGBA8);
  glDispatchCompute(groupsX, groupsY, 1);
  glMemoryBarrier(GL_TEXTURE_FETCH_BARRIER_BIT | GL_SHADER_IMAGE_ACCESS_BARRIER_BIT);

  /* RCAS: sharpened */
  glUseProgram(s_programs[1]);
  SetConstants(s_programs[1], srcWidth, srcHeight, dstWidth, dstHeight, dstWidth - 1, dstHeight - 1);
  glBindTexture(GL_TEXTURE_2D, s_targets[0]);
  glBindImageTexture(1, s_targets[1], 0, GL_FALSE, 0, GL_WRITE_ONLY, GL_RGBA8);
  glDispatchCompute(groupsX, groupsY, 1);
  glMemoryBarrier(GL_FRAMEBUFFER_BARRIER_BIT);

  /* into its place on screen, 1:1 */
  glBindFramebuffer(GL_READ_FRAMEBUFFER, s_readFbo);
  glBindFramebuffer(GL_DRAW_FRAMEBUFFER, drawFbo);
  glBlitFramebuffer(0, 0, dstWidth, dstHeight, dstX, dstY, dstX + dstWidth, dstY + dstHeight,
                    GL_COLOR_BUFFER_BIT, GL_NEAREST);
  glBindFramebuffer(GL_FRAMEBUFFER, drawFbo);

  glBindImageTexture(1, 0, 0, GL_FALSE, 0, GL_WRITE_ONLY, GL_RGBA8);
  glBindTexture(GL_TEXTURE_2D, savedTexture);
  glActiveTexture(savedActive);
  glUseProgram(savedProgram);
  return 1;
}

void YglFsrDeInit(void)
{
  int i;
  DeleteTargets();
  for (i = 0; i < 2; i++)
    if (s_programs[i])
      glDeleteProgram(s_programs[i]);
  s_programs[0] = s_programs[1] = 0;
  s_ready = 0;
  s_failed = 0;
}

#else

void YglFsrSetUpscaling(int mode, float sharpnessStops)
{
  (void)mode;
  (void)sharpnessStops;
}
int YglFsrEnabled(void) { return 0; }
int YglFsrUpscale(unsigned int srcTexture, int srcWidth, int srcHeight, unsigned int drawFbo, int dstX,
                  int dstY, int dstWidth, int dstHeight)
{
  (void)srcTexture; (void)srcWidth; (void)srcHeight; (void)drawFbo;
  (void)dstX; (void)dstY; (void)dstWidth; (void)dstHeight;
  return 0;
}
void YglFsrDeInit(void) {}

#endif
