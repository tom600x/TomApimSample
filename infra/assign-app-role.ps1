#Requires -Version 7.0
<#
.SYNOPSIS
	Assigns an API application role to a service principal or managed identity.

.DESCRIPTION
	Validates the principal, API enterprise application, and application role through Microsoft
	Graph, then creates the app-role assignment if it does not already exist. The operation is
	idempotent and supports -WhatIf.

.PARAMETER PrincipalId
	Object ID of the calling service principal or managed identity, such as APIM's principal ID.

.PARAMETER ResourceId
	Object ID of the API enterprise application (service principal), not its application/client ID.

.PARAMETER AppRoleId
	ID of the application role defined by the API app registration.

.PARAMETER TenantId
	Optional Entra tenant ID to verify against the active Azure CLI context.

.EXAMPLE
	./assign-app-role.ps1 `
		-PrincipalId 5b7225dc-6a68-4ab7-addc-7408ef4b5ff4 `
		-ResourceId 00000000-0000-0000-0000-000000000000 `
		-AppRoleId 11111111-1111-1111-1111-111111111111 `
		-TenantId 418e2841-0128-4dd5-9b6c-47fc5a9a1bde
#>

[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
param(
	[Parameter(Mandatory)]
	[guid]$PrincipalId,

	[Parameter(Mandatory)]
	[guid]$ResourceId,

	[Parameter(Mandatory)]
	[guid]$AppRoleId,

	[guid]$TenantId
)

$ErrorActionPreference = 'Stop'

function Invoke-AzJson {
	param(
		[Parameter(Mandatory)]
		[string[]]$Arguments
	)

	$output = & az @Arguments 2>&1
	if ($LASTEXITCODE -ne 0) {
		throw "Azure CLI command failed: az $($Arguments -join ' ')`n$($output -join [Environment]::NewLine)"
	}

	$json = $output -join [Environment]::NewLine
	if ([string]::IsNullOrWhiteSpace($json)) {
		return $null
	}

	return $json | ConvertFrom-Json
}

if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
	throw 'Azure CLI (az) is required. Install it and sign in before running this script.'
}

$account = Invoke-AzJson -Arguments @('account', 'show', '--output', 'json')
if (-not $account) {
	throw 'No active Azure CLI session. Run az login before running this script.'
}

if ($TenantId -and $account.tenantId -ne $TenantId.ToString()) {
	throw "The active Azure CLI tenant is '$($account.tenantId)', but TenantId '$TenantId' was requested. Run 'az login --tenant $TenantId'."
}

$principalIdValue = $PrincipalId.ToString()
$resourceIdValue = $ResourceId.ToString()
$appRoleIdValue = $AppRoleId.ToString()

$principal = Invoke-AzJson -Arguments @(
	'rest', '--method', 'GET',
	'--url', "https://graph.microsoft.com/v1.0/servicePrincipals/$principalIdValue",
	'--output', 'json'
)

$resource = Invoke-AzJson -Arguments @(
	'rest', '--method', 'GET',
	'--url', "https://graph.microsoft.com/v1.0/servicePrincipals/$resourceIdValue",
	'--output', 'json'
)

$role = @($resource.appRoles) | Where-Object { $_.id -eq $appRoleIdValue }
if (-not $role) {
	throw "App role '$appRoleIdValue' was not found on API enterprise application '$($resource.displayName)' ($resourceIdValue)."
}
if (-not $role.isEnabled) {
	throw "App role '$($role.value)' ($appRoleIdValue) is disabled."
}
if ('Application' -notin $role.allowedMemberTypes) {
	throw "App role '$($role.value)' ($appRoleIdValue) does not allow Application principals."
}

$assignments = Invoke-AzJson -Arguments @(
	'rest', '--method', 'GET',
	'--url', "https://graph.microsoft.com/v1.0/servicePrincipals/$resourceIdValue/appRoleAssignedTo",
	'--output', 'json'
)
$existingAssignment = @($assignments.value) | Where-Object {
	$_.principalId -eq $principalIdValue -and
	$_.resourceId -eq $resourceIdValue -and
	$_.appRoleId -eq $appRoleIdValue
}

if ($existingAssignment) {
	Write-Host "Already assigned: '$($principal.displayName)' has '$($role.value)' on '$($resource.displayName)'." -ForegroundColor DarkGray
	$status = 'AlreadyAssigned'
} elseif ($PSCmdlet.ShouldProcess(
	"'$($resource.displayName)' ($resourceIdValue)",
	"Assign app role '$($role.value)' ($appRoleIdValue) to '$($principal.displayName)' ($principalIdValue)"
)) {
	$body = @{
		principalId = $principalIdValue
		resourceId  = $resourceIdValue
		appRoleId   = $appRoleIdValue
	} | ConvertTo-Json -Compress

	$bodyFile = New-TemporaryFile
	try {
		[IO.File]::WriteAllText($bodyFile.FullName, $body, [Text.UTF8Encoding]::new($false))
		$null = Invoke-AzJson -Arguments @(
			'rest', '--method', 'POST',
			'--url', "https://graph.microsoft.com/v1.0/servicePrincipals/$resourceIdValue/appRoleAssignedTo",
			'--headers', 'Content-Type=application/json',
			'--body', "@$($bodyFile.FullName)",
			'--output', 'json'
		)
	} finally {
		Remove-Item $bodyFile -Force -ErrorAction SilentlyContinue
	}

	Write-Host "Assigned '$($role.value)' to '$($principal.displayName)'." -ForegroundColor Green
	$status = 'Assigned'
} else {
	$status = 'WouldAssign'
}

[pscustomobject]@{
	Status              = $status
	TenantId            = $account.tenantId
	PrincipalName       = $principal.displayName
	PrincipalId         = $principalIdValue
	ResourceName        = $resource.displayName
	ResourceId          = $resourceIdValue
	AppRoleValue        = $role.value
	AppRoleId           = $appRoleIdValue
	AllowedMemberTypes  = $role.allowedMemberTypes -join ', '
}
