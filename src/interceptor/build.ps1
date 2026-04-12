# build.ps1
# Build script for go-mapi interceptor using MinGW
# Usage: .\build.ps1 [-Config Release] [-Tests] [-Clean]

param(
    [ValidateSet("Debug", "Release")]
    [string]$Config = "Debug",
    [switch]$Tests,
    [switch]$Clean
)

$ErrorActionPreference = "Stop"

# Navigate to the interceptor directory (where this script lives)
$interceptorRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$buildDir = Join-Path $interceptorRoot "build"

Write-Host "================================"
Write-Host "  go-mapi Interceptor Build"
Write-Host "  (MinGW + Ninja)"
Write-Host "================================"
Write-Host ""

# Find MinGW installation (prefer mingw-winlibs-ucrt from scoop)
$mingwPaths = @(
    "$env:USERPROFILE\scoop\apps\mingw-winlibs-ucrt\current\bin",
    "$env:USERPROFILE\scoop\apps\mingw\current\bin",
    "C:\mingw64\bin",
    "C:\msys64\mingw64\bin"
)

$mingwBin = $null
foreach ($path in $mingwPaths) {
    if (Test-Path "$path\gcc.exe") {
        $mingwBin = $path
        break
    }
}

if (-not $mingwBin) {
    Write-Error "MinGW not found. Install with: scoop install mingw-winlibs-ucrt"
    exit 1
}

$gccPath = Join-Path $mingwBin "gcc.exe"
$gxxPath = Join-Path $mingwBin "g++.exe"

# Check for CMake (prefer the one bundled with MinGW if available)
$cmakePath = Join-Path $mingwBin "cmake.exe"
if (-not (Test-Path $cmakePath)) {
    $cmake = Get-Command cmake -ErrorAction SilentlyContinue
    if (-not $cmake) {
        Write-Error "CMake not found. Install with: scoop install cmake"
        exit 1
    }
    $cmakePath = $cmake.Source
}

# Check for Ninja (prefer the one bundled with MinGW if available)
$ninjaPath = Join-Path $mingwBin "ninja.exe"
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

# Read version from package.json
$repoRoot = Split-Path -Parent (Split-Path -Parent $interceptorRoot)
$packageJson = Join-Path $repoRoot "src\native-host\package.json"
$goMapiVersion = "0.0.0-dev"
if (Test-Path $packageJson) {
    $pkg = Get-Content $packageJson -Raw | ConvertFrom-Json
    $goMapiVersion = $pkg.version
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
