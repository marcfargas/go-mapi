targetScope = 'resourceGroup'

@description('Existing Artifact Signing account with a completed Public Trust identity validation.')
param accountName string = 'lachispa'

@description('Certificate profile name dedicated to go-mapi releases.')
param certificateProfileName string = 'go-mapi-public'

@description('Completed portal-issued Public Trust identity-validation ID.')
param identityValidationId string

@description('Principal ID of the GitHub OIDC user-assigned managed identity.')
param signingPrincipalId string

resource account 'Microsoft.CodeSigning/codeSigningAccounts@2025-10-13' existing = {
  name: accountName
}

resource profile 'Microsoft.CodeSigning/codeSigningAccounts/certificateProfiles@2025-10-13' = {
  parent: account
  name: certificateProfileName
  properties: {
    identityValidationId: identityValidationId
    profileType: 'PublicTrust'
    includeCity: false
    includeCountry: false
    includePostalCode: false
    includeState: false
    includeStreetAddress: false
  }
}

resource signerRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(profile.id, signingPrincipalId, 'Artifact Signing Certificate Profile Signer')
  scope: profile
  properties: {
    principalId: signingPrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '2837e146-70d7-4cfd-ad55-7efa6464f958')
  }
}

output endpoint string = account.properties.accountUri
output signingAccount string = account.name
output certificateProfile string = profile.name
output certificateProfileResourceId string = profile.id
