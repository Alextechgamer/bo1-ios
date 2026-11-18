#include "include/bo1_asset_gate.h"
#include <array>
#include <fstream>
#include <system_error>

namespace bo1ios {
AssetGateResult InspectStartupAssets(const std::filesystem::path& root) {
    std::error_code error;
    if (!std::filesystem::is_directory(root, error)) {
        return {false, {}, error ? "Cannot read the game folder: " + error.message()
                                : "The game folder is missing."};
    }
    constexpr std::array candidates{
        "zone/Common/common.ff", "zone/Common/common_zombie.ff",
    };
    std::string failure;
    for (const char* relative : candidates) {
        const auto path = root / relative;
        error.clear();
        const auto status = std::filesystem::symlink_status(path, error);
        if (error) {
            if (error != std::errc::no_such_file_or_directory && failure.empty())
                failure = "Cannot inspect " + std::string(relative) + ": " + error.message();
            continue;
        }
        // A directory or symlink cannot masquerade as a completed archive.
        if (!std::filesystem::is_regular_file(status)) continue;
        const auto bytes = std::filesystem::file_size(path, error);
        if (error || bytes == 0) {
            if (failure.empty()) failure = std::string(relative) + " is empty or unreadable.";
            continue;
        }
        std::ifstream stream(path, std::ios::binary);
        char firstByte;
        if (!stream.get(firstByte)) {
            if (failure.empty()) failure = std::string(relative) + " is not readable.";
            continue;
        }
        return {true, relative, "A startup archive is present. The engine must verify the remaining game files."};
    }
    return {false, {}, failure.empty()
        ? "Copy your game files into game, including zone/Common/common.ff or zone/Common/common_zombie.ff."
        : failure};
}
}
