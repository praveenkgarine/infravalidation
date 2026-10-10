#Requires -Version 7.0

[CmdletBinding()]
param(
    [string] $InventoryPath = (Join-Path $PSScriptRoot 'application.json'),

    [string] $OutputDirectory = './validation-results',

    [switch] $RunNetworkChecks,

    [switch] $RunPostgresChecks,

    # Useful in pipelines where incomplete validation must fail the gate.
    [switch] $FailOnNotTested
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false

$results = [System.Collections.Generic.List[object]]::new()
$resourceCache = @{}
$resourceIds = @{}
$entries = @{}

$types = @{
    containerApp            = 'Microsoft.App/containerApps'
    containerAppEnvironment = 'Microsoft.App/managedEnvironments'
    functionApp             = 'Microsoft.Web/sites'
    storageAccount          = 'Microsoft.Storage/storageAccounts'
    postgresFlexibleServer  = 'Microsoft.DBforPostgreSQL/flexibleServers'
    cosmosAccount           = 'Microsoft.DocumentDB/databaseAccounts'
    managedIdentity         = 'Microsoft.ManagedIdentity/userAssignedIdentities'
}

function Add-Result {
    param(
        [string] $Resource,
        [string] $Check,
        [string] $Status,
        $Expected,
        $Actual,
        [string] $Detail = ''
    )

    $results.Add([pscustomobject]@{
        Application = $inventory.application
        Environment = $inventory.environment
        Resource    = $Resource
        Check       = $Check
        Status      = $Status
        Expected    = ConvertTo-Json -InputObject $Expected -Compress -Depth 20
        Actual      = ConvertTo-Json -InputObject $Actual -Compress -Depth 20
        Detail      = $Detail
        Timestamp   = [DateTime]::UtcNow.ToString('o')
    })
}

function Assert-Value {
    param(
        [string] $Resource,
        [string] $Check,
        [bool] $Passed,
        $Expected,
        $Actual
    )

    $status = if ($Passed) { 'Pass' } else { 'Fail' }
    Add-Result $Resource $Check $status $Expected $Actual
}

function Invoke-AzJson {
    param([string[]] $Arguments)

    # Keep CLI error output separate from JSON.
    $stderrFile = [IO.Path]::GetTempFileName()
    try {
        $stdout = & az @Arguments --only-show-errors --output json 2> $stderrFile
        $code = $LASTEXITCODE

        if ($code -ne 0) {
            $message = Get-Content -LiteralPath $stderrFile -Raw
            throw "Azure CLI exited with code ${code}: $message"
        }

        $json = $stdout -join "`n"
        if ([string]::IsNullOrWhiteSpace($json)) {
            throw 'Azure CLI returned no JSON.'
        }

        return ConvertFrom-Json -InputObject $json
    }
    finally {
        Remove-Item -LiteralPath $stderrFile -Force -ErrorAction SilentlyContinue
    }
}

function Get-Resource {
    param([string] $Id)

    if (-not $resourceCache.ContainsKey($Id)) {
        $resourceCache[$Id] = Invoke-AzJson @(
            'resource', 'show', '--ids', $Id
        )
    }

    return $resourceCache[$Id]
}

function Get-PropertyPath {
    param($Object, [string] $Path)

    $value = $Object

    foreach ($part in $Path.Split('.')) {
        if ($null -eq $value) {
            return $null
        }

        $property = $value.PSObject.Properties[$part]
        if ($null -eq $property) {
            return $null
        }

        $value = $property.Value
    }

    return $value
}

function Test-ExpectedValue {
    param($Actual, $Expected)

    if ($null -eq $Actual -or $null -eq $Expected) {
        return ($null -eq $Actual -and $null -eq $Expected)
    }
    if ($Actual -is [array] -or $Expected -is [array]) {
        if ($Actual -isnot [array] -or $Expected -isnot [array] -or
            $Actual.Count -ne $Expected.Count) { return $false }
        for ($index = 0; $index -lt $Actual.Count; $index++) {
            if (-not (Test-ExpectedValue $Actual[$index] $Expected[$index])) {
                return $false
            }
        }
        return $true
    }
    if ($Actual -is [bool] -or $Expected -is [bool]) {
        return ($Actual -is [bool] -and $Expected -is [bool] -and $Actual -eq $Expected)
    }
    if ($Actual -is [string] -or $Expected -is [string]) {
        return ($Actual -is [string] -and $Expected -is [string] -and
            [string]::Equals($Actual, $Expected, [StringComparison]::OrdinalIgnoreCase))
    }
    $numericTypes = @([byte], [sbyte], [int16], [uint16], [int32], [uint32],
        [int64], [uint64], [single], [double], [decimal])
    if ($Actual.GetType() -in $numericTypes -and $Expected.GetType() -in $numericTypes) {
        return ($Actual -eq $Expected)
    }
    # Compare JSON objects recursively, independent of property order.
    if ($Actual -is [pscustomobject] -and $Expected -is [pscustomobject]) {
        $actualNames = @($Actual.PSObject.Properties.Name)
        $expectedNames = @($Expected.PSObject.Properties.Name)
        if ($actualNames.Count -ne $expectedNames.Count) { return $false }
        foreach ($name in $expectedNames) {
            if ($actualNames -cnotcontains $name -or
                -not (Test-ExpectedValue $Actual.$name $Expected.$name)) { return $false }
        }
        return $true
    }
    return ($Actual.GetType() -eq $Expected.GetType() -and $Actual.Equals($Expected))
}

function Get-EntryId {
    param($Entry, [string] $ResourceType)

    if ($Entry.resourceId) {
        return $Entry.resourceId.TrimEnd('/')
    }

    $subscription = if ($Entry.subscriptionId) {
        $Entry.subscriptionId
    } else {
        $inventory.subscriptionId
    }

    $group = if ($Entry.resourceGroup) {
        $Entry.resourceGroup
    } else {
        $inventory.resourceGroup
    }

    if (-not $subscription -or -not $group -or -not $Entry.name) {
        throw 'Resource requires resourceId or subscriptionId/resourceGroup/name.'
    }

    $typeParts = $ResourceType.Split('/')
    $nameParts = $Entry.name.Split('/')
    if ($typeParts.Count -ne $nameParts.Count + 1) {
        throw "Resource type and name segment counts do not match: $ResourceType / $($Entry.name)"
    }
    $id = "/subscriptions/$subscription/resourceGroups/$group/providers/$($typeParts[0])"
    for ($index = 0; $index -lt $nameParts.Count; $index++) {
        $id += "/$($typeParts[$index + 1])/$($nameParts[$index])"
    }
    return $id
}

function Get-FunctionRouting {
    param($Resource, $Config, [hashtable] $Settings, [string] $Traffic)

    $routing = $Resource.properties.outboundVnetRouting
    if ($routing.allTraffic -eq $true) { return $true }
    $modern = Get-PropertyPath $routing $Traffic
    if ($null -ne $modern) { return (Test-ExpectedValue $modern $true) }
    $legacyProperty = if ($Traffic -eq 'applicationTraffic') {
        'vnetRouteAllEnabled'
    } else { 'vnetContentShareEnabled' }
    $legacy = Get-PropertyPath $Resource.properties $legacyProperty
    if ($null -eq $legacy) { $legacy = Get-PropertyPath $Config $legacyProperty }
    if ($null -ne $legacy) { return (Test-ExpectedValue $legacy $true) }
    $setting = if ($Traffic -eq 'applicationTraffic') {
        'WEBSITE_VNET_ROUTE_ALL'
    } else { 'WEBSITE_CONTENTOVERVNET' }
    return ($Settings[$setting] -in @('1', 'true'))
}

function Get-FunctionStorageReference {
    param([hashtable] $Settings, [string] $Purpose)

    $setting = if ($Purpose -eq 'host') {
        'AzureWebJobsStorage'
    } else { 'WEBSITE_CONTENTAZUREFILECONNECTIONSTRING' }
    $connection = [string] $Settings[$setting]
    if ($connection) {
        if ($connection -match '^\s*@Microsoft.KeyVault\(') {
            return [pscustomobject]@{State='Unresolved';AccountName=$null;Mode='KeyVault'}
        }
        $account = [regex]::Match($connection, '(?i)(?:^|;)\s*AccountName\s*=\s*([a-z0-9]{3,24})\s*(?:;|$)')
        if ($account.Success) {
            return [pscustomobject]@{State='Resolved';AccountName=$account.Groups[1].Value;Mode='ConnectionString'}
        }
        return [pscustomobject]@{State='Unresolved';AccountName=$null;Mode='UnsupportedConnectionString'}
    }
    if ($Purpose -eq 'host') {
        $account = [string] $Settings['AzureWebJobsStorage__accountName']
        if ($account -match '^[a-z0-9]{3,24}$') {
            return [pscustomobject]@{State='Resolved';AccountName=$account;Mode='ManagedIdentity'}
        }
        $names = @()
        foreach ($service in @('blob', 'queue', 'table')) {
            $endpoint = [string] $Settings["AzureWebJobsStorage__${service}ServiceUri"]
            if (-not $endpoint) { continue }
            $uri = $null
            if (-not [uri]::TryCreate($endpoint, [UriKind]::Absolute, [ref]$uri) -or
                $uri.Scheme -ne 'https' -or
                $uri.Host -notmatch "^([a-z0-9]{3,24})\.$service\.core\.(windows\.net|usgovcloudapi\.net|chinacloudapi\.cn)$") {
                return [pscustomobject]@{State='Unresolved';AccountName=$null;Mode='CustomServiceUri'}
            }
            $names += $Matches[1]
        }
        $names = @($names | Sort-Object -Unique)
        if ($names.Count -eq 1) {
            return [pscustomobject]@{State='Resolved';AccountName=$names[0];Mode='ManagedIdentity'}
        }
        if ($names.Count -gt 1) {
            return [pscustomobject]@{State='Unresolved';AccountName=$null;Mode='MultipleAccounts'}
        }
    }
    return [pscustomobject]@{State='Missing';AccountName=$null;Mode='None'}
}

function Test-FunctionInfrastructure {
    param($Entry)

    $options = $Entry.functionValidation
    $id = $resourceIds[$Entry.key]
    $site = Get-Resource $id
    $config = Invoke-AzJson @('functionapp', 'config', 'show', '--ids', $id)
    $settings = @{}
    try {
        # Never write these values to reports: connection strings can contain keys.
        try {
            $appSettings = Invoke-AzJson @('functionapp', 'config', 'appsettings', 'list', '--ids', $id)
            foreach ($item in $appSettings) { $settings[$item.name] = $item.value }
        }
        catch { throw 'Unable to read Function App settings. Check app settings list permissions.' }
        finally { $appSettings = $null }

        $subnet = $site.properties.virtualNetworkSubnetId
        Assert-Value $Entry.key 'Function outbound VNet integration' `
            (-not [string]::IsNullOrWhiteSpace($subnet)) 'Integrated subnet' $subnet
        foreach ($traffic in @('applicationTraffic', 'contentShareTraffic')) {
            if ($options.PSObject.Properties[$traffic]) {
                $actual = Get-FunctionRouting $site $config $settings $traffic
                Assert-Value $Entry.key "Function VNet routing: $traffic" `
                    (Test-ExpectedValue $actual $options.$traffic) $options.$traffic $actual
            }
        }

        foreach ($purpose in @('host', 'content')) {
            $reference = Get-FunctionStorageReference $settings $purpose
            $policy = $options.$purpose
            $label = "$($Entry.key) / $purpose storage"
            if ($reference.State -ne 'Resolved') {
                if ($purpose -eq 'content' -and $reference.State -eq 'Missing' -and -not $policy) {
                    continue # Azure Files content storage is not used by every hosting plan.
                }
                $status = if ($reference.State -eq 'Missing') { 'Fail' } else { 'NotTested' }
                Add-Result $label 'Storage account discovery' $status `
                    'Resolvable storage account' $reference.Mode `
                    'No secrets are resolved or reported. Key Vault references and custom endpoints need separate verification.'
                continue
            }
            try {
                $expectedId = if ($policy.expectedResource) { $resourceIds[$policy.expectedResource] } else { $null }
                if ($expectedId) {
                    Assert-Value $label 'Configured storage account' `
                        ($reference.AccountName -eq ($expectedId.Split('/')[-1])) `
                        ($expectedId.Split('/')[-1]) $reference.AccountName
                    if ($reference.AccountName -ne ($expectedId.Split('/')[-1])) { continue }
                    $storage = Get-Resource $expectedId
                } else {
                    $subscription = $id.Split('/')[2]
                    if ($policy.subscriptionId) { $subscription = $policy.subscriptionId }
                    $accounts = @(Invoke-AzJson @('resource', 'list', '--subscription', $subscription,
                        '--resource-type', 'Microsoft.Storage/storageAccounts', '--name', $reference.AccountName))
                    if ($accounts.Count -ne 1) {
                        Add-Result $label 'Storage account discovery' 'NotTested' `
                            'One readable storage account' $reference.AccountName `
                            'Set expectedResource or subscriptionId for storage in another subscription; verify read permissions.'
                        continue
                    }
                    $storage = Get-Resource $accounts[0].id
                }
                Add-Result $label 'Storage account discovery' 'Pass' `
                    'Linked account' $storage.id $reference.Mode
                $checks = @($policy.checks | Where-Object { $null -ne $_ })
                if ($checks.Count -eq 0) {
                    Add-Result $label 'Storage policy' 'NotTested' 'Configured storage checks' $null `
                        'Add host.checks or content.checks to functionValidation.'
                }
                foreach ($check in $checks) {
                    $actual = Get-PropertyPath $storage $check.path
                    Assert-Value $label $check.path `
                        ($null -ne $actual -and (Test-ExpectedValue $actual $check.expected)) $check.expected $actual
                }
                foreach ($group in @($policy.privateEndpointGroups | Where-Object { $null -ne $_ })) {
                    $connections = @($storage.properties.privateEndpointConnections | Where-Object {
                        $_.properties.privateLinkServiceConnectionState.status -eq 'Approved'
                    })
                    $matchingEndpoints = @()
                    foreach ($connection in $connections) {
                        $endpoint = Get-Resource $connection.properties.privateEndpoint.id
                        $links = @($endpoint.properties.privateLinkServiceConnections) + @($endpoint.properties.manualPrivateLinkServiceConnections)
                        foreach ($link in $links) {
                            if ($link -and $link.properties.privateLinkServiceId -eq $storage.id -and
                                $link.properties.groupIds -contains $group -and
                                $link.properties.privateLinkServiceConnectionState.status -eq 'Approved' -and
                                $endpoint.properties.provisioningState -eq 'Succeeded') {
                                $matchingEndpoints += $endpoint.id
                            }
                        }
                    }
                    Assert-Value $label "Approved private endpoint: $group" `
                        ($matchingEndpoints.Count -gt 0) $group $matchingEndpoints
                }
                if ($purpose -eq 'content') {
                    $share = [string] $settings['WEBSITE_CONTENTSHARE']
                    Assert-Value $label 'Content share configured' `
                        (-not [string]::IsNullOrWhiteSpace($share)) 'Share name' $share
                    if ($share) {
                        $shareResource = Get-Resource "$($storage.id)/fileServices/default/shares/$share"
                        Assert-Value $label 'Content share exists' ($null -ne $shareResource.id) 'Existing share' $shareResource.id
                    }
                }
            }
            catch {
                Add-Result $label 'Storage validation' 'Error' 'Readable storage configuration' $null $_.Exception.Message
            }
        }
        Add-Result $Entry.key 'Function-to-storage runtime connectivity' 'NotTested' `
            'DNS, routing and authenticated storage access from Function runtime' $null `
            'Control-plane settings and approved endpoints do not prove runtime access. Runner probes execute outside the Function App.'
    }
    finally { $settings.Clear() }
}

function Get-PrincipalId {
    param($Permission)

    $sourceId = $resourceIds[$Permission.source]
    if (-not $sourceId) {
        throw "Unknown source alias: $($Permission.source)"
    }

    $source = Get-Resource $sourceId

    switch ($Permission.identity.type) {
        'systemAssigned' {
            $principal = $source.identity.principalId
        }

        'userAssigned' {
            $identityId = $Permission.identity.resourceId

            if (-not $identityId) {
                throw 'userAssigned identity requires resourceId.'
            }

            $attached = @(
                $source.identity.userAssignedIdentities.PSObject.Properties.Name
            )

            if ($attached -notcontains $identityId) {
                throw "Expected user-assigned identity is not attached to source."
            }

            $identityResource = Get-Resource $identityId
            $principal = $identityResource.properties.principalId
        }

        default {
            throw 'identity.type must be systemAssigned or userAssigned.'
        }
    }

    if (-not $principal) {
        throw 'Managed identity principal ID is missing.'
    }

    return [string] $principal
}

function Quote-SqlLiteral {
    param([string] $Value)

    # Values are SQL string literals, never raw SQL fragments.
    return "'" + $Value.Replace("'", "''") + "'"
}

function Invoke-PgBoolean {
    param($Permission, [string] $Sql)

    if (-not (Get-Command psql -ErrorAction SilentlyContinue)) {
        throw 'psql is not installed or is not on PATH.'
    }

    $stderrFile = [IO.Path]::GetTempFileName()
    try {
        # Authentication comes from PGPASSWORD, .pgpass, or libpq configuration.
        # --no-password prevents an unattended run from prompting.
        $arguments = @(
            '--no-psqlrc',
            '--no-password',
            '--tuples-only',
            '--no-align',
            '--set', 'ON_ERROR_STOP=1',
            '--host', $Permission.host,
            '--port', '5432',
            '--username', $Permission.validationUser,
            '--dbname', $Permission.database,
            '--command', $Sql
        )

        $stdout = & psql @arguments 2> $stderrFile
        $code = $LASTEXITCODE

        if ($code -ne 0) {
            $message = Get-Content -LiteralPath $stderrFile -Raw
            throw "psql exited with code ${code}: $message"
        }

        $answer = ($stdout -join "`n").Trim()

        if ($answer -notin @('t', 'f')) {
            throw 'PostgreSQL query did not return a single boolean.'
        }

        return ($answer -eq 't')
    }
    finally {
        Remove-Item -LiteralPath $stderrFile -Force -ErrorAction SilentlyContinue
    }
}

# ---------- Inventory validation ----------

if (-not (Test-Path -LiteralPath $InventoryPath -PathType Leaf) -or
    [IO.Path]::GetExtension($InventoryPath) -ne '.json') {
    throw 'InventoryPath must point to an application definition JSON file.'
}
$inventory = Get-Content -LiteralPath $InventoryPath -Raw | ConvertFrom-Json

if (-not $inventory.application -or -not $inventory.resources) {
    throw 'Inventory requires application and a nonempty resources array.'
}

foreach ($entry in $inventory.resources) {
    if (-not $entry.key -or $entries.ContainsKey($entry.key)) {
        throw "Missing or duplicate resource key: $($entry.key)"
    }

    $resourceType = $types[$entry.type]
    if (-not $resourceType) {
        throw "Unsupported resource type: $($entry.type)"
    }

    $entries[$entry.key] = $entry
    $resourceIds[$entry.key] = Get-EntryId $entry $resourceType

    foreach ($check in @($entry.checks | Where-Object { $null -ne $_ })) {
        if (-not $check.path) {
            throw "Property check for $($entry.key) requires path."
        }

        if ($check.operator -and $check.operator -notin @('equals', 'exists')) {
            throw "Unsupported property operator: $($check.operator)"
        }

        if ($check.operator -ne 'exists' -and
            -not $check.expectedResource -and
            -not $check.PSObject.Properties['expected']) {
            throw "Check $($check.path) requires expected or expectedResource."
        }
    }
}

foreach ($entry in $inventory.resources) {
    if ($entry.functionValidation) {
        if ($entry.type -ne 'functionApp') { throw 'functionValidation requires a functionApp resource.' }
        foreach ($traffic in @('applicationTraffic', 'contentShareTraffic')) {
            if ($entry.functionValidation.PSObject.Properties[$traffic] -and
                $entry.functionValidation.$traffic -isnot [bool]) {
                throw "functionValidation.$traffic requires a boolean."
            }
        }
        foreach ($purpose in @('host', 'content')) {
            $policy = $entry.functionValidation.$purpose
            if ($policy.expectedResource -and
                (-not $entries.ContainsKey($policy.expectedResource) -or
                    $entries[$policy.expectedResource].type -ne 'storageAccount')) {
                throw "functionValidation.$purpose.expectedResource must reference a storageAccount."
            }
            foreach ($check in @($policy.checks | Where-Object { $null -ne $_ })) {
                if (-not $check.path -or -not $check.PSObject.Properties['expected']) {
                    throw "functionValidation.$purpose.checks requires path and expected."
                }
            }
            foreach ($group in @($policy.privateEndpointGroups | Where-Object { $null -ne $_ })) {
                if ($group -notin @('blob', 'queue', 'table', 'file')) {
                    throw "Unsupported Function storage private endpoint group: $group"
                }
            }
        }
    }
    foreach ($check in @($entry.checks | Where-Object { $null -ne $_ })) {
        if ($check.expectedResource -and
            -not $resourceIds.ContainsKey($check.expectedResource)) {
            throw "Unknown expectedResource: $($check.expectedResource)"
        }
    }
}

foreach ($pe in @($inventory.privateEndpoints | Where-Object { $null -ne $_ })) {
    if (-not $resourceIds.ContainsKey($pe.target) -or -not $pe.groupId) {
        throw 'Private endpoint requires a known target and groupId.'
    }
}

foreach ($permission in @($inventory.permissions | Where-Object { $null -ne $_ })) {
    if (-not $resourceIds.ContainsKey($permission.source) -or
        -not $resourceIds.ContainsKey($permission.target)) {
        throw 'Permission source and target must reference resource keys.'
    }

    if ($permission.kind -notin @('cosmosNoSql', 'postgres')) {
        throw "Unsupported permission kind: $($permission.kind)"
    }

    if ($permission.kind -eq 'cosmosNoSql' -and
        (-not $permission.roleDefinitionId -or -not $permission.scope)) {
        throw 'Cosmos permission requires roleDefinitionId and scope.'
    }

    if ($permission.kind -eq 'postgres') {
        foreach ($field in @(
            'host', 'database', 'databaseRole', 'validationUser'
        )) {
            if (-not $permission.$field) {
                throw "PostgreSQL permission requires $field."
            }
        }

        foreach ($grant in @($permission.grants | Where-Object { $null -ne $_ })) {
            if ($grant.kind -notin @(
                'database', 'schema', 'table', 'sequence'
            ) -or -not $grant.object -or -not $grant.privilege) {
                throw 'Invalid PostgreSQL grant entry.'
            }
        }
    }
}

if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    throw 'Azure CLI is not installed or is not on PATH.'
}

