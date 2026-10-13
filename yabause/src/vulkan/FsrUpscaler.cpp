// AMD FidelityFX Super Resolution 1.0 (EASU + RCAS) as two compute passes.
//
// The shaders follow AMD's ffx_fsr1.h (MIT licence) through libretro's
// SM 4.0 port of EASU (fsr-pass0.slang: twelve texelFetch taps instead of
// textureGather), as tico's other cores run them; RCAS is FsrRcasF without
// the denoise option, sharpness in stops (0 the sharpest).

#include "FsrUpscaler.h"
#include "VIDVulkan.h"
#include "VulkanTools.h"

#include "shaderc/shaderc.hpp"

#include <cmath>
#include <cstdio>
#include <string>
#include <vector>

namespace {

const char* kEasuSource = R"(
#version 450
layout(local_size_x = 8, local_size_y = 8) in;
layout(set = 0, binding = 0) uniform sampler2D Source;
layout(set = 0, binding = 1, rgba8) uniform writeonly image2D Dest;
layout(push_constant) uniform Push {
  vec2 scale;   // source size / output size
  vec2 offset;  // 0.5 * scale - 0.5
  ivec2 outSize;
  ivec2 srcMax;
  float sharpness;
} pc;

float rcpLo(float a) { return uintBitsToFloat(0x7ef07ebbu - floatBitsToUint(a)); }
float rsqLo(float a) { return uintBitsToFloat(0x5f347d74u - (floatBitsToUint(a) >> 1u)); }
vec3 tap(ivec2 p) { return texelFetch(Source, clamp(p, ivec2(0), pc.srcMax), 0).rgb; }
float luma2(vec3 c) { return c.b * 0.5 + (c.r * 0.5 + c.g); }

// One bilinear quadrant's direction and edge length (FsrEasuSetF)
void quadrant(inout vec2 dir, inout float len, float w,
              float lL, float cL, float rL, float uL, float dL) {
  float lenX = max(abs(rL - cL), abs(cL - lL));
  lenX = rcpLo(lenX);
  float dirX = rL - lL;
  dir.x += dirX * w;
  lenX = clamp(abs(dirX) * lenX, 0.0, 1.0);
  lenX *= lenX;
  len += lenX * w;
  float lenY = max(abs(dL - cL), abs(cL - uL));
  lenY = rcpLo(lenY);
  float dirY = dL - uL;
  dir.y += dirY * w;
  lenY = clamp(abs(dirY) * lenY, 0.0, 1.0);
  lenY *= lenY;
  len += lenY * w;
}

void main() {
  ivec2 gxy = ivec2(gl_GlobalInvocationID.xy);
  if (any(greaterThanEqual(gxy, pc.outSize)))
    return;
  vec2 pp = vec2(gxy) * pc.scale + pc.offset;
  vec2 fp = floor(pp);
  pp -= fp;
  ivec2 sp = ivec2(fp);
  //    b c
  //  e f g h
  //  i j k l
  //    n o
  vec3 b = tap(sp + ivec2( 0, -1)), c = tap(sp + ivec2( 1, -1));
  vec3 e = tap(sp + ivec2(-1,  0)), f = tap(sp + ivec2( 0,  0));
  vec3 g = tap(sp + ivec2( 1,  0)), h = tap(sp + ivec2( 2,  0));
  vec3 i = tap(sp + ivec2(-1,  1)), j = tap(sp + ivec2( 0,  1));
  vec3 k = tap(sp + ivec2( 1,  1)), l = tap(sp + ivec2( 2,  1));
  vec3 n = tap(sp + ivec2( 0,  2)), o = tap(sp + ivec2( 1,  2));
  float bL = luma2(b), cL = luma2(c), eL = luma2(e), fL = luma2(f), gL = luma2(g), hL = luma2(h);
  float iL = luma2(i), jL = luma2(j), kL = luma2(k), lL = luma2(l), nL = luma2(n), oL = luma2(o);

  vec2 dir = vec2(0.0);
  float len = 0.0;
  quadrant(dir, len, (1.0 - pp.x) * (1.0 - pp.y), eL, fL, gL, bL, jL);
  quadrant(dir, len, pp.x * (1.0 - pp.y),         fL, gL, hL, cL, kL);
  quadrant(dir, len, (1.0 - pp.x) * pp.y,         iL, jL, kL, fL, nL);
  quadrant(dir, len, pp.x * pp.y,                 jL, kL, lL, gL, oL);

  vec2 dir2 = dir * dir;
  float dirR = dir2.x + dir2.y;
  bool zro = dirR < (1.0 / 32768.0);
  dirR = rsqLo(dirR);
  dirR = zro ? 1.0 : dirR;
  dir.x = zro ? 1.0 : dir.x;
  dir *= vec2(dirR);

  len = len * 0.5;
  len *= len;
  float stretch = (dir.x * dir.x + dir.y * dir.y) * rcpLo(max(abs(dir.x), abs(dir.y)));
  vec2 len2 = vec2(1.0 + (stretch - 1.0) * len, 1.0 - 0.5 * len);
  float lob = 0.5 + ((1.0 / 4.0 - 0.04) - 0.5) * len;
  float clp = rcpLo(lob);

  vec3 min4 = min(min(f, g), min(j, k));
  vec3 max4 = max(max(f, g), max(j, k));

  vec3 aC = vec3(0.0);
  float aW = 0.0;
#define TAP(OX, OY, COLOR) { \
    vec2 v; \
    v.x = ((OX) - pp.x) * dir.x + ((OY) - pp.y) * dir.y; \
    v.y = ((OX) - pp.x) * (-dir.y) + ((OY) - pp.y) * dir.x; \
    v *= len2; \
    float d2 = min(v.x * v.x + v.y * v.y, clp); \
    float wB = (2.0 / 5.0) * d2 - 1.0; \
    float wA = lob * d2 - 1.0; \
    wB *= wB; wA *= wA; \
    wB = (25.0 / 16.0) * wB - (25.0 / 16.0 - 1.0); \
    float w = wB * wA; \
    aC += (COLOR) * w; aW += w; }
  TAP( 0.0, -1.0, b) TAP( 1.0, -1.0, c) TAP(-1.0,  1.0, i) TAP( 0.0,  1.0, j)
  TAP( 0.0,  0.0, f) TAP(-1.0,  0.0, e) TAP( 1.0,  1.0, k) TAP( 2.0,  1.0, l)
  TAP( 2.0,  0.0, h) TAP( 1.0,  0.0, g) TAP( 1.0,  2.0, o) TAP( 0.0,  2.0, n)
#undef TAP

