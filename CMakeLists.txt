cmake_minimum_required(VERSION 3.24)
project(BO1IOSPlatform VERSION 0.1.0 LANGUAGES CXX)
set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)
include(CTest)

option(BO1_BUILD_IOS_AUDIO "Build and link the pinned native mixer with iOS audio dependencies" OFF)
if(BO1_BUILD_IOS_AUDIO)
  include(cmake/ios_audio.cmake)
endif()

# This initial project builds platform components, not an engine or an IPA.
# The real engine ABI and BO1IOSCreateHostServices adapter remain required.
if(BUILD_TESTING AND NOT CMAKE_SYSTEM_NAME STREQUAL "iOS")
  find_package(Threads REQUIRED)
  add_executable(bo1_platform_tests tests/test_platform_state.cpp ios/bo1_asset_gate.cpp)
  target_include_directories(bo1_platform_tests PRIVATE ios/include)
  target_link_libraries(bo1_platform_tests PRIVATE Threads::Threads)
  add_test(NAME platform_state COMMAND bo1_platform_tests)
endif()

option(BO1_BUILD_IOS_PLATFORM "Compile UIKit/platform static archives with the Apple SDK" OFF)
set(BO1_DXVK_SOURCE_DIR "" CACHE PATH "Pinned DXVK checkout with the Metal patch applied")
if(BO1_BUILD_IOS_PLATFORM)
  if(NOT CMAKE_SYSTEM_NAME STREQUAL "iOS")
    message(FATAL_ERROR "Use -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_SYSROOT=iphoneos -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=16.0")
  endif()
  if(NOT EXISTS "${BO1_DXVK_SOURCE_DIR}/src/wsi/metal/wsi_platform_ios.cpp")
    message(FATAL_ERROR "Set BO1_DXVK_SOURCE_DIR after running patches/dxvk/apply.py on DXVK v2.6.1.")
  endif()
  enable_language(OBJCXX)
  set(CMAKE_OBJCXX_STANDARD 20)
  set(CMAKE_OBJCXX_STANDARD_REQUIRED ON)
  set(CMAKE_OBJCXX_EXTENSIONS OFF)
  set(BO1_VULKAN_INCLUDE "${BO1_DXVK_SOURCE_DIR}/include/vulkan/include")
  add_library(bo1_ios_host STATIC
    ios/AppDelegate.mm ios/GameViewController.mm ios/ios_platform_bridge.mm ios/bo1_asset_gate.cpp)
  target_include_directories(bo1_ios_host PUBLIC ios/include "${BO1_VULKAN_INCLUDE}")
  # Xcode cannot reliably represent a per-language target option when C++ and
  # Objective-C++ share this archive. Set ARC on the .mm sources explicitly.
  set_source_files_properties(ios/AppDelegate.mm ios/GameViewController.mm
    ios/ios_platform_bridge.mm ios/main.mm PROPERTIES COMPILE_OPTIONS "-fobjc-arc")
  target_compile_definitions(bo1_ios_host PUBLIC PLATFORM_IOS=1 VK_USE_PLATFORM_METAL_EXT=1)
  target_link_libraries(bo1_ios_host INTERFACE "-framework Foundation" "-framework UIKit"
    "-framework Metal" "-framework QuartzCore")
  add_library(bo1_ios_entrypoint OBJECT ios/main.mm)
  set_target_properties(bo1_ios_host bo1_ios_entrypoint PROPERTIES
    XCODE_ATTRIBUTE_CLANG_ENABLE_OBJC_ARC "YES")

  # Compilation of the real patched WSI/loader, NOT the complete DXVK renderer.
  add_library(bo1_dxvk_platform STATIC
    "${BO1_DXVK_SOURCE_DIR}/src/wsi/metal/wsi_platform_ios.cpp"
    "${BO1_DXVK_SOURCE_DIR}/src/wsi/wsi_platform.cpp"
    "${BO1_DXVK_SOURCE_DIR}/src/vulkan/vulkan_loader.cpp")
  target_include_directories(bo1_dxvk_platform PRIVATE ios/include
    "${BO1_DXVK_SOURCE_DIR}/include/native/windows" "${BO1_VULKAN_INCLUDE}")
  target_compile_definitions(bo1_dxvk_platform PRIVATE DXVK_WSI_METAL=1 VK_USE_PLATFORM_METAL_EXT=1)
endif()
