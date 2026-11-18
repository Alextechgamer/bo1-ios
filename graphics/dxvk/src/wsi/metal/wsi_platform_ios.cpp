// iOS single-view WSI provider for DXVK v2.6.1.
// This file is an integration overlay, not a vendored DXVK source tree.
// SPDX-License-Identifier: Zlib

#if defined(DXVK_WSI_METAL)

#include "../wsi_platform.h"
#include "ios_platform_bridge.h"

#include <algorithm>
#include <cstdint>
#include <iterator>
#include <limits>
#include <new>

namespace dxvk::wsi {
namespace {

// Opaque monitor identity. UIKit and CAMetalLayer objects never cross this API.
unsigned char s_monitorToken;

HMONITOR monitorHandle() {
  return reinterpret_cast<HMONITOR>(&s_monitorToken);
}

bool validMonitor(HMONITOR monitor) {
  return monitor == monitorHandle() && IOS_IsMetalLayerRegistered();
}

bool validWindow(HWND window) {
  return window && IOS_IsMetalLayerRegistered()
      && reinterpret_cast<void*>(window) == IOS_GetMetalWindowHandle();
}

bool readDisplayMode(WsiMode* mode) {
  if (!mode)
    return false;

  *mode = {};
  if (!IOS_IsMetalLayerRegistered())
    return false;

  // The bridge reads a snapshot published by UIKit during layout. It must not
  // dispatch synchronously to the main queue from this rendering worker.
  IOS_GetDrawableSize(&mode->width, &mode->height);
  const auto refreshRate = IOS_GetMaximumFramesPerSecond();
  if (!mode->width || !mode->height || !refreshRate)
    return false;

  mode->refreshRate = {refreshRate, 1};
  mode->bitsPerPixel = 32;
  mode->interlaced = false;
  return true;
}

class MetalWsiDriver final : public WsiDriver {
public:
  std::vector<const char*> getInstanceExtensions() override {
    // These extensions must be enabled at vkCreateInstance, not only exposed
    // to the compiler via VK_USE_PLATFORM_METAL_EXT.
    return {VK_KHR_SURFACE_EXTENSION_NAME, VK_EXT_METAL_SURFACE_EXTENSION_NAME};
  }

  HMONITOR getDefaultMonitor() override {
    return IOS_IsMetalLayerRegistered() ? monitorHandle() : nullptr;
  }

  HMONITOR enumMonitors(uint32_t index) override {
    return index == 0 ? getDefaultMonitor() : nullptr;
  }

  HMONITOR enumMonitors(const LUID*[], uint32_t, uint32_t index) override {
    // iOS exposes one registered screen here. The bridge does not fabricate
    // Windows adapter LUIDs, matching the native SDL provider's policy.
    return enumMonitors(index);
  }

  bool getDisplayName(HMONITOR monitor, WCHAR (&name)[32]) override {
    std::fill(std::begin(name), std::end(name), WCHAR(0));
    if (!validMonitor(monitor))
      return false;

    constexpr char displayName[] = "\\\\.\\DISPLAY1";
    for (size_t i = 0; i < sizeof(displayName) - 1; ++i)
      name[i] = static_cast<WCHAR>(displayName[i]);
    return true;
  }

  bool getDesktopCoordinates(HMONITOR monitor, RECT* rect) override {
    if (!rect)
      return false;
    *rect = {};

    WsiMode mode = {};
    if (!validMonitor(monitor) || !readDisplayMode(&mode))
      return false;

    const auto limit = static_cast<uint32_t>(std::numeric_limits<LONG>::max());
    rect->right = static_cast<LONG>(std::min(mode.width, limit));
    rect->bottom = static_cast<LONG>(std::min(mode.height, limit));
    return true;
  }

  bool getDisplayMode(HMONITOR monitor, uint32_t index, WsiMode* mode) override {
    if (mode)
      *mode = {};
    // Display-mode switching is owned by UIKit. Advertise only its current
    // pixel dimensions; D3D9 can still use a smaller scaled backbuffer.
    return index == 0 && validMonitor(monitor) && readDisplayMode(mode);
  }