  vec3 pix = min(max4, max(min4, aC * (1.0 / aW)));
  imageStore(Dest, gxy, vec4(pix, 1.0));
}
)";

const char* kRcasSource = R"(
#version 450
layout(local_size_x = 8, local_size_y = 8) in;
layout(set = 0, binding = 0) uniform sampler2D Source;
layout(set = 0, binding = 1, rgba8) uniform writeonly image2D Dest;
layout(push_constant) uniform Push {
  vec2 scale;
  vec2 offset;
  ivec2 outSize;
  ivec2 srcMax;
  float sharpness; // linear: exp2(-stops)
} pc;

#define FSR_RCAS_LIMIT (0.25 - (1.0 / 16.0))
float rcpMed(float a) {
  float b = uintBitsToFloat(0x7ef19fffu - floatBitsToUint(a));
  return b * (-b * a + 2.0);
}
vec3 load(ivec2 p) { return texelFetch(Source, clamp(p, ivec2(0), pc.srcMax), 0).rgb; }
float maxOf3(float x, float y, float z) { return max(x, max(y, z)); }
float minOf3(float x, float y, float z) { return min(x, min(y, z)); }

void main() {
  ivec2 sp = ivec2(gl_GlobalInvocationID.xy);
  if (any(greaterThanEqual(sp, pc.outSize)))
    return;
  //    b
  //  d e f
  //    h
  vec3 b = load(sp + ivec2( 0, -1));
  vec3 d = load(sp + ivec2(-1,  0));
  vec3 e = load(sp);
  vec3 f = load(sp + ivec2( 1,  0));
  vec3 h = load(sp + ivec2( 0,  1));
  vec3 mn4 = min(min(b, d), min(f, h));
  vec3 mx4 = max(max(b, d), max(f, h));
  vec2 peakC = vec2(1.0, -4.0);
  vec3 hitMin = min(mn4, e) * (1.0 / (4.0 * mx4));
  vec3 hitMax = (peakC.x - max(mx4, e)) * (1.0 / (4.0 * mn4 + peakC.y));
  vec3 lobeRGB = max(-hitMin, hitMax);
  float lobe = max(-FSR_RCAS_LIMIT, min(maxOf3(lobeRGB.r, lobeRGB.g, lobeRGB.b), 0.0)) * pc.sharpness;
  float rcpL = rcpMed(4.0 * lobe + 1.0);
  vec3 pix = (lobe * b + lobe * d + lobe * h + lobe * f + e) * rcpL;
  imageStore(Dest, sp, vec4(pix, 1.0));
}
)";

