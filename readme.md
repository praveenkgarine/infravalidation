# Application infrastructure validation

Define the application in `application.json`. This is the only inventory input
format. The checked-in definition is an example: replace its placeholder
subscription ID, resource names, resource groups, subnet IDs, private IPs and
database details with your environment's values before running validation.
The Logic App, ACR, SQL server and SQL database examples start with `enabled: false`;
enable the entries used by your application. Update `privateDns` with the separate
subscription and resource group containing your private DNS zones. Update the ACR
data hostname's region and include every data/geo endpoint that your registry uses.

Install PowerShell 7 (`pwsh`) and Azure CLI, then sign in with `az login`.
The Azure identity needs read access to the resources and role assignments being
validated. Function storage discovery also needs access to list app settings.
Install `psql` if you enable PostgreSQL checks.
Private endpoint DNS probes use Windows `Resolve-DnsName`; run them from your
Windows VDI with `-RunNetworkChecks`. No Node.js packages or `tools` folder are needed.

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
  `storageAccount`, `postgresFlexibleServer`, `cosmosAccount`, `managedIdentity`,
  `logicAppStandard`, `logicAppConsumption`, `containerRegistry`, `sqlServer`,
  `sqlDatabase`.
- `checks`: dotted property `path` with `expected` (native JSON string, boolean,
  number, array or object), or `expectedResource` referencing a resource key.
  `operator` defaults to `equals`; use `exists` to require a populated property.
- `privateEndpoints`: endpoint `name`, resource-key `target`, `groupId`, and
  optional expected `subnetId` and `dnsRecords`. Resource location overrides are supported.
- `dnsLinks`: `zoneName`, `linkName`, expected `vnetId`, and the zone's
  `resourceGroup`/`subscriptionId`. These inherit `privateDns` defaults when present,
  otherwise the application defaults.
- `networkProbes`: `name`, `hostname`, `expectedAddresses` array, and `port`.
  These run only with `-RunNetworkChecks`. Add `target` to associate a probe with a
  resource key so disabling that resource also skips its probe.
- `permissions`: resource-key `source` and `target`, identity definition, and
  `kind` (`cosmosNoSql` or `postgres`). See the sample for role, scope and grant
  definitions. PostgreSQL checks run only with `-RunPostgresChecks`.

Optional sections may be omitted or set to empty arrays. Keep credentials out of
the definition. PostgreSQL credentials come from the runner's `PGPASSWORD`.

## Include only the resources used by each application

Use separate definitions, for example `app1.json` and `app2.json`, selected with
`-InventoryPath`. Omit unused resources and their endpoint/permission definitions,
or keep a shared inventory shape and disable a resource type:

```json
"resourceTypes": {
  "postgresFlexibleServer": false,
  "containerRegistry": true,
  "sqlServer": true,
  "sqlDatabase": true
}
```

For app2, set `postgresFlexibleServer` to `true` and supply its actual PostgreSQL
resource details. Missing type settings default to included. An individual
resource can set `"enabled": false`, even when its type is included. Disabled
resources, their private endpoints, their permissions (source or target), and
network probes with a matching `target` appear as `Skipped` and do not issue
Azure or network requests. `Skipped` does not fail `-FailOnNotTested`.
Disabled entries need a unique `key` and supported `type`; their deployment names
can be omitted. Enabled resources must not reference disabled resources through
`expectedResource`. Disabled means excluded from validation; it does not assert
that the resource is absent from Azure.

## Logic Apps, Azure Container Registry and Azure SQL

| Inventory type | Azure resource type | Name format | Private endpoint group |
| --- | --- | --- | --- |
| `logicAppStandard` | `Microsoft.Web/sites` | `logic-orders-dev` | `sites` |
| `logicAppConsumption` | `Microsoft.Logic/workflows` | `workflow-orders-dev` | Not supported here |
| `containerRegistry` | `Microsoft.ContainerRegistry/registries` | `acrordersdev` | `registry` |
| `sqlServer` | `Microsoft.Sql/servers` | `sql-orders-dev` | `sqlServer` |
| `sqlDatabase` | `Microsoft.Sql/servers/databases` | `sql-orders-dev/orders` | Use the parent `sqlServer` |

