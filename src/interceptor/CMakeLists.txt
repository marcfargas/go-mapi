cmake_minimum_required(VERSION 3.16)
project(go-mapi-interceptor)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# Version — injected at build time (default if not passed via -D)
if(NOT DEFINED GO_MAPI_VERSION)
    set(GO_MAPI_VERSION "0.0.0-dev")
endif()

# Build options
option(BUILD_TESTS "Build test harness" ON)

# CPPTEST-01: enable CTest so add_subdirectory(tests) can register the
# doctest message_converter_tests target with `ctest --output-on-failure`.
enable_testing()

# ============================================================
# message_converter OBJECT library (FOUND-05)
# ------------------------------------------------------------
# Pure MAPI→MailMessage conversion logic extracted from MapiImpl
# so it can be linked by BOTH the go-mapi DLL AND the future
# doctest target (CPPTEST-01/02/03 in Phase 4) without recompiling.
# ============================================================
add_library(message_converter_obj OBJECT
    message_converter.cpp
)

target_include_directories(message_converter_obj PUBLIC
    "${CMAKE_CURRENT_SOURCE_DIR}"
)

target_compile_definitions(message_converter_obj PRIVATE
    GO_MAPI_VERSION="${GO_MAPI_VERSION}"
)

# Propagate the same compiler flags as the DLL target so the object files
# are ABI-compatible. MSVC /W4 and MinGW -Wall are purely compile-time,
# object files themselves are compatible either way.
if(MSVC)
    target_compile_options(message_converter_obj PRIVATE /W4 /WX-)
elseif(MINGW)
    target_compile_options(message_converter_obj PRIVATE -Wall -Wextra -Wno-unused-parameter)
endif()

# Create the DLL
add_library(go-mapi SHARED
    main.cpp
    mapi_impl.cpp
    json_writer.cpp
    fs_utils.cpp
    $<TARGET_OBJECTS:message_converter_obj>
)

# Set DLL output directory
set_target_properties(go-mapi PROPERTIES
    LIBRARY_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/bin"
    RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/bin"
    PREFIX ""  # Avoid "lib" prefix on MinGW
)

# Include directories
target_include_directories(go-mapi PRIVATE
    "${CMAKE_CURRENT_SOURCE_DIR}"
)

# Inject version as compile definition
target_compile_definitions(go-mapi PRIVATE
    GO_MAPI_VERSION="${GO_MAPI_VERSION}"
)

# Platform-specific settings
if(MSVC)
    # MSVC specific options
    target_compile_options(go-mapi PRIVATE /W4 /WX-)
    target_link_libraries(go-mapi PRIVATE kernel32.lib user32.lib)
    set_target_properties(go-mapi PROPERTIES
        LINK_FLAGS "/DEF:\"${CMAKE_CURRENT_SOURCE_DIR}/mapi_exports.def\""
    )
elseif(MINGW)
    # MinGW specific options
    target_compile_options(go-mapi PRIVATE -Wall -Wextra -Wno-unused-parameter)
    target_link_libraries(go-mapi PRIVATE kernel32 user32 -static-libgcc -static-libstdc++)
    set_target_properties(go-mapi PROPERTIES
        LINK_FLAGS "-Wl,--output-def,${CMAKE_BINARY_DIR}/bin/go-mapi.def -static"
    )
    # Export symbols using the .def file
    target_sources(go-mapi PRIVATE mapi_exports.def)
endif()

# Add the test harness and the doctest-based unit tests (CPPTEST-01).
if(BUILD_TESTS)
    add_subdirectory(test-harness)
    add_subdirectory(tests)
endif()

# Summary
message(STATUS "")
message(STATUS "go-mapi Interceptor Build Configuration")
message(STATUS "========================================")
message(STATUS "Compiler: ${CMAKE_CXX_COMPILER_ID}")
message(STATUS "Build Tests: ${BUILD_TESTS}")
message(STATUS "")
