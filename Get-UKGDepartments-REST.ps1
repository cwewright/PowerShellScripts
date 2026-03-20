<#
.SYNOPSIS
    Retrieves all organizations (departments) from UKG HR Service Delivery API
    and writes unique entries to a Dataverse table.

.DESCRIPTION
    Uses the UKG HRSD REST API v2 (client.yml Swagger spec):
      - POST /api/v2/client/tokens  — OAuth client_credentials to get Bearer token
      - GET  /api/v2/client/organizations — list all orgs (recursive, paginated)

    Auth: OAuth2 client_credentials using application_id + application_secret
    via Basic auth to the /tokens endpoint, then Bearer token on all other calls.

    Designed for Azure Automation (PowerShell 7.1 runtime).

.NOTES
    Required Azure Automation Variables (encrypted where noted):
      - UKG_HRSD_BaseUrl          e.g. https://apis.us.people-doc.com
      - UKG_HRSD_ApplicationId    (encrypted) — OAuth application ID
      - UKG_HRSD_ApplicationSecret (encrypted) — OAuth application secret
      - UKG_HRSD_ClientId         — The client ID for scope=client token requests
      - Dataverse_TenantId
      - Dataverse_ClientId
      - Dataverse_ClientSecret    (encrypted)
      - Dataverse_EnvironmentUrl  e.g. https://yourorg.crm.dynamics.com

    Required Dataverse Table:
      - Table: cr_ukgdepartments (or your prefix)
      - Columns: cr_name, cr_description, cr_organizationid, cr_parentorganizationid,
                 cr_haschildren
#>

# -------------------------------------------------------------------
# 1. CONFIGURATION — Pull from Azure Automation variables
# -------------------------------------------------------------------
$ukgBaseUrl          = Get-AutomationVariable -Name 'UKG_HRSD_BaseUrl'            # e.g. https://apis.us.people-doc.com
$ukgAppId            = Get-AutomationVariable -Name 'UKG_HRSD_ApplicationId'
$ukgAppSecret        = Get-AutomationVariable -Name 'UKG_HRSD_ApplicationSecret'
$ukgClientId         = Get-AutomationVariable -Name 'UKG_HRSD_ClientId'

$dataverseTenantId     = Get-AutomationVariable -Name 'Dataverse_TenantId'
$dataverseClientId     = Get-AutomationVariable -Name 'Dataverse_ClientId'
$dataverseClientSecret = Get-AutomationVariable -Name 'Dataverse_ClientSecret'
$dataverseUrl          = Get-AutomationVariable -Name 'Dataverse_EnvironmentUrl'  # e.g. https://yourorg.crm.dynamics.com

# Dataverse table/column configuration — adjust the schema name prefix to match yours
$dataverseTable              = 'cr_ukgdepartments'
$colName                     = 'cr_name'
$colDescription              = 'cr_description'
$colOrganizationId           = 'cr_organizationid'
$colParentOrganizationId     = 'cr_parentorganizationid'
$colHasChildren              = 'cr_haschildren'

# -------------------------------------------------------------------
# 2. AUTHENTICATE TO UKG HRSD API (OAuth2 client_credentials)
# -------------------------------------------------------------------
# POST /api/v2/client/tokens
# Authorization: Basic base64(application_id:application_secret)
# Body (form): grant_type=client_credentials&scope=client&client_id=YOUR_CLIENT_ID
# Returns: { access_token, token_type: "bearer", expires_in }
# -------------------------------------------------------------------

Write-Output "Authenticating to UKG HRSD API..."

$basicAuth = [Convert]::ToBase64String(
    [Text.Encoding]::ASCII.GetBytes("${ukgAppId}:${ukgAppSecret}")
)

$tokenParams = @{
    Uri         = "$ukgBaseUrl/api/v2/client/tokens"
    Method      = 'POST'
    Headers     = @{ 'Authorization' = "Basic $basicAuth" }
    ContentType = 'application/x-www-form-urlencoded'
    Body        = "grant_type=client_credentials&scope=client&client_id=$ukgClientId"
}

$tokenResponse = Invoke-RestMethod @tokenParams

if (-not $tokenResponse.access_token) {
    throw "UKG HRSD OAuth failed. Check application_id, application_secret, and client_id."
}

$ukgToken = $tokenResponse.access_token
Write-Output "UKG HRSD authentication successful. Token expires in $($tokenResponse.expires_in)s."

$apiHeaders = @{
    'Authorization' = "Bearer $ukgToken"
    'Content-Type'  = 'application/json'
    'Accept'        = 'application/json'
}

# -------------------------------------------------------------------
# 3. RETRIEVE ALL ORGANIZATIONS (RECURSIVE)
# -------------------------------------------------------------------
# GET /api/v2/client/organizations?recursive=true&per_page=100
# Pagination: per_page (max 100, default 20) — no cursor on this endpoint,
# uses parent_organization_id / child_organization_id for traversal.
#
# Response: array of OrganizationFull objects:
#   { id, name, description, parent_organization_id, has_children,
#     corporate_name, address1, address2, zip_code, city, country,
#     contact_firstname, contact_lastname, contact_email, contact_phone_number,
#     created_at, updated_at }
# -------------------------------------------------------------------

