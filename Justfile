set dotenv-load := true

default:
    @just --list

install:
    npm ci

build-frontend:
    npm run -w @marcfargas/go-mapi-app-frontend build

test-user: build-frontend
    go test ./internal/mapi/... ./src/app/...
    npm run -w @marcfargas/go-mapi-app-frontend test:run

check-user:
    go vet ./internal/mapi/... ./src/app/...
    npm run -w @marcfargas/go-mapi-app-frontend check

[unix]
test-service:
    go test ./src/service/...

check-service:
    go vet ./src/service/...

check-portable: test-user check-user test-service check-service e2e-user

test-windows: _require-disposable build-frontend
    go test ./internal/mapi/... ./src/app/... ./src/service/...

sandbox-smoke:
    pwsh -NoProfile -File tests/sandbox/run.ps1 -Smoke

[positional-arguments]
sandbox-test *args:
    pwsh -NoProfile -File tests/sandbox/run.ps1 "$@"

[positional-arguments]
prepare-native-inputs *args:
    pwsh -NoProfile -File tests/sandbox/native/prepare.ps1 "$@"

test-windows-tooling:
    pwsh -NoProfile -File tests/Entrypoints.Tests.ps1
    pwsh -NoProfile -File src/app/tests/Build.Tests.ps1
    pwsh -NoProfile -File tests/sandbox/Runner.Tests.ps1
    pwsh -NoProfile -File tests/sandbox/native/Build.Tests.ps1

[positional-arguments]
test-native-inputs *args:
    pwsh -NoProfile -File tests/sandbox/native/Inputs.Tests.ps1 "$@"

build-service:
    go build ./src/service/...

build-service-windows output="release/service/go-mapi-service.exe":
    pwsh -NoProfile -File src/service/build.ps1 -OutputPath '{{output}}'

e2e-user: build-frontend
    npm run -w @marcfargas/go-mapi-e2e test

[positional-arguments]
build-user *args:
    pwsh -NoProfile -ExecutionPolicy Bypass -File src/app/build.ps1 -UseEnvironmentCredentials "$@"

[positional-arguments]
build-user-release *args:
    pwsh -NoProfile -ExecutionPolicy Bypass -File src/app/build.ps1 -Release -UseEnvironmentCredentials "$@"

[positional-arguments]
build-user-machine *args:
    pwsh -NoProfile -ExecutionPolicy Bypass -File src/app/build.ps1 -Release -MachineDistribution -UseEnvironmentCredentials "$@"

dev-user:
    cd src/app && wails build -devtools
    ./src/app/build/bin/go-mapi.exe

build-system-x64:
    pwsh -NoProfile -ExecutionPolicy Bypass -File src/interceptor/build.ps1 -Arch x64 -Config Release

build-system-x86:
    pwsh -NoProfile -ExecutionPolicy Bypass -File src/interceptor/build.ps1 -Arch x86 -Config Release

build-system: build-system-x64 build-system-x86

build-system-release-x64:
    pwsh -NoProfile -ExecutionPolicy Bypass -File src/interceptor/build.ps1 -Arch x64 -Config Release -Release

build-system-release-x86:
    pwsh -NoProfile -ExecutionPolicy Bypass -File src/interceptor/build.ps1 -Arch x86 -Config Release -Release

build-system-release: build-system-release-x64 build-system-release-x86

test-system arch config: _require-disposable
    pwsh -NoProfile -ExecutionPolicy Bypass -File src/interceptor/build.ps1 -Arch {{arch}} -Config {{config}} -Tests -RunTests -Clean

verify-system-release:
    pwsh -NoProfile -ExecutionPolicy Bypass -File src/interceptor/verify-release.ps1

[positional-arguments]
verify-user-distribution *args:
    pwsh -NoProfile -ExecutionPolicy Bypass -File src/app/packaging/verify.ps1 "$@"

