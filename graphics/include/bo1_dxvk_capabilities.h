#pragma once

#include <vulkan/vulkan_core.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct BO1DXVKCapabilityReport {
  uint32_t apiVersion;
  uint32_t missingRequirements;
  char deviceName[VK_MAX_PHYSICAL_DEVICE_NAME_SIZE];
} BO1DXVKCapabilityReport;

// Called synchronously once for each tested requirement. The requirement name
// is valid for this call only. Callbacks must not throw across the C boundary.
typedef void (*BO1DXVKCapabilityCallback)(const char* requirement,
                                        VkBool32 supported, void* context);

// Query the REAL driver for DXVK v2.6.1's D3D9 baseline, without creating a
// device, surface, command buffer, or GPU work. physicalDevice must belong to a
// live instance created through the statically linked MoltenVK entry points.
// The caller owns instance lifetime and external synchronization.
//
// Returns VK_ERROR_FEATURE_NOT_PRESENT and the exact missing names when the
// baseline fails; propagates Vulkan enumeration errors. VK_SUCCESS means only
// these device features/extensions/queue requirements are advertised. It does
// not prove format support, shader translation, presentation, or game rendering.
VkResult BO1_DXVK_QueryD3D9Baseline(VkPhysicalDevice physicalDevice,
                                  BO1DXVKCapabilityReport* report,
                                  BO1DXVKCapabilityCallback callback,
                                  void* context);

#ifdef __cplusplus
}
#endif