struct PushConstants {
  float scale[2];
  float offset[2];
  int32_t outSize[2];
  int32_t srcMax[2];
  float sharpness;
};

void barrier(VkCommandBuffer cmd, VkImage image, VkAccessFlags srcAccess, VkAccessFlags dstAccess,
             VkImageLayout oldLayout, VkImageLayout newLayout, VkPipelineStageFlags srcStage,
             VkPipelineStageFlags dstStage) {
  vks::tools::insertImageMemoryBarrier(cmd, image, srcAccess, dstAccess, oldLayout, newLayout, srcStage,
                                       dstStage, VkImageSubresourceRange{VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1});
}

} // namespace

FsrUpscaler::FsrUpscaler(VIDVulkan* vulkan) : vulkan(vulkan) {}

FsrUpscaler::~FsrUpscaler() { release(); }

VkShaderModule FsrUpscaler::compile(const char* source, const char* name) {
  shaderc::Compiler compiler;
  shaderc::CompileOptions options;
  options.SetOptimizationLevel(shaderc_optimization_level_performance);
  shaderc::SpvCompilationResult result =
      compiler.CompileGlslToSpv(source, shaderc_compute_shader, name, options);
  if (result.GetCompilationStatus() != shaderc_compilation_status_success) {
    printf("FsrUpscaler: %s does not compile: %s\n", name, result.GetErrorMessage().c_str());
    return VK_NULL_HANDLE;
  }
  std::vector<uint32_t> spirv(result.cbegin(), result.cend());
  VkShaderModuleCreateInfo info{};
  info.sType = VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO;
  info.codeSize = spirv.size() * sizeof(uint32_t);
  info.pCode = spirv.data();
  VkShaderModule module = VK_NULL_HANDLE;
  if (vkCreateShaderModule(vulkan->getDevice(), &info, nullptr, &module) != VK_SUCCESS)
    return VK_NULL_HANDLE;
  return module;
}

bool FsrUpscaler::setup() {
  if (ready)
    return true;
  if (failed)
    return false;
  failed = true; // until everything below exists
  VkDevice device = vulkan->getDevice();

  VkSamplerCreateInfo samplerInfo{};
  samplerInfo.sType = VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO;
  samplerInfo.magFilter = VK_FILTER_NEAREST;
  samplerInfo.minFilter = VK_FILTER_NEAREST;
  samplerInfo.mipmapMode = VK_SAMPLER_MIPMAP_MODE_NEAREST;
  samplerInfo.addressModeU = VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE;
  samplerInfo.addressModeV = VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE;
  samplerInfo.addressModeW = VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE;
  samplerInfo.maxLod = 0.0f;
  if (vkCreateSampler(device, &samplerInfo, nullptr, &sampler) != VK_SUCCESS)
    return false;

  VkDescriptorSetLayoutBinding bindings[2]{};
  bindings[0].binding = 0;
  bindings[0].descriptorType = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
  bindings[0].descriptorCount = 1;
  bindings[0].stageFlags = VK_SHADER_STAGE_COMPUTE_BIT;
  bindings[1].binding = 1;
  bindings[1].descriptorType = VK_DESCRIPTOR_TYPE_STORAGE_IMAGE;
  bindings[1].descriptorCount = 1;
  bindings[1].stageFlags = VK_SHADER_STAGE_COMPUTE_BIT;
  VkDescriptorSetLayoutCreateInfo layoutInfo{};
  layoutInfo.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO;
  layoutInfo.bindingCount = 2;
  layoutInfo.pBindings = bindings;
  if (vkCreateDescriptorSetLayout(device, &layoutInfo, nullptr, &setLayout) != VK_SUCCESS)
    return false;

  VkPushConstantRange range{VK_SHADER_STAGE_COMPUTE_BIT, 0, sizeof(PushConstants)};
  VkPipelineLayoutCreateInfo plInfo{};
  plInfo.sType = VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO;
  plInfo.setLayoutCount = 1;
  plInfo.pSetLayouts = &setLayout;
  plInfo.pushConstantRangeCount = 1;
  plInfo.pPushConstantRanges = &range;
  if (vkCreatePipelineLayout(device, &plInfo, nullptr, &pipelineLayout) != VK_SUCCESS)
    return false;

  for (int pass = 0; pass < 2; pass++) {
    VkShaderModule module = compile(pass == 0 ? kEasuSource : kRcasSource, pass == 0 ? "fsr_easu" : "fsr_rcas");
    if (module == VK_NULL_HANDLE)
      return false;
    VkComputePipelineCreateInfo info{};
    info.sType = VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO;
    info.stage.sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO;
    info.stage.stage = VK_SHADER_STAGE_COMPUTE_BIT;
    info.stage.module = module;
    info.stage.pName = "main";
    info.layout = pipelineLayout;
    VkPipeline& pipeline = pass == 0 ? easuPipeline : rcasPipeline;
    const VkResult result = vkCreateComputePipelines(device, VK_NULL_HANDLE, 1, &info, nullptr, &pipeline);
    vkDestroyShaderModule(device, module, nullptr);
    if (result != VK_SUCCESS)
      return false;
  }

  VkDescriptorPoolSize sizes[2] = {{VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, 2},
                                   {VK_DESCRIPTOR_TYPE_STORAGE_IMAGE, 2}};
  VkDescriptorPoolCreateInfo poolInfo{};
  poolInfo.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO;
  poolInfo.maxSets = 2;
  poolInfo.poolSizeCount = 2;
  poolInfo.pPoolSizes = sizes;
  if (vkCreateDescriptorPool(device, &poolInfo, nullptr, &descriptorPool) != VK_SUCCESS)
    return false;
  VkDescriptorSetLayout layouts[2] = {setLayout, setLayout};
  VkDescriptorSet sets[2] = {};
  VkDescriptorSetAllocateInfo allocInfo{};
  allocInfo.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO;
  allocInfo.descriptorPool = descriptorPool;
  allocInfo.descriptorSetCount = 2;
  allocInfo.pSetLayouts = layouts;
  if (vkAllocateDescriptorSets(device, &allocInfo, sets) != VK_SUCCESS)
    return false;
  easuSet = sets[0];
  rcasSet = sets[1];

  failed = false;
  ready = true;
  printf("FsrUpscaler: ready\n");
  return true;
}