$null = Invoke-AzJson @('account', 'show')

# ---------- Resource configuration ----------

foreach ($entry in $inventory.resources) {
    try {
        $resource = Get-Resource $resourceIds[$entry.key]
        Add-Result $entry.key 'Resource exists' 'Pass' $true $true

        foreach ($check in @($entry.checks | Where-Object { $null -ne $_ })) {
            $actual = Get-PropertyPath $resource $check.path

            if ($check.operator -eq 'exists') {
                $passed = $null -ne $actual -and
                    -not [string]::IsNullOrWhiteSpace([string] $actual)

                Assert-Value $entry.key $check.path $passed 'Present' $actual
                continue
            }

            $expected = if ($check.expectedResource) {
                $resourceIds[$check.expectedResource]
            } else {
                $check.expected
            }

            # Missing/null properties do not satisfy an explicit expectation.
            $passed = $null -ne $actual -and (Test-ExpectedValue $actual $expected)

            Assert-Value $entry.key $check.path $passed $expected $actual
        }
    }
    catch {
        Add-Result $entry.key 'Resource configuration' 'Error' `
            'Readable resource' $null $_.Exception.Message
    }
}

# ---------- Function outbound routing and discovered backing storage ----------

foreach ($entry in $inventory.resources | Where-Object { $_.type -eq 'functionApp' -and $_.functionValidation }) {
    try { Test-FunctionInfrastructure $entry }
    catch {
        Add-Result $entry.key 'Function infrastructure' 'Error' 'Readable Function configuration' $null $_.Exception.Message
    }
}

# ---------- Private endpoints ----------

foreach ($pe in @($inventory.privateEndpoints | Where-Object { $null -ne $_ })) {
    try {
        $id = Get-EntryId $pe 'Microsoft.Network/privateEndpoints'
        $endpoint = Get-Resource $id

        Assert-Value $pe.name 'Provisioning state' `
            ($endpoint.properties.provisioningState -eq 'Succeeded') `
            'Succeeded' $endpoint.properties.provisioningState

        if ($pe.subnetId) {
            Assert-Value $pe.name 'Subnet' `
                ($endpoint.properties.subnet.id -eq $pe.subnetId) `
                $pe.subnetId $endpoint.properties.subnet.id
        }

        $connections = @(
            $endpoint.properties.privateLinkServiceConnections
        ) + @(
            $endpoint.properties.manualPrivateLinkServiceConnections
        )

        $matches = @($connections | Where-Object {
            $_ -and
            $_.properties.privateLinkServiceId -eq $resourceIds[$pe.target] -and
            $_.properties.groupIds -contains $pe.groupId
        })

        Assert-Value $pe.name 'Target and subresource' `
            ($matches.Count -gt 0) `
            "$($resourceIds[$pe.target]) / $($pe.groupId)" `
            @($connections | ForEach-Object {
                if ($_) {
                    "$($_.properties.privateLinkServiceId) / $($_.properties.groupIds -join ',')"
                }
            })

        $approved = @($matches | Where-Object {
            $_.properties.privateLinkServiceConnectionState.status -eq 'Approved'
        })

        Assert-Value $pe.name 'Matching connection approved' `
            ($approved.Count -gt 0) 'Approved' `
            @($matches | ForEach-Object {
                $_.properties.privateLinkServiceConnectionState.status
            })
    }
    catch {
        Add-Result $pe.name 'Private endpoint' 'Error' `
            'Readable endpoint' $null $_.Exception.Message
    }
}

# ---------- Private DNS zone links ----------

foreach ($link in @($inventory.dnsLinks | Where-Object { $null -ne $_ })) {
    try {
        $dnsEntry = [pscustomobject]@{
            resourceId    = $link.resourceId
            subscriptionId = $link.subscriptionId
            resourceGroup = $link.resourceGroup
            name          = "$($link.zoneName)/$($link.linkName)"
        }

        $id = Get-EntryId $dnsEntry `
            'Microsoft.Network/privateDnsZones/virtualNetworkLinks'

        $resource = Get-Resource $id

        Assert-Value $link.linkName 'DNS VNet link' `
            ($resource.properties.virtualNetwork.id -eq $link.vnetId) `
            $link.vnetId $resource.properties.virtualNetwork.id

        Assert-Value $link.linkName 'DNS link state' `
            ($resource.properties.virtualNetworkLinkState -eq 'Completed') `
            'Completed' $resource.properties.virtualNetworkLinkState
    }
    catch {
        Add-Result $link.linkName 'DNS VNet link' 'Error' `
            'Readable link' $null $_.Exception.Message
    }
}

# ---------- Network tests: validation runner's perspective ----------

foreach ($probe in @($inventory.networkProbes | Where-Object { $null -ne $_ })) {
    if (-not $RunNetworkChecks) {
        Add-Result $probe.name 'DNS/TCP from runner' 'NotTested' `
            'Run with -RunNetworkChecks' $null
        continue
    }

    try {
        $addresses = @(
            [Net.Dns]::GetHostAddresses($probe.hostname) |
                ForEach-Object { $_.IPAddressToString } |
                Sort-Object -Unique
        )

        if (@($probe.expectedAddresses).Count -eq 0) {
            throw 'Network probe requires expectedAddresses.'
        }

        $difference = @(
            Compare-Object `
                -ReferenceObject @($probe.expectedAddresses | Sort-Object -Unique) `
                -DifferenceObject $addresses
        )

        Assert-Value $probe.name 'DNS addresses from runner' `
            ($difference.Count -eq 0) $probe.expectedAddresses $addresses

        if ($probe.port) {
            $client = [Net.Sockets.TcpClient]::new()
            try {
                $task = $client.ConnectAsync(
                    [string] $probe.hostname,
                    [int] $probe.port
                )

                if (-not $task.Wait(5000)) {
                    throw 'TCP connection timed out after five seconds.'
                }

                $task.GetAwaiter().GetResult()

                Assert-Value $probe.name 'TCP from runner' `
                    $client.Connected 'Connected' $client.Connected
            }
            finally {
                $client.Dispose()
            }
        }
    }
    catch {
        Add-Result $probe.name 'Network probe' 'Error' `
            'Successful DNS/TCP test' $null $_.Exception.Message
    }
}

# ---------- Permissions ----------

foreach ($permission in @($inventory.permissions | Where-Object { $null -ne $_ })) {
    $label = "$($permission.source) -> $($permission.target)"

    try {
        $principalId = Get-PrincipalId $permission
        Add-Result $label 'Managed identity attached' 'Pass' `
            $permission.identity.type $principalId

        if ($permission.kind -eq 'cosmosNoSql') {
            if ($entries[$permission.target].type -ne 'cosmosAccount') {
                throw 'cosmosNoSql target must be a cosmosAccount.'
            }

            $accountId = $resourceIds[$permission.target]

            if ($accountId -notmatch '^/subscriptions/([^/]+)/resourceGroups/([^/]+)/providers/Microsoft\.DocumentDB/databaseAccounts/([^/]+)$') {
                throw "Invalid Cosmos account resource ID: $accountId"
            }
            $assignments = @(Invoke-AzJson @(
                'cosmosdb', 'sql', 'role', 'assignment', 'list',
                '--subscription', $Matches[1],
                '--resource-group', $Matches[2],
                '--account-name', $Matches[3]
            ))
            $expectedRoleId = if (
                $permission.roleDefinitionId.StartsWith('/')
            ) {
                $permission.roleDefinitionId
            } else {
                "$accountId/sqlRoleDefinitions/$($permission.roleDefinitionId)"
            }

            $expectedScope = if (
                $permission.scope.StartsWith(
                    '/subscriptions/',
                    [StringComparison]::OrdinalIgnoreCase
                )
            ) {
                $permission.scope.TrimEnd('/')
            } else {
                $accountId + $permission.scope.TrimEnd('/')
            }

            $matching = @($assignments | Where-Object {
                $_.principalId -eq $principalId -and
                $_.roleDefinitionId -eq $expectedRoleId -and
                $_.scope -and $_.scope.TrimEnd('/') -eq $expectedScope
            })

            Assert-Value $label 'Exact Cosmos NoSQL role assignment' `
                ($matching.Count -gt 0) `
                "$expectedRoleId at $expectedScope" `
                @($matching.id)

            continue
        }

        if (-not $RunPostgresChecks) {
            Add-Result $label 'PostgreSQL identity and grants' 'NotTested' `
                'Run with -RunPostgresChecks' $null
            continue
        }

        if ($entries[$permission.target].type -ne 'postgresFlexibleServer') {
            throw 'postgres target must be a postgresFlexibleServer.'
        }

        $roleLiteral = Quote-SqlLiteral $permission.databaseRole
        $principalLiteral = Quote-SqlLiteral $principalId

        # Convert returned columns to JSON so objectId casing does not
        # depend on how PostgreSQL exposes the extension's column names.
        $mappingSql = @"
BEGIN READ ONLY;
SET LOCAL standard_conforming_strings = on;
SELECT EXISTS (
    SELECT 1
    FROM pg_catalog.pgaadauth_list_principals(false) AS p
    WHERE to_jsonb(p)->>'rolename' = $roleLiteral
      AND lower(
          COALESCE(
              to_jsonb(p)->>'objectId',
              to_jsonb(p)->>'objectid'
          )
      ) = lower($principalLiteral)
);
ROLLBACK;
"@

        # Quiet mode suppresses transaction command tags.
        # The SQL below instead uses a single SELECT for the boolean helper.
        $mappingSql = @"
SELECT EXISTS (
    SELECT 1
    FROM pg_catalog.pgaadauth_list_principals(false) AS p
    WHERE to_jsonb(p)->>'rolename' = $roleLiteral
      AND lower(COALESCE(
          to_jsonb(p)->>'objectId',
          to_jsonb(p)->>'objectid'
      )) = lower($principalLiteral)
);
"@

        $mapped = Invoke-PgBoolean $permission $mappingSql

        Assert-Value $label 'PostgreSQL role maps to identity' `
            $mapped $principalId $mapped

        foreach ($grant in @($permission.grants | Where-Object { $null -ne $_ })) {
            $function = switch ($grant.kind) {
                'database' { 'has_database_privilege' }
                'schema'   { 'has_schema_privilege' }
                'table'    { 'has_table_privilege' }
                'sequence' { 'has_sequence_privilege' }
            }

            $objectLiteral = Quote-SqlLiteral $grant.object
            $privilegeLiteral = Quote-SqlLiteral $grant.privilege

            $sql = "SELECT pg_catalog.$function(" +
                "$roleLiteral, $objectLiteral, $privilegeLiteral);"

            try {
                $allowed = Invoke-PgBoolean $permission $sql

                Assert-Value $label `
                    "$($grant.kind): $($grant.object) / $($grant.privilege)" `
                    $allowed $true $allowed
            }
            catch {
                Add-Result $label `
                    "$($grant.kind): $($grant.object) / $($grant.privilege)" `
                    'Error' $true $null $_.Exception.Message
            }
        }
    }
    catch {
        Add-Result $label 'Permission validation' 'Error' `
            'Expected identity and access' $null $_.Exception.Message
    }
}

