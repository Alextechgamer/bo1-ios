#include "bo1_dxvk_capabilities.h"

#include <algorithm>
#include <cstring>
#include <new>
#include <vector>

// Requirement lists follow the exact pinned sources, not a speculative Vulkan
// profile: dxvk_adapter.cpp::createDevice and d3d9_device.cpp::GetDeviceFeatures
// at 2b1a284f8453baa2bd193709b67e5183074c74ba. Keep this diagnostic at that pin.
extern "C" VkResult BO1_DXVK_QueryD3D9Baseline(
    VkPhysicalDevice physicalDevice, BO1DXVKCapabilityReport* report,
    BO1DXVKCapabilityCallback callback, void* context) {
  if (report)
    *report = {};
  if (!physicalDevice || !report)
    return VK_ERROR_INITIALIZATION_FAILED;

  try {
    VkPhysicalDeviceProperties properties = {};
    vkGetPhysicalDeviceProperties(physicalDevice, &properties);
    report->apiVersion = properties.apiVersion;
    std::memcpy(report->deviceName, properties.deviceName, sizeof(report->deviceName));
    report->deviceName[sizeof(report->deviceName) - 1] = '\0';

    std::vector<VkExtensionProperties> extensions;
    VkResult result = VK_INCOMPLETE;
    // Re-query count after VK_INCOMPLETE instead of silently checking a partial
    // extension set. Failure is distinct from a known unsupported feature.
    for (unsigned attempt = 0; attempt < 8 && result == VK_INCOMPLETE; ++attempt) {
      uint32_t count = 0;
      result = vkEnumerateDeviceExtensionProperties(physicalDevice, nullptr, &count, nullptr);
      if (result != VK_SUCCESS)
        return result;
      extensions.resize(count);
      result = vkEnumerateDeviceExtensionProperties(physicalDevice, nullptr, &count,
                                                    extensions.data());
      extensions.resize(count);
    }
    if (result != VK_SUCCESS)
      return result;
    const auto hasExtension = [&](const char* name) {
      return std::any_of(extensions.begin(), extensions.end(), [&](const auto& extension) {
        return std::strcmp(extension.extensionName, name) == 0;
      });
    };
    const auto require = [&](const char* name, bool supported) {
      if (!supported)
        ++report->missingRequirements;
      if (callback)
        callback(name, supported ? VK_TRUE : VK_FALSE, context);
    };

    VkPhysicalDeviceFeatures2 features = { VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2 };
    VkPhysicalDeviceVulkan11Features vk11 = { VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_1_FEATURES };
    VkPhysicalDeviceVulkan12Features vk12 = { VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_2_FEATURES };
    VkPhysicalDeviceVulkan13Features vk13 = { VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_3_FEATURES };
    VkPhysicalDeviceRobustness2FeaturesEXT robustness2 = {
      VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_ROBUSTNESS_2_FEATURES_EXT };
    const auto prepend = [&](auto& item) {
      item.pNext = features.pNext;
      features.pNext = &item;
    };
    if (properties.apiVersion >= VK_API_VERSION_1_1)
      prepend(vk11);
    if (properties.apiVersion >= VK_API_VERSION_1_2)
      prepend(vk12);
    if (properties.apiVersion >= VK_API_VERSION_1_3)
      prepend(vk13);
    if (hasExtension(VK_EXT_ROBUSTNESS_2_EXTENSION_NAME))
      prepend(robustness2);
    vkGetPhysicalDeviceFeatures2(physicalDevice, &features);

    require("Vulkan API >= 1.3", properties.apiVersion >= VK_API_VERSION_1_3);
    require(VK_KHR_SWAPCHAIN_EXTENSION_NAME, hasExtension(VK_KHR_SWAPCHAIN_EXTENSION_NAME));
    require(VK_EXT_ROBUSTNESS_2_EXTENSION_NAME, hasExtension(VK_EXT_ROBUSTNESS_2_EXTENSION_NAME));

#define REQUIRE_CORE(name) require("VkPhysicalDeviceFeatures." #name, features.features.name)
    REQUIRE_CORE(robustBufferAccess);
    REQUIRE_CORE(fullDrawIndexUint32);
    REQUIRE_CORE(imageCubeArray);
    REQUIRE_CORE(independentBlend);
    REQUIRE_CORE(geometryShader);
    REQUIRE_CORE(sampleRateShading);
    REQUIRE_CORE(multiDrawIndirect);
    REQUIRE_CORE(depthClamp);
    REQUIRE_CORE(depthBiasClamp);
    REQUIRE_CORE(fillModeNonSolid);
    REQUIRE_CORE(multiViewport);
    REQUIRE_CORE(textureCompressionBC);
    REQUIRE_CORE(occlusionQueryPrecise);
    REQUIRE_CORE(shaderClipDistance);
    REQUIRE_CORE(shaderCullDistance);
#undef REQUIRE_CORE
#define REQUIRE_FEATURE(group, type, name) require(#type "." #name, group.name)
    REQUIRE_FEATURE(vk11, VkPhysicalDeviceVulkan11Features, shaderDrawParameters);
    REQUIRE_FEATURE(vk12, VkPhysicalDeviceVulkan12Features, samplerMirrorClampToEdge);
    REQUIRE_FEATURE(vk12, VkPhysicalDeviceVulkan12Features, hostQueryReset);
    REQUIRE_FEATURE(vk12, VkPhysicalDeviceVulkan12Features, timelineSemaphore);
    REQUIRE_FEATURE(vk12, VkPhysicalDeviceVulkan12Features, vulkanMemoryModel);
    REQUIRE_FEATURE(vk13, VkPhysicalDeviceVulkan13Features, shaderDemoteToHelperInvocation);
    REQUIRE_FEATURE(vk13, VkPhysicalDeviceVulkan13Features, synchronization2);
    REQUIRE_FEATURE(vk13, VkPhysicalDeviceVulkan13Features, dynamicRendering);
    // The pinned DXVK disables maintenance4 on two AMD drivers, not MoltenVK.
    VkPhysicalDeviceVulkan12Properties vk12Properties = {
      VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_2_PROPERTIES };
    VkPhysicalDeviceProperties2 properties2 = { VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PROPERTIES_2 };
    if (properties.apiVersion >= VK_API_VERSION_1_2)
      properties2.pNext = &vk12Properties;
    vkGetPhysicalDeviceProperties2(physicalDevice, &properties2);
    if (vk12Properties.driverID != VK_DRIVER_ID_AMD_OPEN_SOURCE &&
        vk12Properties.driverID != VK_DRIVER_ID_AMD_PROPRIETARY)
      REQUIRE_FEATURE(vk13, VkPhysicalDeviceVulkan13Features, maintenance4);
    REQUIRE_FEATURE(robustness2, VkPhysicalDeviceRobustness2FeaturesEXT, robustBufferAccess2);
    REQUIRE_FEATURE(robustness2, VkPhysicalDeviceRobustness2FeaturesEXT, nullDescriptor);
#undef REQUIRE_FEATURE

    uint32_t queueCount = 0;
    vkGetPhysicalDeviceQueueFamilyProperties(physicalDevice, &queueCount, nullptr);
    std::vector<VkQueueFamilyProperties> queues(queueCount);
    vkGetPhysicalDeviceQueueFamilyProperties(physicalDevice, &queueCount, queues.data());
    queues.resize(queueCount);
    const auto requiredQueue = VK_QUEUE_GRAPHICS_BIT | VK_QUEUE_COMPUTE_BIT;
    require("A nonempty queue family supporting GRAPHICS and COMPUTE",
      std::any_of(queues.begin(), queues.end(), [&](const auto& queue) {
        return queue.queueCount && (queue.queueFlags & requiredQueue) == requiredQueue;
      }));

    return report->missingRequirements ? VK_ERROR_FEATURE_NOT_PRESENT : VK_SUCCESS;
  } catch (const std::bad_alloc&) {
    return VK_ERROR_OUT_OF_HOST_MEMORY;
  }
}
