targetScope = 'resourceGroup'

@description('Name of the user-assigned managed identity used by GitHub Actions OIDC.')
param identityName string = 'id-go-mapi-signing-github'

@description('GitHub repository allowed to exchange an OIDC token.')
param repository string = 'marcfargas/go-mapi'

@description('GitHub environment protected before artifact signing can start.')
param environmentName string = 'artifact-signing'

resource signingIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: identityName
  location: resourceGroup().location
}

resource githubOidc 'Microsoft.ManagedIdentity/userAssignedIdentities/federatedIdentityCredentials@2023-01-31' = {
  parent: signingIdentity
  name: 'github-go-mapi-artifact-signing'
  properties: {
    audiences: [
      'api://AzureADTokenExchange'
    ]
    issuer: 'https://token.actions.githubusercontent.com'
    subject: 'repo:${repository}:environment:${environmentName}'
  }
}

output clientId string = signingIdentity.properties.clientId
output principalId string = signingIdentity.properties.principalId
output tenantId string = subscription().tenantId
output subscriptionId string = subscription().subscriptionId
output oidcSubject string = githubOidc.properties.subject
