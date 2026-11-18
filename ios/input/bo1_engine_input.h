#pragma once
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
// Engine thread only, once at the beginning of IN_Frame before IN_MouseMove.
// Requires the real pinned BO1_NATIVE input queue; no runtime is supplied here.
void IOS_BO1_PumpInput(void);
// Generation assigned to native queue writes made by the current engine pump.
// The pinned patch discards writes from an earlier all-source reset.
uint64_t IOS_BO1_InputEpoch(void);
#ifdef __cplusplus
}
#endif
