/// @file TicoVulkan.cpp
/// @brief Vulkan host glue between the tico frontend and yabause's VIDVulkan core.
///
/// Copyright 2025 tico

#include "TicoVulkan.h"
#include "TicoLogger.h"

#include "imgui_impl_vulkan.h"

#include "vulkan/VIDVulkan.h"
#include "vulkan/Renderer.h"
#include "vulkan/Window.h"

#include <cstring>
#include <mutex>
#include <vector>

namespace TicoVulkan
{

namespace
{

struct OverlayTexture {
    VkImage image = VK_NULL_HANDLE;
    VkDeviceMemory memory = VK_NULL_HANDLE;
    VkImageView view = VK_NULL_HANDLE;
    VkSampler sampler = VK_NULL_HANDLE;
    VkDescriptorSet descriptor = VK_NULL_HANDLE;
};

bool s_ready = false;
VkDescriptorPool s_descriptorPool = VK_NULL_HANDLE;
VkCommandPool s_commandPool = VK_NULL_HANDLE;
std::vector<OverlayTexture> s_textures;
std::mutex s_uploadMutex;

VkDevice Device() { return VIDVulkan::getInstance()->getDevice(); }

void DestroyTextureResource(OverlayTexture& tex, bool unregister)
{
    VkDevice device = Device();
    if (unregister && tex.descriptor != VK_NULL_HANDLE)
        ImGui_ImplVulkan_RemoveTexture(tex.descriptor);
    if (tex.sampler != VK_NULL_HANDLE) vkDestroySampler(device, tex.sampler, nullptr);
    if (tex.view != VK_NULL_HANDLE) vkDestroyImageView(device, tex.view, nullptr);
    if (tex.image != VK_NULL_HANDLE) vkDestroyImage(device, tex.image, nullptr);
    if (tex.memory != VK_NULL_HANDLE) vkFreeMemory(device, tex.memory, nullptr);
    tex = OverlayTexture{};
}

} // namespace

bool InitOverlayRenderer()
{
    if (s_ready)
        return true;

    VIDVulkan* vid = VIDVulkan::getInstance();
    Renderer* renderer = vid->getRenderer();
    if (renderer == nullptr || vid->getDevice() == VK_NULL_HANDLE)
    {
        LOG_ERROR("VULKAN", "InitOverlayRenderer: VIDVulkan not ready");
        return false;
    }

    VkDevice device = vid->getDevice();

    // Descriptor pool for ImGui (fonts + overlay textures)
    {
        VkDescriptorPoolSize poolSize{};
        poolSize.type = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
        poolSize.descriptorCount = 128;

        VkDescriptorPoolCreateInfo dpci{};
        dpci.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO;
        dpci.flags = VK_DESCRIPTOR_POOL_CREATE_FREE_DESCRIPTOR_SET_BIT;
        dpci.maxSets = 128;
        dpci.poolSizeCount = 1;
        dpci.pPoolSizes = &poolSize;

        if (vkCreateDescriptorPool(device, &dpci, nullptr, &s_descriptorPool) != VK_SUCCESS)
        {
            LOG_ERROR("VULKAN", "InitOverlayRenderer: descriptor pool creation failed");
            return false;
        }
    }

    // Command pool for synchronous texture uploads
    {
        VkCommandPoolCreateInfo cpci{};
        cpci.sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO;
        cpci.flags = VK_COMMAND_POOL_CREATE_TRANSIENT_BIT;
        cpci.queueFamilyIndex = vid->getVulkanGraphicsQueueFamilyIndex();
        if (vkCreateCommandPool(device, &cpci, nullptr, &s_commandPool) != VK_SUCCESS)
        {
            LOG_ERROR("VULKAN", "InitOverlayRenderer: command pool creation failed");
            vkDestroyDescriptorPool(device, s_descriptorPool, nullptr);
            s_descriptorPool = VK_NULL_HANDLE;
            return false;
        }
    }

    ImGui_ImplVulkan_InitInfo info{};
    info.Instance = renderer->GetVulkanInstance();
    info.PhysicalDevice = vid->getPhysicalDevice();
    info.Device = device;
    info.QueueFamily = vid->getVulkanGraphicsQueueFamilyIndex();
    info.Queue = vid->getVulkanQueue();
    info.DescriptorPool = s_descriptorPool;
    info.RenderPass = vid->getRenderPass();
    info.MinImageCount = 2;
    info.ImageCount = vid->getFrameBufferCount();
    if (info.ImageCount < info.MinImageCount)
        info.ImageCount = info.MinImageCount;
    info.MSAASamples = VK_SAMPLE_COUNT_1_BIT;

    if (!ImGui_ImplVulkan_Init(&info))
    {
        LOG_ERROR("VULKAN", "ImGui_ImplVulkan_Init failed");
        vkDestroyCommandPool(device, s_commandPool, nullptr);
        vkDestroyDescriptorPool(device, s_descriptorPool, nullptr);
        s_commandPool = VK_NULL_HANDLE;
        s_descriptorPool = VK_NULL_HANDLE;
        return false;
    }

    if (!ImGui_ImplVulkan_CreateFontsTexture())
    {
        LOG_ERROR("VULKAN", "ImGui_ImplVulkan_CreateFontsTexture failed");
        ImGui_ImplVulkan_Shutdown();
        vkDestroyCommandPool(device, s_commandPool, nullptr);
        vkDestroyDescriptorPool(device, s_descriptorPool, nullptr);
        s_commandPool = VK_NULL_HANDLE;
        s_descriptorPool = VK_NULL_HANDLE;
        return false;
    }

    s_ready = true;
    LOG_INFO("VULKAN", "Overlay renderer initialized (%u swapchain images)", info.ImageCount);
    return true;
}

void ShutdownOverlayRenderer()
{
    if (!s_ready)
        return;

    VkDevice device = Device();
    vkDeviceWaitIdle(device);

    for (auto& tex : s_textures)
        DestroyTextureResource(tex, true);
    s_textures.clear();

    ImGui_ImplVulkan_Shutdown();

    if (s_commandPool != VK_NULL_HANDLE)
    {
        vkDestroyCommandPool(device, s_commandPool, nullptr);
        s_commandPool = VK_NULL_HANDLE;
    }
    if (s_descriptorPool != VK_NULL_HANDLE)
    {
        vkDestroyDescriptorPool(device, s_descriptorPool, nullptr);
        s_descriptorPool = VK_NULL_HANDLE;
    }
    s_ready = false;
    LOG_INFO("VULKAN", "Overlay renderer shut down");
}

bool IsReady() { return s_ready; }

ImTextureID CreateTextureRGBA(const unsigned char* rgba, uint32_t width, uint32_t height)
{
    if (!s_ready || rgba == nullptr || width == 0 || height == 0)
        return 0;

    std::lock_guard<std::mutex> guard(s_uploadMutex);

    VIDVulkan* vid = VIDVulkan::getInstance();
    VkDevice device = vid->getDevice();
    VkDeviceSize size = (VkDeviceSize)width * height * 4;

    OverlayTexture tex;
    VkBuffer staging = VK_NULL_HANDLE;
    VkDeviceMemory stagingMemory = VK_NULL_HANDLE;
    VkCommandBuffer cmd = VK_NULL_HANDLE;

    // Cleanup helper for the error path
    auto fail = [&]() -> ImTextureID {
        if (cmd != VK_NULL_HANDLE) vkFreeCommandBuffers(device, s_commandPool, 1, &cmd);
        if (staging != VK_NULL_HANDLE) vkDestroyBuffer(device, staging, nullptr);
        if (stagingMemory != VK_NULL_HANDLE) vkFreeMemory(device, stagingMemory, nullptr);
        DestroyTextureResource(tex, false);
        return 0;
    };

    // Staging buffer
    {
        VkBufferCreateInfo bci{};
        bci.sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO;
        bci.size = size;
        bci.usage = VK_BUFFER_USAGE_TRANSFER_SRC_BIT;
        bci.sharingMode = VK_SHARING_MODE_EXCLUSIVE;
        if (vkCreateBuffer(device, &bci, nullptr, &staging) != VK_SUCCESS)
            return fail();

        VkMemoryRequirements req{};
        vkGetBufferMemoryRequirements(device, staging, &req);
        VkMemoryAllocateInfo mai{};
        mai.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;
        mai.allocationSize = req.size;
        mai.memoryTypeIndex = vid->findMemoryType(req.memoryTypeBits,
            VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT);
        if (vkAllocateMemory(device, &mai, nullptr, &stagingMemory) != VK_SUCCESS)
            return fail();
        vkBindBufferMemory(device, staging, stagingMemory, 0);

        void* mapped = nullptr;
        if (vkMapMemory(device, stagingMemory, 0, size, 0, &mapped) != VK_SUCCESS)
            return fail();
        memcpy(mapped, rgba, (size_t)size);
        vkUnmapMemory(device, stagingMemory);
    }

    // Image
    {
        VkImageCreateInfo ici{};
        ici.sType = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO;
        ici.imageType = VK_IMAGE_TYPE_2D;
        ici.format = VK_FORMAT_R8G8B8A8_UNORM;
        ici.extent = {width, height, 1};
        ici.mipLevels = 1;
        ici.arrayLayers = 1;
        ici.samples = VK_SAMPLE_COUNT_1_BIT;
        ici.tiling = VK_IMAGE_TILING_OPTIMAL;
        ici.usage = VK_IMAGE_USAGE_TRANSFER_DST_BIT | VK_IMAGE_USAGE_SAMPLED_BIT;
        ici.sharingMode = VK_SHARING_MODE_EXCLUSIVE;
        ici.initialLayout = VK_IMAGE_LAYOUT_UNDEFINED;
        if (vkCreateImage(device, &ici, nullptr, &tex.image) != VK_SUCCESS)
            return fail();

        VkMemoryRequirements req{};
        vkGetImageMemoryRequirements(device, tex.image, &req);
        VkMemoryAllocateInfo mai{};
        mai.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;
        mai.allocationSize = req.size;
        mai.memoryTypeIndex = vid->findMemoryType(req.memoryTypeBits, VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT);
        if (vkAllocateMemory(device, &mai, nullptr, &tex.memory) != VK_SUCCESS)
            return fail();
        vkBindImageMemory(device, tex.image, tex.memory, 0);
    }

    // Upload + layout transitions
    {
        VkCommandBufferAllocateInfo cbai{};
        cbai.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO;
        cbai.commandPool = s_commandPool;
        cbai.level = VK_COMMAND_BUFFER_LEVEL_PRIMARY;
        cbai.commandBufferCount = 1;
        if (vkAllocateCommandBuffers(device, &cbai, &cmd) != VK_SUCCESS)
            return fail();

        VkCommandBufferBeginInfo cbi{};
        cbi.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
        cbi.flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
        vkBeginCommandBuffer(cmd, &cbi);

        VkImageMemoryBarrier barrier{};
        barrier.sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER;
        barrier.oldLayout = VK_IMAGE_LAYOUT_UNDEFINED;
        barrier.newLayout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;
        barrier.srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
        barrier.dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
        barrier.image = tex.image;
        barrier.srcAccessMask = 0;
        barrier.dstAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT;
        barrier.subresourceRange.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
        barrier.subresourceRange.levelCount = 1;
        barrier.subresourceRange.layerCount = 1;
        vkCmdPipelineBarrier(cmd, VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT,
                             0, 0, nullptr, 0, nullptr, 1, &barrier);

        VkBufferImageCopy region{};
        region.imageSubresource.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
        region.imageSubresource.layerCount = 1;
        region.imageExtent = {width, height, 1};
        vkCmdCopyBufferToImage(cmd, staging, tex.image, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &region);

        barrier.oldLayout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;
        barrier.newLayout = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
        barrier.srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT;
        barrier.dstAccessMask = VK_ACCESS_SHADER_READ_BIT;
        vkCmdPipelineBarrier(cmd, VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT,
                             0, 0, nullptr, 0, nullptr, 1, &barrier);

        vkEndCommandBuffer(cmd);

        VkSubmitInfo submit{};
        submit.sType = VK_STRUCTURE_TYPE_SUBMIT_INFO;
        submit.commandBufferCount = 1;
        submit.pCommandBuffers = &cmd;
        if (vkQueueSubmit(vid->getVulkanQueue(), 1, &submit, VK_NULL_HANDLE) != VK_SUCCESS)
            return fail();
        vkQueueWaitIdle(vid->getVulkanQueue());

        vkFreeCommandBuffers(device, s_commandPool, 1, &cmd);
        cmd = VK_NULL_HANDLE;
        vkDestroyBuffer(device, staging, nullptr);
        staging = VK_NULL_HANDLE;
        vkFreeMemory(device, stagingMemory, nullptr);
        stagingMemory = VK_NULL_HANDLE;
    }

    // View + sampler + ImGui descriptor
    {
        VkImageViewCreateInfo ivci{};
        ivci.sType = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO;
        ivci.image = tex.image;
        ivci.viewType = VK_IMAGE_VIEW_TYPE_2D;
        ivci.format = VK_FORMAT_R8G8B8A8_UNORM;
        ivci.subresourceRange.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
        ivci.subresourceRange.levelCount = 1;
        ivci.subresourceRange.layerCount = 1;
        if (vkCreateImageView(device, &ivci, nullptr, &tex.view) != VK_SUCCESS)
            return fail();

        VkSamplerCreateInfo sci{};
        sci.sType = VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO;
        sci.magFilter = VK_FILTER_LINEAR;
        sci.minFilter = VK_FILTER_LINEAR;
        sci.mipmapMode = VK_SAMPLER_MIPMAP_MODE_LINEAR;
        sci.addressModeU = VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE;
        sci.addressModeV = VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE;
        sci.addressModeW = VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE;
        sci.maxLod = 1.0f;
        if (vkCreateSampler(device, &sci, nullptr, &tex.sampler) != VK_SUCCESS)
            return fail();

        tex.descriptor = ImGui_ImplVulkan_AddTexture(tex.sampler, tex.view,
                                                     VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL);
        if (tex.descriptor == VK_NULL_HANDLE)
            return fail();
    }

    s_textures.push_back(tex);
    return (ImTextureID)(intptr_t)tex.descriptor;
}

void DestroyTexture(ImTextureID texture)
{
    if (texture == 0 || !s_ready)
        return;

    std::lock_guard<std::mutex> guard(s_uploadMutex);

    VkDescriptorSet descriptor = (VkDescriptorSet)(intptr_t)texture;
    for (size_t i = 0; i < s_textures.size(); i++)
    {
        if (s_textures[i].descriptor == descriptor)
        {
            vkDeviceWaitIdle(Device());
            DestroyTextureResource(s_textures[i], true);
            s_textures.erase(s_textures.begin() + i);
            return;
        }
    }
}

void RenderDrawData(ImDrawData* drawData, VkCommandBuffer commandBuffer)
{
    if (!s_ready || drawData == nullptr)
        return;
    ImGui_ImplVulkan_RenderDrawData(drawData, commandBuffer);
}

void PresentOverlayFrame(ImDrawData* drawData)
{
    if (!s_ready || drawData == nullptr)
        return;

    VIDVulkan::getInstance()->renderExternal(
        [drawData](VkDevice, VkPhysicalDevice, VkRenderPass, VkCommandBuffer commandBuffer) {
            ImGui_ImplVulkan_RenderDrawData(drawData, commandBuffer);
        });
}

ImTextureID CaptureGameFrame(int* outW, int* outH)
{
    if (!s_ready)
        return 0;

    void* buf = nullptr;
    int w = 0, h = 0;
    VIDVulkan::getInstance()->getScreenshot(&buf, w, h);
    if (buf == nullptr || w <= 0 || h <= 0)
        return 0;

    ImTextureID tex = CreateTextureRGBA((const unsigned char*)buf, (uint32_t)w, (uint32_t)h);
    free(buf);

    if (outW) *outW = w;
    if (outH) *outH = h;
    return tex;
}

}  // namespace TicoVulkan
