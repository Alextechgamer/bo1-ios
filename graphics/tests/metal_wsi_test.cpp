// Host-side contract tests: real DXVK headers, driver, dispatcher, and loader;
// deterministic stand-ins only for UIKit/MoltenVK process state.
#include "src/wsi/wsi_platform.h"
#include "src/util/util_env.h"
#include "ios_platform_bridge.h"

#include <cassert>
#include <cstdlib>
#include <cstring>
#include <iostream>
#include <string>

namespace {
bool registered = false;
bool paused = false;
uint32_t drawableWidth = 0;
uint32_t drawableHeight = 0;
uint32_t maximumFPS = 0;
unsigned char windowToken;
unsigned char foreignToken;
unsigned surfaceCalls = 0;
VkResult surfaceResult = VK_SUCCESS;
VkInstance lastInstance = VK_NULL_HANDLE;

VkInstance testInstance() {
  return reinterpret_cast<VkInstance>(uintptr_t(0x123400));
}

VkSurfaceKHR testSurface() {
  return reinterpret_cast<VkSurfaceKHR>(uintptr_t(0x567800));
}

VKAPI_ATTR PFN_vkVoidFunction VKAPI_CALL foreignLoader(VkInstance, const char*) {
  return nullptr;
}
} // namespace

extern "C" bool IOS_IsMetalLayerRegistered(void) { return registered; }
extern "C" bool IOS_IsScenePaused(void) { return paused; }
extern "C" void* IOS_GetMetalWindowHandle(void) {
  return registered ? &windowToken : nullptr;
}
extern "C" void IOS_GetDrawableSize(uint32_t* width, uint32_t* height) {
  if (width) *width = drawableWidth;
  if (height) *height = drawableHeight;
}
extern "C" uint32_t IOS_GetMaximumFramesPerSecond(void) { return maximumFPS; }
extern "C" VkResult IOS_CreateVulkanMetalSurface(VkInstance instance, VkSurfaceKHR* surface) {
  ++surfaceCalls;
  lastInstance = instance;
  *surface = surfaceResult == VK_SUCCESS ? testSurface() : VK_NULL_HANDLE;
  return surfaceResult;
}

extern "C" VKAPI_ATTR PFN_vkVoidFunction VKAPI_CALL
vkGetInstanceProcAddr(VkInstance, const char*) { return nullptr; }

namespace dxvk::env {
std::string getEnvVar(const char* name) {
  const auto value = std::getenv(name);
  return value ? value : "";
}
} // namespace dxvk::env

