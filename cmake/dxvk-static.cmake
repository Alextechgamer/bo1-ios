# Full DXVK v2.6.1 native D3D9 archive for the BO1 iOS bridge.
# This module compiles all renderer sources and shaders; it does not compile T5.
include_guard(GLOBAL)
if(NOT CMAKE_C_COMPILER_LOADED)
  enable_language(C)
endif()

option(BO1_DXVK_HOST_VALIDATION "Allow a non-iOS full-source compile for compiler/link audit" OFF)

function(bo1_add_dxvk_d3d9 target)
  cmake_parse_arguments(DXVK "" "SOURCE_DIR;BRIDGE_INCLUDE_DIR;GLSLANG_EXECUTABLE" "" ${ARGN})
  if(DXVK_UNPARSED_ARGUMENTS OR NOT DXVK_SOURCE_DIR)
    message(FATAL_ERROR "bo1_add_dxvk_d3d9 requires SOURCE_DIR and accepts BRIDGE_INCLUDE_DIR/GLSLANG_EXECUTABLE.")
  endif()
  if(NOT CMAKE_SYSTEM_NAME STREQUAL "iOS" AND NOT BO1_DXVK_HOST_VALIDATION)
    message(FATAL_ERROR "Full Metal DXVK targets iOS. BO1_DXVK_HOST_VALIDATION permits a separate host compile only.")
  endif()
  get_filename_component(project_root "${CMAKE_CURRENT_FUNCTION_LIST_DIR}/.." ABSOLUTE)
  get_filename_component(source "${DXVK_SOURCE_DIR}" ABSOLUTE)
  if(NOT DXVK_BRIDGE_INCLUDE_DIR)
    set(DXVK_BRIDGE_INCLUDE_DIR "${project_root}/ios/include")
  endif()
  find_package(Python3 REQUIRED COMPONENTS Interpreter)
  find_package(Git REQUIRED)
  find_package(Threads REQUIRED)

  execute_process(COMMAND "${Python3_EXECUTABLE}" "${project_root}/patches/dxvk/apply.py"
    "${source}" --check-only RESULT_VARIABLE patch_status OUTPUT_VARIABLE patch_output ERROR_VARIABLE patch_error)
  if(NOT patch_status EQUAL 0)
    message(FATAL_ERROR "Pinned DXVK patch verification failed: ${patch_output}${patch_error}")
  endif()
  set(submodules
    "include/native/directx|9df86f2341616ef1888ae59919feaa6d4fad693d"
    "include/spirv|8b246ff75c6615ba4532fe4fde20f1be090c3764"
    "include/vulkan|234c4b7370a8ea3239a214c9e871e4b17c89f4ab"
    "subprojects/libdisplay-info|275e6459c7ab1ddd4b125f28d0440716e4888078")
  foreach(entry IN LISTS submodules)
    string(REPLACE "|" ";" fields "${entry}")
    list(GET fields 0 relative)
    list(GET fields 1 expected)
    execute_process(COMMAND "${GIT_EXECUTABLE}" -C "${source}/${relative}" rev-parse HEAD
      RESULT_VARIABLE result OUTPUT_VARIABLE actual OUTPUT_STRIP_TRAILING_WHITESPACE ERROR_QUIET)
    if(NOT result EQUAL 0 OR NOT actual STREQUAL expected)
      message(FATAL_ERROR "DXVK submodule ${relative} must be at ${expected}; initialize the pinned recursive submodules.")
    endif()
  endforeach()

  if(DXVK_GLSLANG_EXECUTABLE)
    set(glslang "${DXVK_GLSLANG_EXECUTABLE}")
  else()
    find_program(glslang NAMES glslangValidator glslang NO_CMAKE_FIND_ROOT_PATH REQUIRED)
  endif()
  execute_process(COMMAND "${glslang}" --version RESULT_VARIABLE glslang_result
    OUTPUT_VARIABLE glslang_version ERROR_VARIABLE glslang_error)
  if(NOT glslang_result EQUAL 0)
    message(FATAL_ERROR "glslang must run on the build HOST: ${glslang_error}")
  endif()

  include("${CMAKE_CURRENT_FUNCTION_LIST_DIR}/dxvk-sources.cmake")
  set(generated "${CMAKE_CURRENT_BINARY_DIR}/${target}-generated")
  file(MAKE_DIRECTORY "${generated}")
  set(shader_headers)
  # These globs are dependencies only; the compiled shader/source list is the
  # explicit manifest from the pinned upstream Meson build.
  file(GLOB_RECURSE shader_includes CONFIGURE_DEPENDS
    "${source}/src/dxvk/shaders/*.h" "${source}/src/dxvk/hud/shaders/*.h"
    "${source}/src/d3d9/shaders/*.h")
  foreach(shader IN LISTS BO1_DXVK_SHADERS)
    get_filename_component(symbol "${shader}" NAME_WE)
    set(output "${generated}/${symbol}.h")
    add_custom_command(OUTPUT "${output}"
      COMMAND "${glslang}" --quiet --target-env vulkan1.3 --vn "${symbol}"
        "${source}/${shader}" -o "${output}"
      DEPENDS "${source}/${shader}" ${shader_includes}
      COMMENT "Compiling DXVK shader ${symbol}" VERBATIM)
    list(APPEND shader_headers "${output}")
  endforeach()

  # Preserve the complete real EDID parser. Even Metal's empty EDID result does
  # not eliminate D3D9's parser symbol at link time without whole-program LTO.
  set(display_info "${source}/subprojects/libdisplay-info")
  set(pnp_table "${generated}/pnp-id-table.c")
  add_custom_command(OUTPUT "${pnp_table}"
    COMMAND "${Python3_EXECUTABLE}" "${display_info}/tool/gen-search-table.py"
      "${display_info}/pnp.ids" "${pnp_table}" pnp_id_table
    DEPENDS "${display_info}/tool/gen-search-table.py" "${display_info}/pnp.ids"
    COMMENT "Generating display-info PNP table" VERBATIM)

  set(VCS_TAG "v2.6.1-bo1-ios")
  set(BUILD_TARGET "${CMAKE_SYSTEM_PROCESSOR}/${CMAKE_OSX_ARCHITECTURES}")
  set(BUILD_COMPILER "${CMAKE_CXX_COMPILER_ID}")
  set(BUILD_COMPILER_VERSION "${CMAKE_CXX_COMPILER_VERSION}")
  configure_file("${source}/version.h.in" "${generated}/version.h" @ONLY)
  configure_file("${source}/buildenv.h.in" "${generated}/buildenv.h" @ONLY)

  set(sources)
  foreach(relative IN LISTS BO1_DXVK_SOURCES BO1_DXVK_DISPLAY_INFO_SOURCES)
    if(NOT EXISTS "${source}/${relative}")
      message(FATAL_ERROR "Missing pinned DXVK source: ${relative}")
    endif()
    list(APPEND sources "${source}/${relative}")
  endforeach()
  add_library(${target} STATIC ${sources} "${pnp_table}" ${shader_headers}
    "${project_root}/graphics/probes/dxvk_capabilities.cpp")
  set_target_properties(${target} PROPERTIES
    C_STANDARD 11 C_STANDARD_REQUIRED YES CXX_STANDARD 20 CXX_STANDARD_REQUIRED YES
    CXX_EXTENSIONS NO POSITION_INDEPENDENT_CODE YES)
  target_compile_definitions(${target} PRIVATE
    DXVK_WSI_METAL=1 VK_USE_PLATFORM_METAL_EXT=1 VK_ENABLE_BETA_EXTENSIONS=1 BO1_DXVK_STATIC=1)
  # Xcode does not reliably preserve language-filtered target definitions in
  # a mixed C/C++ archive. Keep these libdisplay-info requirements on its real
  # C sources, including the generated PNP table, rather than on C++ files.
  set(display_info_c_sources "${pnp_table}")
  foreach(relative IN LISTS BO1_DXVK_DISPLAY_INFO_SOURCES)
    list(APPEND display_info_c_sources "${source}/${relative}")
  endforeach()
  set_property(SOURCE ${display_info_c_sources} APPEND PROPERTY COMPILE_DEFINITIONS
    _POSIX_C_SOURCE=200809L static_array=static)
  target_include_directories(${target} PRIVATE
    "${DXVK_BRIDGE_INCLUDE_DIR}" "${generated}" "${source}/include"
    "${source}/include/native" "${source}/include/spirv/include"
    "${display_info}/include")
  target_include_directories(${target} PUBLIC
    "${project_root}/graphics/include" "${source}/include/native/windows"
    "${source}/include/native/directx" "${source}/include/vulkan/include")
  # Keep upstream's ordinary unused-parameter/member warnings from obscuring
  # platform errors; do not disable type or link errors to manufacture a build.
  target_compile_options(${target} PRIVATE -Wno-unused-parameter -Wno-missing-field-initializers)
  target_link_libraries(${target} PUBLIC Threads::Threads ${CMAKE_DL_LIBS})
  set_property(TARGET ${target} PROPERTY BO1_DXVK_REVISION "2b1a284f8453baa2bd193709b67e5183074c74ba")
  message(STATUS "Full pinned DXVK D3D9 target: ${target}; 60 generated shaders")
