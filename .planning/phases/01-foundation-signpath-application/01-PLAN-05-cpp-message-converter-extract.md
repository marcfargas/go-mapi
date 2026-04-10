---
phase: 01-foundation-signpath-application
plan: 05
type: execute
wave: 1
depends_on: []
files_modified:
  - src/interceptor/message_converter.h
  - src/interceptor/message_converter.cpp
  - src/interceptor/mapi_impl.h
  - src/interceptor/mapi_impl.cpp
  - src/interceptor/CMakeLists.txt
autonomous: true
requirements: [FOUND-05]

must_haves:
  truths:
    - "Pure message-conversion logic lives in src/interceptor/message_converter.{h,cpp} as free functions or a non-template class in namespace go_mapi::message_converter"
    - "The extracted functions are PUBLIC (not hidden inside a private MapiImpl member) so a future doctest binary can call them directly"
    - "MapiImpl in mapi_impl.cpp delegates to message_converter for all ANSI/Wide MAPI→MailMessage conversion"
    - "The DLL still builds and links successfully with the extracted object file"
    - "CMakeLists.txt structures message_converter.cpp as an OBJECT library (or equivalent) so a future BUILD_TESTS=ON doctest target can consume it without recompiling"
  artifacts:
    - path: "src/interceptor/message_converter.h"
      provides: "Public declarations of MAPI→MailMessage conversion functions"
      contains: "namespace go_mapi"
    - path: "src/interceptor/message_converter.cpp"
      provides: "Pure conversion logic implementation — no DLL, no file I/O, no windows.h exports"
      contains: "ConvertAnsiMessage"
    - path: "src/interceptor/CMakeLists.txt"
      provides: "OBJECT library wiring so go-mapi.dll and a future test binary share the same compiled message_converter.o"
      contains: "OBJECT"
  key_links:
    - from: "MapiImpl::MAPISendMailA (mapi_impl.cpp)"
      to: "message_converter::ConvertAnsiMessage (message_converter.cpp)"
      via: "direct function call after mapi_impl extracts the conversion"
      pattern: "message_converter::ConvertAnsi|go_mapi::message_converter"
    - from: "CMakeLists.txt go-mapi target"
      to: "message_converter_obj OBJECT library"
      via: "target_link_libraries or target_sources with $<TARGET_OBJECTS:message_converter_obj>"
      pattern: "OBJECT|TARGET_OBJECTS"
---

<objective>
Extract the pure MAPI→MailMessage conversion logic (currently living as **private** methods inside `MapiImpl` in `src/interceptor/mapi_impl.cpp`) into a new public `src/interceptor/message_converter.{h,cpp}` module. The DLL (`go-mapi`) continues to work unchanged from the consumer's perspective. CMakeLists.txt is restructured so `message_converter.cpp` is compiled into an OBJECT library that both the DLL and a future `BUILD_TESTS=ON` doctest binary can link against without recompiling.

Purpose: Unblocks CPPTEST-01/02/03 in Phase 4 — doctest tests for ANSI/Wide conversion, recipient address normalization (SMTP:/smtp:/MAILTO:/mailto:/plain), null/empty fields, and UTF-8 bodies. Currently those functions are `private` members of `MapiImpl` and cannot be called from tests without friend declarations or test-only header manipulation.
Output: A new public `message_converter` module, a refactored `mapi_impl.cpp` that delegates to it, and an OBJECT library-based CMakeLists.txt.
</objective>

<execution_context>
This plan implements FOUND-05 from REQUIREMENTS.md. Decisions are locked in `01-CONTEXT.md` section `### FOUND-05 (C++ message_converter extraction)`:
- New files: `src/interceptor/message_converter.h` and `src/interceptor/message_converter.cpp`
- Extract: functions that convert MAPI `lpMapiMessage` / `lpMapiMessageW` into the internal JSON structure — recipient normalization, ANSI/Wide handling, body content extraction
- Stay in DLL glue: DLL entry point, `MAPISendMail`/`MAPISendMailW` exports, file I/O, logging
- CMake: `message_converter.cpp` compiled so a future `BUILD_TESTS=ON` target can link it into a doctest binary without recompilation
- No tests yet — CPPTEST-01/02/03 in Phase 4 consume this

