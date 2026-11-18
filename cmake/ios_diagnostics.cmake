# An explicitly named device diagnostic, separate from the unfinished game app.
# Include only after the real platform, renderer, audio, and input targets exist.
include_guard(GLOBAL)
if(NOT CMAKE_SYSTEM_NAME STREQUAL "iOS" OR CMAKE_OSX_SYSROOT MATCHES "[Ss]imulator")
  message(FATAL_ERROR "BO1 Port Diagnostics packages a real iphoneos app, not a simulator or host binary.")
endif()
foreach(_bo1_diagnostic_target bo1_ios_host bo1_dxvk_d3d9 bo1_native_audio bo1_input_frontend bo1_steam_services)
  if(NOT TARGET "${_bo1_diagnostic_target}")
    message(FATAL_ERROR "Diagnostics requires the real ${_bo1_diagnostic_target} target first.")
  endif()
endforeach()
enable_language(OBJCXX)
set(BO1_IOS_DEPS_DIR "${PROJECT_SOURCE_DIR}/third_party/ios" CACHE PATH "Pinned iOS dependency installation")
set(_bo1_diagnostic_mvk "${BO1_IOS_DEPS_DIR}/MoltenVK/static/MoltenVK.xcframework/ios-arm64/libMoltenVK.a")
if(NOT EXISTS "${_bo1_diagnostic_mvk}")
  message(FATAL_ERROR "Diagnostics requires the real static iphoneos MoltenVK slice: ${_bo1_diagnostic_mvk}")
endif()
set(_bo1_diagnostic_sources
  "${PROJECT_SOURCE_DIR}/ios/Diagnostics/DiagnosticsAppDelegate.mm"
  "${PROJECT_SOURCE_DIR}/ios/Diagnostics/DiagnosticsViewController.mm"
  "${PROJECT_SOURCE_DIR}/ios/Diagnostics/DiagnosticsProbes.mm")
add_executable(bo1_port_diagnostics MACOSX_BUNDLE ${_bo1_diagnostic_sources}
  "${PROJECT_SOURCE_DIR}/engine/probes/apple_address_probe.cpp")
set_property(SOURCE ${_bo1_diagnostic_sources} APPEND PROPERTY COMPILE_OPTIONS "-fobjc-arc")
set_target_properties(bo1_port_diagnostics PROPERTIES
  OUTPUT_NAME "BO1PortDiagnostics"
  CXX_STANDARD 20 CXX_STANDARD_REQUIRED YES CXX_EXTENSIONS NO
  OBJCXX_STANDARD 20 OBJCXX_STANDARD_REQUIRED YES OBJCXX_EXTENSIONS NO
  MACOSX_BUNDLE_GUI_IDENTIFIER "com.alextechgamer.bo1ios.diagnostics"
  MACOSX_BUNDLE_BUNDLE_NAME "BO1PortDiagnostics"
  MACOSX_BUNDLE_INFO_PLIST "${PROJECT_SOURCE_DIR}/ios/Diagnostics/Info.plist.in"
  XCODE_ATTRIBUTE_PRODUCT_BUNDLE_IDENTIFIER "com.alextechgamer.bo1ios.diagnostics"
  XCODE_ATTRIBUTE_TARGETED_DEVICE_FAMILY "1,2"
  XCODE_ATTRIBUTE_SUPPORTED_PLATFORMS "iphoneos"
  XCODE_ATTRIBUTE_CLANG_ENABLE_OBJC_ARC YES
  XCODE_ATTRIBUTE_ALWAYS_EMBED_SWIFT_STANDARD_LIBRARIES YES
  XCODE_ATTRIBUTE_ENABLE_BITCODE NO
  XCODE_ATTRIBUTE_CODE_SIGNING_ALLOWED NO
  XCODE_ATTRIBUTE_CODE_SIGNING_REQUIRED NO)
find_package(Git QUIET)
set(_bo1_diagnostic_revision "unknown")
if(GIT_FOUND)
  execute_process(COMMAND "${GIT_EXECUTABLE}" -C "${PROJECT_SOURCE_DIR}" rev-parse --short=12 HEAD
    OUTPUT_VARIABLE _bo1_diagnostic_revision OUTPUT_STRIP_TRAILING_WHITESPACE ERROR_QUIET)
endif()
if(NOT _bo1_diagnostic_revision MATCHES "^[0-9a-f]+$")
  set(_bo1_diagnostic_revision "unknown")
endif()
string(TIMESTAMP _bo1_diagnostic_build "%Y-%m-%dT%H:%M:%SZ" UTC)
target_compile_definitions(bo1_port_diagnostics PRIVATE SDL_MAIN_HANDLED=1
  BO1_DIAGNOSTICS_SOURCE_REVISION="${_bo1_diagnostic_revision}"
  BO1_DIAGNOSTICS_BUILD_UTC="${_bo1_diagnostic_build}")
target_include_directories(bo1_port_diagnostics PRIVATE
  "${PROJECT_SOURCE_DIR}/ios/Diagnostics")
target_link_libraries(bo1_port_diagnostics PRIVATE
  bo1_ios_host bo1_dxvk_d3d9 bo1_native_audio bo1_input_frontend bo1_steam_services "${_bo1_diagnostic_mvk}"
  "-framework Foundation" "-framework UIKit" "-framework QuartzCore" "-framework Metal"
  "-framework CoreGraphics" "-framework IOSurface" "-framework AVFoundation" "-framework GameController")
# Ordinary archive extraction is intentional: only the host bridge is needed
# from bo1_ios_host. -all_load/-ObjC would pull the unrelated game AppDelegate
# and its missing BO1IOSCreateHostServices factory into this separate app.
# No fake HostServices factory, engine adapter, game entrypoint, or assets.
