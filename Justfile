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

test-service:
    go test ./src/service/...

check-service:
    go vet ./src/service/...

check-portable: test-user check-user test-service check-service e2e-user

test-windows: build-frontend
    go test ./internal/mapi/... ./src/app/... ./src/service/...

[positional-arguments]
prepare-windows *args:
    pwsh -NoProfile -File scripts/prepare-windows-build.ps1 "$@"

build-service:
    go build ./src/service/...

build-service-windows output="release/service/go-mapi-service.exe":
    pwsh -NoProfile -File src/service/build.ps1 -OutputPath '{{output}}'

e2e-user: build-frontend
    npm run -w @marcfargas/go-mapi-e2e test

[positional-arguments]
build-user *args:
    pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/build-wails.ps1 -UseEnvironmentCredentials "$@"

[positional-arguments]
build-user-release *args:
    pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/build-wails.ps1 -Release -UseEnvironmentCredentials "$@"

[positional-arguments]
build-user-machine *args:
    pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/build-wails.ps1 -Release -MachineDistribution -UseEnvironmentCredentials "$@"

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

test-system arch config:
    pwsh -NoProfile -ExecutionPolicy Bypass -File src/interceptor/build.ps1 -Arch {{arch}} -Config {{config}} -Tests -RunTests -Clean

verify-system-release:
    pwsh -NoProfile -ExecutionPolicy Bypass -File src/interceptor/verify-release.ps1

[positional-arguments]
package-user-msix *args:
    pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/build-app-msix.ps1 "$@"

[positional-arguments]
package-user-standalone *args:
    pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/build-app-installer.ps1 "$@"

[positional-arguments]
verify-user-distribution *args:
    pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/verify-app-distribution.ps1 "$@"

[positional-arguments]
verify-user-artifact *args:
    pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/verify-app-artifact.ps1 "$@"

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
build-machine-test-packages *args:
    pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/build-machine-test-packages.ps1 "$@"

[positional-arguments]
machine-update-integration *args:
    pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/run-machine-update-integration.ps1 "$@"

[positional-arguments]
machine-hosted-integration *args:
    pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/run-hosted-machine-integration.ps1 "$@"

[positional-arguments]
e2e-system-windows *args:
    pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/run-component-integration.ps1 "$@"

register-dev-aumid *args:
    pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/register-dev-aumid.ps1 {{args}}

unregister-dev-aumid name="go-mapi (dev)":
    pwsh -NoProfile -Command "$path = Join-Path ([Environment]::GetFolderPath('Programs')) '{{name}}.lnk'; if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force }"

release-track version:
    go run ./internal/mapi/cmd/release-track -- {{version}}

machine-package sku version:
    go run ./internal/mapi/cmd/machine-package -- {{sku}} {{version}}