Write-Output "Fetching all organizations from UKG HRSD..."

$allOrgs = [System.Collections.Generic.List[PSCustomObject]]::new()
$page = 1
$perPage = 100
$hasMore = $true

while ($hasMore) {
    $uri = "$ukgBaseUrl/api/v2/client/organizations?recursive=true&per_page=$perPage&page=$page"

    try {
        $response = Invoke-RestMethod -Uri $uri -Method GET -Headers $apiHeaders
    }
    catch {
        $statusCode = $_.Exception.Response.StatusCode.value__
        Write-Warning "Error fetching organizations page $page (HTTP $statusCode): $($_.Exception.Message)"
        break
    }

    if ($response -and $response.Count -gt 0) {
        foreach ($org in $response) {
            $allOrgs.Add([PSCustomObject]@{
                Id                   = $org.id
                Name                 = $org.name
                Description          = $org.description
                ParentOrganizationId = $org.parent_organization_id
                HasChildren          = $org.has_children
            })
        }
        Write-Output "  Page $page — retrieved $($response.Count) organizations (total so far: $($allOrgs.Count))"
        $page++
        if ($response.Count -lt $perPage) { $hasMore = $false }
    }
    else {
        $hasMore = $false
    }
}

Write-Output "Retrieved $($allOrgs.Count) total organizations."

# -------------------------------------------------------------------
# 4. DEDUPLICATE BY ORGANIZATION ID
# -------------------------------------------------------------------

$uniqueOrgs = $allOrgs |
    Sort-Object Id -Unique

Write-Output "Found $($uniqueOrgs.Count) unique organizations."

# -------------------------------------------------------------------
# 5. AUTHENTICATE TO DATAVERSE
# -------------------------------------------------------------------

Write-Output "Authenticating to Dataverse..."

$dvTokenBody = @{
    grant_type    = 'client_credentials'
    client_id     = $dataverseClientId
    client_secret = $dataverseClientSecret
    scope         = "$dataverseUrl/.default"
}

$dvTokenResponse = Invoke-RestMethod `
    -Uri "https://login.microsoftonline.com/$dataverseTenantId/oauth2/v2.0/token" `
    -Method POST -Body $dvTokenBody -ContentType 'application/x-www-form-urlencoded'

$dvToken = $dvTokenResponse.access_token

if (-not $dvToken) {
    throw "Failed to authenticate to Dataverse. Check App Registration credentials."
}

$dvHeaders = @{
    'Authorization'    = "Bearer $dvToken"
    'Content-Type'     = 'application/json'
    'OData-MaxVersion' = '4.0'
    'OData-Version'    = '4.0'
    'Prefer'           = 'return=representation'
}

Write-Output "Dataverse authentication successful."

# -------------------------------------------------------------------
# 6. FETCH EXISTING RECORDS TO AVOID DUPLICATES
# -------------------------------------------------------------------

Write-Output "Fetching existing Dataverse records..."

$existingRecords = [System.Collections.Generic.HashSet[string]]::new()
$dvFetchUrl = "$dataverseUrl/api/data/v9.2/${dataverseTable}s?`$select=$colOrganizationId"

do {
    $dvResponse = Invoke-RestMethod -Uri $dvFetchUrl -Method GET -Headers $dvHeaders
    foreach ($record in $dvResponse.value) {
        $null = $existingRecords.Add($record.$colOrganizationId)
    }
    $dvFetchUrl = $dvResponse.'@odata.nextLink'
} while ($dvFetchUrl)

Write-Output "Found $($existingRecords.Count) existing records in Dataverse."

# -------------------------------------------------------------------
# 7. WRITE UNIQUE ORGANIZATIONS TO DATAVERSE
# -------------------------------------------------------------------

$created = 0
$skipped = 0

foreach ($org in $uniqueOrgs) {
    if ($existingRecords.Contains($org.Id)) {
        $skipped++
        continue
    }

    $body = @{
        $colName                 = $org.Name
        $colDescription          = $org.Description
        $colOrganizationId       = $org.Id
        $colParentOrganizationId = $org.ParentOrganizationId
        $colHasChildren          = $org.HasChildren
    } | ConvertTo-Json

    try {
        $null = Invoke-RestMethod `
            -Uri "$dataverseUrl/api/data/v9.2/${dataverseTable}s" `
            -Method POST -Headers $dvHeaders -Body $body
        $created++
    }
    catch {
        Write-Warning "Failed to create record for org '$($org.Name)' (ID: $($org.Id)): $($_.Exception.Message)"
    }
}

Write-Output "Done. Created: $created | Skipped (already exist): $skipped"