endfunction()

function(bo1_add_dxvk_link_probe target)
  cmake_parse_arguments(PROBE "" "DXVK_TARGET;PLATFORM_TARGET;MOLTENVK_LIBRARY" "" ${ARGN})
  if(NOT CMAKE_SYSTEM_NAME STREQUAL "iOS")
    message(FATAL_ERROR "The MoltenVK link probe requires the real iOS SDK target.")
  endif()
  if(NOT TARGET "${PROBE_DXVK_TARGET}" OR NOT TARGET "${PROBE_PLATFORM_TARGET}")
    message(FATAL_ERROR "The link probe requires the real DXVK and UIKit bridge targets.")
  endif()
  if(NOT EXISTS "${PROBE_MOLTENVK_LIBRARY}")
    message(FATAL_ERROR "The link probe requires an existing static iphoneos-arm64 MoltenVK library.")
  endif()
  get_filename_component(project_root "${CMAKE_CURRENT_FUNCTION_LIST_DIR}/.." ABSOLUTE)
  add_executable(${target} "${project_root}/graphics/probes/dxvk_link_probe.cpp")
  set_target_properties(${target} PROPERTIES MACOSX_BUNDLE FALSE
    XCODE_ATTRIBUTE_CODE_SIGNING_ALLOWED NO XCODE_ATTRIBUTE_CODE_SIGNING_REQUIRED NO)
  target_link_libraries(${target} PRIVATE
    "$<LINK_LIBRARY:WHOLE_ARCHIVE,${PROBE_DXVK_TARGET}>"
    "${PROBE_PLATFORM_TARGET}" "${PROBE_MOLTENVK_LIBRARY}"
    "-framework Metal" "-framework Foundation" "-framework QuartzCore"
    "-framework CoreGraphics" "-framework IOSurface" "-framework UIKit")
  # Unresolved implementation symbols must fail this probe. No dynamic lookup
  # option, weak fallback, or fake renderer/Metal implementation is supplied.
endfunction()
