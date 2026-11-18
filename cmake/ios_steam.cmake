# The same native Swift Steam client used by the BO2 port, adapted for BO1.
# Auth, protocol, content and UI sources share a module; none uses a game VM.
include_guard(GLOBAL)
if(NOT CMAKE_SYSTEM_NAME STREQUAL "iOS")
  message(FATAL_ERROR "The Steam UIKit target requires the iPhone SDK")
endif()
enable_language(C)
enable_language(Swift)
include("${CMAKE_CURRENT_LIST_DIR}/steam-sources.cmake")

add_library(bo1_steam_content STATIC ${BO1_STEAM_CONTENT_C_SOURCES})
set_target_properties(bo1_steam_content PROPERTIES C_STANDARD 11 C_STANDARD_REQUIRED YES)
target_compile_definitions(bo1_steam_content PRIVATE _DARWIN_C_SOURCE=1)
target_include_directories(bo1_steam_content PUBLIC "${PROJECT_SOURCE_DIR}/ios/SteamServices/Content")
target_link_libraries(bo1_steam_content PUBLIC z lzma)

add_library(bo1_steam_services STATIC ${BO1_STEAM_CORE_SWIFT_SOURCES}
  "${PROJECT_SOURCE_DIR}/ios/SteamServices/BO1InstallSelection.swift"
  "${PROJECT_SOURCE_DIR}/ios/SteamServices/BO1InstallStorage.swift"
  "${PROJECT_SOURCE_DIR}/ios/SteamServices/BO1GameFilesCoordinator.swift"
  "${PROJECT_SOURCE_DIR}/ios/SteamServices/BO1GameFilesView.swift"
  "${PROJECT_SOURCE_DIR}/ios/SteamServices/BO1SteamGameFiles.swift")
set_target_properties(bo1_steam_services PROPERTIES
  Swift_LANGUAGE_VERSION 5
  Swift_MODULE_NAME BO1SteamServices
  XCODE_ATTRIBUTE_SWIFT_VERSION "5.0"
  XCODE_ATTRIBUTE_SWIFT_OBJC_BRIDGING_HEADER "${PROJECT_SOURCE_DIR}/ios/SteamSwiftBridge.h"
  XCODE_ATTRIBUTE_CLANG_ENABLE_MODULES YES)
target_include_directories(bo1_steam_services PUBLIC "${PROJECT_SOURCE_DIR}/ios/include")
target_link_libraries(bo1_steam_services PUBLIC bo1_steam_content
  "-framework Foundation" "-framework UIKit" "-framework SwiftUI"
  "-framework Security" "-framework CoreImage" "-framework Compression")