**Planner note (verify-before-assuming):** The REQUIREMENTS.md text says "extracted from `src/interceptor/main.cpp`" but the actual conversion logic currently lives in `src/interceptor/mapi_impl.cpp` (lines 55-68 of `mapi_impl.h` show the private member declarations: `ConvertAnsiMessage`, `ConvertWideMessage`, `WideToUtf8`, `AnsiToUtf8`, `FilenameFromPath`, `GetOriginApplicationName`). `main.cpp` is already a thin 81-line DLL glue file. The requirement's wording is slightly stale relative to the current code layout, but the intent is clear from CONTEXT.md: make the pure conversion functions public so tests can reach them. This plan extracts from `mapi_impl.cpp`, not `main.cpp`.

**Special constraint 8 from the phase planning context:** "CMake change must structure the target so `message_converter.cpp` is compiled into a static object that can be consumed by BOTH the DLL target and a future `BUILD_TESTS=ON` doctest target without recompilation duplication. Use an OBJECT library or INTERFACE library pattern." → Use `add_library(message_converter_obj OBJECT ...)` and reference via `$<TARGET_OBJECTS:message_converter_obj>`.
</execution_context>

<context>
@.planning/PROJECT.md
@.planning/phases/01-foundation-signpath-application/01-CONTEXT.md
@src/interceptor/main.cpp
@src/interceptor/mapi_impl.h
@src/interceptor/mapi_impl.cpp
@src/interceptor/mapi_types.h
@src/interceptor/json_writer.h
@src/interceptor/CMakeLists.txt

<interfaces>
<!-- Extracted from mapi_impl.h — the private members currently holding conversion logic -->

From src/interceptor/mapi_impl.h lines 55-68 (private section of MapiImpl):
```cpp
private:
    // Convert ANSI MapiMessage to MailMessage struct
    static MailMessage ConvertAnsiMessage(const MapiMessage& msg);

    // Convert Unicode (wide) MapiMessageW to MailMessage struct
    static MailMessage ConvertWideMessage(const MapiMessageW& msg);

    // Convert wide string (UTF-16) to UTF-8
    static std::string WideToUtf8(const wchar_t* wide);
    static std::string AnsiToUtf8(const char* ansi);
    static std::string FilenameFromPath(const std::string& path);

    // Get application name (for originApp field)
    static std::string GetOriginApplicationName();
```

