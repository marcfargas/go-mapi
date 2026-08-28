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
)

add_dependencies(go-mapi-test-harness go-mapi)

# Include directories (interceptor is now parent directory)
target_include_directories(go-mapi-test-harness PRIVATE
    "${CMAKE_CURRENT_SOURCE_DIR}/.."
)

# Platform-specific settings
if(MSVC)
    target_compile_options(go-mapi-test-harness PRIVATE /W4 /WX-)
    target_link_libraries(go-mapi-test-harness PRIVATE kernel32.lib user32.lib shell32.lib)
elseif(MINGW)
    target_compile_options(go-mapi-test-harness PRIVATE -Wall -Wextra -Wno-unused-parameter)
    target_link_libraries(go-mapi-test-harness PRIVATE kernel32 user32 shell32 -static-libgcc -static-libstdc++)
    target_link_options(go-mapi-test-harness PRIVATE -static)
endif()

# Set output directory
set_target_properties(go-mapi-test-harness PROPERTIES
    RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/bin"
)
