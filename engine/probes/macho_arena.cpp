// Link-only experiment. The zero-fill allocation occupies virtual image space;
// this program is NOT launched by the probe runner. Passing the link inspection
// does not establish that iOS will launch it or that its memory budget is usable.
#ifndef BO1_PROBE_ARENA_MIB
#define BO1_PROBE_ARENA_MIB 2048
#endif
static_assert(sizeof(void*) == 8);
static_assert(BO1_PROBE_ARENA_MIB >= 1 && BO1_PROBE_ARENA_MIB <= 3072);
alignas(16384) unsigned char bo1_probe_arena[
    static_cast<__SIZE_TYPE__>(BO1_PROBE_ARENA_MIB) * 1024u * 1024u];
// Use both ends so the linker must retain the complete range. No pages are
// touched by the build/inspection process itself.
int main() {
    return bo1_probe_arena[0] + bo1_probe_arena[sizeof(bo1_probe_arena) - 1];
}
