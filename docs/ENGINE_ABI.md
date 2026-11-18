# Engine ABI and iOS address-model experiments

The inspected ARM64 engine does **not** use ordinary 64-bit C++ pointers for
its reconstructed game structures. It stores 32-bit pointers in a 64-bit
process, and its existing implementation interprets them as absolute addresses
below 4 GiB. That address model is incompatible with the ordinary ARM64 iOS
executable layout described by Apple's loader. A UIKit host, a larger pthread
stack, and a successful static-library compile do not resolve this requirement.

This document and `engine/probes/` separate the compiler, linker, representation
and device-runtime experiments. They do not implement a replacement engine ABI,
compile BO1, or establish playable iOS support.

## Source baseline

| Project | Inspected revision |
| --- | --- |
| Zephelinn/BO1-Ascension-ARM64 | `3401a66355c07d6c590049c2f42b7635c9bf00ac` |
| SevyW/bo1-zombies-android | `e121bab3412988b29534fad26c257adc24329818` |
| Apple XNU | `f6217f891ac0bb64f3d375211650a4c1ff8ca1ea` |
| LLVM reference | `llvmorg-21.1.8` |

The engine's native build uses a generated source tree produced by
[`tools/p32`](https://github.com/Zephelinn/BO1-Ascension-ARM64/tree/3401a66355c07d6c590049c2f42b7635c9bf00ac/tools/p32).
[`native_p32.h`](https://github.com/Zephelinn/BO1-Ascension-ARM64/blob/3401a66355c07d6c590049c2f42b7635c9bf00ac/src/native/native_p32.h)
defines `BO1_P32` as `__ptr32 __uptr`, converts indirect-call/data pointers
through `BO1_NAT`, `BO1_NATD` and `BO1_NATP`, and uses `BO1_ADDR` for address
initialization. The rewrite also preserves other original-width assumptions;
turning `BO1_P32` into an empty macro is not a valid native port.

[`native_lowmem.c`](https://github.com/Zephelinn/BO1-Ascension-ARM64/blob/3401a66355c07d6c590049c2f42b7635c9bf00ac/src/native/native_lowmem.c)
allocates engine memory in a low range. Its engine launcher supplies a stack
from that allocator using `pthread_attr_setstack`. The native entry wrapper
requests a 16 MiB stack, deliberately located in the engine's address range.
An ordinary 64 MiB pthread stack only changes capacity; it provides no low-address
guarantee. Native platform/library pointers are handled separately from rewritten
engine pointers.

The actual entry is the file-local `EngineMain` in
[`src/web/web_main.cpp`](https://github.com/Zephelinn/BO1-Ascension-ARM64/blob/3401a66355c07d6c590049c2f42b7635c9bf00ac/src/web/web_main.cpp),
called through `bo1_android_main` on Android or `main` elsewhere. The iOS adapter
must expose a deliberate entry after its pointer/argument lifetimes are correct.
There is no `Sys_Main` matching the handoff in this revision.

## Why the existing low-address model does not transfer

Apple's pinned
[`bsd/kern/mach_loader.c`](https://github.com/apple-oss-distributions/xnu/blob/f6217f891ac0bb64f3d375211650a4c1ff8ca1ea/bsd/kern/mach_loader.c)
initializes `enforce_hard_pagezero` to true and checks, for a 64-bit ARM64
executable, that `vm_map_has_hard_pagezero(map, 0x100000000)` succeeds. Failure
returns `LOAD_BADMACHO`. This is direct source evidence for a protected first
4 GiB in the normal launch path. It is not evidence that this exact XNU revision
was tested on every supported iPhone; actual device launch remains a separate
check.

The probes preserve the ordinary PIE and PAGEZERO layout. They do not request
smaller PAGEZERO, disabled ASLR, private loader behavior, overwritten mappings,
or a different Apple ABI. `arm64_32` is a different ABI; changing a target name
does not make an iOS ARM64 process use four-byte native pointers.

In the upstream LLVM reference,
[`AArch64.cpp`](https://github.com/llvm/llvm-project/blob/llvmorg-21.1.8/clang/lib/Basic/Targets/AArch64.cpp)
includes `p270:32:32-p271:32:32-p272:64:64` in its AArch64 Mach-O data layout.
[`AArch64ISelLowering.h`](https://github.com/llvm/llvm-project/blob/llvmorg-21.1.8/llvm/lib/Target/AArch64/AArch64ISelLowering.h)
defines address spaces 270/271 as signed/unsigned 32-bit pointers and describes
their extension for use as native addresses. This is an absolute-pointer model,
not an implicit arena-base addition. Apple Clang ships its own revisions, so its
actual frontend and backend must be tested rather than inferred from this tag.

There is also a distinct code-generation risk. The pinned engine includes an
[AArch64 truncating-store fix](https://github.com/Zephelinn/BO1-Ascension-ARM64/blob/3401a66355c07d6c590049c2f42b7635c9bf00ac/tools/p32/clang-21-aarch64-ptr32-truncstore.patch):
recreating a store while widening its address could lose the store's byte/halfword
width and overwrite neighboring fields. The same failure class is tracked in
[LLVM issue 228782](https://github.com/llvm/llvm-project/issues/228782).
The issue was closed when inspected; that does not identify which Apple Clang
release contains a fix. The supplied assembly tests check the compiler actually
used by a build.

## Observed Apple CI result

The latest verified
[workflow run 44245260295](https://github.com/Alextechgamer/bo1-ios/actions/runs/44245260295)
tested commit
[`3f3fa3ed551c2740dbec480f68a09cb947062cae`](https://github.com/Alextechgamer/bo1-ios/commit/3f3fa3ed551c2740dbec480f68a09cb947062cae)
on 2026-11-18. Its
[`engine-abi-evidence` artifact](https://github.com/Alextechgamer/bo1-ios/actions/runs/44245260295/artifacts/14401246488)
contains `report.json`, compiler logs, assembly and Mach-O inspection reports.
The downloaded ZIP's verified SHA-256 is
`5b02f734e11324a28233d4060a06f11ad0b72326160d45c26b853e51b9a7dc5f`.
The actual compiler was **Apple Clang 17.0.0
(`clang-1700.0.13.5`) from Xcode 16.4**, with **iPhoneOS 18.5 SDK** and target
`arm64-apple-ios16.0`.

The frontend layout stage **failed**. The compiler accepted the annotated pointer
type's spelling but its storage and alignment remained eight bytes:

| Assertion | Required | Observed |
| --- | --- | --- |
| Native pointer size | 8 bytes | 8 bytes |
| `sizeof(P32)` | 4 bytes | 8 bytes |
| `alignof(P32)` | 4 bytes | 8 bytes |
| Synthetic record size | 12 bytes | 24 bytes |
| Pointer field offset | 4 bytes | 8 bytes |
| Following field offset | 8 bytes | 16 bytes |

All five incompatible layout assertions remain enabled. This compiler cannot
preserve the inspected engine's four-byte pointer layout with the tested flags.
The ABI job must remain failed for that result; correcting an unrelated diagnostic
build error does not make the engine compatible.

The frontend layout stage was the **only failed experiment**. All eight other
stages passed, as did the separate 12-test inspector suite. The independent
experiments produced these results:

| Experiment | Observed result |
| --- | --- |
| Portable relative-reference test | Passed 18 checks using a real host address above 4 GiB |
| Host address diagnostic | Passed on the macOS runner, including its 64 MiB pthread; no iPhone execution |
| Narrow stores, `-O0` and `-O2` | Both emitted `strb`/`strh` for the supplied isolated LLVM IR |
| Ordinary iOS Mach-O link | Passed; PIE set, protected 4 GiB PAGEZERO, preferred text address `0x100000000` |
| 2048 MiB zero-fill arena link | Passed; zero-fill data size 2,147,483,648 bytes; total mapped image span 2,147,532,800 bytes; file size 33,000 bytes |
| iOS address diagnostic object | Passed with the public VM API and `-Wall -Wextra -Werror`; compiled only, not executed on a device |

The narrow-store passes establish store widths for those IR functions only.
They do not establish correct C++ pointer layouts, a four-byte function-argument
ABI, pointer rebasing, or compatibility of the full engine. The linked arena was
not launched; its small file size reflects zero-fill virtual storage rather than
proof of an available device memory budget. The recorded preferred text address
is a link-time value, before a device's ASLR slide.

For comparison, the earlier
[run 44243665497](https://github.com/Alextechgamer/bo1-ios/actions/runs/44243665497)
at [`f226d374c853512878b89911edc653581a6c03f2`](https://github.com/Alextechgamer/bo1-ios/commit/f226d374c853512878b89911edc653581a6c03f2)
had the same layout failures and an additional diagnostic-object failure because
the iPhoneOS SDK explicitly rejects `mach/mach_vm.h`. The latest run verifies
the correction to public `vm_allocate`/`vm_deallocate` and
`vm_address_t`/`vm_size_t`, including explicit 64-bit assertions. No unavailable
API is redeclared. The compiler diagnostic excerpts now appear directly in CI
output, and the job correctly exits with failure for the incompatible engine
layout. No device runtime result exists yet.

## Run the experiments

On Linux or macOS with Python 3 and a C++20 compiler:

```sh
python3 engine/probes/test_probe_engine_abi.py
python3 scripts/probe_engine_abi.py --output-dir build/engine-abi
```

On a Mac with Xcode and the iPhoneOS SDK, require the Apple stages:

```sh
python3 scripts/probe_engine_abi.py \
  --output-dir build/engine-abi --require-apple
```

The script discovers `clang` and the SDK through `xcrun --sdk iphoneos` and records
the compiler version. `--clang` and `--sdk` allow explicit paths for a controlled
compiler experiment. With `--require-apple`, the version must identify Apple Clang;
use a run without that flag to investigate a custom LLVM build against an Apple
SDK. `--arena-mib` changes the link-only arena size, from 1 to 3072 MiB.

Each stage has its own log and runs even if another stage fails. `report.json`
records passes, failures and skips. An unavailable Apple toolchain is explicitly
skipped on Linux, and makes `--require-apple` return a nonzero status. A failing
executed stage also returns nonzero. CI should upload `build/engine-abi/` even
when this command fails. Failed command stages print the reason, log path and a
bounded diagnostic excerpt directly in CI output; the complete log is retained.
Do not interpret skipped target checks as passing.

| Experiment | What it establishes | What it does not establish |
| --- | --- | --- |
| `relative-reference` | A real host allocation can hold a four-byte base-relative reference, preserve adjacent fields, round-trip a high native address, and reject invalid ranges/alignment | Compiler support for `BO1_P32`, a rewritten engine, an iOS allocator, or device launch |
| `host-address-diagnostic` | Observed addresses for this build host, including a checked 64 MiB pthread stack | iPhone process addresses or iOS behavior |
| `ptr32-frontend-layout` | Actual target compiler accepts `__ptr32 __uptr`; native pointer size is eight, stored size/alignment is four, and the synthetic record assertions pass | Correct code generation for all engine operations or usable absolute low addresses |
| `ptr32-store-O0/O2` | Isolated byte/halfword stores use the appropriate ARM64 store width at both optimization levels | Full backend correctness, ABI interoperability or a runtime memory test |
| `macho-baseline` | Ordinary target link succeeds; parsed load commands identify ARM64 iOS, PIE, protected 4 GiB PAGEZERO and text above it | Successful launch, signing, entitlement availability or gameplay |
| `macho-arena` | The normal linker can retain a requested zero-fill image range and the image span fits 32-bit relative offsets | Device launch of that image, resident memory budget, a common aligned high32 window, or an allocator |
| `ios-address-object` | The device diagnostic compiles against the selected iPhone SDK | Execution on an iPhone; the object must be integrated deliberately into a development app |

`ptr32_store.ll` is isolated LLVM IR with no stack allocations, so a narrow stack
spill cannot accidentally mask a too-wide destination store. The parser rejects
a wider store or an unexpected helper call. Its own tests include the corruption
case and malformed Mach-O commands. The frontend test retains all its layout
assertions; these are small probe records, not substitutes for the engine's
existing assertions.

Every generated report explicitly states `engine_ready=false`,
`engine_compiled=false`, and `ios_runtime_tested=false`, including when every
requested build experiment passes. These are intentional limits of this runner.

## Candidate: 32-bit relative engine pointers above 4 GiB

A possible research route is a common base-relative address domain: keep each
stored engine pointer four bytes wide, reserve zero for null, and decode every
other value as `base + offset`. Encode native pointers as checked `address - base`.
All referenced objects must lie in the same representable span; system pointers
outside it remain normal 64-bit pointers.

This differs from preserving the low 32 bits and OR-ing a fixed high word.
The latter works only if every nonnull target lies in one aligned 4 GiB window
and the low-zero encoding is reserved. A position-independent image may cross an
aligned window boundary after ASLR. A base-relative span can cross that boundary,
provided its length still fits the available offsets. `relative_reference_test.cpp`
checks that arithmetic distinction with integers and dereferences only real
allocated objects.

The included typed `RelativeReference<T>` and `RelativeArena` are a useful
representation proof: they prove that field size and native high-address access
can coexist. They do **not** demonstrate transparent C++ pointer semantics,
function pointers, engine object layout compatibility beyond the synthetic record,
or a source-compatible replacement for `__ptr32`. Substituting this class through
the entire reconstructed engine would be a substantial separate port.

### Compiler-assisted route

Changing the meaning of the existing rewritten address space could potentially
avoid changing thousands of source-level pointer declarations. That is an
engineering hypothesis, not an implemented compiler patch. A custom frontend/IR
lowering/backend must preserve four-byte storage while correctly handling all of:

1. **Memory access and conversion.** Every address-space load/store, atomic,
   compare/exchange, and memory intrinsic must decode the base. Native-to-engine
   casts must encode/check the range and preserve null. Pointer arithmetic,
   comparisons, integer casts and optimizer assumptions need specified semantics;
   a single `addrspacecast` change is insufficient. Both spaces 270 and 271 must be
   audited if the rewritten code can emit both.
2. **Image addresses and initialization.** Text, globals, constant strings,
   function targets and pointer tables must be within the chosen domain.
   Storing a 64-bit native symbol relocation directly into a four-byte field
   cannot represent its full address. The existing `BO1_ADDR` workaround already
   makes some initialization run through opaque native helpers; the new scheme
   must initialize the arena base before those conversions and encode offsets
   deliberately. A linker-resolved symbol-minus-base representation is another
   possible design, but Mach-O relocation support, ASLR behavior and initialization
   order must be proved with explicit object/link tests. The supplied array link
   test does **not** exercise global pointer relocations.
3. **Indirect calls and host callbacks.** `BO1_NAT`, `BO1_NATD` and `BO1_NATP`
   currently turn integer pointer bits into native addresses. Their behavior must
   distinguish relative engine references from already-native pointers; applying
   a base to both would corrupt the latter. Engine function targets can be decoded
   within the image, but framework functions outside the domain need full native
   pointers or in-domain thunks. A callback entered by UIKit, SDL, audio or a worker
   must establish any required engine base/thread context before using rewritten
   pointers. A platform callback ABI cannot silently become a private engine ABI.
4. **Heap, stacks and thread-local objects.** All engine-addressable heap objects
   and escaped stack/TLS addresses must fit the domain. Engine worker stacks need
   deliberate placement, not just large capacities. Darwin runtime TLS allocation
   cannot be assumed to share the executable arena. Either engine TLS must be
   supplied within it or uses must be converted to explicit native boundaries.
5. **Sentinels, serialization and library boundaries.** Existing integer sentinels,
   pointer differences, varargs, deletion, libc calls, external assets and network
   representations need an audit. Stored relative values are process-domain
   references, not automatically the file/network representation of a BO1 object.
   Native library handles and their ownership remain native.

A process-global base load is a straightforward first code-generation experiment.
A reserved ARM64 register may reduce repeated loads, but it requires coordinated
register allocation and initialization at every entry/callback/thread boundary;
no such calling convention is implemented here. Tests must inspect optimized and
unoptimized code, and a custom pass must demonstrate that no unsupported pointer
operation escapes its lowering.

### Legal image/arena placement experiment

`macho_arena.cpp` adds a zero-fill range to an otherwise ordinary ARM64 iOS image.
The probe links it with normal PAGEZERO and PIE, retains both endpoints, and checks
the non-PAGEZERO image span. It does not launch the binary or touch arena pages.
A successful link would support trying a contiguous image-relative domain above
the protected range. It would not guarantee that iOS accepts the large image,
that the full engine/dependencies fit within the span, or that the physical memory
budget supports gameplay. A 2 GiB virtual array is not 2 GiB of approved resident
memory.

The complete engine image must be measured with its actual code, globals,
libraries and arena, including address gaps and ASLR. Host frameworks can remain
outside the domain only where the rewritten engine stores/receives explicit
native pointers or suitable thunks. This experiment preserves the OS layout;
it is not a way to make the first 4 GiB allocatable.

## Next evidence needed before compiling gameplay

1. Run and retain the Apple compiler, narrow-store and normal Mach-O reports on
   the exact Xcode version selected for CI. A failing frontend/backend identifies
   whether a custom compiler is required even before rebasing is attempted.
2. Add a target-codegen experiment for the proposed relative-pointer lowering,
   including nulls, structs, byte/halfword stores, memcpy, pointer arithmetic,
   indirect functions, p0/p271 conversion and out-of-domain rejection. Preserve
   the full engine's existing size/offset assertions when trying generated headers.
3. Add distinct static-initialization/relocation experiments: global references to
   code and data, tables copied at startup, ASLR slide, and constructors running
   before the engine entry. Inspect both object relocations and final device values.
4. Integrate `BO1ProbeAddressModel(FILE*)` deliberately into a device development
   app. It reports code/data/heap/stack/TLS addresses and a 64 MiB pthread. Its
   fixed one-page allocation uses no overwrite flag and frees memory only on
   success; it observes availability without modifying existing mappings. Simulator
   or macOS output is not device evidence. Then separately test an approved
   above-4-GiB arena, custom stack placement, and the complete image range.
5. Only after those conditions hold, port the actual `EngineMain` wrapper,
   platform/library boundaries and render workers. Validate one supported Zombies
   map on device, including pause/resume and memory pressure. The upstream
   [feature table](https://github.com/Zephelinn/BO1-Ascension-ARM64/blob/3401a66355c07d6c590049c2f42b7635c9bf00ac/README.md)
   still lists campaign as unavailable; resolving the pointer ABI does not add
   campaign implementation.

An alternative is a true native-64-bit engine with explicit 32-bit disk/network
decoders and corrected in-memory structures. That avoids the common-domain
constraint but requires a broader source/layout audit. Neither alternative is
established by a compiler define or by the portable offset test alone.
