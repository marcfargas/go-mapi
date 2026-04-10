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
