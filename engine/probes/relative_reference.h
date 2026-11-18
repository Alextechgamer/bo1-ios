#pragma once

// Representation experiment only. This is NOT a replacement definition of
// BO1_P32, an asset loader, an allocator, or an engine pointer ABI.
#include <cstddef>
#include <cstdint>
#include <limits>
#include <type_traits>

namespace bo1::probe {

template <class T> struct RelativeReference {
    std::uint32_t offset = 0; // zero is null; arena offset zero is reserved
};
static_assert(sizeof(RelativeReference<int>) == 4);
static_assert(alignof(RelativeReference<int>) == 4);
static_assert(std::is_trivially_copyable_v<RelativeReference<int>>);

// The caller owns this range. There is no process-global allocator or implicit
// conversion from arbitrary native pointers. Reject references to the wrong
// range, overflow, and unaligned values instead of silently truncating them.
class RelativeArena final {
public:
    RelativeArena(void* storage, std::size_t bytes) noexcept
        : base_(reinterpret_cast<std::uintptr_t>(storage)), bytes_(bytes) {}

    bool valid() const noexcept {
        return base_ != 0 && bytes_ > 1 &&
            bytes_ <= std::numeric_limits<std::uint32_t>::max() &&
            base_ <= std::numeric_limits<std::uintptr_t>::max() - bytes_;
    }

    template <class T>
    bool encode(const T* value, RelativeReference<T>& result) const noexcept {
        result.offset = 0;
        if (!value) return true;
        if (!valid()) return false;
        const auto address = reinterpret_cast<std::uintptr_t>(value);
        if (address <= base_ || address % alignof(T) != 0) return false;
        const auto offset = address - base_;
        if (offset >= bytes_ || sizeof(T) > bytes_ - offset) return false;
        result.offset = static_cast<std::uint32_t>(offset);
        return true;
    }

    template <class T>
    bool decode(RelativeReference<T> value, T*& result) const noexcept {
        result = nullptr;
        if (!value.offset) return true;
        if (!valid() || value.offset >= bytes_ || sizeof(T) > bytes_ - value.offset)
            return false;
        const auto address = base_ + value.offset;
        if (address % alignof(T) != 0) return false;
        result = reinterpret_cast<T*>(address);
        return true;
    }

private:
    std::uintptr_t base_;
    std::size_t bytes_;
};

} // namespace bo1::probe
