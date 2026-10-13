#pragma once

// AMD FidelityFX Super Resolution 1.0 for the final picture: EASU upscales
// the game's render target to the size it takes on screen, RCAS sharpens it,
// and the result is copied into the swapchain image. Both passes are compute
// shaders, so the swapchain needs no storage usage.

#include <cstdint>
#include <vulkan/vulkan.h>

class VIDVulkan;

class FsrUpscaler {
public:
  explicit FsrUpscaler(VIDVulkan* vulkan);
  ~FsrUpscaler();

  FsrUpscaler(const FsrUpscaler&) = delete;
  FsrUpscaler& operator=(const FsrUpscaler&) = delete;

  // Sharpness in stops, as RCAS takes it: 0 the sharpest, each stop halves it.
  void setSharpness(float stops) { sharpnessStops = stops; }

  // Upscales srcImage (srcWidth x srcHeight, in srcLayout, left in it) into
  // the dst rectangle of dstImage. dstImage goes from UNDEFINED to
  // finalDstLayout, as the nearest blit it replaces leaves it. Returns false
  // when FSR cannot run (it then recorded nothing).
  bool record(VkCommandBuffer cmd, VkImage srcImage, VkImageView srcView, VkImageLayout srcLayout,
              uint32_t srcWidth, uint32_t srcHeight, VkImage dstImage, int32_t dstX, int32_t dstY,
              uint32_t dstWidth, uint32_t dstHeight, VkImageLayout finalDstLayout);

  // The source's view is about to be destroyed: bind the next one afresh.
  void sourceChanged() { boundSource = VK_NULL_HANDLE; }

  void release();

private:
  struct Target {
    VkImage image = VK_NULL_HANDLE;
    VkDeviceMemory memory = VK_NULL_HANDLE;
    VkImageView view = VK_NULL_HANDLE;
  };

  bool setup();
  bool resize(uint32_t width, uint32_t height);
  void destroyTargets();
  VkShaderModule compile(const char* source, const char* name);
  bool createTarget(Target& target, uint32_t width, uint32_t height);

  VIDVulkan* vulkan;
  float sharpnessStops = 0.2f;
  bool ready = false;
  bool failed = false;

  VkSampler sampler = VK_NULL_HANDLE;
  VkDescriptorSetLayout setLayout = VK_NULL_HANDLE;
  VkPipelineLayout pipelineLayout = VK_NULL_HANDLE;
  VkPipeline easuPipeline = VK_NULL_HANDLE;
  VkPipeline rcasPipeline = VK_NULL_HANDLE;
  VkDescriptorPool descriptorPool = VK_NULL_HANDLE;
  VkDescriptorSet easuSet = VK_NULL_HANDLE;
  VkDescriptorSet rcasSet = VK_NULL_HANDLE;

  Target easuOut; // the upscaled picture
  Target rcasOut; // the sharpened picture
  uint32_t width = 0;
  uint32_t height = 0;
  VkImageView boundSource = VK_NULL_HANDLE;
};
