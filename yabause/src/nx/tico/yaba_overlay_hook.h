/* Lets the frontend draw its own UI (the tico overlay) on top of each
 * presented frame, with whichever renderer is active. Both hooks run on the
 * thread that presents: the VDP thread for Vulkan, the emulation thread for
 * OpenGL. */
#ifndef YABA_NX_OVERLAY_HOOK_H
#define YABA_NX_OVERLAY_HOOK_H

#include <stdint.h>
#include <vulkan/vulkan.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
  VkInstance instance;
  VkPhysicalDevice physical_device;
  VkDevice device;
  VkQueue queue;
  uint32_t queue_family;
  /* the final render pass, open on command_buffer when the hook runs */
  VkRenderPass render_pass;
  VkCommandBuffer command_buffer;
  VkFormat format;
  uint32_t image_count;
  uint32_t width;
  uint32_t height;
} YabaVkOverlayContext;

typedef void (*YabaVkOverlayHook)(const YabaVkOverlayContext *context);
/* called with the window framebuffer bound, before the buffer swap */
typedef void (*YabaGlOverlayHook)(int width, int height);

extern YabaVkOverlayHook yaba_vk_overlay_hook;
extern YabaGlOverlayHook yaba_gl_overlay_hook;

#ifdef __cplusplus
}
#endif

#endif