# ---------- Reports ----------

$null = New-Item -ItemType Directory -Path $OutputDirectory -Force

$results.ToArray() |
    ConvertTo-Json -Depth 20 |
    Set-Content -LiteralPath (Join-Path $OutputDirectory 'results.json') `
        -Encoding utf8

$style = @'
<style>
body { font-family: Segoe UI, sans-serif; margin: 24px; }
table { border-collapse: collapse; width: 100%; }
th, td { border: 1px solid #ddd; padding: 8px; text-align: left; }
th { background: #eef2f6; }
td { overflow-wrap: anywhere; }
</style>
'@

$results.ToArray() |
    ConvertTo-Html -Title 'Application infrastructure validation' -Head $style |
    Set-Content -LiteralPath (Join-Path $OutputDirectory 'results.html') `
        -Encoding utf8

$results.ToArray() |
    Format-Table Resource, Check, Status -AutoSize

$summary = $results.ToArray() |
    Group-Object Status |
    Select-Object Name, Count

$summary | Format-Table -AutoSize

if (@($results | Where-Object Status -eq 'Error').Count -gt 0) {
    exit 2
}

if (@($results | Where-Object Status -eq 'Fail').Count -gt 0) {
    exit 1
}

if ($FailOnNotTested -and
    @($results | Where-Object Status -eq 'NotTested').Count -gt 0) {
    exit 3
}

exit 0

