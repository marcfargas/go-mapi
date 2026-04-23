# build.ps1
# Build script for go-mapi interceptor using mingw-mstorsjo-llvm-ucrt
# (triple-prefixed clang driver — x86_64-w64-mingw32-clang[++] or
#  i686-w64-mingw32-clang[++]).
#
# Usage: .\build.ps1 [-Arch x64|x86] [-Config Release] [-Tests] [-Clean]
#
# Why triple-prefixed clang (QUICK-260423-ntu T3a):
#   The host machine is Windows on ARM64. The scoop-installed `gcc.exe`
#   shim points at gcc-aarch64-none-elf (bare-metal ARM ELF cross-compiler),
#   which is unusable for Windows DLL builds. mingw-mstorsjo-llvm-ucrt
#   ships a multi-target clang driver that emits both x86_64 and i686
#   mingw32 PE binaries with a single toolchain install — no winlibs
#   fallback needed.

param(
    [ValidateSet("x64", "x86")]
    [string]$Arch = "x64",
    [ValidateSet("Debug", "Release")]
    [string]$Config = "Debug",
    [switch]$Tests,
    [switch]$Clean
)

$ErrorActionPreference = "Stop"

# Navigate to the interceptor directory (where this script lives)
$interceptorRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$buildDir = Join-Path $interceptorRoot "build-$Arch"

Write-Host "================================"
Write-Host "  go-mapi Interceptor Build"
Write-Host "  (mingw-mstorsjo-llvm-ucrt / clang + Ninja)"
Write-Host "  Arch: $Arch"
Write-Host "================================"
Write-Host ""

# Find the mingw-mstorsjo-llvm-ucrt toolchain (scoop-installed). Triple-
# prefixed drivers MUST be used explicitly — on ARM64 Windows the plain
# `gcc.exe` / `g++.exe` shims resolve to gcc-aarch64-none-elf (bare-metal)
# and will not produce usable Windows PE binaries.
$clangBin = "$env:USERPROFILE\scoop\apps\mingw-mstorsjo-llvm-ucrt\current\bin"
if (-not (Test-Path $clangBin)) {
    Write-Error "mingw-mstorsjo-llvm-ucrt not found at $clangBin. Install with: scoop install mingw-mstorsjo-llvm-ucrt"
    exit 1
}

$triple = if ($Arch -eq "x64") { "x86_64-w64-mingw32" } else { "i686-w64-mingw32" }
$gccPath = Join-Path $clangBin "$triple-clang.exe"
$gxxPath = Join-Path $clangBin "$triple-clang++.exe"
foreach ($p in @($gccPath, $gxxPath)) {
    if (-not (Test-Path $p)) {
        Write-Error "Required compiler not found: $p"
        exit 1
    }
}

# Check for CMake (prefer the one bundled with MinGW if available)
$cmakePath = Join-Path $clangBin "cmake.exe"
if (-not (Test-Path $cmakePath)) {
    $cmake = Get-Command cmake -ErrorAction SilentlyContinue
    if (-not $cmake) {
        Write-Error "CMake not found. Install with: scoop install cmake"
        exit 1
    }
    $cmakePath = $cmake.Source
}

# Check for Ninja (prefer the one bundled with MinGW if available)
$ninjaPath = Join-Path $clangBin "ninja.exe"
if (-not (Test-Path $ninjaPath)) {
    $ninja = Get-Command ninja -ErrorAction SilentlyContinue
    if (-not $ninja) {
        Write-Error "Ninja not found. Install with: scoop install ninja"
        exit 1
    }
    $ninjaPath = $ninja.Source
}

Write-Host "CMake: $cmakePath"
Write-Host "Ninja: $ninjaPath"
Write-Host "GCC:   $gccPath"
Write-Host "G++:   $gxxPath"
Write-Host "Interceptor Root: $interceptorRoot"
Write-Host ""

# Clean build directory if requested
if ($Clean) {
    Write-Host "Cleaning build directory..."
    if (Test-Path $buildDir) {
        Remove-Item $buildDir -Recurse -Force
    }
}

# Create build directory
if (-not (Test-Path $buildDir)) {
    New-Item $buildDir -ItemType Directory | Out-Null
}

Write-Host "Configuration: $Config"
Write-Host "Build Tests: $Tests"
Write-Host "Build Directory: $buildDir"
Write-Host ""

# Configure CMake with Ninja generator
Write-Host "Configuring CMake..."

# Read version from the repo-root package.json. The old path
# src/native-host/package.json no longer exists (v2.x pre-pivot artifact);
# the authoritative version lives at the repo root now.
$repoRoot = Split-Path -Parent (Split-Path -Parent $interceptorRoot)
$packageJson = Join-Path $repoRoot "package.json"
$goMapiVersion = "0.0.0-dev"
if (Test-Path $packageJson) {
    $pkg = Get-Content $packageJson -Raw | ConvertFrom-Json
    if ($pkg.version) {
        $goMapiVersion = $pkg.version
    }
}
Write-Host "Version: $goMapiVersion"

$cmakeArgs = @(
    "-G", "Ninja",
    "-DCMAKE_BUILD_TYPE=$Config",
    "-DCMAKE_C_COMPILER=$gccPath",
    "-DCMAKE_CXX_COMPILER=$gxxPath",
    "-DCMAKE_MAKE_PROGRAM=$ninjaPath",
    "-DBUILD_TESTS=$(if ($Tests) { 'ON' } else { 'OFF' })",
    "-DGO_MAPI_VERSION=$goMapiVersion",
    "-S", $interceptorRoot,
    "-B", $buildDir
)

& $cmakePath $cmakeArgs
if ($LASTEXITCODE -ne 0) {
    Write-Error "CMake configuration failed"
    exit 1
}

# Build
Write-Host ""
Write-Host "Building..."
& $cmakePath --build $buildDir --config $Config
if ($LASTEXITCODE -ne 0) {
    Write-Error "Build failed"
    exit 1
}

Write-Host ""
Write-Host "================================"
Write-Host "  Build successful!"
Write-Host "================================"
Write-Host ""
Write-Host "Output directory: $buildDir\bin"
Write-Host ""

# List built files
if (Test-Path "$buildDir\bin") {
    Write-Host "Built files:"
    Get-ChildItem "$buildDir\bin" | ForEach-Object { Write-Host "  - $($_.Name)" }
}
