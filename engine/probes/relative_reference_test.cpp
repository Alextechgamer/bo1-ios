#include "relative_reference.h"
#include <array>
#include <cstring>
#include <iostream>
#include <limits>
#include <new>
#include <stdexcept>

static_assert(sizeof(std::uintptr_t) == 8, "The experiment requires a 64-bit host.");

namespace {
unsigned checks = 0;
void require(bool condition, const char* description) {
    ++checks;
    if (!condition) throw std::runtime_error(description);
}
// These are probe records, not copied/guessed engine structures. They exercise
// one four-byte reference field between neighboring fields at a high address.
struct Record {
    std::uint32_t first;
    bo1::probe::RelativeReference<Record> next;
    std::uint32_t last;
};
static_assert(sizeof(Record) == 12);
static_assert(offsetof(Record, next) == 4);
static_assert(offsetof(Record, last) == 8);
}

int main() {
    try {
        alignas(64) std::array<std::byte, 4096> bytes{};
        bo1::probe::RelativeArena arena(bytes.data(), bytes.size());
        require(arena.valid(), "allocated arena rejected");
        Record* first = ::new (bytes.data() + 64) Record{0x12345678, {}, 0x87654321};
        Record* second = ::new (bytes.data() + 128) Record{9, {}, 10};
        require(arena.encode(second, first->next), "encode failed");
        require(first->next.offset == 128, "encoded value is not a base-relative offset");
        require(first->first == 0x12345678 && first->last == 0x87654321,
                "reference store corrupted adjacent fields");
        Record* decoded = nullptr;
        require(arena.decode(first->next, decoded) && decoded == second,
                "decode did not preserve full native address");
        require(decoded->first == 9, "decoded reference did not reach the allocated object");

        // Copies keep the arena-relative value, independently of the address
        // of the field containing it (unlike field-relative pointers).
        Record copy = *first;
        require(arena.decode(copy.next, decoded) && decoded == second,
                "copying a reference changed its target");
        require(arena.encode<Record>(nullptr, copy.next) && copy.next.offset == 0,
                "null encoding failed");
        decoded = second;
        require(arena.decode(copy.next, decoded) && decoded == nullptr,
                "null decoding failed");

        bo1::probe::RelativeReference<Record> invalid{1};
        require(!arena.decode(invalid, decoded) && decoded == nullptr,
                "unaligned reference accepted");
        invalid.offset = static_cast<std::uint32_t>(bytes.size() - 4);
        require(!arena.decode(invalid, decoded), "object crossing arena end accepted");
        invalid.offset = std::numeric_limits<std::uint32_t>::max();
        require(!arena.decode(invalid, decoded), "out-of-range reference accepted");
        Record outside{1, {}, 2};
        require(!arena.encode(&outside, invalid) && invalid.offset == 0,
                "pointer outside arena silently truncated");
        require(!arena.encode(reinterpret_cast<Record*>(bytes.data()), invalid),
                "reserved null offset used for a nonnull object");
        bo1::probe::RelativeArena tooLarge(bytes.data(), std::uint64_t{1} << 32);
        require(!tooLarge.valid(), "arena larger than representable offsets accepted");

        // Show exactly why copying just the low bits of a high native address
        // is different from a usable zero-extended absolute pointer.
        const auto address = reinterpret_cast<std::uintptr_t>(second);
        const bool highAddress = address >= (std::uint64_t{1} << 32);
        if (highAddress) {
            const auto truncated = static_cast<std::uint32_t>(address);
            require(static_cast<std::uintptr_t>(truncated) != address,
                    "expected high native address unexpectedly survived truncation");
        }

        // A low32/OR-high-bits scheme fails across a 4GiB boundary. These are
        // integer arithmetic only: no fabricated address is dereferenced.
        constexpr std::uint64_t window = 0x100000000ull;
        constexpr std::uint64_t crossesWindow = 0x200000040ull;
        require((window | static_cast<std::uint32_t>(crossesWindow)) != crossesWindow,
                "high-window boundary counterexample failed");
        constexpr std::uint64_t unalignedBase = 0x1fffff000ull;
        constexpr std::uint32_t relative = 0x1040u;
        require(unalignedBase + relative == crossesWindow,
                "base-relative offset did not cross high32 boundary correctly");

        std::cout << "{\"checks\":" << checks
                  << ",\"reference_storage_bytes\":" << sizeof(first->next)
                  << ",\"arena_above_4gib\":" << (highAddress ? "true" : "false")
                  << ",\"engine_compiled\":false,\"ios_runtime_tested\":false}\n";
        return 0;
    } catch (const std::exception& exception) {
        std::cerr << exception.what() << '\n';
        return 1;
    }
}