int main() {
  using namespace dxvk;
  unsetenv("DXVK_WSI_DRIVER");

  // Assert actual bootstrap registration, including the iOS default hint.
  wsi::init();
  wsi::init();
  wsi::quit(); // One reference remains; the driver must still be available.
  assert(!wsi::MetalWSI.createDriver(nullptr));

  const auto extensions = wsi::getInstanceExtensions();
  assert(extensions.size() == 2);
  assert(std::strcmp(extensions[0], VK_KHR_SURFACE_EXTENSION_NAME) == 0);
  assert(std::strcmp(extensions[1], VK_EXT_METAL_SURFACE_EXTENSION_NAME) == 0);

  const auto window = reinterpret_cast<HWND>(&windowToken);
  const auto foreignWindow = reinterpret_cast<HWND>(&foreignToken);
  assert(!wsi::getDefaultMonitor());
  assert(!wsi::isWindow(window));
  assert(wsi::isMinimized(window));
  uint32_t width = 99, height = 99;
  wsi::getWindowSize(window, &width, &height);
  assert(width == 0 && height == 0);

  registered = true;
  drawableWidth = 2622;
  drawableHeight = 1206;
  maximumFPS = 120;
  assert(wsi::isWindow(window));
  assert(!wsi::isWindow(nullptr));
  assert(!wsi::isWindow(foreignWindow));
  assert(!wsi::isOccluded(window));

  wsi::getWindowSize(window, &width, nullptr);
  wsi::getWindowSize(window, nullptr, &height);
  wsi::getWindowSize(window, nullptr, nullptr);
  assert(width == 2622 && height == 1206);
  wsi::getWindowSize(foreignWindow, &width, &height);
  assert(width == 0 && height == 0);

  const auto monitor = wsi::getDefaultMonitor();
  assert(monitor && monitor == wsi::enumMonitors(0));
  assert(!wsi::enumMonitors(1));
  assert(wsi::getWindowMonitor(window) == monitor);
  assert(!wsi::getWindowMonitor(foreignWindow));
  WCHAR displayName[32];
  assert(wsi::getDisplayName(monitor, displayName));
  assert(displayName[0] == '\\' && displayName[1] == '\\');
  assert(!wsi::getDisplayName(nullptr, displayName) && displayName[0] == 0);
  RECT rect = {};
  assert(wsi::getDesktopCoordinates(monitor, &rect));
  assert(rect.left == 0 && rect.top == 0 && rect.right == 2622 && rect.bottom == 1206);
  assert(!wsi::getDesktopCoordinates(monitor, nullptr));

  wsi::WsiMode mode = {};
  assert(wsi::getDisplayMode(monitor, 0, &mode));
  assert(mode.width == 2622 && mode.height == 1206);
  assert(mode.bitsPerPixel == 32 && !mode.interlaced);
  assert(mode.refreshRate.numerator == 120 && mode.refreshRate.denominator == 1);
  assert(wsi::setWindowMode(monitor, window, nullptr, mode));
  mode.width = 1280;
  assert(!wsi::setWindowMode(monitor, window, nullptr, mode));
  assert(wsi::getCurrentDisplayMode(monitor, &mode));
  mode.refreshRate = {240, 2};
  assert(wsi::setWindowMode(monitor, window, nullptr, mode));
  mode.refreshRate = {60, 1};
  assert(!wsi::setWindowMode(monitor, window, nullptr, mode));
  mode.refreshRate = {120, 0};
  assert(!wsi::setWindowMode(monitor, window, nullptr, mode));
  mode.refreshRate = {0, 0};
  assert(wsi::setWindowMode(monitor, window, nullptr, mode));
  mode.bitsPerPixel = 16;
  assert(!wsi::setWindowMode(monitor, window, nullptr, mode));
  assert(!wsi::getDisplayMode(monitor, 1, &mode));
  assert(mode.width == 0 && mode.height == 0);
  assert(!wsi::getDesktopDisplayMode(nullptr, &mode));
  assert(wsi::getMonitorEdid(monitor).empty());
  assert(wsi::enterFullscreenMode(monitor, window, nullptr, false));
  assert(!wsi::enterFullscreenMode(monitor, foreignWindow, nullptr, false));
  assert(wsi::leaveFullscreenMode(window, nullptr, false));
  assert(wsi::restoreDisplayMode());

  // UIKit updates become visible to renderer queries without a new driver.
  drawableWidth = 1206;
  drawableHeight = 2622;
  wsi::getWindowSize(window, &width, &height);
  assert(width == 1206 && height == 2622);
  paused = true;
  assert(wsi::isMinimized(window) && wsi::isOccluded(window));
  paused = false;
  drawableHeight = 0;
  assert(wsi::isMinimized(window));
  assert(!wsi::getCurrentDisplayMode(monitor, &mode));
  drawableHeight = 2622;

  VkSurfaceKHR surface = testSurface();
  assert(wsi::createSurface(window, &vkGetInstanceProcAddr, testInstance(), nullptr)
      == VK_ERROR_INITIALIZATION_FAILED);
  assert(wsi::createSurface(window, &vkGetInstanceProcAddr, VK_NULL_HANDLE, &surface)
      == VK_ERROR_INITIALIZATION_FAILED);
  assert(surface == VK_NULL_HANDLE && surfaceCalls == 0);
  assert(wsi::createSurface(window, foreignLoader, testInstance(), &surface)
      == VK_ERROR_INITIALIZATION_FAILED);
  assert(surfaceCalls == 0);
  assert(wsi::createSurface(foreignWindow, &vkGetInstanceProcAddr, testInstance(), &surface)
      == VK_ERROR_SURFACE_LOST_KHR);
  assert(surfaceCalls == 0);
  assert(wsi::createSurface(window, &vkGetInstanceProcAddr, testInstance(), &surface) == VK_SUCCESS);
  assert(surface == testSurface() && lastInstance == testInstance() && surfaceCalls == 1);
  surfaceResult = VK_ERROR_EXTENSION_NOT_PRESENT;
  assert(wsi::createSurface(window, &vkGetInstanceProcAddr, testInstance(), &surface)
      == VK_ERROR_EXTENSION_NOT_PRESENT);
  assert(surface == VK_NULL_HANDLE && surfaceCalls == 2);

  registered = false;
  assert(!wsi::isWindow(window));
  assert(!wsi::getCurrentDisplayMode(monitor, &mode));
  assert(wsi::createSurface(window, &vkGetInstanceProcAddr, testInstance(), &surface)
      == VK_ERROR_SURFACE_LOST_KHR);
  assert(surfaceCalls == 2);

  // Compile and exercise the actual loader patch: no libvulkan.so is needed.
  {
    vk::LibraryLoader loader;
    assert(loader.valid());
    assert(loader.getLoaderProc() == &vkGetInstanceProcAddr);
  }
  wsi::quit();
  std::cout << "Metal WSI contract tests passed against DXVK v2.6.1.\n";
}