  bool getCurrentDisplayMode(HMONITOR monitor, WsiMode* mode) override {
    return getDisplayMode(monitor, 0, mode);
  }

  bool getDesktopDisplayMode(HMONITOR monitor, WsiMode* mode) override {
    return getDisplayMode(monitor, 0, mode);
  }

  WsiEdidData getMonitorEdid(HMONITOR) override {
    return {}; // UIKit has no EDID contract; do not invent HDR metadata.
  }

  void getWindowSize(HWND window, uint32_t* width, uint32_t* height) override {
    uint32_t drawableWidth = 0;
    uint32_t drawableHeight = 0;
    if (validWindow(window))
      IOS_GetDrawableSize(&drawableWidth, &drawableHeight);
    if (width)
      *width = drawableWidth;
    if (height)
      *height = drawableHeight;
  }

  void resizeWindow(HWND, DxvkWindowState*, uint32_t, uint32_t) override {
    // Never resize a UIView from a worker. UIKit layout publishes drawableSize;
    // DXVK's presenter scales a backbuffer that differs from that size.
  }

  bool setWindowMode(HMONITOR monitor, HWND window, DxvkWindowState*,
                     const WsiMode& requested) override {
    WsiMode current = {};
    if (!validWindow(window) || !validMonitor(monitor) || !readDisplayMode(&current))
      return false;

    if (requested.width != current.width || requested.height != current.height
        || requested.bitsPerPixel != current.bitsPerPixel || requested.interlaced)
      return false;

    // Zero numerator means unspecified refresh. Otherwise, only accept the
    // actual screen mode; this backend cannot change iOS display modes.
    return requested.refreshRate.numerator == 0
        || (requested.refreshRate.denominator != 0
            && uint64_t(requested.refreshRate.numerator) * current.refreshRate.denominator
               == uint64_t(current.refreshRate.numerator) * requested.refreshRate.denominator);
  }

  bool enterFullscreenMode(HMONITOR monitor, HWND window, DxvkWindowState*, bool) override {
    return validMonitor(monitor) && validWindow(window);
  }

  bool leaveFullscreenMode(HWND window, DxvkWindowState*, bool) override {
    return validWindow(window); // UIKit keeps the same full-screen host view.
  }

  bool restoreDisplayMode() override {
    return true; // No display mode was changed.
  }

  HMONITOR getWindowMonitor(HWND window) override {
    return validWindow(window) ? getDefaultMonitor() : nullptr;
  }

  bool isWindow(HWND window) override {
    return validWindow(window);
  }

  bool isMinimized(HWND window) override {
    uint32_t width = 0, height = 0;
    getWindowSize(window, &width, &height);
    return !width || !height || IOS_IsScenePaused();
  }

  bool isOccluded(HWND window) override {
    return isMinimized(window);
  }

  void updateFullscreenWindow(HMONITOR, HWND, bool) override {
    // UIKit controls placement. There is no desktop z-order to change.
  }

  VkResult createSurface(HWND window, PFN_vkGetInstanceProcAddr getInstanceProcAddr,
                         VkInstance instance, VkSurfaceKHR* surface) override {
    if (!surface)
      return VK_ERROR_INITIALIZATION_FAILED;
    *surface = VK_NULL_HANDLE;

    if (!validWindow(window))
      return VK_ERROR_SURFACE_LOST_KHR;
    if (!instance || getInstanceProcAddr != &::vkGetInstanceProcAddr)
      return VK_ERROR_INITIALIZATION_FAILED;

    // This bundle uses statically linked MoltenVK, including this exact loader
    // proc. Reject foreign loader domains rather than passing their instances
    // into the bridge's linked MoltenVK entry points.
    return IOS_CreateVulkanMetalSurface(instance, surface);
  }
};

bool createMetalWsiDriver(WsiDriver** driver) {
  if (!driver)
    return false;
  *driver = new (std::nothrow) MetalWsiDriver();
  return *driver != nullptr;
}

} // namespace

WsiBootstrap MetalWSI = {"Metal", createMetalWsiDriver};

} // namespace dxvk::wsi

#endif // DXVK_WSI_METAL
