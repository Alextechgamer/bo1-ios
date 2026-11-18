#pragma once
#include <filesystem>
#include <string>

namespace bo1ios {
// A launcher presence check, not full install/ownership/integrity validation.
struct AssetGateResult {
    bool present = false;
    std::string relativePath;
    std::string message;
};
AssetGateResult InspectStartupAssets(const std::filesystem::path& gameDirectory);
}
