/// @file TicoVulkan.h
/// @brief Vulkan host glue between the tico frontend and yabause's VIDVulkan core.
///
/// VIDVulkan owns the VkInstance/VkDevice/swapchain (created through Renderer +
/// Window with the NVK driver). This module only adds what the tico overlay
/// needs on top of it:
///   - the ImGui Vulkan backend (descriptor pool + pipeline on VIDVulkan's
///     swapchain render pass)
///   - RGBA texture uploads for overlay icons / avatars / RA badges
///   - presentation of standalone overlay frames while the emulator is paused
///     (via VIDVulkan::renderExternal)
///
/// Copyright 2025 tico
#pragma once

#include "imgui.h"

#include <vulkan/vulkan.h>
#include <cstdint>

struct ImDrawData;

namespace TicoVulkan
{

// Bring up the ImGui Vulkan backend. Must be called AFTER YabauseInit() (the
// VIDVulkan device/swapchain exist) and after the ImGui context + fonts are
// ready. Safe to call more than once.
bool InitOverlayRenderer();

// Tear the ImGui backend + all overlay textures down. Call BEFORE
// YabauseDeInit() (the VkDevice must still be alive).
void ShutdownOverlayRenderer();

// True once InitOverlayRenderer() succeeded.
bool IsReady();

// Upload an RGBA8 image and register it with ImGui. Returns 0 on failure.
// The queue is submitted and waited on synchronously. Callers must make sure
// the VDP render thread is not submitting concurrently (paused, or called
// from the render thread itself).
ImTextureID CreateTextureRGBA(const unsigned char* rgba, uint32_t width, uint32_t height);

// Destroy a texture previously returned by CreateTextureRGBA.
void DestroyTexture(ImTextureID texture);

// Record ImGui draw data into an externally-provided command buffer (used by
// the VIDVulkan overlay hook while a render pass is active, VDP thread).
void RenderDrawData(ImDrawData* drawData, VkCommandBuffer commandBuffer);

// Present a standalone overlay frame while the emulator is paused: acquires a
// swapchain image through VIDVulkan::renderExternal, records the draw data and
// presents. Main thread only, emulation must be stopped.
void PresentOverlayFrame(ImDrawData* drawData);

// Capture the last presented game frame into an ImGui texture (pause
// background). Returns 0 on failure. outW/outH receive the capture size.
ImTextureID CaptureGameFrame(int* outW, int* outH);

}  // namespace TicoVulkan
