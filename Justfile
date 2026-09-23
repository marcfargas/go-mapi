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

e2e-user: build-frontend
    npm run -w @marcfargas/go-mapi-e2e test

build-user:
    pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/build-wails.ps1 -UseEnvironmentCredentials

build-user-release:
    pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/build-wails.ps1 -Release -UseEnvironmentCredentials

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

verify-system-release:
    pwsh -NoProfile -ExecutionPolicy Bypass -File src/interceptor/verify-release.ps1

package-user-msix *args:
    pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/build-app-msix.ps1 {{args}}

package-user-standalone *args:
    pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/build-app-installer.ps1 {{args}}

verify-user-distribution *args:
    pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/verify-app-distribution.ps1 {{args}}

package-system *args:
    pwsh -NoProfile -ExecutionPolicy Bypass -File src/installer/msi/build.ps1 {{args}}

verify-system-package *args:
    pwsh -NoProfile -ExecutionPolicy Bypass -File src/installer/msi/verify.ps1 {{args}}

e2e-system-windows *args:
    pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/run-component-integration.ps1 {{args}}

register-dev-aumid *args:
    pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/register-dev-aumid.ps1 {{args}}

unregister-dev-aumid name="go-mapi (dev)":
    pwsh -NoProfile -Command "$path = Join-Path ([Environment]::GetFolderPath('Programs')) '{{name}}.lnk'; if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force }"

release-track version:
    go run ./internal/mapi/cmd/release-track -- {{version}}

machine-package sku version:
    go run ./internal/mapi/cmd/machine-package -- {{sku}} {{version}}