Standard Logic App validation also verifies that the site kind contains
`workflowapp`. Both Logic App hosting models support normal property checks;
private endpoints require Standard hosting. SQL databases have independent
existence and property checks, while DNS and private endpoints attach to the
logical SQL server. These checks do not execute SQL queries or validate SQL
database permissions. Add a `networkProbes` entry for TCP port 1433 if needed.

ACR examples check Premium SKU, disabled public access and disabled admin login.
ACR uses distinct NIC IPs for the registry hostname and regional data endpoints.
Include a DNS record entry for each endpoint/region used by your application,
including regional geo endpoints when enabled. The validator checks the entries
you configure; it does not automatically enumerate every registry replica.
See Microsoft's [ACR private endpoint guidance](https://learn.microsoft.com/en-us/azure/container-registry/container-registry-private-endpoints),
[Standard Logic App networking](https://learn.microsoft.com/en-us/azure/logic-apps/secure-single-tenant-workflow-virtual-network-private-endpoint),
and [Azure SQL Private Link](https://learn.microsoft.com/en-us/azure/azure-sql/database/private-endpoint-overview?view=azuresql).

## Compare endpoint IPs, Azure private DNS and on-premises VDI DNS

Configure the shared DNS location, independently of the application subscription:

```json
"privateDns": {
  "subscriptionId": "11111111-1111-1111-1111-111111111111",
  "resourceGroup": "rg-private-dns"
}
```

The endpoint can live in a different subscription or RG too: set its own
`subscriptionId`/`resourceGroup` or `resourceId`. Add hostname-specific DNS records:

```json
{
  "name": "pe-orders-acr",
  "target": "acr",
  "groupId": "registry",
  "dnsRecords": [
    {
      "hostname": "acrordersdev.azurecr.io",
      "zoneName": "privatelink.azurecr.io",
      "recordName": "acrordersdev"
    },
    {
      "hostname": "acrordersdev.eastus.data.azurecr.io",
      "zoneName": "privatelink.azurecr.io",
      "recordName": "acrordersdev.eastus.data"
    }
  ]
}
```

For every configured record, the report separately checks:

1. The hostname maps to IPs actually assigned to the private endpoint NIC.
2. The Azure private DNS A record exists/read access succeeds and its full IP set
   exactly matches those hostname-specific NIC IPs.
3. With `-RunNetworkChecks`, the hostname resolves from the VDI to that same IP set.

The endpoint must be successfully provisioned with an approved connection to
the configured resource and subresource before DNS validation runs. The Azure
identity needs read access to the endpoints, their NICs, and the private DNS A
records in the separate DNS subscription. No subscription switching is needed;
the script reads fully qualified resource IDs.

VDI queries use `Resolve-DnsName -Type A -DnsOnly -NoHostsFile`, follow CNAMEs and
use the VDI's configured DNS servers by default. This checks the DNS answer you
would inspect with `nslookup` without depending on localized command output or
hosts-file overrides. Set `privateDns.dnsServer` to an on-premises DNS server IP
to query that server explicitly; a record's `dnsServer` overrides it. The test
verifies the effective DNS answer, not the contents of the on-premises DNS server's
zone database (which could be forwarding to Azure). Public IPs, extra addresses,
missing records, and unresolved names cannot pass.

Each record can override `subscriptionId` and `resourceGroup`. For a custom
on-premises alias, set `hostname` to that alias and `endpointFqdn` to the Azure
hostname shown in the endpoint NIC DNS metadata. If Azure omits hostname metadata,
set `ipConfigurationName` to the exact NIC IP configuration name. An ambiguous
hostname never falls back to comparing all NIC IPs. This version validates IPv4
A records; configure each storage subresource or other service hostname separately.
Without `-RunNetworkChecks`, Azure DNS is still checked and VDI resolution is
reported as `NotTested`.

```powershell
pwsh -File ./Test-AppInfrastructure.ps1 `
    -InventoryPath ./app1.json `
    -OutputDirectory ./reports/app1 `
    -RunNetworkChecks
```

`dnsRecords` discovers current endpoint IPs, so it needs no hardcoded
`expectedAddresses`. The older `networkProbes` entries still compare configured
static IPs and optionally test TCP; update or remove their static IP expectations
when you use the dynamic endpoint DNS checks instead.

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


