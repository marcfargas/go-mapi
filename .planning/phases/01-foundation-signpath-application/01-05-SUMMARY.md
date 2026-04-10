---
phase: 01-foundation-signpath-application
plan: 05
subsystem: interceptor
tags: [cpp, cmake, refactor, testability, object-library, mapi]

# Dependency graph
requires:
  - phase: 00-initialization
    provides: existing MapiImpl C++ interceptor with private conversion helpers
provides:
  - Public message_converter module with pure MAPI→MailMessage conversion functions
  - OBJECT library CMake pattern enabling doctest targets to link without recompilation
  - Testable surface for CPPTEST-01/02/03 (Phase 4) without friend declarations
affects: [phase-04-testing, CPPTEST-01, CPPTEST-02, CPPTEST-03]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "CMake OBJECT library for test-friendly code sharing between DLL and future test binaries"
    - "Namespace-scoped free functions (go_mapi::message_converter::*) for pure, testable logic"

key-files:
  created:
    - src/interceptor/message_converter.h
    - src/interceptor/message_converter.cpp
  modified:
    - src/interceptor/mapi_impl.h
    - src/interceptor/mapi_impl.cpp
    - src/interceptor/CMakeLists.txt

key-decisions:
  - "Use free functions in nested namespace go_mapi::message_converter — not a class — for simplicity and direct test access"
  - "Keep GetOriginApplicationName in MapiImpl (Windows process API — not pure conversion)"
  - "Caller (MAPISendMailA/W) populates msg.originApp after calling message_converter — preserves behavior without leaking process APIs into the pure module"
  - "OBJECT library pattern chosen over INTERFACE/static lib — compiles message_converter.cpp exactly once, shareable via \$<TARGET_OBJECTS:message_converter_obj>"

patterns-established:
  - "Pure logic extraction: isolate testable code in nested namespace free functions, keep side-effecting code (Windows APIs, file I/O) in the original class"
  - "CMake OBJECT library for test-sharing: compile once, link into both production DLL and future test binaries"

requirements-completed: [FOUND-05]

# Metrics
duration: 5 min
completed: 2026-04-10
---

# Phase 01 Plan 05: C++ message_converter extraction Summary

**Pure MAPI→MailMessage conversion logic extracted from MapiImpl private members into a public `go_mapi::message_converter` namespace, wired as a CMake OBJECT library so the DLL and future doctest targets share the same compiled object file.**

## Performance

- **Duration:** 5 min
- **Started:** 2026-04-10T15:43:44Z
- **Completed:** 2026-04-10T15:49:07Z
- **Tasks:** 3
- **Files modified:** 5 (2 created, 3 modified)

## Accomplishments

- Created `src/interceptor/message_converter.{h,cpp}` exposing 5 pure conversion functions (`ConvertAnsiMessage`, `ConvertWideMessage`, `WideToUtf8`, `AnsiToUtf8`, `FilenameFromPath`) in the `go_mapi::message_converter` namespace
- Removed the matching 5 private member declarations from `MapiImpl` in `mapi_impl.h` and deleted their bodies from `mapi_impl.cpp`
- Updated `MAPISendMailA`/`MAPISendMailW` in `mapi_impl.cpp` to delegate to `message_converter::Convert*Message(...)` and populate `msg.originApp` in the caller
- Restructured `CMakeLists.txt` to compile `message_converter.cpp` as an OBJECT library (`message_converter_obj`) consumed by the DLL via `$<TARGET_OBJECTS:message_converter_obj>`, ready for future doctest target reuse
- Verified with a clean `cmake -B build-verify -G "MinGW Makefiles" -DBUILD_TESTS=OFF` + `cmake --build build-verify --target go-mapi` that `go-mapi.dll` builds and all 6 MAPI exports (`MAPIFreeBuffer`, `MAPILogon`, `MAPILogoff`, `MAPISendDocuments`, `MAPISendMail`, `MAPISendMailW`) are preserved
- Also verified `BUILD_TESTS=ON` still configures cleanly (test-harness subdirectory wiring untouched)

## Task Commits

Each task was committed atomically:

1. **Task 1: Create message_converter.h** — `1c34abc` (feat)
2. **Task 2: Move implementations into message_converter.cpp** — `6df833e` (refactor)
3. **Task 3: Restructure CMakeLists.txt with OBJECT library** — `d8b604f` (chore)

**Plan metadata:** committed separately via final docs commit

## Files Created/Modified