[positional-arguments]
verify-user-artifact *args:
    pwsh -NoProfile -ExecutionPolicy Bypass -File src/app/verify-artifact.ps1 "$@"

[positional-arguments]
package-system *args:
    pwsh -NoProfile -ExecutionPolicy Bypass -File src/installer/msi/build.ps1 -SKU system "$@"

[positional-arguments]
package-suite *args:
    pwsh -NoProfile -ExecutionPolicy Bypass -File src/installer/msi/build.ps1 -SKU suite "$@"

[positional-arguments]
verify-system-package *args:
    pwsh -NoProfile -ExecutionPolicy Bypass -File src/installer/msi/verify.ps1 -SKU system "$@"

[positional-arguments]
verify-suite-package *args:
    pwsh -NoProfile -ExecutionPolicy Bypass -File src/installer/msi/verify.ps1 -SKU suite "$@"

[positional-arguments]
build-machine-test-services *args:
    pwsh -NoProfile -ExecutionPolicy Bypass -File src/installer/msi/tests/build-services.ps1 "$@"

[positional-arguments]
build-machine-test-packages *args: _require-disposable
    pwsh -NoProfile -ExecutionPolicy Bypass -File src/installer/msi/tests/build-fixtures.ps1 "$@"

[positional-arguments]
machine-update-integration *args: _require-disposable
    pwsh -NoProfile -ExecutionPolicy Bypass -File src/installer/msi/tests/update.ps1 "$@"

[positional-arguments]
machine-hosted-integration *args: _require-disposable
    pwsh -NoProfile -ExecutionPolicy Bypass -File src/installer/msi/tests/hosted.ps1 "$@"

[positional-arguments]
e2e-system-windows *args: _require-disposable
    pwsh -NoProfile -ExecutionPolicy Bypass -File tests/sandbox/component-integration.ps1 "$@"

[positional-arguments]
register-dev-aumid *args:
    pwsh -NoProfile -ExecutionPolicy Bypass -File src/app/register-dev-aumid.ps1 "$@"

unregister-dev-aumid name="go-mapi (dev)":
    pwsh -NoProfile -Command "$path = Join-Path ([Environment]::GetFolderPath('Programs')) '{{name}}.lnk'; if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force }"

release-track version:
    go run ./internal/mapi/cmd/release-track -- {{version}}

machine-package sku version:
    go run ./internal/mapi/cmd/machine-package -- {{sku}} {{version}}

