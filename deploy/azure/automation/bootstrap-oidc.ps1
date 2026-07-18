[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[0-9a-fA-F-]{36}$')]
    [string]$SubscriptionId,

    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[A-Za-z0-9_.-]+$')]
    [string]$GitHubOwner,

    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[A-Za-z0-9_.-]+$')]
    [string]$GitHubRepo,

    [ValidatePattern('^[A-Za-z0-9_.-]+$')]
    [string]$GitHubEnvironment = 'production',

    [ValidatePattern('^[A-Za-z0-9_.-]+$')]
    [string]$ApplicationName = 'keivo-github-production'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    throw 'Azure CLI is required. Install it from https://learn.microsoft.com/cli/azure/install-azure-cli.'
}

Write-Host 'Opening an interactive Azure sign-in...'
az login --output none
az account set --subscription $SubscriptionId

$tenantId = az account show --query tenantId --output tsv
if ([string]::IsNullOrWhiteSpace($tenantId)) {
    throw 'Azure CLI did not return a tenant ID.'
}

$appId = az ad app list --display-name $ApplicationName --query '[0].appId' --output tsv
if ([string]::IsNullOrWhiteSpace($appId)) {
    $appId = az ad app create --display-name $ApplicationName --query appId --output tsv
}

$appObjectId = az ad app show --id $appId --query id --output tsv
$principalId = az ad sp list --filter "appId eq '$appId'" --query '[0].id' --output tsv
if ([string]::IsNullOrWhiteSpace($principalId)) {
    $principalId = az ad sp create --id $appId --query id --output tsv
}

$credentialName = "github-$GitHubEnvironment"
$subject = "repo:$GitHubOwner/$GitHubRepo`:environment:$GitHubEnvironment"
$existingCredentialId = az ad app federated-credential list `
    --id $appId `
    --query "[?name=='$credentialName'].id | [0]" `
    --output tsv

if (-not [string]::IsNullOrWhiteSpace($existingCredentialId)) {
    az ad app federated-credential delete `
        --id $appId `
        --federated-credential-id $existingCredentialId `
        --output none
}

$credentialDocument = [ordered]@{
    name        = $credentialName
    issuer      = 'https://token.actions.githubusercontent.com'
    subject     = $subject
    description = "GitHub Actions environment $GitHubEnvironment for $GitHubOwner/$GitHubRepo"
    audiences   = @('api://AzureADTokenExchange')
}

$temporaryFile = Join-Path ([IO.Path]::GetTempPath()) ("keivo-oidc-{0}.json" -f [guid]::NewGuid())
try {
    $credentialDocument | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $temporaryFile -Encoding UTF8
    az ad app federated-credential create `
        --id $appId `
        --parameters $temporaryFile `
        --output none
}
finally {
    if (Test-Path -LiteralPath $temporaryFile) {
        Remove-Item -LiteralPath $temporaryFile -Force
    }
}

$subscriptionScope = "/subscriptions/$SubscriptionId"
$requiredRoles = @(
    'Contributor',
    'Role Based Access Control Administrator',
    'Key Vault Secrets Officer'
)

foreach ($role in $requiredRoles) {
    $assignmentCount = az role assignment list `
        --assignee-object-id $principalId `
        --scope $subscriptionScope `
        --role $role `
        --query 'length(@)' `
        --output tsv
    if ($assignmentCount -eq '0') {
        az role assignment create `
            --assignee-object-id $principalId `
            --assignee-principal-type ServicePrincipal `
            --role $role `
            --scope $subscriptionScope `
            --output none
    }
}

Write-Host ''
Write-Host 'OIDC bootstrap complete. Add these non-secret values as GitHub Environment secrets:'
Write-Host "AZURE_CLIENT_ID=$appId"
Write-Host "AZURE_TENANT_ID=$tenantId"
Write-Host "AZURE_SUBSCRIPTION_ID=$SubscriptionId"
Write-Host "APPLICATION_OBJECT_ID=$appObjectId"
Write-Host "SERVICE_PRINCIPAL_OBJECT_ID=$principalId"
Write-Host ''
Write-Host "Federated subject: $subject"
Write-Host 'No client secret was created.'
