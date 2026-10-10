$ErrorActionPreference = 'Stop'
$scriptPath = Join-Path $PSScriptRoot '../Test-AppInfrastructure.ps1'
$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile(
    $scriptPath, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count) { throw ($parseErrors.Message -join '; ') }

# Load helpers only: no Azure calls, database connections, or script exit.
foreach ($name in @('Get-EntryId', 'Test-ExpectedValue', 'Get-PropertyPath')) {
    $definition = $ast.Find({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -eq $name
    }, $true)
    Invoke-Expression $definition.Extent.Text
}

$script:checks = 0
function Assert-Test {
    param([bool]$Passed, [string]$Name)
    if (-not $Passed) { throw "Failed: $Name" }
    $script:checks++
}

$inventory = [pscustomobject]@{subscriptionId='sub';resourceGroup='rg'}
$dns = Get-EntryId ([pscustomobject]@{name='zone/link'}) `
    'Microsoft.Network/privateDnsZones/virtualNetworkLinks'
Assert-Test ($dns -ceq '/subscriptions/sub/resourceGroups/rg/providers/Microsoft.Network/privateDnsZones/zone/virtualNetworkLinks/link') 'Nested DNS ID'
$root = Get-EntryId ([pscustomobject]@{name='account'}) 'Microsoft.DocumentDB/databaseAccounts'
Assert-Test ($root -ceq '/subscriptions/sub/resourceGroups/rg/providers/Microsoft.DocumentDB/databaseAccounts/account') 'Root resource ID'
$explicit = Get-EntryId ([pscustomobject]@{resourceId='/custom/id/'}) 'ignored'
Assert-Test ($explicit -ceq '/custom/id') 'Explicit resource ID'
$rejected = $false
try { Get-EntryId ([pscustomobject]@{name='zone'}) 'Microsoft.Network/privateDnsZones/virtualNetworkLinks' }
catch { $rejected = $true }
Assert-Test $rejected 'Invalid name segment count'
Assert-Test (-not (Test-ExpectedValue 'false' $false)) 'String cannot match boolean'
Assert-Test (Test-ExpectedValue $false $false) 'False matches false'
Assert-Test (-not (Test-ExpectedValue @('extra','expected') 'expected')) 'Array cannot match scalar'
Assert-Test (-not (Test-ExpectedValue @('extra','expected') @('expected'))) 'Array lengths must match'
Assert-Test (Test-ExpectedValue @('a','b') @('a','b')) 'Equal arrays'
Assert-Test (-not (Test-ExpectedValue @('b','a') @('a','b'))) 'Array order matters'
Assert-Test (-not (Test-ExpectedValue '1' 1)) 'String cannot match number'
Assert-Test (Test-ExpectedValue ([int]1) ([long]1)) 'Equivalent JSON numbers'
Assert-Test (Test-ExpectedValue '/SUBSCRIPTIONS/sub' '/subscriptions/sub') 'Resource ID case'
$left = '{"enabled":false,"items":[1,2]}' | ConvertFrom-Json
$right = '{"items":[1,2],"enabled":false}' | ConvertFrom-Json
Assert-Test (Test-ExpectedValue $left $right) 'Object property order'
$right.enabled = 'false'
Assert-Test (-not (Test-ExpectedValue $left $right)) 'Nested type mismatch'
$missing = [pscustomobject]@{}
Assert-Test (@($missing.permissions | Where-Object { $null -ne $_ }).Count -eq 0) 'Omitted optional section'
Assert-Test (@(@() | Where-Object { $null -ne $_ }).Count -eq 0) 'Empty optional section'
$accountId = '/subscriptions/sub/resourceGroups/rg/providers/Microsoft.DocumentDB/databaseAccounts/account'
$resourceIds = @{cosmos=$accountId;backend='/source'}
$entries = @{cosmos=[pscustomobject]@{type='cosmosAccount'}}
$inventory = [pscustomobject]@{permissions=@([pscustomobject]@{
    source='backend';target='cosmos';kind='cosmosNoSql'
    identity=[pscustomobject]@{type='systemAssigned'}
    roleDefinitionId='role';scope='/dbs/orders/colls/items'
})}
function Get-PrincipalId { return 'principal' }
function Add-Result { }
function Assert-Value {
    param($Resource, $Check, $Passed, $Expected, $Actual)
    $script:cosmosPassed = $Passed
}
function Invoke-AzJson {
    param([string[]]$Arguments)
    $script:azArguments = $Arguments
    return [pscustomobject]@{
        id='assignment';principalId='principal'
        roleDefinitionId="$accountId/sqlRoleDefinitions/role"
        scope="$accountId/dbs/orders/colls/items"
    }
}
$permissionLoop = $ast.Find({
    param($node)
    $node -is [System.Management.Automation.Language.ForEachStatementAst] -and
    $node.Extent.Text.Contains('Exact Cosmos NoSQL role assignment')
}, $true)
Invoke-Expression $permissionLoop.Extent.Text
Assert-Test $script:cosmosPassed 'Cosmos flattened CLI response matches'
Assert-Test (($script:azArguments -join ' ') -ceq 'cosmosdb sql role assignment list --subscription sub --resource-group rg --account-name account') 'Cosmos CLI arguments'
$inventory.permissions[0].roleDefinitionId = 'different-role'
Invoke-Expression $permissionLoop.Extent.Text
Assert-Test (-not $script:cosmosPassed) 'Wrong Cosmos role fails'
$inventory.permissions[0].roleDefinitionId = 'role'
$inventory.permissions[0].scope = '/dbs/other'
Invoke-Expression $permissionLoop.Extent.Text
Assert-Test (-not $script:cosmosPassed) 'Wrong Cosmos scope fails'
foreach ($name in @('Get-FunctionRouting', 'Get-FunctionStorageReference', 'Test-FunctionInfrastructure', 'Add-Result', 'Assert-Value')) {
    $definition = $ast.Find({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name
    }, $true)
    Invoke-Expression $definition.Extent.Text
}
$modern = '{"properties":{"outboundVnetRouting":{"allTraffic":true,"applicationTraffic":false}}}' | ConvertFrom-Json
Assert-Test (Get-FunctionRouting $modern $null @{} 'applicationTraffic') 'All traffic overrides individual flag'
$modern.properties.outboundVnetRouting.allTraffic = $false
Assert-Test (-not (Get-FunctionRouting $modern $null @{WEBSITE_VNET_ROUTE_ALL='1'} 'applicationTraffic')) 'Modern false overrides legacy setting'
$legacy = '{"properties":{"vnetRouteAllEnabled":true}}' | ConvertFrom-Json
Assert-Test (Get-FunctionRouting $legacy $null @{} 'applicationTraffic') 'Legacy site routing'
Assert-Test (Get-FunctionRouting ([pscustomobject]@{}) $null @{WEBSITE_CONTENTOVERVNET='1'} 'contentShareTraffic') 'Legacy content setting'
Assert-Test (-not (Get-FunctionRouting ([pscustomobject]@{}) $null @{} 'applicationTraffic')) 'Missing route setting defaults false'
$secret = 'DO-NOT-REPORT-THIS-KEY'
$reference = Get-FunctionStorageReference @{AzureWebJobsStorage="DefaultEndpointsProtocol=https;AccountName=hoststore;AccountKey=$secret"} 'host'
Assert-Test ($reference.AccountName -eq 'hoststore' -and $reference.Mode -eq 'ConnectionString') 'Connection string discovery'
Assert-Test (($reference | ConvertTo-Json) -notmatch $secret) 'Discovery excludes connection secret'
$reference = Get-FunctionStorageReference @{AzureWebJobsStorage__accountName='hoststore'} 'host'
Assert-Test ($reference.AccountName -eq 'hoststore') 'Managed identity account name'
$reference = Get-FunctionStorageReference @{AzureWebJobsStorage__blobServiceUri='https://hoststore.blob.core.windows.net';AzureWebJobsStorage__queueServiceUri='https://hoststore.queue.core.windows.net'} 'host'
Assert-Test ($reference.AccountName -eq 'hoststore') 'Managed identity service URIs'
$reference = Get-FunctionStorageReference @{AzureWebJobsStorage__blobServiceUri='https://hoststore.blob.core.windows.net';AzureWebJobsStorage__queueServiceUri='https://otherstore.queue.core.windows.net'} 'host'
Assert-Test ($reference.State -eq 'Unresolved') 'Conflicting storage URI accounts'
$reference = Get-FunctionStorageReference @{AzureWebJobsStorage='@Microsoft.KeyVault(SecretUri=https://vault/secrets/storage)'} 'host'
Assert-Test ($reference.State -eq 'Unresolved' -and $reference.Mode -eq 'KeyVault') 'Unresolved Key Vault reference'
$reference = Get-FunctionStorageReference @{} 'content'
Assert-Test ($reference.State -eq 'Missing') 'Absent content storage'

$storageId = '/subscriptions/sub/resourceGroups/rg/providers/Microsoft.Storage/storageAccounts/hoststore'
$functionId = '/subscriptions/sub/resourceGroups/rg/providers/Microsoft.Web/sites/function'
$endpointId = '/subscriptions/sub/resourceGroups/rg/providers/Microsoft.Network/privateEndpoints/storage'
$resourceIds = @{function=$functionId;storage=$storageId}
$entry = '{"key":"function","functionValidation":{"applicationTraffic":true,"host":{"expectedResource":"storage","checks":[{"path":"properties.publicNetworkAccess","expected":"Disabled"}],"privateEndpointGroups":["blob","queue"]}}}' | ConvertFrom-Json
$script:testSettings = @([pscustomobject]@{name='AzureWebJobsStorage';value="AccountName=hoststore;AccountKey=$secret"})
function Invoke-AzJson {
    param([string[]]$Arguments)
    if ($Arguments -contains 'appsettings') { return $script:testSettings }
    if ($Arguments -contains 'show') { return [pscustomobject]@{} }
    throw 'Unexpected mock Azure command'
}
function Get-Resource {
    param([string]$Id)
    if ($Id -eq $functionId) {
        return [pscustomobject]@{id=$Id;properties=[pscustomobject]@{
            virtualNetworkSubnetId='/subnet';outboundVnetRouting=[pscustomobject]@{applicationTraffic=$true}
        }}
    }
    if ($Id -eq $storageId) {
        return [pscustomobject]@{id=$Id;properties=[pscustomobject]@{
            publicNetworkAccess='Disabled';privateEndpointConnections=@([pscustomobject]@{properties=[pscustomobject]@{
                privateLinkServiceConnectionState=[pscustomobject]@{status='Approved'}
                privateEndpoint=[pscustomobject]@{id=$endpointId}
            }})
        }}
    }
    if ($Id -eq $endpointId) {
        return [pscustomobject]@{id=$Id;properties=[pscustomobject]@{
            provisioningState='Succeeded';privateLinkServiceConnections=@([pscustomobject]@{properties=[pscustomobject]@{
                privateLinkServiceId=$storageId;groupIds=@('blob')
                privateLinkServiceConnectionState=[pscustomobject]@{status='Approved'}
            }})
        }}
    }
    throw 'Unexpected mock resource ID'
}
$results = [System.Collections.Generic.List[object]]::new()
Test-FunctionInfrastructure $entry
Assert-Test (@($results | Where-Object { $_.Check -eq 'properties.publicNetworkAccess' -and $_.Status -eq 'Pass' }).Count -eq 1) 'Discovered host storage policy passes'
Assert-Test (@($results | Where-Object { $_.Check -eq 'Approved private endpoint: blob' -and $_.Status -eq 'Pass' }).Count -eq 1) 'Approved matching blob endpoint'
Assert-Test (@($results | Where-Object { $_.Check -eq 'Approved private endpoint: queue' -and $_.Status -eq 'Fail' }).Count -eq 1) 'Missing queue endpoint fails'
Assert-Test (($results | ConvertTo-Json -Depth 20) -notmatch $secret) 'Reports exclude connection secrets'
Assert-Test (@($results | Where-Object { $_.Check -eq 'Function-to-storage runtime connectivity' -and $_.Status -eq 'NotTested' }).Count -eq 1) 'Configuration does not claim runtime connectivity'
$script:testSettings = @([pscustomobject]@{name='AzureWebJobsStorage';value='@Microsoft.KeyVault(SecretUri=https://vault/secrets/storage)'})
$results.Clear()
Test-FunctionInfrastructure $entry
Assert-Test (@($results | Where-Object { $_.Check -eq 'Storage account discovery' -and $_.Status -eq 'NotTested' }).Count -eq 1) 'Unresolved storage does not pass'
# Exercise the real JSON loading and definition validation without Azure calls.
$source = Get-Content -LiteralPath $scriptPath -Raw
$validationStart = $source.IndexOf('# ---------- Inventory validation ----------')
$validationEnd = $source.IndexOf("if (-not (Get-Command az", $validationStart)
$validationCode = $source.Substring($validationStart, $validationEnd - $validationStart)
$typeDefinition = $ast.Find({
    param($node)
    $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
    $node.Left.Extent.Text -eq '$types'
}, $true)
Invoke-Expression $typeDefinition.Extent.Text
$InventoryPath = Join-Path $PSScriptRoot '../application.json'
$resourceIds = @{}
$entries = @{}
Invoke-Expression $validationCode
Assert-Test ($inventory.application -eq 'orders' -and $entries.Count -eq 7) 'Sample JSON passes definition validation'
Assert-Test ($resourceIds['storage'] -eq '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-orders-dev/providers/Microsoft.Storage/storageAccounts/stordersdev') 'JSON defaults resolve resource IDs'
$defaultPath = $ast.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'InventoryPath' }
Assert-Test ($defaultPath.DefaultValue.Extent.Text -eq "(Join-Path `$PSScriptRoot 'application.json')") 'Default definition is beside the script'
foreach ($invalidPath in @($PSScriptRoot, $scriptPath, (Join-Path $PSScriptRoot 'missing.json'))) {
    $InventoryPath = $invalidPath
    $rejected = $false
    try { Invoke-Expression $validationCode }
    catch { $rejected = $_.Exception.Message -like '*application definition JSON file*' }
    Assert-Test $rejected 'Reject directories, non-JSON files and missing definitions'
}
Write-Output "Passed $script:checks offline regression checks; script parses successfully."
