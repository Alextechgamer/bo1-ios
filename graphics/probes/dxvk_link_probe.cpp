// A linker verification executable, deliberately not a UIKit/game app.
// The CI target force-loads the full DXVK archive and links the real platform
// bridge and static MoltenVK. It does not stand in for a successful game boot.
#include "bo1_dxvk_d3d9.h"
#include "ios_platform_bridge.h"

namespace {
IDirect3D9* (WINAPI* volatile create9)(UINT) = &BO1_DXVK_Direct3DCreate9;
HRESULT (WINAPI* volatile create9Ex)(UINT, IDirect3D9Ex**) = &BO1_DXVK_Direct3DCreate9Ex;
PFN_vkGetInstanceProcAddr volatile getVulkanProc = &vkGetInstanceProcAddr;
void* (*volatile getWindowHandle)(void) = &IOS_GetMetalWindowHandle;
}

int main() {
  // Taking these addresses proves linkage without creating GPU work from a
  // command-line executable that has no CAMetalLayer or app lifecycle.
  return create9 && create9Ex && getVulkanProc && getWindowHandle ? 0 : 1;
}
