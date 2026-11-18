#pragma once
#include <atomic>
#include <cstdint>

namespace bo1ios {
class DisplayState final {
public:
    // Pack dimensions to avoid a mixed old/new size during rotation.
    void publishSize(std::uint32_t w, std::uint32_t h) noexcept {
        size_.store((std::uint64_t(w) << 32) | h, std::memory_order_release);
    }
    void readSize(std::uint32_t* w, std::uint32_t* h) const noexcept {
        const auto value = size_.load(std::memory_order_acquire);
        if (w) *w = static_cast<std::uint32_t>(value >> 32);
        if (h) *h = static_cast<std::uint32_t>(value);
    }
    void publishRefreshRate(std::uint32_t fps) noexcept { refresh_.store(fps); }
    std::uint32_t refreshRate() const noexcept { return refresh_.load(); }
    void setRegistered(bool value) noexcept { registered_.store(value); }
    bool isRegistered() const noexcept { return registered_.load(); }
    void requestPause(bool value) noexcept { paused_.store(value); }
    bool isPaused() const noexcept { return paused_.load(); }
private:
    std::atomic<std::uint64_t> size_{0};
    std::atomic<std::uint32_t> refresh_{0};
    std::atomic<bool> registered_{false};
    std::atomic<bool> paused_{true};
};
}
