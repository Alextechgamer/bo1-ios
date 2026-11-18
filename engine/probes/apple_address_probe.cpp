// An optional diagnostic to call from a development iOS app. It observes this
// process and allocates/deallocates private memory only. It never removes or
// weakens PAGEZERO, overwrites mappings, disables ASLR, or executes mapped data.
#include <cinttypes>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <pthread.h>

static_assert(sizeof(std::uintptr_t) == 8, "This diagnostic requires a 64-bit process.");

#if defined(__APPLE__)
#include <mach/mach.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <TargetConditionals.h>
// The iPhoneOS SDK exports vm_allocate/vm_deallocate. mach/mach_vm.h is
// explicitly unsupported there; do not redeclare unavailable private APIs.
static_assert(sizeof(vm_address_t) == 8, "The public VM API must preserve arm64 addresses.");
static_assert(sizeof(vm_size_t) == 8, "The public VM API must preserve arm64 sizes.");
#endif

namespace {
int globalSample;
thread_local int tlsSample;
void sampleFunction() {}
void printAddress(FILE* output, const char* name, const void* pointer) {
    const auto value = reinterpret_cast<std::uintptr_t>(pointer);
    std::fprintf(output, "%s=0x%" PRIxPTR " below4GiB=%d high32=0x%" PRIxPTR "\n",
                 name, value, value < (std::uint64_t{1} << 32), value >> 32);
}
struct ThreadProbe { FILE* output; };
void* threadMain(void* context) {
    auto* probe = static_cast<ThreadProbe*>(context);
    int localSample = 0;
    printAddress(probe->output, "pthread64MiB.local", &localSample);
    printAddress(probe->output, "pthread64MiB.tls", &tlsSample);
    return nullptr;
}
}

extern "C" int BO1ProbeAddressModel(FILE* output) {
    if (!output) return 1;
    std::fprintf(output, "BO1 address diagnostic: no engine is invoked.\n");
#if defined(__APPLE__)
    std::fprintf(output, "apple=1 ios=%d simulator=%d\n", TARGET_OS_IOS, TARGET_OS_SIMULATOR);
#else
    std::fprintf(output, "apple=0 ios=0 simulator=0\n");
#endif
    int localSample = 0;
    printAddress(output, "caller.stack", &localSample);
    printAddress(output, "global", &globalSample);
    printAddress(output, "tls", &tlsSample);
    printAddress(output, "literal", "BO1 address diagnostic");
    printAddress(output, "function", reinterpret_cast<const void*>(&sampleFunction));
    void* heap = std::malloc(4096);
    printAddress(output, "malloc", heap);
    std::free(heap);

    pthread_attr_t attributes;
    int status = pthread_attr_init(&attributes);
    if (status != 0) return status;
    status = pthread_attr_setstacksize(&attributes, 64u * 1024u * 1024u);
    ThreadProbe probe{output};
    pthread_t thread{};
    if (status == 0) status = pthread_create(&thread, &attributes, threadMain, &probe);
    pthread_attr_destroy(&attributes);
    if (status == 0) status = pthread_join(thread, nullptr);
    std::fprintf(output, "pthread64MiB.status=%d\n", status);

#if defined(__APPLE__)
    const auto* header = _dyld_get_image_header(0);
    const auto slide = _dyld_get_image_vmaddr_slide(0);
    if (header && header->magic == MH_MAGIC_64) {
        const auto* header64 = reinterpret_cast<const mach_header_64*>(header);
        const auto* command = reinterpret_cast<const load_command*>(header64 + 1);
        std::fprintf(output, "main_image.MH_PIE=%d slide=0x%" PRIxPTR "\n",
                     (header64->flags & MH_PIE) != 0, static_cast<std::uintptr_t>(slide));
        for (std::uint32_t index = 0; index < header64->ncmds; ++index) {
            if (command->cmd == LC_SEGMENT_64) {
                const auto* segment = reinterpret_cast<const segment_command_64*>(command);
                std::fprintf(output, "segment.%.16s vmaddr=0x%" PRIx64 " size=0x%" PRIx64
                             " initprot=%d maxprot=%d\n", segment->segname,
                             static_cast<std::uint64_t>(segment->vmaddr),
                             static_cast<std::uint64_t>(segment->vmsize),
                             segment->initprot, segment->maxprot);
            }
            command = reinterpret_cast<const load_command*>(
                reinterpret_cast<const unsigned char*>(command) + command->cmdsize);
        }
    }

    // VM_FLAGS_FIXED without VM_FLAGS_OVERWRITE must fail if a range is
    // unavailable. This is a one-page observation, not an allocator strategy.
    vm_address_t low = 0x40000000ull;
    const vm_size_t bytes = vm_page_size;
    const kern_return_t lowResult = vm_allocate(mach_task_self(), &low, bytes, VM_FLAGS_FIXED);
    std::fprintf(output, "low_page_probe.status=%d address=0x%" PRIx64 "\n",
                 lowResult, static_cast<std::uint64_t>(low));
    if (lowResult == KERN_SUCCESS) vm_deallocate(mach_task_self(), low, bytes);

    vm_address_t ordinary = 0;
    const kern_return_t highResult = vm_allocate(mach_task_self(), &ordinary, bytes, VM_FLAGS_ANYWHERE);
    std::fprintf(output, "ordinary_page_probe.status=%d address=0x%" PRIx64 "\n",
                 highResult, static_cast<std::uint64_t>(ordinary));
    if (highResult == KERN_SUCCESS) vm_deallocate(mach_task_self(), ordinary, bytes);
#endif
    std::fprintf(output, "engine_compatible=UNPROVEN\n");
    return status;
}

#ifdef BO1_ADDRESS_PROBE_STANDALONE
int main() { return BO1ProbeAddressModel(stdout); }
#endif