# The Windows act runner executes on the host. Allow checks and unsigned builds/packages.
[windows]
[script('pwsh', '-NoProfile', '-File')]
[extension('.ps1')]
[positional-arguments]
ci mode="run" job="windows-check":
    param([ValidateSet('run','plan')][string]$Mode, [ValidateSet('windows-check','app-packages','admin-service-fixtures')][string]$Job)
    $ErrorActionPreference = 'Stop'
    $arguments = @('-P', 'windows-latest=-self-hosted', '-W', '.github/workflows/ci.yml', '-j', $Job)
    if ($Job -eq 'app-packages') { $arguments += @('--matrix', 'role:standalone') }
    if ($Job -in @('app-packages','admin-service-fixtures') -and $Mode -eq 'run') {
        $artifacts = Join-Path $PWD ('release/act/' + [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N'))
        $arguments += @('--artifact-server-path', $artifacts)
        Write-Host "Package artifacts: $artifacts"
    }
    if ($Mode -eq 'plan') { $arguments += '--list' }
    & act @arguments
    exit $LASTEXITCODE

[windows]
ci-plan job="windows-check": (ci "plan" job)

# Build unsigned user packages through the same GitHub job as CI.
[windows]
package-user: (ci "run" "app-packages")

[windows]
[script('pwsh', '-NoProfile', '-File')]
[extension('.ps1')]
setup-act:
    if (Get-Command act -ErrorAction SilentlyContinue) { & act --version; exit $LASTEXITCODE }
    & winget list --id nektos.act --exact --accept-source-agreements
    if ($LASTEXITCODE -eq 0) { Write-Host 'act is installed. Open a fresh shell to refresh PATH.'; exit 0 }
    & winget install --id nektos.act --exact --source winget --accept-source-agreements --accept-package-agreements
    exit $LASTEXITCODE

[windows]
[script('pwsh', '-NoProfile', '-File')]
[extension('.ps1')]
[positional-arguments]
doctor-windows:
    $ErrorActionPreference = 'Stop'
    foreach ($entry in @(@('go','version','go1\.25\.'), @('node','--version','^v20\.'), @('npm','--version','^\d'), @('just','--version','just '))) {
        $version = & $entry[0] $entry[1]
        if ($LASTEXITCODE -ne 0 -or ($version -join ' ') -notmatch $entry[2]) { throw "Unsupported or missing $($entry[0]): $version" }
    }

# This job executes no service TestMain, DLL harness, registration or installer.
[windows]
check-windows: doctor-windows test-user check-user check-service test-windows-tooling test-msi-tooling test-attachment-tooling
    just build-service-tests

build-service-tests output=".tmp/service.test.exe":
    go test -c -o '{{output}}' ./src/service

[script('pwsh', '-NoProfile', '-File')]
[extension('.ps1')]
test-attachment-tooling:
    $env:GOWORK = 'off'
    & go test -C tests/installed-attachment/fake-gmail -count=1
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    & pwsh -NoProfile -File tests/installed-attachment/Contract.Tests.ps1
    exit $LASTEXITCODE

test-msi-tooling:
    pwsh -NoProfile -File src/installer/msi/tests/Build.Tests.ps1
    pwsh -NoProfile -File src/installer/msi/tests/Hosted.Tests.ps1
    pwsh -NoProfile -File src/installer/msi/tests/DeferredInterruptionGuard.Tests.ps1
    pwsh -NoProfile -File src/installer/msi/tests/MachineReadinessEvidence.Tests.ps1
    pwsh -NoProfile -File src/installer/msi/tests/ReadinessInstaller.Tests.ps1

# Pure build/admission checks need the service resource compiler, but never run a PE.
test-machine-service-inputs:
    pwsh -NoProfile -File src/installer/msi/tests/ServiceBuilds.Tests.ps1

[positional-arguments]
test-installed-attachment *args: _require-disposable
    pwsh -NoProfile -File tests/installed-attachment/Test-Attachment.ps1 "$@"

[positional-arguments]
[script('pwsh', '-NoProfile', '-File')]
[extension('.ps1')]
azure-test-trust mode state-path *signed-files: _require-disposable
    param([string]$Mode, [string]$StatePath, [Parameter(ValueFromRemainingArguments=$true)][string[]]$SignedFiles)
    $ErrorActionPreference = 'Stop'
    & ./distribution/signing/azure-test-trust.ps1 -Mode $Mode -StatePath $StatePath -SignedFiles $SignedFiles

[positional-arguments]
write-machine-signed-input *args:
    pwsh -NoProfile -File src/installer/msi/write-signed-input.ps1 "$@"

test-windows-race: _require-disposable build-frontend
    go test -race -v ./internal/mapi/... ./src/app/... ./src/service/...

build-native-tests arch config="Release":
    pwsh -NoProfile -File src/interceptor/build.ps1 -Arch {{arch}} -Config {{config}} -Tests

[windows]
test-service: _require-disposable
    go test ./src/service/...

# The marker is supplied only inside the owned guest, not by the act host wrapper.
[private]
[script('pwsh', '-NoProfile', '-File')]
[extension('.ps1')]
_require-disposable:
    if ($env:GOMAPI_SANDBOX -eq '1') { exit 0 }
    if ($env:GITHUB_ACTIONS -eq 'true' -and !$env:ACT) { exit 0 }
    throw 'This command changes Windows state. Run it in an owned disposable guest.'
