# Portable, thread-safe input state plus independently compiled Apple frontend.
find_package(Threads REQUIRED)
add_library(bo1_input_core STATIC
  "${PROJECT_SOURCE_DIR}/ios/input/InputState.cpp"
  "${PROJECT_SOURCE_DIR}/ios/input/ios_input_bridge.cpp")
target_include_directories(bo1_input_core PUBLIC "${PROJECT_SOURCE_DIR}/ios/include"
  PRIVATE "${PROJECT_SOURCE_DIR}/ios/input")
target_link_libraries(bo1_input_core PUBLIC Threads::Threads)

set(BO1_ENGINE_SOURCE_DIR "" CACHE PATH "Pinned BO1 Ascension source checkout")
if(BO1_ENGINE_SOURCE_DIR)
  set(_bo1_gpad_header "${BO1_ENGINE_SOURCE_DIR}/src/client/gpad_backend.h")
  if(NOT EXISTS "${_bo1_gpad_header}")
    message(FATAL_ERROR "BO1_ENGINE_SOURCE_DIR does not contain the native gamepad backend header")
  endif()
  file(SHA256 "${_bo1_gpad_header}" _bo1_gpad_sha)
  if(NOT _bo1_gpad_sha STREQUAL "58f1c47455a3ac1e6d797eace183446e7f26c2d65c6cbe962ba162b8cc743180")
    message(FATAL_ERROR "Native gamepad interface differs from the reviewed engine pin")
  endif()
  add_library(bo1_engine_input STATIC "${PROJECT_SOURCE_DIR}/ios/input/bo1_engine_input.cpp")
  target_include_directories(bo1_engine_input PUBLIC "${PROJECT_SOURCE_DIR}/ios/input"
    PRIVATE "${BO1_ENGINE_SOURCE_DIR}/src")
  target_link_libraries(bo1_engine_input PUBLIC bo1_input_core)
  # The real native input queue exports must resolve in the eventual engine.
  # Do not link this adapter into a diagnostics app with fake queue functions.
endif()

if(BUILD_TESTING AND NOT CMAKE_SYSTEM_NAME STREQUAL "iOS")
  add_executable(bo1_input_state_tests "${PROJECT_SOURCE_DIR}/tests/test_input_state.cpp")
  target_include_directories(bo1_input_state_tests PRIVATE "${PROJECT_SOURCE_DIR}/ios/input")
  target_link_libraries(bo1_input_state_tests PRIVATE bo1_input_core)
  add_test(NAME input_state COMMAND bo1_input_state_tests)
  if(TARGET bo1_engine_input)
    add_executable(bo1_input_engine_tests "${PROJECT_SOURCE_DIR}/tests/test_input_engine.cpp")
    target_include_directories(bo1_input_engine_tests PRIVATE "${BO1_ENGINE_SOURCE_DIR}/src")
    target_link_libraries(bo1_input_engine_tests PRIVATE bo1_engine_input)
    add_test(NAME input_engine_contract COMMAND bo1_input_engine_tests)
  endif()
endif()

function(bo1_add_input_frontend)
  add_library(bo1_input_frontend STATIC
    "${PROJECT_SOURCE_DIR}/ios/input/BO1TouchHUD.mm"
    "${PROJECT_SOURCE_DIR}/ios/input/BO1InputFrontend.mm")
  set_property(SOURCE "${PROJECT_SOURCE_DIR}/ios/input/BO1TouchHUD.mm"
    "${PROJECT_SOURCE_DIR}/ios/input/BO1InputFrontend.mm"
    APPEND PROPERTY COMPILE_OPTIONS "-fobjc-arc")
  set_target_properties(bo1_input_frontend PROPERTIES XCODE_ATTRIBUTE_CLANG_ENABLE_OBJC_ARC "YES")
  target_include_directories(bo1_input_frontend PUBLIC "${PROJECT_SOURCE_DIR}/ios/input")
  target_link_libraries(bo1_input_frontend PUBLIC bo1_input_core
    "-framework UIKit" "-framework Foundation" "-framework QuartzCore" "-framework GameController")
endfunction()
