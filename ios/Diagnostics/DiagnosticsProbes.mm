#import "DiagnosticsProbes.h"
#include "bo1_dxvk_capabilities.h"
#include "ios_platform_bridge.h"
#include "native_audio.h"

#include <algorithm>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <exception>
#include <memory>
#include <unistd.h>
#include <vector>
#include <vulkan/vulkan_metal.h>

extern "C" int BO1ProbeAddressModel(FILE *output);

namespace {
bool isCancelled(const std::atomic_bool *cancelled) {
    return cancelled && cancelled->load();
}
NSString *string(const char *value) {
    return value ? ([NSString stringWithUTF8String:value] ?: @"<invalid UTF-8>") : @"<none>";
}
NSString *version(uint32_t value) {
    return [NSString stringWithFormat:@"%u.%u.%u", VK_API_VERSION_MAJOR(value),
        VK_API_VERSION_MINOR(value), VK_API_VERSION_PATCH(value)];
}
struct VulkanScope {
    VkInstance instance = VK_NULL_HANDLE;
    VkSurfaceKHR surface = VK_NULL_HANDLE;
    ~VulkanScope() {
        if (surface) vkDestroySurfaceKHR(instance, surface, nullptr);
        if (instance) vkDestroyInstance(instance, nullptr);
    }
};

void queryVulkan(NSMutableString *output, const std::atomic_bool *cancelled) {
    [output appendString:@"VULKAN / METAL\n"];
    uint32_t loaderVersion = VK_API_VERSION_1_0;
    VkResult result = vkEnumerateInstanceVersion(&loaderVersion);
    [output appendFormat:@"Instance API: %@ (VkResult %d)\n", version(loaderVersion), result];
    if (result != VK_SUCCESS || isCancelled(cancelled)) return;

    std::vector<VkExtensionProperties> extensions;
    result = VK_INCOMPLETE;
    for (unsigned attempt = 0; attempt < 8 && result == VK_INCOMPLETE; ++attempt) {
        uint32_t count = 0;
        result = vkEnumerateInstanceExtensionProperties(nullptr, &count, nullptr);
        if (result != VK_SUCCESS) break;
        extensions.resize(count);
        result = vkEnumerateInstanceExtensionProperties(nullptr, &count, extensions.data());
        extensions.resize(count);
    }
    if (result != VK_SUCCESS) {
        [output appendFormat:@"Instance-extension query failed: VkResult %d\n", result];
        return;
    }
    const auto has = [&](const char *name) {
        return std::any_of(extensions.begin(), extensions.end(), [&](const auto& extension) {
            return std::strcmp(extension.extensionName, name) == 0;
        });
    };
    const char *required[] = {VK_KHR_SURFACE_EXTENSION_NAME, VK_EXT_METAL_SURFACE_EXTENSION_NAME};
    std::vector<const char *> enabled;
    for (const char *name : required) {
        const bool supported = has(name);
        [output appendFormat:@"%@ %@\n", supported ? @"[available]" : @"[missing]", string(name)];
        if (supported) enabled.push_back(name);
    }
    if (enabled.size() != 2) {
        [output appendString:@"Metal-surface instance cannot be created with the required extensions.\n"];
        return;
    }
    VkInstanceCreateFlags flags = 0;
    if (has(VK_KHR_PORTABILITY_ENUMERATION_EXTENSION_NAME)) {
        enabled.push_back(VK_KHR_PORTABILITY_ENUMERATION_EXTENSION_NAME);
        flags |= VK_INSTANCE_CREATE_ENUMERATE_PORTABILITY_BIT_KHR;
    }
    if (isCancelled(cancelled)) return;
    VkApplicationInfo app = {VK_STRUCTURE_TYPE_APPLICATION_INFO};
    app.pApplicationName = "BO1 Port Diagnostics";
    app.pEngineName = "Platform checks only";
    app.apiVersion = std::min(loaderVersion, VK_API_VERSION_1_3);
    VkInstanceCreateInfo create = {VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO};
    create.flags = flags;
    create.pApplicationInfo = &app;
    create.enabledExtensionCount = static_cast<uint32_t>(enabled.size());
    create.ppEnabledExtensionNames = enabled.data();
    VulkanScope scope;
    result = vkCreateInstance(&create, nullptr, &scope.instance);
    [output appendFormat:@"vkCreateInstance (requested %@): %d\n", version(app.apiVersion), result];
    if (result != VK_SUCCESS || isCancelled(cancelled)) return;

    result = IOS_CreateVulkanMetalSurface(scope.instance, &scope.surface);
    [output appendFormat:@"Real CAMetalLayer surface: VkResult %d; created=%@\n", result,
        scope.surface ? @"yes" : @"no"];
    uint32_t width = 0, height = 0;
    IOS_GetDrawableSize(&width, &height);
    [output appendFormat:@"Published drawable: %u x %u pixels\n", width, height];

    std::vector<VkPhysicalDevice> devices;
    result = VK_INCOMPLETE;
    for (unsigned attempt = 0; attempt < 8 && result == VK_INCOMPLETE; ++attempt) {
        uint32_t count = 0;
        result = vkEnumeratePhysicalDevices(scope.instance, &count, nullptr);
        if (result != VK_SUCCESS) break;
        devices.resize(count);
        result = vkEnumeratePhysicalDevices(scope.instance, &count, devices.data());
        devices.resize(count);
    }
    [output appendFormat:@"Physical-device enumeration: %d; count=%lu\n", result,
        static_cast<unsigned long>(devices.size())];
    if (result != VK_SUCCESS) return;
    for (size_t index = 0; index < devices.size() && !isCancelled(cancelled); ++index) {
        VkPhysicalDeviceProperties properties{};
        vkGetPhysicalDeviceProperties(devices[index], &properties);
        [output appendFormat:@"\nDevice %lu: %@\nPhysical-device API: %@\n",
            static_cast<unsigned long>(index), string(properties.deviceName), version(properties.apiVersion)];
        if (app.apiVersion < VK_API_VERSION_1_1) {
            [output appendString:@"DXVK baseline unavailable: instance API is below Vulkan 1.1 (DXVK requires 1.3).\n"];
            continue;
        }
        BO1DXVKCapabilityReport report{};
        result = BO1_DXVK_QueryD3D9Baseline(devices[index], &report,
            [](const char *name, VkBool32 supported, void *context) {
                NSMutableString *text = (__bridge NSMutableString *)context;
                [text appendFormat:@"  %@ %@\n", supported ? @"[supported]" : @"[MISSING]", string(name)];
            }, (__bridge void *)output);
        [output appendFormat:@"DXVK 2.6.1 D3D9 baseline: VkResult %d; missing=%u\n",
            result, report.missingRequirements];
        if (scope.surface) {
            uint32_t count = 0;
            vkGetPhysicalDeviceQueueFamilyProperties(devices[index], &count, nullptr);
            for (uint32_t queue = 0; queue < count; ++queue) {
                VkBool32 canPresent = VK_FALSE;
                const VkResult surfaceResult = vkGetPhysicalDeviceSurfaceSupportKHR(
                    devices[index], queue, scope.surface, &canPresent);
                [output appendFormat:@"Queue %u surface support: VkResult %d, advertised=%@\n",
                    queue, surfaceResult, canPresent ? @"yes" : @"no"];
            }
        }
    }
    [output appendString:@"\nNo VkDevice, swapchain, draw, or GPU command was created.\n"
        @"Feature availability and surface creation do not establish rendering correctness.\n"];
    // VulkanScope always destroys the surface before its instance, including
    // cancellation/error returns. It never needs vkDeviceWaitIdle: no device.
}

void queryAddresses(NSMutableString *output) {
    [output appendString:@"\nADDRESS MODEL\n"
        @"Invoked on a diagnostic worker; this is not the engine's process layout.\n"];
    NSString *templatePath = [NSTemporaryDirectory() stringByAppendingPathComponent:@"bo1-address-XXXXXX"];
    const char *path = templatePath.fileSystemRepresentation;
    std::vector<char> writable(path, path + std::strlen(path) + 1);
    const int descriptor = mkstemp(writable.data());
    if (descriptor < 0) {
        [output appendString:@"Unable to create the private address-report stream.\n"];
        return;
    }
    // The temporary file is private and unlinked immediately; sharing is a
    // separate user action on the finished report string.
    unlink(writable.data());
    FILE *raw = fdopen(descriptor, "w+");
    if (!raw) {
        close(descriptor);
        [output appendString:@"Unable to open the address-report stream.\n"];
        return;
    }
    std::unique_ptr<FILE, decltype(&std::fclose)> file(raw, &std::fclose);
    const int status = BO1ProbeAddressModel(file.get());
    std::fflush(file.get());
    std::rewind(file.get());
    NSMutableData *data = [NSMutableData data];
    char buffer[4096];
    size_t count;
    while ((count = std::fread(buffer, 1, sizeof(buffer), file.get())) != 0 && data.length < 256 * 1024)
        [data appendBytes:buffer length:count];
    NSString *addressText = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    [output appendString:addressText ?: @"Address report was not valid UTF-8.\n"];
    [output appendFormat:@"Address probe return code: %d\n", status];
    if (data.length >= 256 * 1024) [output appendString:@"Address output truncated at 256 KiB.\n"];
}
}

NSString *BO1RunDiagnosticProbes(const std::atomic_bool *cancelled) {
    NSMutableString *report = [NSMutableString string];
    @autoreleasepool {
        try {
            if (!isCancelled(cancelled)) queryVulkan(report, cancelled);
            if (!isCancelled(cancelled)) queryAddresses(report);
            [report appendFormat:@"\nAUDIO FORMAT AVAILABILITY\nPCM16=%d MS-ADPCM=%d xWMA=%d\n",
                bo1_audio_supports(BO1_AUDIO_PCM16), bo1_audio_supports(BO1_AUDIO_MSADPCM),
                bo1_audio_supports(BO1_AUDIO_XWMA)];
            [report appendString:@"Availability is not a decoding/playback test. Use Test audio for the PCM output path.\n"];
        } catch (const std::exception& error) {
            [report appendFormat:@"\nDiagnostic exception: %@\n", string(error.what())];
        }
        if (isCancelled(cancelled))
            [report appendString:@"\nChecks cancelled when the application became inactive; partial results above.\n"];
        [report appendString:@"\nAll temporary Vulkan objects have been destroyed. Engine compatibility: UNPROVEN.\n"];
    }
    return report;
}
