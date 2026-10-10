# Application infrastructure validation

Define the application in `application.json`. This is the only inventory input
format. The checked-in definition is an example: replace its placeholder
subscription ID, resource names, resource groups, subnet IDs, private IPs and
database details with your environment's values before running validation.

Install PowerShell 7 (`pwsh`) and Azure CLI, then sign in with `az login`.
The Azure identity needs read access to the resources and role assignments being
validated. Function storage discovery also needs access to list app settings.
Install `psql` if you enable PostgreSQL checks.

```powershell
az login
pwsh -File ./Test-AppInfrastructure.ps1 -OutputDirectory ./reports/orders-dev

# Use a different application definition, or enable probes from this runner.
pwsh -File ./Test-AppInfrastructure.ps1 `
    -InventoryPath ./application.json `
    -OutputDirectory ./reports/orders-dev `
    -RunNetworkChecks
```

The default definition is `application.json` beside the script. The default report
directory is `./validation-results`, relative to the current working directory.
Each run writes `results.json` and `results.html` and prints a status summary.
Exit codes are 0 for no failed checks, 1 for failed expectations, 2 for validation
errors, and 3 for `NotTested` checks when `-FailOnNotTested` is enabled. Invalid
definitions and missing prerequisites terminate the script before validation.

## Define the application

- `application` and a nonempty `resources` array are required. `environment`,
  `subscriptionId` and `resourceGroup` provide shared defaults.
- `resources`: each entry has a unique `key`, a supported `type`, and a `name`
  or full `resourceId`. An entry can override `subscriptionId` and `resourceGroup`.
  Supported types: `containerApp`, `containerAppEnvironment`, `functionApp`,
  `storageAccount`, `postgresFlexibleServer`, `cosmosAccount`, `managedIdentity`.
- `checks`: dotted property `path` with `expected` (native JSON string, boolean,
  number, array or object), or `expectedResource` referencing a resource key.
  `operator` defaults to `equals`; use `exists` to require a populated property.
- `privateEndpoints`: endpoint `name`, resource-key `target`, `groupId`, and
  optional expected `subnetId`. Resource location overrides are supported.
- `dnsLinks`: `zoneName`, `linkName`, expected `vnetId`, and the zone's
  `resourceGroup`/`subscriptionId` if different from the application defaults.
- `networkProbes`: `name`, `hostname`, `expectedAddresses` array, and `port`.
  These run only with `-RunNetworkChecks`.
- `permissions`: resource-key `source` and `target`, identity definition, and
  `kind` (`cosmosNoSql` or `postgres`). See the sample for role, scope and grant
  definitions. PostgreSQL checks run only with `-RunPostgresChecks`.

Optional sections may be omitted or set to empty arrays. Keep credentials out of
the definition. PostgreSQL credentials come from the runner's `PGPASSWORD`.

## PostgreSQL validation

Use a validation user allowed to inspect the database roles and grants. For an
Entra-authenticated validation user, obtain a token before running the script:

```powershell
$token = az account get-access-token `
    --resource https://ossrdbms-aad.database.windows.net `
    --query accessToken --output tsv
if ($LASTEXITCODE -ne 0) { throw 'Failed to obtain PostgreSQL access token.' }
$env:PGPASSWORD = $token
try {
    pwsh -File ./Test-AppInfrastructure.ps1 `
        -RunNetworkChecks -RunPostgresChecks -FailOnNotTested
}
finally {
    Remove-Item Env:PGPASSWORD -ErrorAction SilentlyContinue
    $token = $null
}
```

## Function App outbound integration and backing storage

The Function App resource can enable extra checks with `functionValidation`.
The sample inventory checks outbound application routing, content-share routing,
and the storage account actually configured for `AzureWebJobsStorage`.
The existing `properties.virtualNetworkSubnetId` check also validates the expected subnet.

Storage discovery reads Function App settings using Azure CLI and supports:

- `AzureWebJobsStorage` connection strings.
- `AzureWebJobsStorage__accountName` for managed identity connections.
- Standard Azure, Azure Government and Azure China blob/queue/table service URIs.
- `WEBSITE_CONTENTAZUREFILECONNECTIONSTRING` for separate Azure Files content storage.

Connection strings and account keys are never included in reports. Key Vault
references and custom endpoint names are reported as `NotTested`; the script
does not resolve secrets. Reading app settings requires the corresponding
Microsoft.Web configuration list permission in addition to resource read access.

`host.expectedResource` optionally links the discovered host account to a storage
resource key in the inventory. Without it, the script discovers the account in
the Function App subscription. Use `host.subscriptionId` for automatic discovery
in another subscription, or an inventory storage resource with a full resource ID.
Storage expectations are explicit `path`/`expected` pairs in `host.checks`.
`host.privateEndpointGroups` checks approved, successfully provisioned private
endpoints for the specified subresources. Adjust the sample blob/queue/table list
to the services used by your application.

Content storage is discovered separately when configured; it need not be the host
account. To enforce its policy, add this beside `host` in `functionValidation`:

```json
"content": {
  "checks": [
    { "path": "properties.publicNetworkAccess", "expected": "Disabled" },
    { "path": "properties.supportsHttpsTrafficOnly", "expected": true },
    { "path": "properties.minimumTlsVersion", "expected": "TLS1_2" }
  ],
  "privateEndpointGroups": ["file"]
}
```

When Azure Files content storage is discovered, the script also checks
`WEBSITE_CONTENTSHARE` and the share's existence through the management API.
An absent content connection is skipped if no content policy is configured,
because not every hosting plan uses Azure Files. A configured content policy
makes an absent connection a failure. Hosting configurations that keep their
storage outside these app settings require additional validation.

Routing checks support `outboundVnetRouting.allTraffic`, individual application
and content flags, and legacy site/app settings. A modern individual flag takes
precedence over its legacy counterpart; `allTraffic=true` enables both checks.
See [Microsoft's routing reference](https://learn.microsoft.com/en-us/azure/app-service/configure-vnet-integration-routing)
and [Function connection settings](https://learn.microsoft.com/en-us/azure/azure-functions/manage-connections).

These are configuration checks. Function-to-storage DNS resolution, NSG/UDR
behavior, and authenticated data access still require tests from the Function
runtime and are explicitly reported as `NotTested`. `-FailOnNotTested` therefore
fails the gate until those limitations are addressed. `-RunNetworkChecks` probes
execute from the validation runner, not the Function App.

Run offline regression checks with:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ./tests/Test-AppInfrastructure.Tests.ps1
```


