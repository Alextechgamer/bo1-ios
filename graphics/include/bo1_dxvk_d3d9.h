#pragma once

// This header belongs on the NATIVE 64-bit side of the engine/DXVK bridge.
// Do not include it in a pointer-rewritten T5 engine translation unit.
#include <d3d9.h>

#ifdef __cplusplus
extern "C" {
#endif

IDirect3D9* WINAPI BO1_DXVK_Direct3DCreate9(UINT sdkVersion);
HRESULT WINAPI BO1_DXVK_Direct3DCreate9Ex(UINT sdkVersion, IDirect3D9Ex** output);

#ifdef __cplusplus
}
#endif
