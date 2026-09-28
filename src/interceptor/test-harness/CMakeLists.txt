cmake_minimum_required(VERSION 3.16)
project(go-mapi-test-harness)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# Create the test harness executable
add_executable(go-mapi-test-harness
    test_utils.cpp
    ../fs_utils.cpp
    src/main.cpp
    src/test_simple_send.cpp
    src/test_with_attachments.cpp
    src/test_unicode.cpp
    src/test_unicode_wide.cpp
    src/test_multiple_recipients.cpp
    src/test_ansi_encoding.cpp
    src/test_null_filename.cpp
    src/test_attachment_copy_failure.cpp
    src/test_send_documents.cpp
)

add_dependencies(go-mapi-test-harness go-mapi)

# Manual installed-state probe: dispatch through the Windows system mapi32 stub.
# Deliberately absent from CTest, which runs without an installed provider.
add_executable(installed_mapi_probe src/installed_mapi_probe.cpp)
target_include_directories(installed_mapi_probe PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}/..")

# Include directories (interceptor is now parent directory)
target_include_directories(go-mapi-test-harness PRIVATE
    "${CMAKE_CURRENT_SOURCE_DIR}/.."
)

# Platform-specific settings
if(MSVC)
    target_compile_options(go-mapi-test-harness PRIVATE /W4 /WX-)
    target_link_libraries(go-mapi-test-harness PRIVATE kernel32.lib user32.lib shell32.lib)
    target_compile_options(installed_mapi_probe PRIVATE /W4)
elseif(MINGW)
    target_compile_options(go-mapi-test-harness PRIVATE -Wall -Wextra -Wno-unused-parameter)
    target_link_libraries(go-mapi-test-harness PRIVATE kernel32 user32 shell32 -static-libgcc -static-libstdc++)
    target_link_options(go-mapi-test-harness PRIVATE -static)
    target_compile_options(installed_mapi_probe PRIVATE -Wall -Wextra)
    target_link_libraries(installed_mapi_probe PRIVATE -static-libgcc -static-libstdc++)
    target_link_options(installed_mapi_probe PRIVATE -static)
endif()

# Set output directory
set_target_properties(go-mapi-test-harness PROPERTIES
    RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/bin"
)
set_target_properties(installed_mapi_probe PROPERTIES
    RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/bin"
)
