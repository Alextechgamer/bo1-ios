// Freestanding compiler/ABI probe. No SDK headers or proprietary game code.
// Compile for arm64-apple-ios16.0 with -fms-extensions -fdeclspec.
#if !defined(__clang__)
#error "This probe tests Clang's address-space pointer extensions."
#endif

using U32 = __UINT32_TYPE__;
using U64 = __UINT64_TYPE__;
using P32 = unsigned char* __ptr32 __uptr;
static_assert(sizeof(void*) == 8, "Target must be normal arm64, not arm64_32.");
static_assert(sizeof(P32) == 4, "Clang must preserve a four-byte pointer object.");
static_assert(alignof(P32) == 4, "Clang ptr32 field alignment changed.");

struct LayoutProbe { U32 before; P32 pointer; U32 after; };
static_assert(sizeof(LayoutProbe) == 12);
static_assert(__builtin_offsetof(LayoutProbe, pointer) == 4);
static_assert(__builtin_offsetof(LayoutProbe, after) == 8);

// Inspect these conversions in IR/assembly. Unmodified ptr32 denotes an
// absolute low address; a successful compile does NOT implement rebasing.
extern "C" void* bo1_probe_expand_absolute(P32 pointer) { return (void*)pointer; }
extern "C" P32 bo1_probe_truncate_absolute(void* pointer) { return (P32)pointer; }
extern "C" U64 bo1_probe_pointer_bits(P32 pointer) { return (U64)pointer; }
extern "C" U32 bo1_probe_layout_size() { return sizeof(LayoutProbe); }