- `src/interceptor/message_converter.h` (created, 32 lines) — Public declarations of 5 pure conversion functions in `go_mapi::message_converter`
- `src/interceptor/message_converter.cpp` (created, 174 lines) — Implementations moved verbatim from `MapiImpl`, except `originApp` population moved to the caller
- `src/interceptor/mapi_impl.h` (modified) — Removed 5 private member declarations; kept `GetOriginApplicationName` with explanatory comment
- `src/interceptor/mapi_impl.cpp` (modified, 288 → 131 lines, −157) — Deleted moved function bodies; added `#include "message_converter.h"`; `MAPISendMailA`/`MAPISendMailW` now call `message_converter::` and assign `msg.originApp` in the caller
- `src/interceptor/CMakeLists.txt` (modified) — Added `message_converter_obj` OBJECT library, appended `$<TARGET_OBJECTS:message_converter_obj>` to the `go-mapi` SHARED target; left `set_target_properties`, `target_include_directories`, `target_compile_definitions`, MSVC/MinGW branches, `BUILD_TESTS`/test-harness wiring, and summary block untouched

### Functions extracted (5)

| Function | From | To |
|----------|------|----|
| `ConvertAnsiMessage(const MapiMessage&)` | `MapiImpl` private | `go_mapi::message_converter` |
| `ConvertWideMessage(const MapiMessageW&)` | `MapiImpl` private | `go_mapi::message_converter` |
| `WideToUtf8(const wchar_t*)` | `MapiImpl` private | `go_mapi::message_converter` |
| `AnsiToUtf8(const char*)` | `MapiImpl` private | `go_mapi::message_converter` |
| `FilenameFromPath(const std::string&)` | `MapiImpl` private | `go_mapi::message_converter` |

### Functions explicitly kept in MapiImpl (1)

| Function | Reason |
|----------|--------|
| `GetOriginApplicationName()` | Calls `GetCurrentProcess()` / `GetModuleFileNameExW` — inspects the live calling process, not pure conversion. Untestable without a live process context. Caller (`MAPISendMailA/W`) invokes it and assigns to `msg.originApp` after calling the pure converter, preserving behavior. |

### CMake pattern

```cmake
add_library(message_converter_obj OBJECT
    message_converter.cpp
)
# ... include dirs, compile definitions, warning flags ...

add_library(go-mapi SHARED
    main.cpp
    mapi_impl.cpp
    json_writer.cpp
    fs_utils.cpp
    $<TARGET_OBJECTS:message_converter_obj>
)
```

Phase 4 CPPTEST-01/02/03 can now add a doctest target without recompiling:

```cmake
if(BUILD_TESTS)
    add_executable(message_converter_tests
        tests/message_converter_tests.cpp
        $<TARGET_OBJECTS:message_converter_obj>
    )
endif()
```

### Line count evidence (move, not copy)

| File | Before | After | Delta |
|------|--------|-------|-------|
| `mapi_impl.cpp` | 288 | 131 | −157 |
| `message_converter.cpp` | (new) | 174 | +174 |

`mapi_impl.cpp` shrinks by 157 lines. The small delta between `−157` and the `message_converter.cpp` size (174) is explained by added namespace boilerplate, the necessary `#include <windows.h>` re-declaration, and expanded comments in the new file.

### Build verification

- `cmake -B build-verify -G "MinGW Makefiles" -DBUILD_TESTS=OFF` — ✅ configured cleanly
- `cmake --build build-verify --target go-mapi` — ✅ built `build-verify/bin/go-mapi.dll` (2,835,494 bytes)
- `cmake -B build-verify2 -G "MinGW Makefiles" -DBUILD_TESTS=ON` — ✅ configured cleanly (test-harness subdir untouched)
- DLL exports (from `go-mapi.def`): `MAPIFreeBuffer`, `MAPILogoff`, `MAPILogon`, `MAPISendDocuments`, `MAPISendMail`, `MAPISendMailW` — all 6 preserved
- Build directories cleaned after verification

### Files not touched (as required)

- `src/interceptor/main.cpp` — unchanged
- `src/interceptor/json_writer.h` / `json_writer.cpp` — unchanged
- `src/interceptor/fs_utils.h` / `fs_utils.cpp` — unchanged
- `src/interceptor/mapi_types.h` — unchanged
- `src/interceptor/mapi_exports.def` — unchanged
- `src/interceptor/test-harness/` — unchanged

## Decisions Made

