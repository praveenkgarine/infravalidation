$ErrorActionPreference = 'Stop'
$scriptPath = Join-Path $PSScriptRoot '../Test-AppInfrastructure.ps1'
$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile(
    $scriptPath, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count) { throw ($parseErrors.Message -join '; ') }

# Load helpers only: no Azure calls, database connections, or script exit.
foreach ($name in @('Get-EntryId', 'Test-ExpectedValue', 'Get-PropertyPath', 'Test-ResourceEnabled')) {
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
Assert-Test ($inventory.application -eq 'orders' -and $entries.Count -eq 11 -and $resourceIds.Count -eq 7) 'Sample JSON validates with optional resource examples disabled'
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
# New resource IDs and per-application selection.
$InventoryPath = Join-Path $PSScriptRoot '../application.json'
$resourceIds = @{}
$entries = @{}
Invoke-Expression $validationCode
$inventory.resourceTypes.postgresFlexibleServer = $false
Assert-Test (-not (Test-ResourceEnabled $entries.postgres)) 'Type switch excludes PostgreSQL'
Assert-Test (Test-ResourceEnabled $entries.cosmos) 'Type switch leaves unrelated resources enabled'
Assert-Test (-not (Test-ResourceEnabled $entries.acr)) 'Individual resource switch excludes ACR'
$entries.acr.enabled = $true
Assert-Test (Test-ResourceEnabled $entries.acr) 'Individual resource switch enables ACR'
Assert-Test ((Get-EntryId $entries.acr $types.containerRegistry) -like '*/Microsoft.ContainerRegistry/registries/acrordersdev') 'ACR resource ID'
Assert-Test ((Get-EntryId $entries.logic $types.logicAppStandard) -like '*/Microsoft.Web/sites/logic-orders-dev') 'Standard Logic App resource ID'
Assert-Test ((Get-EntryId ([pscustomobject]@{name='workflow'}) $types.logicAppConsumption) -like '*/Microsoft.Logic/workflows/workflow') 'Consumption Logic App resource ID'
Assert-Test ((Get-EntryId $entries.sql $types.sqlServer) -like '*/Microsoft.Sql/servers/sql-orders-dev') 'SQL logical server resource ID'
Assert-Test ((Get-EntryId $entries.sqldb $types.sqlDatabase) -like '*/Microsoft.Sql/servers/sql-orders-dev/databases/orders') 'SQL database nested resource ID'

# Exercise definition validation through temporary JSON files, not Azure.
$sample = Get-Content -LiteralPath $InventoryPath -Raw
$temporaryInventory = Join-Path ([IO.Path]::GetTempPath()) ('infravalidation-' + [guid]::NewGuid() + '.json')
function Test-Definition {
    param($Definition)
    $Definition | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $temporaryInventory
    $InventoryPath = $temporaryInventory
    $resourceIds = @{}
    $entries = @{}
    Invoke-Expression $validationCode
    return $resourceIds
}
try {
    $definition = $sample | ConvertFrom-Json
    $definition.resourceTypes.postgresFlexibleServer = $false
    $ids = Test-Definition $definition
    Assert-Test (-not $ids.ContainsKey('postgres')) 'Disabled type does not resolve an ARM resource ID'
    $definition.resources | Where-Object key -eq 'postgres' | ForEach-Object { $_.name = $null }
    $ids = Test-Definition $definition
    Assert-Test (-not $ids.ContainsKey('postgres')) 'Disabled resource can omit its deployment name'
    $definition.resourceTypes.postgresFlexibleServer = 'false'
    $rejected = $false
    try { Test-Definition $definition } catch { $rejected = $_.Exception.Message -like '*boolean*' }
    Assert-Test $rejected 'String type switches rejected'
    $definition = $sample | ConvertFrom-Json
    $definition.resources[0] | Add-Member enabled 'false'
    $rejected = $false
    try { Test-Definition $definition } catch { $rejected = $_.Exception.Message -like '*boolean*' }
    Assert-Test $rejected 'String resource switches rejected'
    $definition = $sample | ConvertFrom-Json
    $definition.privateDns.subscriptionId = $null
    $rejected = $false
    try { Test-Definition $definition } catch { $rejected = $_.Exception.Message -like '*DNS requires subscriptionId*' }
    Assert-Test $rejected 'Cross-subscription DNS location must be explicit'
    $definition = $sample | ConvertFrom-Json
    ($definition.resources | Where-Object key -eq 'sqldb').enabled = $true
    $definition.privateEndpoints[-1].target = 'sqldb'
    $rejected = $false
    try { Test-Definition $definition } catch { $rejected = $_.Exception.Message -like '*target a sqlServer*' }
    Assert-Test $rejected 'SQL endpoint cannot target an individual database'
    $definition = $sample | ConvertFrom-Json
    $definition.resources[0].checks[0] | Add-Member expectedResource 'acr'
    $rejected = $false
    try { Test-Definition $definition } catch { $rejected = $_.Exception.Message -like '*Unknown expectedResource*' }
    Assert-Test $rejected 'Enabled checks cannot depend on disabled resources'
}
finally { Remove-Item -LiteralPath $temporaryInventory -ErrorAction SilentlyContinue }

foreach ($name in @('Test-AddressSet', 'Get-EndpointDnsAddresses', 'Test-PrivateEndpointDns', 'Resolve-RunnerDns')) {
    $definition = $ast.Find({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name
    }, $true)
    Invoke-Expression $definition.Extent.Text
}
Assert-Test (Test-AddressSet @('10.0.0.2','10.0.0.1','10.0.0.1') @('10.0.0.1','10.0.0.2')) 'DNS set comparison ignores order and duplicates'
Assert-Test (-not (Test-AddressSet @() @())) 'Empty DNS answers cannot pass'
Assert-Test (-not (Test-AddressSet @('10.0.0.1','20.0.0.1') @('10.0.0.1'))) 'Extra public DNS answer fails'
$endpoint = '{"properties":{"networkInterfaces":[{"id":"/nic"}],"customDnsConfigs":[]}}' | ConvertFrom-Json
$script:nic = '{"properties":{"ipConfigurations":[{"name":"registry","properties":{"privateIPAddress":"10.0.0.4","privateLinkConnectionProperties":{"fqdns":["registry.azurecr.io"]}}},{"name":"data","properties":{"privateIPAddress":"10.0.0.5","privateLinkConnectionProperties":{"fqdns":["registry.eastus.data.azurecr.io"]}}}]}}' | ConvertFrom-Json
$script:zoneAddress = '10.0.0.4'
function Get-Resource {
    param([string]$Id)
    if ($Id -eq '/nic') { return $script:nic }
    $script:dnsRecordId = $Id
    if ($script:zoneReadFails) { throw 'DNS record is missing or unreadable' }
    return [pscustomobject]@{properties=[pscustomobject]@{aRecords=@([pscustomobject]@{ipv4Address=$script:zoneAddress})}}
}
$record = '{"hostname":"registry.azurecr.io","zoneName":"privatelink.azurecr.io","recordName":"registry"}' | ConvertFrom-Json
Assert-Test (Test-AddressSet @(Get-EndpointDnsAddresses $endpoint $record) @('10.0.0.4')) 'ACR registry selects only its NIC IP'
$dataRecord = '{"hostname":"registry.eastus.data.azurecr.io","zoneName":"privatelink.azurecr.io","recordName":"registry.eastus.data"}' | ConvertFrom-Json
Assert-Test (Test-AddressSet @(Get-EndpointDnsAddresses $endpoint $dataRecord) @('10.0.0.5')) 'ACR data endpoint selects its separate NIC IP'
$record.hostname = 'registry.privatelink.azurecr.io'
Assert-Test (Test-AddressSet @(Get-EndpointDnsAddresses $endpoint $record) @('10.0.0.4')) 'Public and private-link names map to same NIC IP'
$record.hostname = 'alias.example.com'
$record | Add-Member endpointFqdn 'registry.azurecr.io'
Assert-Test (Test-AddressSet @(Get-EndpointDnsAddresses $endpoint $record) @('10.0.0.4')) 'Custom on-prem alias maps using endpointFqdn'
$record.PSObject.Properties.Remove('endpointFqdn')
$rejected = $false
try { Get-EndpointDnsAddresses $endpoint $record } catch { $rejected = $true }
Assert-Test $rejected 'Unknown hostname cannot pass using every NIC IP'
$record | Add-Member ipConfigurationName 'data'
Assert-Test (Test-AddressSet @(Get-EndpointDnsAddresses $endpoint $record) @('10.0.0.5')) 'Explicit NIC configuration selection'
$record.PSObject.Properties.Remove('ipConfigurationName')
$record.hostname = 'registry.azurecr.io'
$script:nic.properties.ipConfigurations[0].properties.privateLinkConnectionProperties.fqdns = @()
$endpoint.properties.customDnsConfigs = @([pscustomobject]@{fqdn='registry.azurecr.io';ipAddresses=@('10.0.0.4')})
Assert-Test (Test-AddressSet @(Get-EndpointDnsAddresses $endpoint $record) @('10.0.0.4')) 'Endpoint DNS metadata fallback validates NIC ownership'
$endpoint.properties.customDnsConfigs[0].ipAddresses = @('10.0.0.99')
$rejected = $false
try { Get-EndpointDnsAddresses $endpoint $record } catch { $rejected = $true }
Assert-Test $rejected 'Stale endpoint DNS metadata cannot pass'
$endpoint.properties.customDnsConfigs[0].ipAddresses = @('10.0.0.4')

# Verify real resolver arguments without using VDI DNS during offline tests.
function Resolve-DnsName {
    param($Name, $Type, [switch]$DnsOnly, [switch]$NoHostsFile, $Server, $ErrorAction)
    $script:resolverArguments = @($Name,$Type,$DnsOnly.IsPresent,$NoHostsFile.IsPresent,$Server)
    return @([pscustomobject]@{Type='CNAME';NameHost='registry.privatelink.azurecr.io'},
        [pscustomobject]@{Type='A';IPAddress='10.0.0.4'})
}
Assert-Test (Test-AddressSet @(Resolve-RunnerDns 'registry.azurecr.io' '10.1.0.10') @('10.0.0.4')) 'VDI resolver follows CNAME and extracts A answers'
Assert-Test ($script:resolverArguments[2] -and $script:resolverArguments[3] -and $script:resolverArguments[4] -eq '10.1.0.10') 'VDI query bypasses hosts file and uses selected DNS server'

$inventory = [pscustomobject]@{application='test';privateDns=[pscustomobject]@{subscriptionId='dns-sub';resourceGroup='dns-rg';dnsServer='10.1.0.10'}}
$pe = [pscustomobject]@{name='pe-acr';dnsRecords=@($record)}
$RunNetworkChecks = $true
$results.Clear()
Test-PrivateEndpointDns $pe $endpoint
Assert-Test ($script:dnsRecordId -eq '/subscriptions/dns-sub/resourceGroups/dns-rg/providers/Microsoft.Network/privateDnsZones/privatelink.azurecr.io/A/registry') 'DNS A record uses separate subscription and RG'
Assert-Test (@($results | Where-Object Status -eq 'Pass').Count -eq 3) 'NIC Azure DNS and VDI DNS all match'
$script:zoneAddress = '10.0.0.99'
$results.Clear()
Test-PrivateEndpointDns $pe $endpoint
Assert-Test (@($results | Where-Object { $_.Check -eq 'Azure private DNS A record matches endpoint' -and $_.Status -eq 'Fail' }).Count -eq 1) 'Wrong Azure DNS IP fails'
Assert-Test (@($results | Where-Object { $_.Check -eq 'VDI DNS matches endpoint' -and $_.Status -eq 'Pass' }).Count -eq 1) 'VDI test still runs when Azure DNS mismatches'
$script:zoneReadFails = $true
$results.Clear()
Test-PrivateEndpointDns $pe $endpoint
Assert-Test (@($results | Where-Object Status -eq 'Error').Count -eq 1) 'Missing or unreadable Azure DNS record cannot pass'
$script:zoneReadFails = $false
$script:zoneAddress = '10.0.0.4'
function Resolve-DnsName { throw 'VDI resolver unavailable' }
$results.Clear()
Test-PrivateEndpointDns $pe $endpoint
Assert-Test (@($results | Where-Object { $_.Check -eq 'VDI DNS resolution' -and $_.Status -eq 'Error' }).Count -eq 1) 'Unresolvable on-prem hostname cannot pass'
function Resolve-DnsName { return [pscustomobject]@{Type='A';IPAddress='20.0.0.1'} }
$results.Clear()
Test-PrivateEndpointDns $pe $endpoint
Assert-Test (@($results | Where-Object { $_.Check -eq 'VDI DNS matches endpoint' -and $_.Status -eq 'Fail' }).Count -eq 1) 'Public VDI DNS answer fails'
$RunNetworkChecks = $false
$results.Clear()
Test-PrivateEndpointDns $pe $endpoint
Assert-Test (@($results | Where-Object { $_.Check -eq 'VDI DNS matches endpoint' -and $_.Status -eq 'NotTested' }).Count -eq 1) 'Runner DNS requires network switch'
$record | Add-Member subscriptionId 'override-sub'
$record | Add-Member resourceGroup 'override-rg'
$results.Clear()
Test-PrivateEndpointDns $pe $endpoint
Assert-Test ($script:dnsRecordId -like '/subscriptions/override-sub/resourceGroups/override-rg/*') 'Per-record DNS location overrides defaults'

# Disabled types skip complete runtime loops without issuing Azure calls.
$inventory = [pscustomobject]@{
    application='test';resourceTypes=[pscustomobject]@{postgresFlexibleServer=$false}
    resources=@([pscustomobject]@{key='postgres';type='postgresFlexibleServer'})
    privateEndpoints=@([pscustomobject]@{name='pe-pg';target='postgres';groupId='postgresqlServer'})
    permissions=@([pscustomobject]@{source='backend';target='postgres';kind='postgres'})
    networkProbes=@([pscustomobject]@{name='pg-probe';target='postgres'})
}
$entries = @{postgres=$inventory.resources[0];backend=[pscustomobject]@{key='backend';type='containerApp'}}
function Get-Resource { throw 'Disabled resources must not issue Azure reads' }
function Get-PrincipalId { throw 'Disabled permissions must not issue identity reads' }
$results.Clear()
foreach ($marker in @('# ---------- Resource configuration ----------', '# ---------- Private endpoints ----------', '# ---------- Network tests:')) {
    $start = $source.IndexOf($marker)
    $next = $source.IndexOf('# ----------', $start + $marker.Length)
    Invoke-Expression $source.Substring($start, $next - $start)
}
Invoke-Expression $permissionLoop.Extent.Text
Assert-Test (@($results | Where-Object Status -eq 'Skipped').Count -eq 4) 'Disabled PostgreSQL skips resource endpoint network and permission checks'
Assert-Test (@($results | Where-Object Status -eq 'Error').Count -eq 0) 'Disabled dependencies do not generate errors'

# Standard Logic App must be an actual workflow site, not just any App Service.
$inventory = [pscustomobject]@{application='test';resources=@([pscustomobject]@{key='logic';type='logicAppStandard'})}
$resourceIds = @{logic='/logic'}
function Get-Resource { return [pscustomobject]@{id='/logic';kind='app,workflowapp'} }
$start = $source.IndexOf('# ---------- Resource configuration ----------')
$next = $source.IndexOf('# ----------', $start + 10)
$resourceLoop = $source.Substring($start, $next - $start)
$results.Clear()
Invoke-Expression $resourceLoop
Assert-Test (@($results | Where-Object { $_.Check -eq 'Standard Logic App kind' -and $_.Status -eq 'Pass' }).Count -eq 1) 'Standard Logic App workflow site passes'
function Get-Resource { return [pscustomobject]@{id='/logic';kind='app'} }
$results.Clear()
Invoke-Expression $resourceLoop
Assert-Test (@($results | Where-Object { $_.Check -eq 'Standard Logic App kind' -and $_.Status -eq 'Fail' }).Count -eq 1) 'Regular App Service cannot pass as Standard Logic App'

# DNS cannot run against an endpoint pointing to another service or pending approval.
$inventory = [pscustomobject]@{application='test';privateEndpoints=@([pscustomobject]@{
    name='pe-acr';resourceId='/endpoint';target='acr';groupId='registry';dnsRecords=@($record)
})}
$entries = @{acr=[pscustomobject]@{type='containerRegistry'}}
$resourceIds = @{acr='/registry'}
$script:endpointForLoop = '{"properties":{"provisioningState":"Succeeded","privateLinkServiceConnections":[{"properties":{"privateLinkServiceId":"/other-registry","groupIds":["registry"],"privateLinkServiceConnectionState":{"status":"Approved"}}}]}}' | ConvertFrom-Json
function Get-Resource { return $script:endpointForLoop }
function Test-PrivateEndpointDns { throw 'DNS must not run without approved matching endpoint' }
$start = $source.IndexOf('# ---------- Private endpoints ----------')
$next = $source.IndexOf('# ----------', $start + 10)
$endpointLoop = $source.Substring($start, $next - $start)
$results.Clear()
Invoke-Expression $endpointLoop
Assert-Test (@($results | Where-Object { $_.Check -eq 'Target and subresource' -and $_.Status -eq 'Fail' }).Count -eq 1) 'Wrong endpoint target fails'
Assert-Test (@($results | Where-Object { $_.Check -eq 'Private endpoint DNS' -and $_.Status -eq 'NotTested' }).Count -eq 1) 'Wrong endpoint target prevents DNS validation'
$script:endpointForLoop.properties.privateLinkServiceConnections[0].properties.privateLinkServiceId = '/registry'
$script:endpointForLoop.properties.privateLinkServiceConnections[0].properties.privateLinkServiceConnectionState.status = 'Pending'
$results.Clear()
Invoke-Expression $endpointLoop
Assert-Test (@($results | Where-Object { $_.Check -eq 'Matching connection approved' -and $_.Status -eq 'Fail' }).Count -eq 1) 'Pending endpoint approval fails'
Assert-Test (@($results | Where-Object Status -eq 'Error').Count -eq 0) 'Unapproved endpoint skips DNS without misleading reads'
Write-Output "Passed $script:checks offline regression checks; script parses successfully."
