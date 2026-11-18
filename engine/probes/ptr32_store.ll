; Isolated target-backend test; no allocas/prologue stores can mask a bad
; destination store. This tests the failure class of LLVM issue #228782.
target datalayout = "e-m:o-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-n32:64-S128-Fn32"
target triple = "arm64-apple-ios16.0.0"

define void @bo1_probe_store8(ptr addrspace(271) %destination, i8 %value) {
  store i8 %value, ptr addrspace(271) %destination, align 1
  ret void
}

define void @bo1_probe_store16(ptr addrspace(271) %destination, i16 %value) {
  store i16 %value, ptr addrspace(271) %destination, align 2
  ret void
}

define i8 @bo1_probe_load8(ptr addrspace(271) %source) {
  %value = load i8, ptr addrspace(271) %source, align 1
  ret i8 %value
}