bool FsrUpscaler::createTarget(Target& target, uint32_t w, uint32_t h) {
  VkDevice device = vulkan->getDevice();
  VkImageCreateInfo image{};
  image.sType = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO;
  image.imageType = VK_IMAGE_TYPE_2D;
  image.format = VK_FORMAT_R8G8B8A8_UNORM;
  image.extent = {w, h, 1};
  image.mipLevels = 1;
  image.arrayLayers = 1;
  image.samples = VK_SAMPLE_COUNT_1_BIT;
  image.tiling = VK_IMAGE_TILING_OPTIMAL;
  image.usage = VK_IMAGE_USAGE_STORAGE_BIT | VK_IMAGE_USAGE_SAMPLED_BIT | VK_IMAGE_USAGE_TRANSFER_SRC_BIT;
  image.initialLayout = VK_IMAGE_LAYOUT_UNDEFINED;
  if (vkCreateImage(device, &image, nullptr, &target.image) != VK_SUCCESS)
    return false;
  VkMemoryRequirements reqs;
  vkGetImageMemoryRequirements(device, target.image, &reqs);
  VkMemoryAllocateInfo alloc{};
  alloc.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;
  alloc.allocationSize = reqs.size;
  alloc.memoryTypeIndex = vulkan->findMemoryType(reqs.memoryTypeBits, VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT);
  if (vkAllocateMemory(device, &alloc, nullptr, &target.memory) != VK_SUCCESS ||
      vkBindImageMemory(device, target.image, target.memory, 0) != VK_SUCCESS)
    return false;
  VkImageViewCreateInfo view{};
  view.sType = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO;
  view.viewType = VK_IMAGE_VIEW_TYPE_2D;
  view.format = VK_FORMAT_R8G8B8A8_UNORM;
  view.subresourceRange = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1};
  view.image = target.image;
  return vkCreateImageView(device, &view, nullptr, &target.view) == VK_SUCCESS;
}

void FsrUpscaler::destroyTargets() {
  VkDevice device = vulkan->getDevice();
  for (Target* target : {&easuOut, &rcasOut}) {
    if (target->view)
      vkDestroyImageView(device, target->view, nullptr);
    if (target->image)
      vkDestroyImage(device, target->image, nullptr);
    if (target->memory)
      vkFreeMemory(device, target->memory, nullptr);
    *target = Target{};
  }
  width = height = 0;
  boundSource = VK_NULL_HANDLE;
}

