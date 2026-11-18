#import <Foundation/Foundation.h>
#import <QuartzCore/CAMetalLayer.h>
#include "include/ios_platform_bridge.h"
#include "include/bo1_display_state.h"
#include <vulkan/vulkan_metal.h>
#include <mutex>

#if !__has_feature(objc_arc)
#error "Build ios_platform_bridge.mm with -fobjc-arc."
#endif
// Also works when the DXVK build defines VK_NO_PROTOTYPES.
extern "C" VKAPI_ATTR PFN_vkVoidFunction VKAPI_CALL
vkGetInstanceProcAddr(VkInstance instance, const char* name);

namespace {
bo1ios::DisplayState display;
std::mutex layerMutex;
CAMetalLayer* __strong registeredLayer = nil;
char windowToken;
}

extern "C" void IOS_RegisterMetalLayer(void* layer) {
    NSCAssert([NSThread isMainThread], @"Register the layer on the UIKit thread.");
    CAMetalLayer* candidate = (__bridge CAMetalLayer*)layer;
    NSCAssert(!candidate || [candidate isKindOfClass:CAMetalLayer.class],
              @"The game view must be backed by CAMetalLayer.");
    std::lock_guard<std::mutex> lock(layerMutex);
    NSCAssert(!candidate || !registeredLayer || candidate == registeredLayer,
              @"Stop DXVK and destroy surfaces before replacing the layer.");
    registeredLayer = candidate;
    display.setRegistered(candidate != nil);
    if (!candidate) {
        display.publishSize(0, 0);
        display.publishRefreshRate(0);
        display.requestPause(true);
    }
}

extern "C" void IOS_UpdateDrawableMetrics(uint32_t w, uint32_t h, uint32_t fps) {
    NSCAssert([NSThread isMainThread], @"Publish drawable metrics from layout.");
    display.publishSize(w, h);
    display.publishRefreshRate(fps);
}
extern "C" void IOS_GetDrawableSize(uint32_t* w, uint32_t* h) { display.readSize(w, h); }
extern "C" uint32_t IOS_GetMaximumFramesPerSecond(void) { return display.refreshRate(); }
extern "C" bool IOS_IsMetalLayerRegistered(void) { return display.isRegistered(); }
extern "C" void* IOS_GetMetalWindowHandle(void) {
    return display.isRegistered() ? &windowToken : nullptr;
}
extern "C" void IOS_RequestScenePause(bool paused) { display.requestPause(paused); }
extern "C" bool IOS_IsScenePaused(void) { return display.isPaused(); }

extern "C" VkResult IOS_CreateVulkanMetalSurface(VkInstance instance, VkSurfaceKHR* surface) {
    if (!surface) return VK_ERROR_INITIALIZATION_FAILED;
    *surface = VK_NULL_HANDLE;
    if (!instance) return VK_ERROR_INITIALIZATION_FAILED;
    const auto createSurface = reinterpret_cast<PFN_vkCreateMetalSurfaceEXT>(
        vkGetInstanceProcAddr(instance, "vkCreateMetalSurfaceEXT"));
    if (!createSurface) return VK_ERROR_EXTENSION_NOT_PRESENT;
    // No UIKit calls or main-thread dispatch from the rendering worker.
    std::lock_guard<std::mutex> lock(layerMutex);
    if (!registeredLayer) return VK_ERROR_SURFACE_LOST_KHR;
    VkMetalSurfaceCreateInfoEXT info{};
    info.sType = VK_STRUCTURE_TYPE_METAL_SURFACE_CREATE_INFO_EXT;
    info.pLayer = registeredLayer;
    const VkResult result = createSurface(instance, &info, nullptr, surface);
    if (result != VK_SUCCESS) *surface = VK_NULL_HANDLE;
    return result;
}
