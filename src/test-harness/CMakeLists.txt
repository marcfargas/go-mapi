cmake_minimum_required(VERSION 3.16)
project(go-mapi-test-harness)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# Create the test harness executable
add_executable(go-mapi-test-harness
    test_utils.cpp
    src/main.cpp
    src/test_simple_send.cpp
    src/test_with_attachments.cpp
    src/test_unicode.cpp
    src/test_multiple_recipients.cpp
)

# Link against Windows libraries
target_link_libraries(go-mapi-test-harness PRIVATE
    kernel32.lib
    user32.lib
)

# Include directories
target_include_directories(go-mapi-test-harness PRIVATE
    "${CMAKE_CURRENT_SOURCE_DIR}/../interceptor"
)

# MSVC specific options
if(MSVC)
    target_compile_options(go-mapi-test-harness PRIVATE /W4 /WX-)
endif()

# Set output directory
set_target_properties(go-mapi-test-harness PROPERTIES
    RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/bin"
)
