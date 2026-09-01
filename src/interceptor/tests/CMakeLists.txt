cmake_minimum_required(VERSION 3.16)

# CPPTEST-01: doctest-based unit tests for message_converter.
#
# Only built when -DBUILD_TESTS=ON is passed to the parent CMake. Links
# against the message_converter_obj OBJECT library from the parent
# CMakeLists.txt (FOUND-05), so the test binary exercises the exact
# same translation units as the production DLL with zero recompile.

add_executable(message_converter_tests
    message_converter_tests.cpp
    $<TARGET_OBJECTS:message_converter_obj>
)

target_include_directories(message_converter_tests PRIVATE
    "${CMAKE_CURRENT_SOURCE_DIR}"
    "${CMAKE_CURRENT_SOURCE_DIR}/.."
)

# Place the test binary next to the DLL and harness for consistency.
set_target_properties(message_converter_tests PROPERTIES
    RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/bin"
)

# Match the parent DLL target's compiler flags so the linked object files
# are ABI-compatible. These flags are purely compile-time — we keep them
# identical as a defensive measure.
if(MSVC)
    target_compile_options(message_converter_tests PRIVATE /W4 /WX-)
    target_link_libraries(message_converter_tests PRIVATE kernel32.lib user32.lib)
elseif(MINGW)
    target_compile_options(message_converter_tests PRIVATE -Wall -Wextra -Wno-unused-parameter)
    target_link_libraries(message_converter_tests PRIVATE kernel32 user32 -static-libgcc -static-libstdc++)
    target_link_options(message_converter_tests PRIVATE -static)
endif()

# Register the test with CTest so `ctest --output-on-failure` in CI runs it.
add_test(NAME message_converter_tests
         COMMAND message_converter_tests)

# QUICK-260423-tk6: fs_utils unit tests (attachment-copy helpers).
#
# Exercises the new GenerateUniqueStem / GetAttachmentsDirForStem /
# EnsureDirExists / CopyFileToDir / WriteErrorForStem helpers. Links
# fs_utils.cpp directly — unlike message_converter, fs_utils is not
# in an OBJECT library because it's only consumed by the DLL itself.
add_executable(fs_utils_tests
    fs_utils_tests.cpp
    ../fs_utils.cpp
)

target_include_directories(fs_utils_tests PRIVATE
    "${CMAKE_CURRENT_SOURCE_DIR}"
    "${CMAKE_CURRENT_SOURCE_DIR}/.."
)

set_target_properties(fs_utils_tests PROPERTIES
    RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/bin"
)

if(MSVC)
    target_compile_options(fs_utils_tests PRIVATE /W4 /WX-)
    target_link_libraries(fs_utils_tests PRIVATE kernel32.lib user32.lib shell32.lib)
elseif(MINGW)
    target_compile_options(fs_utils_tests PRIVATE -Wall -Wextra -Wno-unused-parameter)
    target_link_libraries(fs_utils_tests PRIVATE kernel32 user32 shell32 -static-libgcc -static-libstdc++)
    target_link_options(fs_utils_tests PRIVATE -static)
endif()

add_test(NAME fs_utils_tests
         COMMAND fs_utils_tests)

# Queue-v1 producer conformance. This uses the same checked-in fixtures that
# the Go consumer validates, while exercising the native serializer directly.
add_executable(queue_v1_tests
    queue_v1_tests.cpp
    ../json_writer.cpp
    ../fs_utils.cpp
)

target_include_directories(queue_v1_tests PRIVATE
    "${CMAKE_CURRENT_SOURCE_DIR}"
    "${CMAKE_CURRENT_SOURCE_DIR}/.."
)
target_compile_definitions(queue_v1_tests PRIVATE
    GO_MAPI_VERSION="4.0.0"
    GO_MAPI_QUEUE_FIXTURE_DIR="${CMAKE_CURRENT_SOURCE_DIR}/../../../tests/protocol-fixtures/queue-v1"
)
set_target_properties(queue_v1_tests PROPERTIES
    RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/bin"
)

if(MSVC)
    target_compile_options(queue_v1_tests PRIVATE /W4 /WX-)
    target_link_libraries(queue_v1_tests PRIVATE kernel32.lib user32.lib shell32.lib)
elseif(MINGW)
    target_compile_options(queue_v1_tests PRIVATE -Wall -Wextra -Wno-unused-parameter)
    target_link_libraries(queue_v1_tests PRIVATE kernel32 user32 shell32 -static-libgcc -static-libstdc++)
    target_link_options(queue_v1_tests PRIVATE -static)
endif()

add_test(NAME queue_v1_tests
         COMMAND queue_v1_tests)

add_executable(component_compat_tests
    component_compat_tests.cpp
    $<TARGET_OBJECTS:component_compat_obj>
)
target_include_directories(component_compat_tests PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}" "${CMAKE_CURRENT_SOURCE_DIR}/..")
target_compile_definitions(component_compat_tests PRIVATE
    GO_MAPI_COMPAT_FIXTURE="${CMAKE_CURRENT_SOURCE_DIR}/../../../tests/component-compatibility/compatibility-v1.json"
)
set_target_properties(component_compat_tests PROPERTIES RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/bin")
if(MSVC)
    target_compile_options(component_compat_tests PRIVATE /W4 /WX-)
elseif(MINGW)
    target_compile_options(component_compat_tests PRIVATE -Wall -Wextra -Wno-unused-parameter)
    target_link_options(component_compat_tests PRIVATE -static)
endif()
add_test(NAME component_compat_tests COMMAND component_compat_tests)