- **Free functions over a class** — `go_mapi::message_converter::ConvertAnsiMessage(...)` is called directly from tests without instantiating any object or navigating a `friend` relationship.
- **`GetOriginApplicationName` stays in `MapiImpl`** — it queries the live process via `GetModuleFileNameExW`, which is not pure conversion and is untestable without an ambient process context. The DLL entry point now assigns `msg.originApp = GetOriginApplicationName()` in the caller after the pure converter runs. Net behavior is identical.
- **OBJECT library (not STATIC / INTERFACE)** — compiles `message_converter.cpp` exactly once, and `$<TARGET_OBJECTS:message_converter_obj>` lets both the DLL and a future test executable link the same object file without duplication. Matches the constraint from the phase planning context.
- **Namespace `go_mapi::message_converter`** — nested under `go_mapi` to match the existing `go_mapi::MapiImpl`/`go_mapi::JsonWriter` naming, keeping the public C++ API coherent.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 2 - Missing Critical] Moved `originApp` population from converter into DLL caller**
- **Found during:** Task 2 (moving `ConvertAnsiMessage` / `ConvertWideMessage` bodies verbatim)
- **Issue:** The original `MapiImpl::ConvertAnsiMessage` set `result.originApp = GetOriginApplicationName();` as its first line. `GetOriginApplicationName` is explicitly kept in `MapiImpl` (Windows process API, not pure). A verbatim move would leave the pure module calling a function that no longer exists in its namespace, **or** would drag `GetOriginApplicationName` into the pure module and violate the testability goal (the whole point of the extraction is that tests can call the converter without a live process context).
- **Fix:** Removed the `originApp` assignment from `message_converter::ConvertAnsiMessage` / `ConvertWideMessage` bodies (replaced with a comment pointing to the caller). `MapiImpl::MAPISendMailA` and `MAPISendMailW` now assign `msg.originApp = GetOriginApplicationName();` immediately after calling the pure converter, preserving the wire-format behavior.
- **Files modified:** `src/interceptor/message_converter.cpp`, `src/interceptor/mapi_impl.cpp`
- **Verification:** Runtime behavior unchanged — the JSON written by `JsonWriter::WriteMailToFile(msg)` still contains a populated `originApp` field. Build verified with clean cmake configure + build producing `go-mapi.dll` with all exports intact.
- **Committed in:** `6df833e` (Task 2 commit)

---

**Total deviations:** 1 auto-fixed (1 missing critical)
**Impact on plan:** Necessary to preserve end-to-end behavior while keeping the pure module free of Windows process-context APIs. This was implicit in the plan's constraint that `GetOriginApplicationName` stays in `MapiImpl` — the plan text said "move the 5 functions verbatim" and "keep `GetOriginApplicationName` in `MapiImpl`", which are mutually satisfied only by relocating the `originApp` assignment to the caller. No scope creep; strictly minimal diff.

## Issues Encountered

None. Pre-existing compiler warnings in `json_writer.h` (multi-line comment at line 36) and `mapi_impl.cpp` / `fs_utils.cpp` (`#pragma comment` ignored on MinGW) were observed during the build verification but are out of scope — they existed before this plan and are not caused by the extraction.

## User Setup Required

None - no external service configuration required.

## Next Phase Readiness

- Phase 4 CPPTEST-01/02/03 (doctest tests for ANSI/Wide conversion, recipient normalization, null/empty fields, UTF-8 bodies) is now unblocked — the target functions are public, live in a testable module, and the CMake OBJECT library is ready to be linked into a sibling doctest binary.
- Remaining Phase 1 plans (`01-02`, `01-04`, `01-06`, `01-07`, `01-08`) are unaffected by this change.
- No blockers introduced.

## Self-Check

Verifying claims in this SUMMARY before declaring the plan complete.

### Files exist

- `src/interceptor/message_converter.h` — FOUND
- `src/interceptor/message_converter.cpp` — FOUND
- `src/interceptor/mapi_impl.h` — FOUND (modified)
- `src/interceptor/mapi_impl.cpp` — FOUND (modified)
- `src/interceptor/CMakeLists.txt` — FOUND (modified)

### Commits exist

- `1c34abc` (Task 1) — FOUND
- `6df833e` (Task 2) — FOUND
- `d8b604f` (Task 3) — FOUND

## Self-Check: PASSED

---
*Phase: 01-foundation-signpath-application*
*Completed: 2026-04-10*
