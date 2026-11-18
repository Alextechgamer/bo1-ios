# Build the real, native-pointer audio mixer independently of the unresolved
# engine pointer32 ABI. This module does not implement the engine's lifecycle.
if(NOT CMAKE_SYSTEM_NAME STREQUAL "iOS")
  message(FATAL_ERROR "The iOS audio target requires the iphoneos toolchain")
endif()
set(BO1_IOS_DEPS_DIR "${PROJECT_SOURCE_DIR}/third_party/ios" CACHE PATH "Pinned iOS dependency installation")
set(BO1_ENGINE_SOURCE_DIR "" CACHE PATH "SevyW/bo1-zombies-android at the documented engine revision")
set(_bo1_audio_source "${BO1_ENGINE_SOURCE_DIR}/src/native/native_audio.cpp")
set(_bo1_audio_header "${BO1_ENGINE_SOURCE_DIR}/src/native/native_audio.h")
if(NOT EXISTS "${_bo1_audio_source}" OR NOT EXISTS "${_bo1_audio_header}")
  message(FATAL_ERROR "Set BO1_ENGINE_SOURCE_DIR to SevyW/bo1-zombies-android e121bab3412988b29534fad26c257adc24329818")
endif()
file(SHA256 "${_bo1_audio_source}" _bo1_audio_sha)
file(SHA256 "${_bo1_audio_header}" _bo1_audio_header_sha)
if(NOT _bo1_audio_sha STREQUAL "5379bcffc4eeaa70eb67b93aae5f6251b66f87887bea706bf0657caed5702962"
    OR NOT _bo1_audio_header_sha STREQUAL "0a53fd704761d8728ef78d1d643e4357f86ae478e351b3e30c00bd573c2ae7a3")
  message(FATAL_ERROR "Native audio source differs from the verified upstream revision; review and update its pin first")
endif()

set(_bo1_sdl "${BO1_IOS_DEPS_DIR}/SDL2-ios")
set(_bo1_ffmpeg "${BO1_IOS_DEPS_DIR}/ffmpeg-ios")
foreach(_name SDL2 avformat avcodec swresample avutil)
  if(_name STREQUAL "SDL2")
    set(_prefix "${_bo1_sdl}")
  else()
    set(_prefix "${_bo1_ffmpeg}")
  endif()
  set(_archive "${_prefix}/lib/lib${_name}.a")
  if(NOT EXISTS "${_archive}")
    message(FATAL_ERROR "Missing ${_archive}; run bash scripts/build_ios_deps.sh")
  endif()
  add_library(bo1_dep_${_name} STATIC IMPORTED GLOBAL)
  set_target_properties(bo1_dep_${_name} PROPERTIES
    IMPORTED_LOCATION "${_archive}" INTERFACE_INCLUDE_DIRECTORIES "${_prefix}/include")
endforeach()
target_link_libraries(bo1_dep_SDL2 INTERFACE "-framework Foundation" "-framework CoreAudio"
  "-framework AudioToolbox" "-framework AVFoundation" "-framework UIKit")
target_link_libraries(bo1_dep_avformat INTERFACE bo1_dep_avcodec bo1_dep_avutil)
target_link_libraries(bo1_dep_avcodec INTERFACE bo1_dep_avutil)
target_link_libraries(bo1_dep_swresample INTERFACE bo1_dep_avutil)

add_library(bo1_native_audio STATIC "${_bo1_audio_source}")
target_include_directories(bo1_native_audio PUBLIC "${BO1_ENGINE_SOURCE_DIR}/src/native")
target_compile_definitions(bo1_native_audio PRIVATE BO1_FFMPEG=1 SDL_MAIN_HANDLED=1)
target_link_libraries(bo1_native_audio PUBLIC bo1_dep_SDL2 bo1_dep_avcodec)

# A real device executable link, with actual libraries and no undefined-symbol
# allowances. It is not packaged as an app and is not run on the build host.
add_executable(bo1_audio_link_probe "${PROJECT_SOURCE_DIR}/tests/ios_audio_link_probe.cpp")
target_compile_definitions(bo1_audio_link_probe PRIVATE SDL_MAIN_HANDLED=1)
target_link_libraries(bo1_audio_link_probe PRIVATE bo1_native_audio bo1_dep_avformat bo1_dep_swresample)
set_target_properties(bo1_audio_link_probe PROPERTIES
  XCODE_ATTRIBUTE_CODE_SIGNING_ALLOWED "NO" XCODE_ATTRIBUTE_CODE_SIGNING_REQUIRED "NO")
