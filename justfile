set shell := ["bash", "-eu", "-o", "pipefail", "-c"]

repo := "marcfargas/go-mapi"
resource_group := "rg-lachispa-artifact-signing"
account := "lachispa"
test_profile := "lachispa-test"
oidc_deployment := "go-mapi-artifact-signing-oidc"

# List the operational commands for Artifact Signing.
default:
    @just --list

# Validate the three CI workflows and Bicep templates locally.
ci-check:
    go run github.com/rhysd/actionlint/cmd/actionlint@v1.7.9 .github/workflows/build.yml .github/workflows/artifact-signing.yml .github/workflows/release.yml
    python3 -c 'import pathlib, yaml; [yaml.safe_load(path.read_text()) for path in pathlib.Path(".github/workflows").glob("*.yml")]; print("workflow YAML OK")'
    az bicep build --file infra/artifact-signing/main.bicep --stdout >/dev/null
    az bicep build --file infra/artifact-signing/profile.bicep --stdout >/dev/null
    git diff --check

# Preview the GitHub OIDC managed-identity deployment. Use the clean signing Azure profile.
azure-oidc-what-if:
    az deployment group what-if --resource-group {{resource_group}} --name {{oidc_deployment}} --template-file infra/artifact-signing/main.bicep --parameters repository={{repo}} environmentName=artifact-signing

# Create/update the GitHub OIDC managed identity and federated credential.
azure-oidc-deploy:
    az deployment group create --resource-group {{resource_group}} --name {{oidc_deployment}} --template-file infra/artifact-signing/main.bicep --parameters repository={{repo}} environmentName=artifact-signing

# Grant the deployed GitHub identity signing access only to the test certificate profile.
azure-test-signer-role:
    principal_id="$$(az deployment group show --resource-group {{resource_group}} --name {{oidc_deployment}} --query properties.outputs.principalId.value -o tsv)"; az role assignment create --assignee-object-id "$$principal_id" --assignee-principal-type ServicePrincipal --role 'Artifact Signing Certificate Profile Signer' --scope "/subscriptions/$$(az account show --query id -o tsv)/resourceGroups/{{resource_group}}/providers/Microsoft.CodeSigning/codeSigningAccounts/{{account}}/certificateProfiles/{{test_profile}}"

# Configure GitHub's protected signing environment for the existing test profile. OIDC uses no client secret.
github-test-environment:
    client_id="$$(az deployment group show --resource-group {{resource_group}} --name {{oidc_deployment}} --query properties.outputs.clientId.value -o tsv)"; tenant_id="$$(az account show --query tenantId -o tsv)"; subscription_id="$$(az account show --query id -o tsv)"; gh api --method PUT repos/{{repo}}/environments/artifact-signing >/dev/null; gh variable set AZURE_CLIENT_ID --env artifact-signing --repo {{repo}} --body "$$client_id"; gh variable set AZURE_TENANT_ID --env artifact-signing --repo {{repo}} --body "$$tenant_id"; gh variable set AZURE_SUBSCRIPTION_ID --env artifact-signing --repo {{repo}} --body "$$subscription_id"; gh variable set AZURE_ARTIFACT_SIGNING_ENDPOINT --env artifact-signing --repo {{repo}} --body https://weu.codesigning.azure.net/; gh variable set AZURE_ARTIFACT_SIGNING_ACCOUNT --env artifact-signing --repo {{repo}} --body {{account}}; gh variable set AZURE_ARTIFACT_SIGNING_CERTIFICATE_PROFILE --env artifact-signing --repo {{repo}} --body {{test_profile}}

# Dispatch the non-release Windows producer. It creates go-mapi-windows-unsigned.
ci-build version="0.0.0-signing-test" channel="test":
    gh workflow run build.yml --repo {{repo}} --ref main -f version={{version}} -f channel={{channel}}

# Dispatch the separate official Azure Artifact Signing workflow for a completed Build run.
ci-sign build_run_id:
    gh workflow run artifact-signing.yml --repo {{repo}} --ref main -f build_run_id={{build_run_id}}

# Wait for a GitHub Actions run and return its exit status.
ci-watch run_id:
    gh run watch {{run_id}} --repo {{repo}} --exit-status

# Publish an already-signed artifact for an existing tag. This is intentionally manual.
ci-release signed_run_id tag:
    gh workflow run release.yml --repo {{repo}} --ref main -f signed_run_id={{signed_run_id}} -f tag={{tag}} -f publish=false
