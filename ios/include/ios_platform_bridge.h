#pragma once
#include <stdbool.h>
#include <stdint.h>
#include <vulkan/vulkan_core.h>
#ifdef __cplusplus
extern "C" {
#endif
// Main thread only. Unregister NULL only after DXVK stops and destroys surfaces.
// Requires ARC; the implementation keeps a strong reference to the layer.
void IOS_RegisterMetalLayer(void* metalLayer);
// Layout publishes physical pixels. Render workers never query UIKit objects.
void IOS_UpdateDrawableMetrics(uint32_t width, uint32_t height, uint32_t refreshRate);
void IOS_GetDrawableSize(uint32_t* width, uint32_t* height);
uint32_t IOS_GetMaximumFramesPerSecond(void);
bool IOS_IsMetalLayerRegistered(void);
// D3D9 hDeviceWindow/hFocusWindow token; not a UIKit, SDL or Android pointer.
// NULL means no layer is registered.
void* IOS_GetMetalWindowHandle(void);
// State request ONLY, not GPU synchronization. The host adapter must stop
// production and serialize/drain DXVK workers before UIKit backgrounds.
void IOS_RequestScenePause(bool paused);
bool IOS_IsScenePaused(void);
// Uses static MoltenVK. The instance must use the same loader and enable
// VK_KHR_surface and VK_EXT_metal_surface. Failure clears *surface to NULL.
VkResult IOS_CreateVulkanMetalSurface(VkInstance instance, VkSurfaceKHR* surface);
#ifdef __cplusplus
}
#endif