**Which functions to extract (pure conversion — no Windows calls except UTF-16/UTF-8 string conversion):**
- `ConvertAnsiMessage(const MapiMessage&) -> MailMessage` — YES, extract (pure)
- `ConvertWideMessage(const MapiMessageW&) -> MailMessage` — YES, extract (pure)
- `WideToUtf8(const wchar_t*) -> std::string` — YES, extract (pure UTF-16→UTF-8, may use WideCharToMultiByte but that's a standard conversion)
- `AnsiToUtf8(const char*) -> std::string` — YES, extract (pure)
- `FilenameFromPath(const std::string&) -> std::string` — YES, extract (pure string manipulation)

**Which functions to KEEP in MapiImpl (platform/process-specific):**
- `GetOriginApplicationName() -> std::string` — KEEP (calls `GetModuleFileNameA` or similar Windows API to get the calling process name; this is not pure conversion and is untestable without a live process)

**CMakeLists.txt current structure (lines 15-22):**
```cmake
add_library(go-mapi SHARED
    main.cpp
    mapi_impl.cpp
    json_writer.cpp
    fs_utils.cpp
)
```

This must become:
```cmake
# OBJECT library for pure conversion logic — shared between the DLL and future doctest targets
add_library(message_converter_obj OBJECT
    message_converter.cpp
)
target_include_directories(message_converter_obj PUBLIC
    "${CMAKE_CURRENT_SOURCE_DIR}"
)
target_compile_definitions(message_converter_obj PRIVATE
    GO_MAPI_VERSION="${GO_MAPI_VERSION}"
)

# The DLL target consumes the object library
add_library(go-mapi SHARED
    main.cpp
    mapi_impl.cpp
    json_writer.cpp
    fs_utils.cpp
    $<TARGET_OBJECTS:message_converter_obj>
)
```

A future Phase 4 CPPTEST-01/02/03 plan will add:
```cmake
if(BUILD_TESTS)
    add_executable(message_converter_tests
        tests/message_converter_tests.cpp
        $<TARGET_OBJECTS:message_converter_obj>
    )
    # ... doctest include, target_link_libraries ...
endif()
```
without recompiling `message_converter.cpp`. This is the test-compatibility win from OBJECT libraries.
</interfaces>
</context>

<tasks>

<task type="auto" tdd="false">
  <name>Task 1: Create message_converter.h with public declarations of pure conversion functions</name>
  <files>src/interceptor/message_converter.h</files>
  <read_first>
    - src/interceptor/mapi_impl.h (full file — understand which functions to extract)
    - src/interceptor/mapi_impl.cpp (full file — read the implementations of ConvertAnsiMessage, ConvertWideMessage, WideToUtf8, AnsiToUtf8, FilenameFromPath to confirm they are indeed pure and understand their exact signatures and return types)
    - src/interceptor/mapi_types.h (understand MapiMessage, MapiMessageW, MailMessage, Recipient types referenced by the signatures)
    - src/interceptor/json_writer.h (confirm whether the conversion functions return a struct that is then serialized separately, or whether they serialize inline)
  </read_first>
  <action>
    Create `src/interceptor/message_converter.h` with public declarations of the pure conversion functions. Use a nested namespace `go_mapi::message_converter` so the API is clearly separated from the existing `go_mapi::MapiImpl` class:

    ```cpp
    #pragma once

    #include <string>
    #include "mapi_types.h"

    namespace go_mapi {
    namespace message_converter {

    // Convert an ANSI MAPI message to the internal MailMessage representation.
    // Pure conversion — no file I/O, no DLL entry points, no global state.
    // Callable from tests via the FOUND-05 OBJECT library target.
    MailMessage ConvertAnsiMessage(const MapiMessage& msg);

    // Convert a Unicode (wide) MAPI message to the internal MailMessage representation.
    // Pure conversion — no file I/O, no DLL entry points, no global state.
    MailMessage ConvertWideMessage(const MapiMessageW& msg);

    // Convert a wide (UTF-16) C string to UTF-8.
    // Returns empty string for nullptr input.
    std::string WideToUtf8(const wchar_t* wide);

    // Convert an ANSI C string to UTF-8 (passthrough if already ASCII).
    // Returns empty string for nullptr input.
    std::string AnsiToUtf8(const char* ansi);

    // Extract the filename portion of a path (basename).
    // Pure string manipulation — handles both forward and backward slashes.
    std::string FilenameFromPath(const std::string& path);

    } // namespace message_converter
    } // namespace go_mapi
    ```

    **Scope discipline:**
    - Do NOT add any new functions beyond those listed above
    - Do NOT declare `GetOriginApplicationName` here — it stays in MapiImpl (calls Windows API to inspect the calling process)
    - Do NOT create a class — use free functions in the nested namespace for simplicity and testability
    - Do NOT include `<windows.h>` in this header — forward-declare only what is needed via `mapi_types.h`
    - The header must be includable by both `mapi_impl.cpp` AND a future `tests/message_converter_tests.cpp` without any Windows DLL-specific includes
  </action>
  <verify>
    <automated>test -f src/interceptor/message_converter.h && grep -c "namespace message_converter" src/interceptor/message_converter.h</automated>
  </verify>
  <acceptance_criteria>
    - File `src/interceptor/message_converter.h` exists
    - Contains `namespace go_mapi` and nested `namespace message_converter` declarations (grep: `grep -c "namespace message_converter" src/interceptor/message_converter.h` returns at least 1)
    - Declares exactly 5 free functions: `ConvertAnsiMessage`, `ConvertWideMessage`, `WideToUtf8`, `AnsiToUtf8`, `FilenameFromPath` (grep for each function name returns at least 1 match)
    - Does NOT include `<windows.h>` directly (grep: `grep -n "#include <windows" src/interceptor/message_converter.h` returns no matches — transitive includes via mapi_types.h are acceptable)
    - Does NOT declare `GetOriginApplicationName`, `MAPISendMailA`, or any DLL-export-related function (grep: `grep -n "GetOriginApplicationName\|MAPISendMail" src/interceptor/message_converter.h` returns no matches)
  </acceptance_criteria>
  <done>
    Public header exists declaring exactly the pure conversion functions, nested namespace used, no Windows DLL machinery leaked into the interface.
  </done>
</task>

<task type="auto" tdd="false">
  <name>Task 2: Create message_converter.cpp implementing the pure conversion functions</name>
  <files>src/interceptor/message_converter.cpp, src/interceptor/mapi_impl.h, src/interceptor/mapi_impl.cpp</files>
  <read_first>
    - src/interceptor/mapi_impl.cpp (full file — all 288 lines, especially the bodies of ConvertAnsiMessage, ConvertWideMessage, WideToUtf8, AnsiToUtf8, FilenameFromPath)
    - src/interceptor/mapi_impl.h (full file — the MapiImpl class definition you will be editing)
    - src/interceptor/message_converter.h (the header you created in Task 1)
  </read_first>
  <action>
    Create `src/interceptor/message_converter.cpp` and MOVE (not copy) the implementations of the 5 listed functions out of `mapi_impl.cpp` into it:

    ```cpp
    #include "message_converter.h"
    // Additional standard/platform includes required by the moved function bodies
    // (e.g. <windows.h> for WideCharToMultiByte if WideToUtf8 uses it, <algorithm> for std::replace, etc.)
    // Add only what is actually needed by the moved code — do not speculatively include headers.

    namespace go_mapi {
    namespace message_converter {

    // --- Paste the exact bodies of ConvertAnsiMessage, ConvertWideMessage, WideToUtf8,
    //     AnsiToUtf8, and FilenameFromPath here, with the following adjustments:
    //     1. Change "MapiImpl::FunctionName" to "FunctionName" (they are no longer members)
    //     2. If any of them called another member (e.g. ConvertAnsiMessage calling AnsiToUtf8),
    //        replace "MapiImpl::" with nothing — the call becomes an unqualified call within
    //        the same namespace, which resolves correctly.
    //     3. Do NOT alter any conversion logic. This is a cut-and-paste, not a rewrite.

    } // namespace message_converter
    } // namespace go_mapi
    ```

    Then update `src/interceptor/mapi_impl.h` to:
    1. REMOVE the 5 private member declarations (`ConvertAnsiMessage`, `ConvertWideMessage`, `WideToUtf8`, `AnsiToUtf8`, `FilenameFromPath`)
    2. KEEP `GetOriginApplicationName` as a private member (it stays in MapiImpl — uses Windows process APIs)
    3. Add `#include "message_converter.h"` if MapiImpl call sites need direct access (alternative: include only in mapi_impl.cpp — preferred, see below)

    Then update `src/interceptor/mapi_impl.cpp` to:
    1. REMOVE the 5 function body definitions you moved out
    2. Add `#include "message_converter.h"` at the top
    3. Update every internal call site from `MapiImpl::ConvertAnsiMessage(msg)` / `ConvertAnsiMessage(msg)` / etc. to `message_converter::ConvertAnsiMessage(msg)` (or `using namespace go_mapi::message_converter;` at file scope if preferred — either is acceptable, pick whichever keeps the diff smallest)

    **Scope discipline:**
    - Do NOT change conversion logic in any way — this is a mechanical move
    - Do NOT rename any function
    - Do NOT change any function signature
    - Do NOT add error handling, logging, or validation that was not already there
    - Do NOT touch `main.cpp`, `json_writer.cpp`, `fs_utils.cpp`, or any header besides `mapi_impl.h` and `message_converter.h`
    - Keep `GetOriginApplicationName` inside `MapiImpl` — it is process-specific and does not belong in pure conversion

    After the moves, `mapi_impl.cpp` should be noticeably shorter (by roughly 100-200 lines depending on function body sizes), and `message_converter.cpp` should contain the moved code verbatim except for the namespace change.
  </action>
  <verify>
    <automated>test -f src/interceptor/message_converter.cpp && grep -c "namespace message_converter" src/interceptor/message_converter.cpp && ! grep -n "MapiImpl::ConvertAnsiMessage\|MapiImpl::ConvertWideMessage\|MapiImpl::WideToUtf8\|MapiImpl::AnsiToUtf8\|MapiImpl::FilenameFromPath" src/interceptor/mapi_impl.cpp</automated>
  </verify>
  <acceptance_criteria>
    - File `src/interceptor/message_converter.cpp` exists
    - Contains `namespace go_mapi { namespace message_converter {` wrapping (grep: `grep -c "namespace message_converter" src/interceptor/message_converter.cpp` returns at least 1)
    - Contains definitions of all 5 moved functions (grep for `ConvertAnsiMessage`, `ConvertWideMessage`, `WideToUtf8`, `AnsiToUtf8`, `FilenameFromPath` each returns at least 1 match in message_converter.cpp)
    - `src/interceptor/mapi_impl.h` no longer declares `ConvertAnsiMessage`, `ConvertWideMessage`, `WideToUtf8`, `AnsiToUtf8`, `FilenameFromPath` as members of `MapiImpl` (grep: `grep -n "MapiImpl\|ConvertAnsiMessage\|ConvertWideMessage" src/interceptor/mapi_impl.h` — the 5 function names should only appear in the class if at all, but ideally not at all; verify by reading the file that they are removed from the `private:` section)
    - `src/interceptor/mapi_impl.h` STILL declares `GetOriginApplicationName` (grep: `grep -n "GetOriginApplicationName" src/interceptor/mapi_impl.h` returns at least 1 match)
    - `src/interceptor/mapi_impl.cpp` no longer contains the function body definitions `MapiImpl::ConvertAnsiMessage`, `MapiImpl::ConvertWideMessage`, `MapiImpl::WideToUtf8`, `MapiImpl::AnsiToUtf8`, `MapiImpl::FilenameFromPath` (grep: `grep -n "MapiImpl::ConvertAnsiMessage\|MapiImpl::ConvertWideMessage\|MapiImpl::WideToUtf8\|MapiImpl::AnsiToUtf8\|MapiImpl::FilenameFromPath" src/interceptor/mapi_impl.cpp` returns NO matches)
    - `src/interceptor/mapi_impl.cpp` now calls into the `message_converter` namespace (grep: `grep -n "message_converter::" src/interceptor/mapi_impl.cpp` returns at least 2 matches — at minimum inside `MAPISendMailA` and `MAPISendMailW`)
    - `src/interceptor/mapi_impl.cpp` includes `message_converter.h` (grep: `grep -n "#include \"message_converter.h\"" src/interceptor/mapi_impl.cpp` returns 1 match)
    - Line count of `mapi_impl.cpp` is lower than the original 288 lines (evidence that code was removed, not copied)
    - `src/interceptor/main.cpp` is NOT modified in this task (diff shows zero changes)
    - `src/interceptor/CMakeLists.txt` is NOT modified in this task (Task 3 owns that)
  </acceptance_criteria>
  <done>
    Pure conversion functions moved verbatim from MapiImpl (private) into a public `message_converter` namespace in a new .cpp file. mapi_impl.cpp delegates via unqualified/qualified calls. No logic changes.
  </done>
</task>

<task type="auto" tdd="false">
  <name>Task 3: Restructure CMakeLists.txt to use an OBJECT library for message_converter</name>
  <files>src/interceptor/CMakeLists.txt</files>
  <read_first>
    - src/interceptor/CMakeLists.txt (full file — understand the current go-mapi SHARED target, include directories, compile definitions, MSVC/MinGW branches)
    - src/interceptor/test-harness/CMakeLists.txt if present (so the existing test harness is not broken by the restructure) — use `ls` first to check
  </read_first>
  <action>
    Restructure `src/interceptor/CMakeLists.txt` so `message_converter.cpp` is compiled into an OBJECT library that the DLL consumes and a future BUILD_TESTS=ON doctest target can also link against without recompiling. The existing `BUILD_TESTS` option already defaults to ON and points at `test-harness/` — do not touch the test-harness subdirectory wiring, just make sure the OBJECT library is reachable from both the DLL and any future sibling target.

    Apply these changes (preserving the rest of the file verbatim):

    **Change 1 — Before the `add_library(go-mapi SHARED ...)` declaration, add the OBJECT library:**
    ```cmake
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
    ```

    **Change 2 — Modify the `add_library(go-mapi SHARED ...)` call to include the object files:**

    Before:
    ```cmake
    add_library(go-mapi SHARED
        main.cpp
        mapi_impl.cpp
        json_writer.cpp
        fs_utils.cpp
    )
    ```

    After:
    ```cmake
    add_library(go-mapi SHARED
        main.cpp
        mapi_impl.cpp
        json_writer.cpp
        fs_utils.cpp
        $<TARGET_OBJECTS:message_converter_obj>
    )
    ```

    **Change 3 — Do NOT touch:**
    - The `set_target_properties(go-mapi PROPERTIES ...)` block
    - The MSVC/MinGW branches that configure link flags, .def files, output paths
    - The `target_include_directories(go-mapi PRIVATE ...)` block — the DLL already has this, and the OBJECT library now has its own PUBLIC include dir, which propagates via `$<TARGET_OBJECTS:...>` (this is the standard CMake pattern).
    - The `target_compile_definitions(go-mapi PRIVATE GO_MAPI_VERSION="${GO_MAPI_VERSION}")` block
    - The `if(BUILD_TESTS) add_subdirectory(test-harness) endif()` block at the bottom — the existing test harness continues to work unchanged
    - The summary message block

    **Scope discipline:**
    - Do NOT add a doctest target in this plan — CPPTEST-01 in Phase 4 owns that work
    - Do NOT add test sources now — the `message_converter_obj` OBJECT library just has to be reachable for future tests
    - Do NOT rename the existing `go-mapi` target
    - Do NOT change CMake minimum version
    - Do NOT add find_package calls

    After the change, running cmake configure + build must produce `go-mapi.dll` exactly as before. The DLL should be byte-equivalent to before the refactor (modulo changes introduced in Task 2 — the message_converter symbols now live in a separately-compiled object file, but linker output should be functionally identical).
  </action>
  <verify>
    <automated>cd src/interceptor && rm -rf build-verify && cmake -B build-verify -G "MinGW Makefiles" -DBUILD_TESTS=OFF && cmake --build build-verify --target go-mapi && test -f build-verify/bin/go-mapi.dll && rm -rf build-verify</automated>
  </verify>
  <acceptance_criteria>
    - `src/interceptor/CMakeLists.txt` contains `add_library(message_converter_obj OBJECT message_converter.cpp)` (grep: `grep -n "add_library(message_converter_obj OBJECT" src/interceptor/CMakeLists.txt` returns 1 match)
    - `src/interceptor/CMakeLists.txt` contains `$<TARGET_OBJECTS:message_converter_obj>` inside the `add_library(go-mapi SHARED ...)` sources list (grep: `grep -n "TARGET_OBJECTS:message_converter_obj" src/interceptor/CMakeLists.txt` returns 1 match)
    - The existing `go-mapi SHARED` target still lists `main.cpp mapi_impl.cpp json_writer.cpp fs_utils.cpp` as sources (grep: each filename returns at least 1 match in the add_library block)
    - The `BUILD_TESTS` option and `add_subdirectory(test-harness)` are unchanged (grep returns same matches as before)
    - The `target_include_directories(go-mapi PRIVATE ...)` block is unchanged
    - The `target_compile_definitions(go-mapi PRIVATE GO_MAPI_VERSION=...)` block is unchanged
    - Running `cmake -B build-verify -DBUILD_TESTS=OFF` from `src/interceptor/` succeeds with no errors
    - Running `cmake --build build-verify --target go-mapi` produces `build-verify/bin/go-mapi.dll`
    - The DLL exports are preserved — check the .def file generation at `build-verify/bin/go-mapi.def` (MinGW only) or equivalent MSVC output lists `MAPISendMail`, `MAPISendMailW`, `MAPILogon`, `MAPILogoff`, `MAPIFreeBuffer`, `MAPISendDocuments`
  </acceptance_criteria>
  <done>
    CMakeLists.txt uses an OBJECT library for message_converter.cpp, the DLL target consumes the object files via TARGET_OBJECTS, a clean build from a fresh build directory produces go-mapi.dll successfully, and a future doctest target can link $<TARGET_OBJECTS:message_converter_obj> without recompilation.
  </done>
</task>

</tasks>

<verification>
- `cmake -B build` from `src/interceptor/` succeeds (both with and without `-DBUILD_TESTS=ON`)
- `cmake --build build --target go-mapi` produces `build/bin/go-mapi.dll`
- DLL exports are preserved (MAPISendMail, MAPISendMailW, MAPILogon, MAPILogoff, MAPIFreeBuffer, MAPISendDocuments)
- `message_converter.h` declares exactly 5 public free functions in `go_mapi::message_converter` namespace
- `message_converter.cpp` implements all 5 with bodies verbatim-moved from `mapi_impl.cpp`
- `mapi_impl.cpp` is shorter than before (evidence of move, not copy)
- `main.cpp` is unchanged
- `json_writer.{h,cpp}`, `fs_utils.{h,cpp}`, `mapi_types.h` are unchanged
</verification>

<success_criteria>
- Pure conversion functions live in a new public `message_converter` module
- DLL builds and links successfully with the extracted object file
- OBJECT library pattern allows future doctest target to link without recompiling
- No logic changes (mechanical move only)
- Existing test-harness subdirectory wiring is unchanged
- CMake MSVC/MinGW branches preserved
</success_criteria>

<output>
After completion, create `.planning/phases/01-foundation-signpath-application/01-05-SUMMARY.md` documenting:
- The exact list of functions extracted (5 functions)
- The functions explicitly kept in MapiImpl and why (GetOriginApplicationName = Windows process API)
- The OBJECT library CMake pattern used
- Line count of mapi_impl.cpp before and after the move (evidence of size reduction)
- Confirmation that a clean cmake configure + build still produces go-mapi.dll with all exports
- Confirmation that main.cpp, json_writer.cpp, fs_utils.cpp were not touched
</output>
