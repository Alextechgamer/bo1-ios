#include "bo1_asset_gate.h"
#include "bo1_display_state.h"
#include <atomic>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <stdexcept>
#include <thread>
#include <unistd.h>

namespace fs = std::filesystem;
static unsigned checks = 0;
static void require(bool ok, const char* why) {
    ++checks;
    if (!ok) throw std::runtime_error(why);
}
static void write(const fs::path& path, const char* bytes) {
    fs::create_directories(path.parent_path());
    std::ofstream stream(path, std::ios::binary);
    stream << bytes;
    if (!stream) throw std::runtime_error("fixture write failed");
}

static void testAssets(const fs::path& root) {
    const auto common = root / "zone/Common/common.ff";
    const auto zombie = root / "zone/Common/common_zombie.ff";
    require(!bo1ios::InspectStartupAssets(root).present, "missing root accepted");
    write(root, "not a directory");
    require(!bo1ios::InspectStartupAssets(root).present, "file root accepted");
    fs::remove(root);
    fs::create_directories(common);
    require(!bo1ios::InspectStartupAssets(root).present, "directory archive accepted");
    fs::remove(common);
    write(common, "");
    require(!bo1ios::InspectStartupAssets(root).present, "empty archive accepted");
    write(zombie, "test fixture, not actual game data");
    auto result = bo1ios::InspectStartupAssets(root);
    require(result.present && result.relativePath == "zone/Common/common_zombie.ff", "zombie fallback failed");
    write(common, "startup presence fixture");
    result = bo1ios::InspectStartupAssets(root);
    require(result.present && result.relativePath == "zone/Common/common.ff", "common archive precedence failed");
    const auto installing = root / ".bo1-install-in-progress.json";
    write(installing, "interrupted installation fixture");
    require(!bo1ios::InspectStartupAssets(root).present, "interrupted install accepted with an existing common archive");
    fs::remove(installing);
    require(bo1ios::InspectStartupAssets(root).present, "completed rollback/commit did not reopen asset gate");
    fs::create_symlink(root / "absent-transaction", installing);
    require(!bo1ios::InspectStartupAssets(root).present, "dangling transaction marker accepted");
    fs::remove(installing);
    fs::remove(common);
    fs::remove(zombie);
    write(root / "elsewhere.ff", "unrelated file");
    fs::create_symlink(root / "elsewhere.ff", common);
    require(!bo1ios::InspectStartupAssets(root).present, "symlink archive accepted");
    require(!bo1ios::InspectStartupAssets(root).message.empty(), "missing diagnostic");
}

static void testDisplayState() {
    bo1ios::DisplayState state;
    std::uint32_t w = 1, h = 1;
    state.readSize(&w, &h);
    require(w == 0 && h == 0, "initial size not zero");
    require(state.isPaused() && !state.isRegistered(), "unsafe startup state");
    state.setRegistered(true);
    state.publishSize(2796, 1290);
    state.publishRefreshRate(120);
    state.requestPause(false);
    state.readSize(&w, &h);
    require(w == 2796 && h == 1290 && state.refreshRate() == 120, "metrics lost");
    require(state.isRegistered() && !state.isPaused(), "foreground state lost");
    state.readSize(nullptr, nullptr);
    state.publishSize(0, 0);
    std::atomic<bool> done{false}, torn{false};
    std::thread writer([&] {
        for (std::uint32_t i = 1; i != 200001; ++i) state.publishSize(i * 2, i);
        done.store(true);
    });
    do {
        state.readSize(&w, &h);
        if (w != 2 * h) torn.store(true);
    } while (!done.load());
    writer.join();
    require(!torn.load(), "torn drawable dimensions during concurrent layout/read");
    state.requestPause(true);
    state.setRegistered(false);
    state.publishSize(0, 0);
    state.publishRefreshRate(0);
    state.readSize(&w, &h);
    require(state.isPaused() && !state.isRegistered() && w == 0 && h == 0,
            "teardown state invalid");
}

int main() {
    char temporary[] = "/tmp/bo1-ios-platform-XXXXXX";
    const char* directory = mkdtemp(temporary);
    if (!directory) return 2;
    try {
        testAssets(fs::path(directory) / "game");
        testDisplayState();
        fs::remove_all(directory);
        std::cout << "PASS: " << checks << " platform checks (asset presence and display state)\n";
    } catch (const std::exception& error) {
        fs::remove_all(directory);
        std::cerr << "FAIL: " << error.what() << '\n';
        return 1;
    }
}