bool FsrUpscaler::resize(uint32_t w, uint32_t h) {
  if (w == width && h == height && easuOut.view && rcasOut.view)
    return true;
  // the targets may still be read by a frame in flight
  vkDeviceWaitIdle(vulkan->getDevice());
  destroyTargets();
  if (!createTarget(easuOut, w, h) || !createTarget(rcasOut, w, h)) {
    destroyTargets();
    return false;
  }
  width = w;
  height = h;

  // RCAS reads the upscaled picture and writes the sharpened one
  VkDescriptorImageInfo read{sampler, easuOut.view, VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL};
  VkDescriptorImageInfo write{VK_NULL_HANDLE, rcasOut.view, VK_IMAGE_LAYOUT_GENERAL};
  VkWriteDescriptorSet writes[2]{};
  for (int i = 0; i < 2; i++) {
    writes[i].sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
    writes[i].dstSet = rcasSet;
    writes[i].dstBinding = i;
    writes[i].descriptorCount = 1;
  }
  writes[0].descriptorType = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
  writes[0].pImageInfo = &read;
  writes[1].descriptorType = VK_DESCRIPTOR_TYPE_STORAGE_IMAGE;
  writes[1].pImageInfo = &write;
  vkUpdateDescriptorSets(vulkan->getDevice(), 2, writes, 0, nullptr);
  return true;
}

bool FsrUpscaler::record(VkCommandBuffer cmd, VkImage srcImage, VkImageView srcView, VkImageLayout srcLayout,
                         uint32_t srcWidth, uint32_t srcHeight, VkImage dstImage, int32_t dstX, int32_t dstY,
                         uint32_t dstWidth, uint32_t dstHeight, VkImageLayout finalDstLayout) {
  if (srcWidth == 0 || srcHeight == 0 || dstWidth == 0 || dstHeight == 0)
    return false;
  if (!setup() || !resize(dstWidth, dstHeight))
    return false;
  VkDevice device = vulkan->getDevice();

  // EASU reads the game's render target (the descriptor changes when it is rebuilt)
  if (boundSource != srcView) {
    VkDescriptorImageInfo read{sampler, srcView, VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL};
    VkDescriptorImageInfo write{VK_NULL_HANDLE, easuOut.view, VK_IMAGE_LAYOUT_GENERAL};
    VkWriteDescriptorSet writes[2]{};
    for (int i = 0; i < 2; i++) {
      writes[i].sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
      writes[i].dstSet = easuSet;
      writes[i].dstBinding = i;
      writes[i].descriptorCount = 1;
    }
    writes[0].descriptorType = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
    writes[0].pImageInfo = &read;
    writes[1].descriptorType = VK_DESCRIPTOR_TYPE_STORAGE_IMAGE;
    writes[1].pImageInfo = &write;
    vkUpdateDescriptorSets(device, 2, writes, 0, nullptr);
    boundSource = srcView;
  }

  const VkPipelineStageFlags anyGraphics = VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT |
                                           VK_PIPELINE_STAGE_TRANSFER_BIT;
  barrier(cmd, srcImage, VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT, VK_ACCESS_SHADER_READ_BIT, srcLayout,
          VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL, anyGraphics, VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT);
  barrier(cmd, easuOut.image, 0, VK_ACCESS_SHADER_WRITE_BIT, VK_IMAGE_LAYOUT_UNDEFINED, VK_IMAGE_LAYOUT_GENERAL,
          VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT, VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT);
  barrier(cmd, rcasOut.image, 0, VK_ACCESS_SHADER_WRITE_BIT, VK_IMAGE_LAYOUT_UNDEFINED, VK_IMAGE_LAYOUT_GENERAL,
          VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT, VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT);

  PushConstants pc{};
  pc.scale[0] = static_cast<float>(srcWidth) / dstWidth;
  pc.scale[1] = static_cast<float>(srcHeight) / dstHeight;
  pc.offset[0] = 0.5f * pc.scale[0] - 0.5f;
  pc.offset[1] = 0.5f * pc.scale[1] - 0.5f;
  pc.outSize[0] = static_cast<int32_t>(dstWidth);
  pc.outSize[1] = static_cast<int32_t>(dstHeight);
  pc.srcMax[0] = static_cast<int32_t>(srcWidth) - 1;
  pc.srcMax[1] = static_cast<int32_t>(srcHeight) - 1;
  pc.sharpness = std::exp2(-sharpnessStops);
  const uint32_t groupsX = (dstWidth + 7) / 8, groupsY = (dstHeight + 7) / 8;

  vkCmdBindPipeline(cmd, VK_PIPELINE_BIND_POINT_COMPUTE, easuPipeline);
  vkCmdBindDescriptorSets(cmd, VK_PIPELINE_BIND_POINT_COMPUTE, pipelineLayout, 0, 1, &easuSet, 0, nullptr);
  vkCmdPushConstants(cmd, pipelineLayout, VK_SHADER_STAGE_COMPUTE_BIT, 0, sizeof(pc), &pc);
  vkCmdDispatch(cmd, groupsX, groupsY, 1);

  barrier(cmd, easuOut.image, VK_ACCESS_SHADER_WRITE_BIT, VK_ACCESS_SHADER_READ_BIT, VK_IMAGE_LAYOUT_GENERAL,
          VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL, VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT,
          VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT);

  pc.srcMax[0] = static_cast<int32_t>(dstWidth) - 1;
  pc.srcMax[1] = static_cast<int32_t>(dstHeight) - 1;
  vkCmdBindPipeline(cmd, VK_PIPELINE_BIND_POINT_COMPUTE, rcasPipeline);
  vkCmdBindDescriptorSets(cmd, VK_PIPELINE_BIND_POINT_COMPUTE, pipelineLayout, 0, 1, &rcasSet, 0, nullptr);
  vkCmdPushConstants(cmd, pipelineLayout, VK_SHADER_STAGE_COMPUTE_BIT, 0, sizeof(pc), &pc);
  vkCmdDispatch(cmd, groupsX, groupsY, 1);

  // the sharpened picture into its place on screen, 1:1
  barrier(cmd, rcasOut.image, VK_ACCESS_SHADER_WRITE_BIT, VK_ACCESS_TRANSFER_READ_BIT, VK_IMAGE_LAYOUT_GENERAL,
          VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT);
  barrier(cmd, dstImage, 0, VK_ACCESS_TRANSFER_WRITE_BIT, VK_IMAGE_LAYOUT_UNDEFINED,
          VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT);
  VkImageBlit region{};
  region.srcSubresource = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1};
  region.srcOffsets[1] = {static_cast<int32_t>(dstWidth), static_cast<int32_t>(dstHeight), 1};
  region.dstSubresource = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1};
  region.dstOffsets[0] = {dstX, dstY, 0};
  region.dstOffsets[1] = {dstX + static_cast<int32_t>(dstWidth), dstY + static_cast<int32_t>(dstHeight), 1};
  // a blit, not a copy: the swapchain's format may differ from RGBA8
  vkCmdBlitImage(cmd, rcasOut.image, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, dstImage,
                 VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &region, VK_FILTER_NEAREST);

  barrier(cmd, dstImage, VK_ACCESS_TRANSFER_WRITE_BIT, VK_ACCESS_MEMORY_READ_BIT,
          VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, finalDstLayout, VK_PIPELINE_STAGE_TRANSFER_BIT,
          VK_PIPELINE_STAGE_TRANSFER_BIT);
  barrier(cmd, srcImage, VK_ACCESS_SHADER_READ_BIT, VK_ACCESS_MEMORY_READ_BIT,
          VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL, srcLayout, VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT,
          VK_PIPELINE_STAGE_TRANSFER_BIT);
  return true;
}

void FsrUpscaler::release() {
  if (!vulkan)
    return;
  VkDevice device = vulkan->getDevice();
  if (device == VK_NULL_HANDLE)
    return;
  vkDeviceWaitIdle(device);
  destroyTargets();
  if (descriptorPool)
    vkDestroyDescriptorPool(device, descriptorPool, nullptr);
  if (easuPipeline)
    vkDestroyPipeline(device, easuPipeline, nullptr);
  if (rcasPipeline)
    vkDestroyPipeline(device, rcasPipeline, nullptr);
  if (pipelineLayout)
    vkDestroyPipelineLayout(device, pipelineLayout, nullptr);
  if (setLayout)
    vkDestroyDescriptorSetLayout(device, setLayout, nullptr);
  if (sampler)
    vkDestroySampler(device, sampler, nullptr);
  descriptorPool = VK_NULL_HANDLE;
  easuPipeline = rcasPipeline = VK_NULL_HANDLE;
  pipelineLayout = VK_NULL_HANDLE;
  setLayout = VK_NULL_HANDLE;
  sampler = VK_NULL_HANDLE;
  easuSet = rcasSet = VK_NULL_HANDLE;
  ready = false;
  failed = false;
}
